#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path


def default_workers():
    """
    计算默认并发数。
    策略：使用 (CPU核心数 - 1)，保留一个核心给系统，避免卡顿。
    最少保留 1 个 Worker。
    """
    count = os.cpu_count() or 1
    return max(count - 1, 1)


def find_c_files(root_dir):
    """
    递归扫描指定目录下的所有 .c 文件。
    返回绝对路径列表，并排序以保证处理顺序的可复现性。
    """
    root = Path(root_dir)
    files = []
    for path in root.rglob("*.c"):
        if path.is_file():
            files.append(str(path.resolve()))
    files.sort()
    return files


def parse_one_file(args):
    """
    [单文件模式] Worker 任务函数。
    调用底层 C 解析器处理单个文件。
    用于调试或非批处理模式。
    """
    parser_bin, path = args
    try:
        # 调用 C 二进制: cfc_parser <file_path>
        result = subprocess.run(
            [parser_bin, path],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        return (path, [], f"spawn failed: {exc}")

    err = None
    if result.returncode != 0:
        err = result.stderr.strip() or f"exit code {result.returncode}"

    # C 解析器直接输出 JSON 数组: ["func1", "func2"]
    output = result.stdout.strip() or "[]"
    try:
        names = json.loads(output)
        if not isinstance(names, list):
            raise ValueError("output is not a list")
    except Exception as exc:
        return (path, [], f"invalid output: {exc}")

    return (path, names, err)


def parse_batch_files(args):
    """
    [批处理模式] Worker 任务函数。
    一次性将多个文件路径传递给 C 解析器，极大减少进程创建开销。
    """
    parser_bin, paths = args
    # 构造命令: cfc_parser --batch file1 file2 file3 ...
    cmd = [parser_bin, "--batch", *paths]
    try:
        result = subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        # 如果启动失败，所有文件都标记为失败
        return [(path, [], f"spawn failed: {exc}") for path in paths]

    output_map = {}
    parse_error = None
    
    # 解析 C 程序的输出
    # 在 --batch 模式下，C 程序每处理完一个文件会打印一行 JSON 对象:
    # {"path": "...", "fc": [...]}
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError("record is not an object")
            record_path = record.get("path")
            record_fc = record.get("fc")
            if not isinstance(record_path, str) or not isinstance(record_fc, list):
                raise ValueError("invalid record fields")
            output_map[record_path] = record_fc
        except Exception as exc:
            parse_error = f"invalid batch output: {exc}"
            break

    # 整理结果，确保输入的每个 path 都有对应的输出或错误信息
    results = []
    stderr_message = result.stderr.strip()
    for path in paths:
        err = None
        if parse_error:
            err = parse_error
        elif path not in output_map:
            err = "missing batch output" # C 程序可能崩溃或未输出该文件结果
        
        # 附加全局的 stderr 信息（如果有）
        if stderr_message:
            err = stderr_message if not err else f"{err}; {stderr_message}"
        
        results.append((path, output_map.get(path, []), err))

    return results


def chunk_list(items, size):
    """
    辅助函数：将列表分割成指定大小的块。
    """
    for i in range(0, len(items), size):
        yield items[i : i + size]


def ensure_parent(path):
    """
    辅助函数：确保文件的父目录存在。
    """
    parent = Path(path).resolve().parent
    parent.mkdir(parents=True, exist_ok=True)


def resolve_parser_binary(script_path):
    """
    智能查找 C 解析器二进制文件 (cfc_parser) 的位置。
    查找顺序：
    1. 环境变量 PARSERCFC_PARSER
    2. build/cfc_parser (开发环境)
    3. 与脚本同级 (安装环境)
    4. PATH 中的 cfc_parser
    """
    override = os.environ.get("PARSERCFC_PARSER")
    if override:
        return str(Path(override).expanduser().resolve())

    # 判断脚本位置，适配 bin/ 或 src/ 目录结构
    if script_path.parent.name in ("bin", "src"):
        root_dir = script_path.parent.parent
    else:
        root_dir = script_path.parent

    # 检查 build 目录 (源码编译运行)
    candidate = (root_dir / "build" / "cfc_parser").resolve()
    if candidate.exists():
        return str(candidate)

    # 检查同级目录 (make install 后)
    sibling = (script_path.parent / "cfc_parser").resolve()
    if sibling.exists():
        return str(sibling)

    # 默认尝试系统 PATH
    return "cfc_parser"


def main():
    default_w = default_workers()
    parser = argparse.ArgumentParser(
        prog="parsercfc",
        usage="parsercfc [-h] [-w WORKERS] [-o-fc OUTPUT_FC] [-o-null_fc OUTPUT_NULL_FC] dir",
        description=(
            "C语言函数名提取工具。\n"
            "扫描指定目录下的所有.c文件，提取函数定义。\n"
            "结果输出到 fc.json (有函数) 和 null_fc.json (无函数)。"
        ),
    )
    parser.add_argument("dir", help="[必选] 要解析的源代码目录路径")
    parser.add_argument(
        "-w",
        "--workers",
        type=int,
        default=default_w,
        help=f"使用的进程数 (默认为 CPU核心数-1: {default_w})",
    )
    parser.add_argument(
        "-o-fc",
        dest="output_fc",
        default="fc.json",
        help="fc.json 的生成路径 (默认: 当前目录下 fc.json)",
    )
    parser.add_argument(
        "-o-null_fc",
        dest="output_null_fc",
        default="null_fc.json",
        help="null_fc.json 的生成路径 (默认: 当前目录下 null_fc.json)",
    )

    args = parser.parse_args()

    workers = args.workers if args.workers > 0 else 1
    target_dir = Path(args.dir).resolve()
    if not target_dir.exists():
        print(f"error: dir not found: {target_dir}", file=sys.stderr)
        return 2

    # 1. 查找解析器二进制
    parser_bin = resolve_parser_binary(Path(__file__).resolve())
    
    # 2. 扫描文件列表
    files = find_c_files(target_dir)
    total_files = len(files)

    print(f"Scan dir: {target_dir}")
    print(f"Workers: {workers}")
    print(f"Found {total_files} .c files")
    print(f"Output fc.json: {args.output_fc}")
    print(f"Output null_fc.json: {args.output_null_fc}")

    results = {}
    null_files = []
    errors = []

    # 处理空目录情况
    if total_files == 0:
        ensure_parent(args.output_fc)
        ensure_parent(args.output_null_fc)
        with open(args.output_fc, "w", encoding="utf-8") as fc_fp:
            json.dump(results, fc_fp, ensure_ascii=True, indent=2, sort_keys=True)
        with open(args.output_null_fc, "w", encoding="utf-8") as null_fp:
            json.dump(null_files, null_fp, ensure_ascii=True, indent=2)
        print("No .c files found, outputs created.")
        return 0

    start_time = time.time()
    report_every = max(1, total_files // 20)
    processed = 0

    # 3. 计算批处理大小 (Batch Size)
    # 允许通过环境变量覆盖，否则根据文件数和 Worker 数自动计算
    env_batch = int(os.environ.get("PARSERCFC_BATCH_SIZE", "0") or 0)
    if env_batch > 0:
        batch_size = env_batch
    else:
        # 自动计算：试图让每个 Worker 至少跑 4 轮，同时限制每批最大 100 个文件
        auto = max(1, total_files // (workers * 4)) if workers > 0 else 1
        batch_size = max(1, min(100, auto))

    # 4. 启动多进程池
    with ProcessPoolExecutor(max_workers=workers) as executor:
        if batch_size <= 1:
            # 单文件模式 (兼容旧逻辑或调试用)
            futures = {
                executor.submit(parse_one_file, (parser_bin, path)): 1
                for path in files
            }
        else:
            # 批处理模式 (性能最优)
            chunks = list(chunk_list(files, batch_size))
            futures = {
                executor.submit(parse_batch_files, (parser_bin, chunk)): len(chunk)
                for chunk in chunks
            }

        # 5. 处理结果
        for future in as_completed(futures):
            result = future.result()
            
            # 统一处理单文件和批处理的返回格式
            if batch_size <= 1:
                # 单文件返回: (path, names, err)
                file_path, names, err = result
                results[file_path] = {"fc": names}
                if not names:
                    null_files.append(file_path)
                if err:
                    errors.append((file_path, err))
                processed += 1
            else:
                # 批处理返回: list of (path, names, err)
                for file_path, names, err in result:
                    results[file_path] = {"fc": names}
                    if not names:
                        null_files.append(file_path)
                    if err:
                        errors.append((file_path, err))
                processed += futures[future]

            # 打印进度条
            if processed % report_every == 0 or processed == total_files:
                percent = (processed / total_files) * 100.0
                elapsed = time.time() - start_time
                print(f"[{processed}/{total_files}] {percent:.1f}% elapsed {elapsed:.1f}s")

    # 6. 统计与写入输出
    total_functions = sum(len(v["fc"]) for v in results.values())
    elapsed = time.time() - start_time

    # 按路径字母顺序排序，保证输出文件可读性和确定性
    ordered_results = {key: results[key] for key in sorted(results)}
    null_files_sorted = sorted(null_files)

    ensure_parent(args.output_fc)
    ensure_parent(args.output_null_fc)
    
    with open(args.output_fc, "w", encoding="utf-8") as fc_fp:
        json.dump(ordered_results, fc_fp, ensure_ascii=True, indent=2)
    with open(args.output_null_fc, "w", encoding="utf-8") as null_fp:
        json.dump(null_files_sorted, null_fp, ensure_ascii=True, indent=2)

    print("Done.")
    print(f"Elapsed: {elapsed:.2f}s")
    print(f"Total files: {total_files}")
    print(f"Total functions: {total_functions}")
    print(f"Files with no functions: {len(null_files)}")
    if errors:
        print(f"Parser errors: {len(errors)}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())

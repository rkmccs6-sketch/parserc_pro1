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
    count = os.cpu_count() or 1
    return max(count - 1, 1)


def find_c_files(root_dir):
    root = Path(root_dir)
    files = []
    for path in root.rglob("*.c"):
        if path.is_file():
            files.append(str(path.resolve()))
    files.sort()
    return files


def parse_one_file(args):
    parser_bin, path = args
    try:
        result = subprocess.run(
            [parser_bin, path],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        return (path, [], f"spawn failed: {exc}")

    if result.returncode != 0:
        err = result.stderr.strip() or f"exit code {result.returncode}"
        return (path, [], err)

    output = result.stdout.strip() or "[]"
    try:
        names = json.loads(output)
        if not isinstance(names, list):
            raise ValueError("output is not a list")
    except Exception as exc:
        return (path, [], f"invalid output: {exc}")

    return (path, names, None)


def parse_batch_files(args):
    parser_bin, paths = args
    cmd = [parser_bin, "--batch", *paths]
    try:
        result = subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        return [(path, [], f"spawn failed: {exc}") for path in paths]

    output_map = {}
    parse_error = None
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

    results = []
    stderr_message = result.stderr.strip()
    for path in paths:
        err = None
        if parse_error:
            err = parse_error
        elif path not in output_map:
            err = "missing batch output"
        if stderr_message:
            err = stderr_message if not err else f"{err}; {stderr_message}"
        results.append((path, output_map.get(path, []), err))

    return results


def chunk_list(items, size):
    for i in range(0, len(items), size):
        yield items[i : i + size]


def ensure_parent(path):
    parent = Path(path).resolve().parent
    parent.mkdir(parents=True, exist_ok=True)


def resolve_parser_binary(script_path):
    override = os.environ.get("PARSERCFC_PARSER")
    if override:
        return str(Path(override).expanduser().resolve())

    if script_path.parent.name in ("bin", "src"):
        root_dir = script_path.parent.parent
    else:
        root_dir = script_path.parent

    candidate = (root_dir / "build" / "cfc_parser").resolve()
    if candidate.exists():
        return str(candidate)

    sibling = (script_path.parent / "cfc_parser").resolve()
    if sibling.exists():
        return str(sibling)

    return "cfc_parser"


def main():
    default_w = default_workers()
    parser = argparse.ArgumentParser(
        prog="parsercfc",
        usage="parsercfc [-h] [-w WORKERS] [-o-fc OUTPUT_FC] [-o-null_fc OUTPUT_NULL_FC] dir",
        description=(
            "获取指定文件夹路径下的所有.c文件定义的函数名，将每个.c文件中定义的函数声明保存到fc.json，"
            "没有C语言函数定义的.c文件路径保存到null_fc.json"
        ),
    )
    parser.add_argument("dir", help="[必选] 要解析的源代码目录路径")
    parser.add_argument(
        "-w",
        "--workers",
        type=int,
        default=default_w,
        help=f"使用的线程数 (默认为 CPU核心数-1: {default_w})",
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

    parser_bin = resolve_parser_binary(Path(__file__).resolve())
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

    env_batch = int(os.environ.get("PARSERCFC_BATCH_SIZE", "0") or 0)
    if env_batch > 0:
        batch_size = env_batch
    else:
        auto = max(1, total_files // (workers * 4)) if workers > 0 else 1
        batch_size = max(1, min(100, auto))

    with ProcessPoolExecutor(max_workers=workers) as executor:
        if batch_size <= 1:
            futures = {
                executor.submit(parse_one_file, (parser_bin, path)): 1
                for path in files
            }
        else:
            chunks = list(chunk_list(files, batch_size))
            futures = {
                executor.submit(parse_batch_files, (parser_bin, chunk)): len(chunk)
                for chunk in chunks
            }

        for future in as_completed(futures):
            result = future.result()
            if batch_size <= 1:
                file_path, names, err = result
                results[file_path] = {"fc": names}
                if not names:
                    null_files.append(file_path)
                if err:
                    errors.append((file_path, err))
                processed += 1
            else:
                for file_path, names, err in result:
                    results[file_path] = {"fc": names}
                    if not names:
                        null_files.append(file_path)
                    if err:
                        errors.append((file_path, err))
                processed += futures[future]

            if processed % report_every == 0 or processed == total_files:
                percent = (processed / total_files) * 100.0
                elapsed = time.time() - start_time
                print(f"[{processed}/{total_files}] {percent:.1f}% elapsed {elapsed:.1f}s")

    total_functions = sum(len(v["fc"]) for v in results.values())
    elapsed = time.time() - start_time

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

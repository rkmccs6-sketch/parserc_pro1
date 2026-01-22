# 第1章 总体介绍
## 1.1 项目简介
parsercfc 是一款运行在 Linux 环境下的 C 语言函数解析工具。它面向“批量解析目录中
所有 .c 文件并提取函数定义”的需求，自动递归扫描指定目录，将每个 .c 文件内的函数名
列表输出到 fc.json，同时将没有函数定义的 .c 文件路径输出到 null_fc.json。

项目采用 Flex/Bison 构建词法与语法解析器，以 C 实现高性能解析核心，再由 Python
进行多进程调度、批量解析（方案 A）、结果汇总与输出。核心特点包括：
- 面向真实工程源码，兼容可编译的 C 语法风格
- 多进程并发 + 批处理，充分利用硬件资源
- 输出路径有序（升序），函数名列表保持源码定义顺序
- 支持一键安装与卸载（make / make clean）

## 1.2 功能概览
1. 递归扫描目录中的所有 .c 文件
2. 提取函数定义（非声明）并保留定义顺序
3. 输出 fc.json 与 null_fc.json
4. 运行信息输出：进度、耗时、文件数、函数数、空函数文件数
5. 支持多进程并发与批量解析（方案 A）

## 1.3 技术栈
- Flex：词法分析（注释、标识符、关键字、括号、块等）
- Bison：语法驱动（函数定义识别的 Token 流处理）
- C：高性能解析器核心
- Python：多进程调度、批处理、宏解析与结果汇总
- Makefile：编译、安装、清理

## 1.4 目录结构与文件职责
```
.
├─ Makefile                # 构建、安装、清理
├─ README.md               # 项目说明（本文件）
├─ src/
│  ├─ lexer.l               # Flex 词法规则
│  ├─ parser.y              # Bison 语法规则
│  ├─ cfc_parser.c          # C 解析器主体
│  └─ parsercfc.py          # Python 调度与输出
├─ doc/
│  ├─ Requirement Analysis.md  # 需求分析
│  └─ plan.md               # 计划与约束
├─ test/
│  ├─ in/                   # 待解析工程目录（如 FFmpeg）
│  └─ out/                  # 输出与日志
└─ .gitignore               # 忽略规则
```

# 第2章 技术实现
## 2.1 词法分析（src/lexer.l）
使用 Flex 定义 C 语言相关 Token：
- 识别关键字、标识符、常量、字符串/字符常量
- 跳过注释与预处理指令
- 捕获代码块，遇到完整 "{}" 块输出 BLOCK
该阶段将复杂源码简化为可解析的 Token 流，提高后续解析效率。

## 2.2 语法驱动（src/parser.y）
使用 Bison 构建“Token 流驱动”的轻量解析：
- 不做完整 C 语法树，仅关注函数定义形态
- 识别到函数头 + BLOCK 组合时记录函数名
- 允许不规范格式，只要可编译即可识别

## 2.3 解析核心（src/cfc_parser.c）
核心职责：
1. 读取单文件并调用 Flex/Bison 解析
2. 记录函数名（保留定义顺序）
3. 支持批量模式：`--batch file1 file2 ...`
4. 输出 JSON（单文件输出数组，批量输出逐行 JSON）

## 2.4 并发与批处理（src/parsercfc.py）
Python 负责：
- 递归查找 .c 文件
- 使用 `ProcessPoolExecutor` 并发解析
- 批量调用 `cfc_parser --batch`（方案 A）
- 生成 fc.json / null_fc.json 并打印统计信息

### 2.4.1 批量模式（方案 A）
将“每文件一次启动解析器”改为“批量启动解析器”，显著减少进程启动开销：
- 默认自动分批（可通过 `PARSERCFC_BATCH_SIZE` 控制）
- 每批由一个子进程解析多文件

### 2.4.2 宏解析与顺序修复
为保证函数顺序与宏生成函数的准确性，Python 会：
- 扫描 `#define` 宏并处理 `##` 拼接
- 识别宏生成的函数名（如 `DEFINE_OPT_SHOW_SECTION`、`ARRAY_RENAME`、`FUN`）
- 合并 C 解析器结果与宏结果
- 最终顺序与源码定义顺序一致

## 2.5 构建与安装（Makefile）
- `make`：编译并安装工具到系统路径
- `make clean`：卸载并清理构建产物
- 支持 `PREFIX` 指定安装前缀

# 第3章 安装、使用与输出格式
## 3.1 安装与卸载
默认安装到 `/usr/local/bin`：
```bash
make
```

安装到自定义目录：
```bash
make PREFIX=$HOME/.local
```

卸载并清理：
```bash
make clean
```

## 3.2 使用方式
```bash
parsercfc -h
parsercfc -w 4 -o-fc /path/to/fc.json -o-null_fc /path/to/null_fc.json /path/to/src
```

常用参数：
- `-w/--workers`：进程数，默认 CPU 核心数 - 1
- `-o-fc`：fc.json 输出路径
- `-o-null_fc`：null_fc.json 输出路径

环境变量：
- `PARSERCFC_BATCH_SIZE`：控制批量大小，设为 1 则退回单文件模式
- `PARSERCFC_PARSER`：手动指定解析器二进制路径

## 3.3 输出格式
### 3.3.1 fc.json
- **路径按字典序升序排列**
- **函数列表按源码定义顺序**
```json
{
  "/abs/path/a.c": { "fc": ["foo", "bar"] },
  "/abs/path/b.c": { "fc": [] }
}
```

### 3.3.2 null_fc.json
```json
[
  "/abs/path/b.c",
  "/abs/path/c.c"
]
```

# 第4章 测试与评估（以 FFmpeg 为例）
## 4.1 测试准备
将 FFmpeg 工程放入：
```
test/in/FFmpeg
```

执行：
```bash
parsercfc -w 4 -o-fc test/out/fc.json -o-null_fc test/out/null_fc.json test/in/FFmpeg
```

## 4.2 性能测试（不同参数对比）
### 4.2.1 单文件模式（关闭批量）
```bash
PARSERCFC_BATCH_SIZE=1 parsercfc -w 4 ...
```
示例耗时（本机）：
- real: 2.482s

### 4.2.2 批量模式（方案 A）
```bash
parsercfc -w 4 ...
```
示例耗时（本机）：
- real: 1.881s

> 注：性能受机器与负载影响，以上为示例结果。

## 4.3 解析准确性示例
### 4.3.1 ffprobe.c（宏展开）
- `DEFINE_OPT_SHOW_SECTION` 宏生成函数可正确识别
- 示例结果：`opt_show_chapters` 等函数被正确输出

### 4.3.2 math.c（宏 FUN）
- `FUN(fmin, ...)` 等宏生成函数被识别
- 输出顺序与源码一致：
  `fmin -> fmax -> fminf -> fmaxf -> fmodl -> scalbnl -> copysignl`

### 4.3.3 aacps_tablegen_template.c（宏重定义）
- `ARRAY_RENAME` 在 `#if/#else` 中被正确解析为 `write_float_*`
- 输出为：
  `write_float_3d_array`、`write_float_4d_array`、`main`

---
以上即方案 A 分支的完整使用说明与测试结论。

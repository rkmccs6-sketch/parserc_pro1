#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "utils.h" /* 引入工具库声明，如 parser_reset_state */

/* ========================================================================== */
/* 外部声明 (External Declarations)                                           */
/* ========================================================================== */

/* Bison 生成的解析入口 */
extern int yyparse(void);
/* Flex 的输入文件指针 */
extern FILE *yyin;
/* Flex 的输入流重置函数 */
extern void yyrestart(FILE *input_file);
/* Lexer 的状态重置函数 (定义在 lexer.l) */
extern void lexer_reset(void);

/* ========================================================================== */
/* 内部数据结构 (Internal Data Structures)                                    */
/* ========================================================================== */

/* * FunctionList: 简单的动态字符串数组
 * 用于在内存中暂存当前文件解析到的所有函数名
 */
typedef struct {
    char **items;    /* 字符串数组指针 */
    size_t count;    /* 当前元素个数 */
    size_t capacity; /* 当前分配的容量 */
} FunctionList;

/* 全局结果列表，用于收集 parser.y 回调的数据 */
static FunctionList g_functions;

/* ========================================================================== */
/* 列表管理函数 (List Management)                                             */
/* ========================================================================== */

/* 初始化列表 */
static void list_init(FunctionList *list) {
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

/* 释放列表内存 */
static void list_free(FunctionList *list) {
    size_t i = 0;
    for (i = 0; i < list->count; i++) {
        free(list->items[i]);
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

/* 向列表添加新函数名 */
static void list_add(FunctionList *list, const char *name) {
    size_t new_cap = 0;
    char *copy = NULL;

    if (!name) {
        return;
    }

    copy = strdup(name);
    if (!copy) {
        return; /* 内存分配失败，静默忽略 */
    }

    /* 动态扩容逻辑 */
    if (list->count == list->capacity) {
        new_cap = list->capacity == 0 ? 16 : list->capacity * 2;
        char **new_items = (char **)realloc(list->items, new_cap * sizeof(char *));
        if (!new_items) {
            free(copy);
            return;
        }
        list->items = new_items;
        list->capacity = new_cap;
    }

    list->items[list->count++] = copy;
}

/* * 核心回调函数：记录函数名
 * 由 utils.c 中的 check_and_record 调用
 */
void record_function(const char *name) {
    list_add(&g_functions, name);
}

/* ========================================================================== */
/* JSON 输出工具 (JSON Output Utilities)                                      */
/* ========================================================================== */

/* * JSON 字符串转义
 * 将 C 字符串中的特殊字符转换为 JSON 安全的转义序列 (e.g. \n -> \\n)
 */
static void json_escape_and_print(const char *s) {
    const unsigned char *p = (const unsigned char *)s;
    putchar('"'); /* 开始引号 */
    while (*p) {
        unsigned char c = *p++;
        switch (c) {
        case '\\': fputs("\\\\", stdout); break;
        case '"':  fputs("\\\"", stdout); break;
        case '\b': fputs("\\b", stdout); break;
        case '\f': fputs("\\f", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (c < 0x20) {
                /* 控制字符转为 Unicode 编码 */
                fprintf(stdout, "\\u%04x", c);
            } else {
                fputc(c, stdout);
            }
            break;
        }
    }
    putchar('"'); /* 结束引号 */
}

/* 打印字符串数组为 JSON 列表: ["func1", "func2"] */
static void print_json_array(const FunctionList *list, int newline) {
    size_t i = 0;
    putchar('[');
    for (i = 0; i < list->count; i++) {
        if (i > 0) {
            putchar(',');
        }
        json_escape_and_print(list->items[i]);
    }
    putchar(']');
    if (newline) {
        putchar('\n');
    }
}

/* 打印完整的批处理记录: {"path": "/a/b.c", "fc": [...]} */
static void print_json_record(const char *path, const FunctionList *list) {
    fputs("{\"path\":", stdout);
    json_escape_and_print(path);
    fputs(",\"fc\":", stdout);
    print_json_array(list, 0);
    putchar('}');
    putchar('\n'); /* 批处理模式下每行一个 JSON 对象 */
}

/* ========================================================================== */
/* 解析驱动逻辑 (Parsing Driver)                                              */
/* ========================================================================== */

/* * 解析单个文件
 * path: 文件路径
 * batch_mode: 是否为批处理模式（决定输出格式）
 * 返回值: 0 成功, 非0 失败
 */
static int parse_file(const char *path, int batch_mode) {
    int rc = 0;

    /* 1. 清理上一轮的结果 */
    list_free(&g_functions);
    list_init(&g_functions);

    /* 2. 打开文件 */
    yyin = fopen(path, "r");
    if (!yyin) {
        fprintf(stderr, "error: cannot open file: %s\n", path);
        /* 即使打开失败，也输出一个空结果，保持批处理流程不断 */
        if (batch_mode) {
            print_json_record(path, &g_functions);
        } else {
            print_json_array(&g_functions, 1);
        }
        return 2;
    }

    /* 3. 重置 Lexer/Parser 状态 (关键：防止宏定义跨文件污染) */
    lexer_reset();
    parser_reset_state();
    yyrestart(yyin);

    /* 4. 执行解析 */
    if (yyparse() != 0) {
        rc = 1; /* 解析过程中有语法错误 */
    }

    /* 5. 关闭文件 */
    fclose(yyin);

    /* 6. 输出结果 */
    if (batch_mode) {
        print_json_record(path, &g_functions);
    } else {
        print_json_array(&g_functions, 1);
    }

    return rc;
}

/* ========================================================================== */
/* 主函数 (Main)                                                              */
/* ========================================================================== */

int main(int argc, char **argv) {
    int batch_mode = 0;
    int start_idx = 1;
    int rc = 0;

    /* 初始化全局列表 */
    list_init(&g_functions);

    if (argc < 2) {
        fprintf(stderr, "usage: cfc_parser [--batch] <file.c> [file2.c ...]\n");
        return 2;
    }

    /* 检查命令行参数是否启用批处理模式 */
    if (strcmp(argv[1], "--batch") == 0) {
        batch_mode = 1;
        start_idx = 2;
    }

    if (start_idx >= argc) {
        fprintf(stderr, "usage: cfc_parser [--batch] <file.c> [file2.c ...]\n");
        return 2;
    }

    /* 遍历处理所有输入文件 */
    for (int i = start_idx; i < argc; i++) {
        int file_rc = parse_file(argv[i], batch_mode);
        if (file_rc != 0) {
            rc = file_rc; /* 只要有一个文件失败，最终返回值即为非0 */
        }
    }

    list_free(&g_functions);
    return rc;
}

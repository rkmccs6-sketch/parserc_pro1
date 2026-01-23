#ifndef UTILS_H
#define UTILS_H

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 在 parser.y 的 %union 中使用，必须公开定义 */
typedef struct ArgList {
    char **items;
    size_t count;
    size_t capacity;
} ArgList;

/* 外部函数声明 (定义在 cfc_parser.c 中) */
void record_function(const char *name);

/* 供 parser.y 和 lexer.l 调用的函数 */
void parser_reset_state(void);
void macro_register_definition(const char *line);
int macro_lookup_token(const char *name);

/* 列表操作工具函数 */
ArgList *arg_list_new(void);
void arg_list_add(ArgList *list, char *value);
void arg_list_free(ArgList *list);

/* 字符串操作工具函数 */
char *concat(const char *s1, const char *s2);
char *concat_with_space(const char *s1, const char *s2);
char *concat_with_array_prefix(const char *suffix);
void set_array_rename_prefix(const char *line);

/* 核心解析逻辑封装 */
void check_and_record(char *full_sig);
char *render_macro_name(const char *macro_name, const ArgList *args);
char *render_macro_expansion(const char *macro_name, const ArgList *args);

#endif /* UTILS_H */

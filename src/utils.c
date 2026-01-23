#include "utils.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* * 引入 Parser 生成的头文件，以获取 Token 枚举值 (如 MACRO_TEMPLATE)。
 * 放在此处全局包含，是为了避免在函数内部包含导致的 "unused variable" 警告。
 */
#include "parser.tab.h"

/* ========================================================================== */
/* 内部数据结构定义 (Internal Data Structures)                                */
/* ========================================================================== */

/* * NamePart: 宏展开模式中的一个片段
 * 它可以是普通文本，也可以是指向宏参数的引用
 */
typedef struct {
    char *text;   /* 文本内容 */
    int is_param; /* 标记：1表示这是一个参数引用，0表示普通文本 */
} NamePart;

/* * NamePartList: 宏展开模式片段列表
 * 用于存储解析后的宏体结构，例如 "prefix_" + param + "_suffix"
 */
typedef struct {
    NamePart *items;
    size_t count;
    size_t capacity;
} NamePartList;

/* * MacroDef: 宏定义描述符
 * 存储一个宏的完整信息，包括名称、参数表、以及两种展开模式
 */
typedef struct {
    char *name;         /* 宏名称 */
    char **params;      /* 参数名列表 */
    size_t param_count; /* 参数个数 */
    
    /* * name_parts: 用于生成函数名的模式 
     * 例如对于 #define TEST(x) void test_##x(void)
     * name_parts 将存储 "test_" + x
     */
    NamePartList *name_parts; 
    
    /* * expansion_parts: 用于普通替换的模式
     * 例如对于 #define FN(x) x
     * expansion_parts 将存储 x
     */
    NamePartList *expansion_parts; 
} MacroDef;

/* * MacroList: 全局宏定义列表
 * 简单的动态数组实现，用于符号表查找
 */
typedef struct {
    MacroDef *items;
    size_t count;
    size_t capacity;
} MacroList;

/* ========================================================================== */
/* 全局变量 (Global Variables)                                                */
/* ========================================================================== */

/* 全局宏符号表 */
static MacroList macro_list = {0};

/* 数组重命名宏的前缀，默认为 "write_float_" (针对 FFmpeg 特定场景) */
static char array_rename_prefix[64] = "write_float_";

/* ========================================================================== */
/* ArgList 实现 (Argument List Implementation)                                */
/* ========================================================================== */

/* 创建一个新的参数列表容器 */
ArgList *arg_list_new(void) {
    ArgList *list = (ArgList *)calloc(1, sizeof(ArgList));
    return list;
}

/* 向列表添加一个字符串参数，自动扩容 */
void arg_list_add(ArgList *list, char *value) {
    if (!list) {
        free(value);
        return;
    }
    if (list->count == list->capacity) {
        size_t new_cap = list->capacity == 0 ? 4 : list->capacity * 2;
        char **next = (char **)realloc(list->items, new_cap * sizeof(char *));
        if (!next) {
            free(value);
            return;
        }
        list->items = next;
        list->capacity = new_cap;
    }
    list->items[list->count++] = value;
}

/* 释放参数列表及其包含的所有字符串 */
void arg_list_free(ArgList *list) {
    if (!list) {
        return;
    }
    for (size_t i = 0; i < list->count; i++) {
        free(list->items[i]);
    }
    free(list->items);
    free(list);
}

/* ========================================================================== */
/* NamePartList 实现 (Internal Helper)                                        */
/* ========================================================================== */

static NamePartList *name_parts_new(void) {
    NamePartList *list = (NamePartList *)calloc(1, sizeof(NamePartList));
    return list;
}

static void name_parts_add(NamePartList *list, const char *text, int is_param) {
    if (!list || !text) {
        return;
    }
    if (list->count == list->capacity) {
        size_t new_cap = list->capacity == 0 ? 4 : list->capacity * 2;
        NamePart *next = (NamePart *)realloc(list->items, new_cap * sizeof(NamePart));
        if (!next) {
            return;
        }
        list->items = next;
        list->capacity = new_cap;
    }
    list->items[list->count].text = strdup(text);
    list->items[list->count].is_param = is_param;
    list->count++;
}

static void name_parts_append(NamePartList *dst, const NamePartList *src) {
    if (!dst || !src) {
        return;
    }
    for (size_t i = 0; i < src->count; i++) {
        name_parts_add(dst, src->items[i].text, src->items[i].is_param);
    }
}

static NamePartList *name_parts_clone(const NamePartList *src) {
    if (!src) {
        return NULL;
    }
    NamePartList *clone = name_parts_new();
    if (!clone) {
        return NULL;
    }
    name_parts_append(clone, src);
    return clone;
}

static void name_parts_free(NamePartList *list) {
    if (!list) {
        return;
    }
    for (size_t i = 0; i < list->count; i++) {
        free(list->items[i].text);
    }
    free(list->items);
    free(list);
}

/* ========================================================================== */
/* MacroDef 实现 (Macro Management)                                           */
/* ========================================================================== */

static void macro_free(MacroDef *macro) {
    if (!macro) {
        return;
    }
    free(macro->name);
    for (size_t i = 0; i < macro->param_count; i++) {
        free(macro->params[i]);
    }
    free(macro->params);
    name_parts_free(macro->name_parts);
    name_parts_free(macro->expansion_parts);
    
    /* 清零指针防止悬挂引用 */
    macro->name = NULL;
    macro->params = NULL;
    macro->param_count = 0;
    macro->name_parts = NULL;
    macro->expansion_parts = NULL;
}

/* 清空整个宏符号表 */
static void macro_list_reset(void) {
    for (size_t i = 0; i < macro_list.count; i++) {
        macro_free(&macro_list.items[i]);
    }
    free(macro_list.items);
    macro_list.items = NULL;
    macro_list.count = 0;
    macro_list.capacity = 0;
}

static void macro_list_add(MacroDef *macro) {
    if (!macro) {
        return;
    }
    if (macro_list.count == macro_list.capacity) {
        size_t new_cap = macro_list.capacity == 0 ? 8 : macro_list.capacity * 2;
        MacroDef *next = (MacroDef *)realloc(macro_list.items, new_cap * sizeof(MacroDef));
        if (!next) {
            macro_free(macro);
            return;
        }
        macro_list.items = next;
        macro_list.capacity = new_cap;
    }
    macro_list.items[macro_list.count++] = *macro;
}

/* 在符号表中查找宏定义 (线性搜索，后添加的优先) */
static MacroDef *macro_find(const char *name) {
    if (!name) {
        return NULL;
    }
    /* 倒序遍历，模拟作用域覆盖（虽然本项目目前是单层作用域） */
    for (size_t i = macro_list.count; i > 0; i--) {
        MacroDef *macro = &macro_list.items[i - 1];
        if (macro->name && strcmp(macro->name, name) == 0) {
            return macro;
        }
    }
    return NULL;
}

/* ========================================================================== */
/* 字符串工具函数 (String Utilities)                                          */
/* ========================================================================== */

/* 拼接两个字符串，返回新分配的内存 */
char *concat(const char *s1, const char *s2) {
    if (!s1) {
        return s2 ? strdup(s2) : NULL;
    }
    if (!s2) {
        return s1 ? strdup(s1) : NULL;
    }
    char *result = malloc(strlen(s1) + strlen(s2) + 1);
    if (!result) {
        return NULL;
    }
    strcpy(result, s1);
    strcat(result, s2);
    return result;
}

/* 拼接两个字符串，中间加一个空格 */
char *concat_with_space(const char *s1, const char *s2) {
    char *temp = concat(s1, " ");
    char *out = concat(temp, s2);
    free(temp);
    return out;
}

/* 解析 #define 行，提取 ARRAY_RENAME 宏的前缀设置
 * FFmpeg 中常用 ARRAY_RENAME(x) 来生成 write_float_x 函数
 */
void set_array_rename_prefix(const char *line) {
    if (!line) {
        return;
    }
    if (!strstr(line, "ARRAY_RENAME")) {
        return;
    }
    if (strstr(line, "write_float_")) {
        strcpy(array_rename_prefix, "write_float_");
    } else if (strstr(line, "write_int32_t_")) {
        strcpy(array_rename_prefix, "write_int32_t_");
    }
}

/* 辅助函数：将后缀与当前的 array_rename_prefix 拼接 */
char *concat_with_array_prefix(const char *suffix) {
    return concat(array_rename_prefix, suffix);
}

/* 检查字符串是否为 C 语言保留字 (防止误报为函数名) */
static int is_reserved_name(const char *name) {
    static const char *reserved[] = {
        "if", "else", "for", "while", "do", "switch", "case", "default",
        "break", "continue", "return", "goto", "sizeof",
    };
    size_t count = sizeof(reserved) / sizeof(reserved[0]);
    for (size_t i = 0; i < count; i++) {
        if (strcmp(name, reserved[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

/* 检查字符串是否为合法的 C 语言标识符 */
static int is_valid_identifier(const char *name) {
    if (!name || !name[0]) {
        return 0;
    }
    if (!(isalpha((unsigned char)name[0]) || name[0] == '_')) {
        return 0;
    }
    for (size_t i = 1; name[i]; i++) {
        if (!(isalnum((unsigned char)name[i]) || name[i] == '_')) {
            return 0;
        }
    }
    return 1;
}

/* 复制字符串片段 */
static char *dup_range(const char *start, const char *end) {
    size_t len = (size_t)(end - start);
    char *out = (char *)malloc(len + 1);
    if (!out) {
        return NULL;
    }
    memcpy(out, start, len);
    out[len] = '\0';
    return out;
}

/* 去除宏定义中的续行符 (\ + 换行)，合并为单行字符串 */
static char *strip_line_continuations(const char *text) {
    size_t len = strlen(text);
    char *out = (char *)malloc(len + 1);
    size_t i = 0;
    size_t j = 0;
    if (!out) {
        return NULL;
    }
    while (i < len) {
        if (text[i] == '\\') {
            /* 处理 \n */
            if (i + 1 < len && text[i + 1] == '\n') {
                i += 2;
                continue;
            }
            /* 处理 \r\n (Windows) */
            if (i + 2 < len && text[i + 1] == '\r' && text[i + 2] == '\n') {
                i += 3;
                continue;
            }
        }
        out[j++] = text[i++];
    }
    out[j] = '\0';
    return out;
}

/* ========================================================================== */
/* 宏内容解析 (Micro Tokenizer for Macro Bodies)                              */
/* ========================================================================== */

typedef enum {
    MACRO_TOK_EOF = 0,
    MACRO_TOK_IDENT,
    MACRO_TOK_PASTE,    /* ## 连接符 */
    MACRO_TOK_LPAREN,
    MACRO_TOK_RPAREN,
    MACRO_TOK_LBRACKET,
    MACRO_TOK_RBRACKET,
    MACRO_TOK_LBRACE,
    MACRO_TOK_RBRACE,
    MACRO_TOK_COMMA,
    MACRO_TOK_SEMI,
    MACRO_TOK_ASSIGN,
    MACRO_TOK_OTHER,
} MacroTok;

/* 简单的词法分析器，用于解析宏定义体内的 Token */
static MacroTok macro_next_token(const char *text, size_t *idx, char **ident_out) {
    size_t i = *idx;
    if (ident_out) {
        *ident_out = NULL;
    }
    while (text[i]) {
        unsigned char c = (unsigned char)text[i];
        if (isspace(c)) {
            i++;
            continue;
        }
        /* 跳过 // 注释 */
        if (c == '/' && text[i + 1] == '/') {
            i = i + 2;
            while (text[i] && text[i] != '\n') {
                i++;
            }
            continue;
        }
        /* 跳过 / * ... * / 注释 */
        if (c == '/' && text[i + 1] == '*') {
            i = i + 2;
            while (text[i] && !(text[i] == '*' && text[i + 1] == '/')) {
                i++;
            }
            if (text[i]) {
                i += 2;
            }
            continue;
        }
        /* 跳过字符串和字符常量 */
        if (c == '"' || c == '\'') {
            unsigned char quote = c;
            i++;
            while (text[i]) {
                if (text[i] == '\\') {
                    i += 2;
                    continue;
                }
                if ((unsigned char)text[i] == quote) {
                    i++;
                    break;
                }
                i++;
            }
            continue;
        }
        /* 识别连接符 ## */
        if (c == '#' && text[i + 1] == '#') {
            i += 2;
            *idx = i;
            return MACRO_TOK_PASTE;
        }
        /* 识别标识符 */
        if (isalpha(c) || c == '_') {
            size_t start = i;
            i++;
            while (text[i]) {
                unsigned char cc = (unsigned char)text[i];
                if (!(isalnum(cc) || cc == '_')) {
                    break;
                }
                i++;
            }
            if (ident_out) {
                *ident_out = dup_range(text + start, text + i);
            }
            *idx = i;
            return MACRO_TOK_IDENT;
        }
        /* 识别数字 (视为标识符处理，简化逻辑) */
        if (isdigit(c)) {
            size_t start = i;
            i++;
            while (text[i]) {
                unsigned char cc = (unsigned char)text[i];
                if (!(isalnum(cc) || cc == '_')) {
                    break;
                }
                i++;
            }
            if (ident_out) {
                *ident_out = dup_range(text + start, text + i);
            }
            *idx = i;
            return MACRO_TOK_IDENT;
        }
        /* 识别符号 */
        i++;
        *idx = i;
        switch (c) {
        case '(': return MACRO_TOK_LPAREN;
        case ')': return MACRO_TOK_RPAREN;
        case '[': return MACRO_TOK_LBRACKET;
        case ']': return MACRO_TOK_RBRACKET;
        case '{': return MACRO_TOK_LBRACE;
        case '}': return MACRO_TOK_RBRACE;
        case ',': return MACRO_TOK_COMMA;
        case ';': return MACRO_TOK_SEMI;
        case '=': return MACRO_TOK_ASSIGN;
        default:  return MACRO_TOK_OTHER;
        }
    }
    *idx = i;
    return MACRO_TOK_EOF;
}

/* 辅助函数：根据标识符创建 NamePartList */
static NamePartList *name_parts_from_ident(const char *ident, char **params, size_t param_count) {
    NamePartList *list = name_parts_new();
    if (!list) {
        return NULL;
    }
    int is_param = 0;
    /* 检查该标识符是否为宏参数名 */
    for (size_t i = 0; i < param_count; i++) {
        if (strcmp(params[i], ident) == 0) {
            is_param = 1;
            break;
        }
    }
    name_parts_add(list, ident, is_param);
    return list;
}

/* * 核心逻辑：从宏定义体中提取函数名模板
 * 适用于: #define DEF_FUNC(x) void prefix_##x##_suffix(void) { ... }
 * 目标是提取出: prefix_ + x + _suffix
 */
static NamePartList *extract_function_name_template(const char *body, char **params, size_t param_count) {
    size_t idx = 0;
    NamePartList *last_parts = NULL;
    NamePartList *paren_candidate = NULL;
    NamePartList *pending_parts = NULL;
    int pending_paste = 0;
    int paren_depth = 0;
    int bracket_depth = 0;

    while (1) {
        char *ident = NULL;
        MacroTok tok = macro_next_token(body, &idx, &ident);
        if (tok == MACRO_TOK_EOF) {
            break;
        }
        if (tok == MACRO_TOK_PASTE) {
            pending_paste = last_parts != NULL;
            continue;
        }
        if (tok == MACRO_TOK_IDENT) {
            NamePartList *parts = name_parts_from_ident(ident, params, param_count);
            free(ident);
            /* 如果前一个 Token 是 ##，则合并 */
            if (pending_paste && last_parts) {
                name_parts_append(last_parts, parts);
                name_parts_free(parts);
            } else {
                name_parts_free(last_parts);
                last_parts = parts;
            }
            pending_paste = 0;
            continue;
        }
        pending_paste = 0;
        
        /* 简单的括号平衡跟踪，试图找到最像函数声明的部分 */
        switch (tok) {
        case MACRO_TOK_LPAREN:
            if (paren_depth == 0 && !pending_parts) {
                name_parts_free(paren_candidate);
                paren_candidate = name_parts_clone(last_parts);
            }
            paren_depth++;
            break;
        case MACRO_TOK_RPAREN:
            if (paren_depth > 0) {
                paren_depth--;
                if (paren_depth == 0 && !pending_parts && paren_candidate) {
                    pending_parts = paren_candidate;
                    paren_candidate = NULL;
                }
            }
            break;
        case MACRO_TOK_LBRACKET:
            bracket_depth++;
            break;
        case MACRO_TOK_RBRACKET:
            if (bracket_depth > 0) {
                bracket_depth--;
            }
            break;
        case MACRO_TOK_LBRACE:
            /* 遇到 {，之前的 pending_parts 很可能就是函数名 */
            if (paren_depth == 0 && bracket_depth == 0 && pending_parts) {
                name_parts_free(last_parts);
                name_parts_free(paren_candidate);
                return pending_parts;
            }
            break;
        case MACRO_TOK_COMMA:
        case MACRO_TOK_SEMI:
        case MACRO_TOK_ASSIGN:
            if (paren_depth == 0 && bracket_depth == 0) {
                name_parts_free(last_parts);
                name_parts_free(paren_candidate);
                name_parts_free(pending_parts);
                last_parts = NULL;
                paren_candidate = NULL;
                pending_parts = NULL;
            }
            break;
        default:
            break;
        }
    }

    name_parts_free(last_parts);
    name_parts_free(paren_candidate);
    name_parts_free(pending_parts);
    return NULL;
}

/* * 核心逻辑：从宏定义体中提取普通展开模式
 * 适用于: #define FN(x) x
 */
static NamePartList *extract_macro_expansion_parts(const char *body, char **params, size_t param_count) {
    size_t idx = 0;
    NamePartList *parts = NULL;
    int pending_paste = 0;

    while (1) {
        char *ident = NULL;
        MacroTok tok = macro_next_token(body, &idx, &ident);
        if (tok == MACRO_TOK_EOF) {
            break;
        }
        if (tok == MACRO_TOK_PASTE) {
            pending_paste = 1;
            continue;
        }
        if (tok == MACRO_TOK_IDENT) {
            NamePartList *piece = name_parts_from_ident(ident, params, param_count);
            free(ident);
            if (!parts) {
                parts = piece;
            } else if (pending_paste) {
                name_parts_append(parts, piece);
                name_parts_free(piece);
            } else {
                /* 结构过于复杂，不适合作为简单展开 */
                name_parts_free(parts);
                name_parts_free(piece);
                return NULL;
            }
            pending_paste = 0;
            continue;
        }
        /* 遇到非标识符，停止解析 */
        name_parts_free(parts);
        return NULL;
    }
    if (pending_paste) {
        name_parts_free(parts);
        return NULL;
    }
    return parts;
}

/* * 解析 #define 行字符串，提取名称、参数列表和宏体
 */
static int parse_macro_definition_str(const char *line, char **name_out, char ***params_out, size_t *param_count, char **body_out) {
    const char *define_pos = strstr(line, "define");
    if (!define_pos) {
        return 0;
    }
    const char *p = define_pos + strlen("define");
    /* 跳过 define 后的空格 */
    while (*p && isspace((unsigned char)*p)) {
        p++;
    }
    if (!isalpha((unsigned char)*p) && *p != '_') {
        return 0;
    }
    /* 提取宏名称 */
    const char *name_start = p;
    while (*p && (isalnum((unsigned char)*p) || *p == '_')) {
        p++;
    }
    char *name = dup_range(name_start, p);
    if (!name) {
        return 0;
    }
    
    /* 检查是否为带参数的宏 ( 紧跟在名字后面，不能有空格 */
    /* 注意：ISO C 要求宏名和左括号之间不能有空格，但有些编译器宽松 */
    while (*p && isspace((unsigned char)*p)) {
        p++;
    }
    if (*p != '(') {
        free(name);
        return 0; /* 暂不支持无参宏作为函数生成器 */
    }
    p++;

    size_t cap = 0;
    size_t count = 0;
    char **params = NULL;

    /* 提取参数列表 */
    while (*p && *p != ')') {
        while (*p && isspace((unsigned char)*p)) {
            p++;
        }
        const char *param_start = p;
        while (*p && (isalnum((unsigned char)*p) || *p == '_')) {
            p++;
        }
        if (param_start != p) {
            char *param = dup_range(param_start, p);
            if (param) {
                if (count == cap) {
                    size_t new_cap = cap == 0 ? 4 : cap * 2;
                    char **next = (char **)realloc(params, new_cap * sizeof(char *));
                    if (!next) {
                        free(param);
                        break;
                    }
                    params = next;
                    cap = new_cap;
                }
                if (count < cap) {
                    params[count++] = param;
                } else {
                    free(param);
                }
            }
        }
        while (*p && isspace((unsigned char)*p)) {
            p++;
        }
        if (*p == ',') {
            p++;
            continue;
        }
        /* 跳过异常字符直到 , 或 ) */
        if (*p != ')') {
            while (*p && *p != ',' && *p != ')') {
                p++;
            }
        }
    }
    if (*p != ')') {
        /* 参数列表解析失败 */
        free(name);
        for (size_t i = 0; i < count; i++) {
            free(params[i]);
        }
        free(params);
        return 0;
    }
    p++;
    while (*p && isspace((unsigned char)*p)) {
        p++;
    }

    /* 提取宏体 */
    char *body = strip_line_continuations(p);
    if (!body) {
        free(name);
        for (size_t i = 0; i < count; i++) {
            free(params[i]);
        }
        free(params);
        return 0;
    }

    *name_out = name;
    *params_out = params;
    *param_count = count;
    *body_out = body;
    return 1;
}

/* * 外部接口：注册宏定义
 * 由 Lexer 扫描到 #define 时调用
 */
void macro_register_definition(const char *line) {
    char *name = NULL;
    char **params = NULL;
    size_t param_count = 0;
    char *body = NULL;
    
    /* 解析宏定义字符串 */
    if (!parse_macro_definition_str(line, &name, &params, &param_count, &body)) {
        return;
    }
    if (param_count == 0) {
        free(name);
        for (size_t i = 0; i < param_count; i++) {
            free(params[i]);
        }
        free(params);
        free(body);
        return;
    }
    
    /* 尝试提取两种模式：函数模板模式和普通展开模式 */
    NamePartList *name_parts = extract_function_name_template(body, params, param_count);
    NamePartList *expansion_parts = extract_macro_expansion_parts(body, params, param_count);
    free(body);
    
    /* 清理无效结果 */
    if (name_parts && name_parts->count == 0) {
        name_parts_free(name_parts);
        name_parts = NULL;
    }
    if (expansion_parts && expansion_parts->count == 0) {
        name_parts_free(expansion_parts);
        expansion_parts = NULL;
    }
    
    /* 创建并存储宏定义对象 */
    MacroDef macro = {0};
    macro.name = name;
    macro.params = params;
    macro.param_count = param_count;
    macro.name_parts = name_parts;
    macro.expansion_parts = expansion_parts;
    macro_list_add(&macro);
}

/* 辅助函数：根据参数名获取调用时的实参值 */
static const char *macro_arg_for_param(const MacroDef *macro, const ArgList *args, const char *param) {
    if (!macro || !args || !param) {
        return "";
    }
    for (size_t i = 0; i < macro->param_count; i++) {
        if (strcmp(macro->params[i], param) == 0) {
            if (i < args->count && args->items[i]) {
                return args->items[i];
            }
            return "";
        }
    }
    return "";
}

/* 辅助函数：根据模式和实参渲染结果字符串 */
static char *render_macro_parts(const MacroDef *macro, const ArgList *args, const NamePartList *parts) {
    if (!macro || !parts) {
        return NULL;
    }
    if (!args || args->count != macro->param_count) {
        return NULL;
    }
    size_t cap = 64;
    size_t len = 0;
    char *out = (char *)malloc(cap);
    if (!out) {
        return NULL;
    }
    out[0] = '\0';
    for (size_t i = 0; i < parts->count; i++) {
        NamePart *part = &parts->items[i];
        /* 如果是参数，用实参替换；否则保留原文本 */
        const char *text = part->is_param ? macro_arg_for_param(macro, args, part->text) : part->text;
        if (!text) {
            text = "";
        }
        size_t add = strlen(text);
        
        /* 动态扩容 */
        if (len + add + 1 > cap) {
            size_t new_cap = cap;
            while (len + add + 1 > new_cap) {
                new_cap *= 2;
            }
            char *next = (char *)realloc(out, new_cap);
            if (!next) {
                free(out);
                return NULL;
            }
            out = next;
            cap = new_cap;
        }
        memcpy(out + len, text, add);
        len += add;
        out[len] = '\0';
    }
    
    /* 结果校验 */
    if (!is_valid_identifier(out) || is_reserved_name(out)) {
        free(out);
        return NULL;
    }
    return out;
}

/* 外部接口：渲染函数模板宏 (如 DECLARE_FUNC) */
char *render_macro_name(const char *macro_name, const ArgList *args) {
    MacroDef *macro = macro_find(macro_name);
    return render_macro_parts(macro, args, macro ? macro->name_parts : NULL);
}

/* 外部接口：渲染普通展开宏 (如重命名宏) */
char *render_macro_expansion(const char *macro_name, const ArgList *args) {
    MacroDef *macro = macro_find(macro_name);
    return render_macro_parts(macro, args, macro ? macro->expansion_parts : NULL);
}

/* 辅助函数：去除字符串两端的空格，并压缩内部连续空格 */
static char *trim_spaces(const char *s) {
    size_t len = strlen(s);
    char *out = malloc(len + 1);
    size_t i = 0;
    size_t j = 0;
    int space_flag = 0;
    if (!out) {
        return NULL;
    }
    for (i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (isspace(c)) {
            if (!space_flag && j > 0) {
                out[j++] = ' ';
                space_flag = 1;
            }
        } else {
            out[j++] = (char)c;
            space_flag = 0;
        }
    }
    if (j > 0 && out[j - 1] == ' ') {
        j--;
    }
    out[j] = '\0';
    return out;
}

/* * 核心接口：校验函数签名并记录
 * 由 Parser 在匹配到 `signature BLOCK` 时调用
 * 负责清洗字符串、提取函数名、排除误报
 */
void check_and_record(char *full_sig) {
    if (!full_sig) {
        return;
    }

    char *clean = trim_spaces(full_sig);
    if (!clean) {
        return;
    }

    /* 寻找左括号，以此分割函数名和返回类型 */
    char *p = strchr(clean, '(');
    if (!p) {
        free(clean);
        return;
    }

    /* 从括号左侧开始回溯，找到函数名的结束和开始 */
    char *end = p - 1;
    while (end >= clean && isspace((unsigned char)*end)) {
        end--;
    }
    char *start = end;
    while (start >= clean && (isalnum((unsigned char)*start) || *start == '_')) {
        start--;
    }
    start++;

    if (start > end) {
        free(clean);
        return;
    }

    /* 过滤常见的控制流关键字 */
    size_t word_len = (size_t)(end - start + 1);
    if ((word_len == 2 && strncmp(start, "if", 2) == 0) ||
        (word_len == 3 && strncmp(start, "for", 3) == 0) ||
        (word_len == 5 && strncmp(start, "while", 5) == 0) ||
        (word_len == 6 && strncmp(start, "switch", 6) == 0) ||
        (word_len == 6 && strncmp(start, "return", 6) == 0) ||
        (word_len == 4 && strncmp(start, "else", 4) == 0)) {
        free(clean);
        return;
    }

    char *name = strndup(start, word_len);
    if (!name) {
        free(clean);
        return;
    }

    /* 调用 cfc_parser.c 中定义的记录函数 */
    record_function(name);
    free(name);
    free(clean);
}

/* * 核心接口：Lexer 调用此函数查询标识符属性
 * 决定一个 IDENTIFIER 是普通标识符，还是宏调用
 */
int macro_lookup_token(const char *name) {
    MacroDef *macro = macro_find(name);
    if (!macro) {
        return 0;
    }

    /* 根据宏的特性返回对应的 Token 类型 */
    if (macro->name_parts && macro->name_parts->count > 0) {
        return MACRO_TEMPLATE; /* 是函数模板宏 */
    }
    if (macro->expansion_parts && macro->expansion_parts->count > 0) {
        return MACRO_RENAME;   /* 是重命名宏 */
    }
    /* 硬编码处理 FFmpeg 的 fn() 宏 */
    if (strcmp(macro->name, "fn") == 0 || strcmp(macro->name, "FN") == 0) {
        return MACRO_RENAME;
    }
    return MACRO_CALL; /* 是普通宏调用 */
}

/* * 外部接口：重置解析器状态
 * 用于多文件批量解析时清理上下文
 */
void parser_reset_state(void) {
    macro_list_reset();
    strcpy(array_rename_prefix, "write_float_");
}

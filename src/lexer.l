%option noyywrap nounput noinput

%{
#include "parser.tab.h"
#include "utils.h"
#include <stdlib.h>
#include <string.h>

/* --- 全局状态变量 --- */

/* 用于记录花括号的嵌套深度，实现函数体跳过逻辑 */
static int brace_depth = 0;

/* 用于缓存跨行的预处理指令内容 */
static char *pp_buffer = NULL;
static size_t pp_buf_len = 0;

/* --- 辅助函数实现 --- */

/* 重置预处理缓冲区，准备接收新的宏定义 */
static void pp_reset(void) {
    free(pp_buffer);
    pp_buffer = NULL;
    pp_buf_len = 0;
}

/* 将文本追加到预处理缓冲区，处理多行宏定义 */
static void pp_append(const char *text) {
    size_t len = strlen(text);
    char *next = (char *)realloc(pp_buffer, pp_buf_len + len + 1);
    if (!next) {
        return;
    }
    memcpy(next + pp_buf_len, text, len);
    pp_buf_len += len;
    next[pp_buf_len] = '\0';
    pp_buffer = next;
}

/* 复制字符串到新内存，赋值给 yylval.str 供 Bison 使用 */
static char *dup_text(const char *text) {
    size_t len = strlen(text);
    char *out = (char *)malloc(len + 1);
    if (!out) {
        return NULL;
    }
    memcpy(out, text, len + 1);
    return out;
}
%}

/* --- 状态定义 (Start Conditions) --- */
/* BRACE: 进入函数体内部或代码块内部 */
/* BRACE_COMMENT: 代码块内部的块注释 */
/* BRACE_STRING: 代码块内部的字符串字面量 */
/* BRACE_CHAR: 代码块内部的字符常量 */
/* COMMENT: 全局层面的块注释 */
/* PREPROC: 普通预处理指令 */
/* PREPROC_DEFINE: #define 宏定义指令 */
%x BRACE BRACE_COMMENT BRACE_STRING BRACE_CHAR COMMENT PREPROC PREPROC_DEFINE

%%

    /* ====================================================================== */
    /* 1. 预处理指令处理 (Preprocessor Directives)                            */
    /* ====================================================================== */

    /* 匹配以反斜杠结尾的 #define 行（多行宏开始） */
^[ \t]*#[ \t]*define[^\n]*\\\n { 
    pp_reset(); 
    pp_append(yytext); 
    BEGIN(PREPROC_DEFINE); /* 进入多行宏定义状态 */
}

    /* 匹配单行 #define */
^[ \t]*#[ \t]*define[^\n]*\n {
    yylval.str = dup_text(yytext);
    if (yylval.str) {
        /* 注册宏定义，以便后续识别宏调用 */
        macro_register_definition(yylval.str);
    }
    return PP_DEFINE;
}

    /* 匹配其他以反斜杠结尾的预处理指令（忽略） */
^[ \t]*#[^\n]*\\\n    { BEGIN(PREPROC); }

    /* 匹配其他普通预处理指令（忽略） */
^[ \t]*#[^\n]*\n      { /* skip preprocessor line */ }

    /* --- PREPROC 状态：跳过续行的预处理指令 --- */
<PREPROC>.*\\\n       { /* skip continued preprocessor line */ }
<PREPROC>.*\n         { BEGIN(INITIAL); } /* 结束 */
<PREPROC><<EOF>>      { BEGIN(INITIAL); }

    /* --- PREPROC_DEFINE 状态：收集多行宏定义体 --- */
<PREPROC_DEFINE>.*\\\n { pp_append(yytext); /* 继续收集 */ }
<PREPROC_DEFINE>.*\n   {
    /* 最后一行，提交完整的宏定义字符串 */
    pp_append(yytext);
    yylval.str = pp_buffer;
    pp_buffer = NULL;
    pp_buf_len = 0;
    if (yylval.str) {
        macro_register_definition(yylval.str);
    }
    BEGIN(INITIAL);
    return PP_DEFINE;
}
<PREPROC_DEFINE><<EOF>> {
    /* 处理文件意外结束的情况 */
    if (pp_buffer) {
        yylval.str = pp_buffer;
        pp_buffer = NULL;
        pp_buf_len = 0;
        if (yylval.str) {
            macro_register_definition(yylval.str);
        }
        BEGIN(INITIAL);
        return PP_DEFINE;
    }
    BEGIN(INITIAL);
}

    /* ====================================================================== */
    /* 2. 空白与注释处理 (Whitespace & Comments)                              */
    /* ====================================================================== */

[ \t\r\n]+            { /* skip whitespace */ }
"//".* { /* skip line comment */ }

"/*"                  { BEGIN(COMMENT); }
<COMMENT>"*/"         { BEGIN(INITIAL); }
<COMMENT>.|\n         { /* skip comment content */ }

    /* ====================================================================== */
    /* 3. 函数体/代码块跳过逻辑 (Body Skipping - 核心优化)                    */
    /* ====================================================================== */

    /* 在 INITIAL 状态遇到左花括号，标志着函数体或结构体的开始 */
"{"                   { brace_depth = 1; BEGIN(BRACE); }

    /* BRACE 状态下的注释处理 */
<BRACE>"/*"           { BEGIN(BRACE_COMMENT); }
<BRACE>"//".* { /* skip line comment inside brace */ }
<BRACE_COMMENT>"*/"   { BEGIN(BRACE); }
<BRACE_COMMENT>.|\n   { /* skip */ }

    /* BRACE 状态下的字符串/字符处理（防止字符串里的 } 干扰深度计数） */
<BRACE>"\""           { BEGIN(BRACE_STRING); }
<BRACE>"'"            { BEGIN(BRACE_CHAR); }

<BRACE_STRING>\\(.)   { /* skip escaped char inside string */ }
<BRACE_STRING>"\""    { BEGIN(BRACE); }
<BRACE_STRING>.|\n    { /* skip content */ }

<BRACE_CHAR>\\(.)     { /* skip escaped char inside char const */ }
<BRACE_CHAR>"'"       { BEGIN(BRACE); }
<BRACE_CHAR>.|\n      { /* skip content */ }

    /* BRACE 状态下的深度计数 */
<BRACE>"{"            { brace_depth++; }
<BRACE>"}"            {
                          brace_depth--;
                          if (brace_depth == 0) {
                              /* 深度归零，说明跳过了完整的函数体 */
                              BEGIN(INITIAL);
                              return BLOCK; /* 返回一个占位符 Token */
                          }
                      }
<BRACE>[ \t\r\n]+      { /* skip whitespace inside brace */ }
<BRACE>.              { /* 忽略代码块内的所有其他内容 */ }

    /* ====================================================================== */
    /* 4. 关键字定义 (Keywords)                                               */
    /* ====================================================================== */

"typedef"             { return TYPEDEF; }
"ARRAY_RENAME"        { return ARRAY_RENAME; } /* FFmpeg 特有宏 */
"extern"              { return EXTERN; }
"static"              { return STATIC; }
"auto"                { return AUTO; }
"register"            { return REGISTER; }
"_Thread_local"       { return THREAD_LOCAL; }
"__thread"            { return THREAD_LOCAL; }

    /* 基本数据类型 */
"void"                { return VOID; }
"char"                { return CHAR; }
"short"               { return SHORT; }
"int"                 { return INT; }
"long"                { return LONG; }
"float"               { return FLOAT; }
"double"              { return DOUBLE; }
"signed"              { return SIGNED; }
"unsigned"            { return UNSIGNED; }
"_Bool"               { return BOOL; }
"_Complex"            { return COMPLEX; }
"_Imaginary"          { return IMAGINARY; }

    /* 聚合类型 */
"struct"              { return STRUCT; }
"union"               { return UNION; }
"enum"                { return ENUM; }

    /* 类型修饰符 */
"const"               { return CONST; }
"volatile"            { return VOLATILE; }
"restrict"            { return RESTRICT; }
"_Atomic"             { return ATOMIC; }
"__const"             { return CONST; }
"__volatile__"        { return VOLATILE; }
"__restrict"          { return RESTRICT; }
"__restrict__"        { return RESTRICT; }

    /* 函数修饰符 */
"inline"              { return INLINE; }
"__inline"            { return INLINE; }
"__inline__"          { return INLINE; }
"_Noreturn"           { return NORETURN; }

    /* 对齐与类型查询 */
"_Alignas"            { return ALIGNAS; }
"__alignas"           { return ALIGNAS; }
"__alignas__"         { return ALIGNAS; }
"typeof"              { return TYPEOF; }
"__typeof__"          { return TYPEOF; }

    /* 编译器扩展关键字 */
"__attribute__"       { return ATTRIBUTE; }
"__attribute"         { return ATTRIBUTE; }
"__declspec"          { return DECLSPEC; }
"__asm__"             { return ASM; }
"__asm"               { return ASM; }
"asm"                 { return ASM; }

"..."                 { return ELLIPSIS; }

    /* ====================================================================== */
    /* 5. 字面量 (Literals)                                                   */
    /* ====================================================================== */

\"([^\\\n]|(\\.))*\"  { yylval.str = dup_text(yytext); return STRING_LITERAL; }
\'([^\\\n]|(\\.))*\'  { yylval.str = dup_text(yytext); return CONSTANT; }

    /* 十六进制数字 */
0[xX][0-9a-fA-F]+[uUlL]* { yylval.str = dup_text(yytext); return CONSTANT; }
    /* 十进制/八进制数字 */
[0-9]+([uUlL]*|[uUlL]+)             { yylval.str = dup_text(yytext); return CONSTANT; }
    /* 浮点数 */
[0-9]+\\.[0-9]*([eE][+-]?[0-9]+)?[fFlL]* { yylval.str = dup_text(yytext); return CONSTANT; }
[0-9]*\\.[0-9]+([eE][+-]?[0-9]+)?[fFlL]* { yylval.str = dup_text(yytext); return CONSTANT; }

    /* ====================================================================== */
    /* 6. 标识符与宏查找 (Identifier & Macro Lookup)                          */
    /* ====================================================================== */

[a-zA-Z_][a-zA-Z0-9_]* {
    /* 核心逻辑：检查该标识符是否为已知宏 */
    int token = macro_lookup_token(yytext);
    if (token != 0) {
        /* 如果是特殊宏（如函数模板宏），返回对应的 Token */
        yylval.str = dup_text(yytext);
        return token;
    }
    /* 否则返回普通标识符 */
    yylval.str = dup_text(yytext);
    return IDENTIFIER;
}

    /* ====================================================================== */
    /* 7. 运算符与标点 (Operators & Punctuation)                              */
    /* ====================================================================== */

";"                  { return ';'; }
","                  { return ','; }
"*"                  { return '*'; }
"="                  { return '='; }
"("                  { return '('; }
")"                  { return ')'; }
"["                  { return '['; }
"]"                  { return ']'; }

    /* 兜底规则：返回其他单个字符 */
.                    { return OTHER; }

%%

/* --- 用户代码段 --- */

/* 重置 Lexer 状态，用于处理下一个文件 */
void lexer_reset(void) {
    brace_depth = 0;
    pp_reset();
    BEGIN(INITIAL);
}

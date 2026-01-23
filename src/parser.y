/* ========================================================================== */
/* C语言函数解析器 - Bison 语法定义文件                                       */
/* ========================================================================== */

%code requires {
    /* 引入工具库头文件，确保在生成的头文件中包含 ArgList 等类型定义 */
#include "utils.h"
}

%{
#include <stdio.h>
#include <stdlib.h>
#include "utils.h"

/* Flex生成的词法分析函数 */
int yylex(void);
/* 错误处理函数 */
void yyerror(const char *s);
%}

/* 定义语义值类型 (Semantic Values) */
%union {
    char *str;      /* 用于存储标识符、类型名、拼接后的签名字符串 */
    ArgList *args;  /* 用于存储宏调用的参数列表 */
}

/* ========================================================================== */
/* Token 定义                                                                 */
/* ========================================================================== */

/* 标识符与字面量 */
%token <str> IDENTIFIER
%token <str> CONSTANT STRING_LITERAL PP_DEFINE

/* 宏处理相关 Token (由 Lexer 动态识别) */
%token <str> MACRO_TEMPLATE  /* 类似函数定义的宏，如 DECLARE_FUNC(x) */
%token <str> MACRO_RENAME    /* 重命名宏，如 #define fn(x) x */
%token <str> MACRO_CALL      /* 普通宏调用 */
%token ARRAY_RENAME          /* 特定数组重命名宏 */

/* C语言关键字 */
%token TYPEDEF EXTERN STATIC AUTO REGISTER THREAD_LOCAL
%token VOID CHAR SHORT INT LONG FLOAT DOUBLE SIGNED UNSIGNED BOOL COMPLEX IMAGINARY
%token STRUCT UNION ENUM
%token CONST VOLATILE RESTRICT ATOMIC
%token INLINE NORETURN
%token ALIGNAS TYPEOF
%token ATTRIBUTE DECLSPEC ASM
%token ELLIPSIS

/* 特殊 Token */
%token BLOCK  /* 代表跳过的函数体 {...} */
%token OTHER  /* 未知字符 */

/* ========================================================================== */
/* 非终结符类型定义 (Non-terminal Types)                                      */
/* ========================================================================== */

/* 这些规则返回拼接后的字符串 */
%type <str> signature sig_element token_chunk nested_parentheses any_token_in_paren array_index
%type <str> macro_arg macro_arg_parts macro_arg_piece macro_arg_group macro_arg_group_piece
%type <str> array_rename_invocation macro_rename_invocation

/* 这些规则返回参数列表结构 */
%type <args> macro_arg_list macro_arg_list_opt

/* 自动释放内存，防止内存泄漏 */
%destructor { free($$); } <str>
%destructor { arg_list_free($$); } <args>

%%

/* ========================================================================== */
/* 顶层文法 (Top-Level Grammar)                                               */
/* ========================================================================== */

/* 程序由一系列元素组成 */
program:
    /* empty */
    | program element
    ;

/* 顶层元素可以是：函数定义、宏调用、宏定义或全局语句 */
element:
    func_definition             /* 核心目标：函数定义 */
    | macro_template_invocation /* 宏模板形式的函数定义 */
    | macro_call                /* 顶层宏调用 */
    | macro_definition          /* #define 宏定义 */
    | global_statement          /* 全局变量声明或原型声明 */
    | error ';' { yyerrok; }    /* 错误恢复：遇到分号跳过 */
    | error BLOCK { yyerrok; }  /* 错误恢复：遇到代码块跳过 */
    ;

/* 处理预处理宏定义 */
macro_definition:
    PP_DEFINE { 
        /* 1. 检查是否包含 ARRAY_RENAME 等特殊宏，设置前缀 */
        set_array_rename_prefix($1); 
        /* 2. 注册宏定义到全局符号表，供 Lexer 查表使用 */
        macro_register_definition($1);
        free($1); 
    }
    ;

/* ========================================================================== */
/* 函数定义规则 (Function Definition)                                         */
/* ========================================================================== */

/* 函数定义 = 签名 + 代码块 */
func_definition:
    signature BLOCK {
        /* 将拼接好的函数签名传递给工具函数进行校验和记录 */
        /* check_and_record 会负责解析出真正的函数名，排除误报 */
        check_and_record($1);
        free($1);
    }
    ;

/* 宏模板形式的函数定义，例如: DECLARE_TEST(test_case_1) { ... } */
/* 这里处理的是类似宏展开后生成的函数头 */
macro_template_invocation
    : MACRO_TEMPLATE '(' macro_arg_list_opt ')' {
        /* 尝试从宏模板中渲染出函数名 */
        char *name = render_macro_name($1, $3);
        if (name) {
            record_function(name);
            free(name);
        }
        free($1);
        arg_list_free($3);
    }
    ;

/* 普通宏调用，如 module_init(my_init); */
macro_call
    : MACRO_CALL '(' macro_arg_list_opt ')' { 
        /* 仅消耗 Token，不产生输出 */
        free($1); 
        arg_list_free($3);
    }
    ;

/* 全局语句：函数原型声明、变量声明、或者仅有的分号 */
global_statement:
    signature ';' { free($1); }              /* 函数声明: void func(); */
    | signature '=' initializer ';' { free($1); } /* 变量定义: int x = 1; */
    | ';' { }                                /* 空语句 */
    ;

/* ========================================================================== */
/* 签名构建规则 (Signature Construction)                                      */
/* ========================================================================== */

/* 签名由一系列元素拼接而成，这是为了捕获 "static inline void *func" 这种复杂结构 */
signature:
    sig_element { $$ = $1; }
    | signature sig_element {
        /* 递归拼接，单词之间加空格 */
        $$ = concat_with_space($1, $2);
        free($1);
        free($2);
    }
    | signature '(' nested_parentheses ')' {
        /* 处理函数参数列表或函数指针: func(int a, int b) */
        char *temp = concat($1, "(");
        char *temp2 = concat(temp, $3);
        $$ = concat(temp2, ")");
        free($1);
        free($3);
        free(temp);
        free(temp2);
    }
    | signature '[' array_index ']' {
        /* 处理数组定义: int arr[10] */
        char *temp = concat($1, "[");
        char *temp2 = concat(temp, $3);
        $$ = concat(temp2, "]");
        free($1);
        free($3);
        free(temp);
        free(temp2);
    }
    ;

/* 签名的基本组成单元 */
sig_element:
    token_chunk { $$ = $1; }         /* 普通关键字或标识符 */
    | macro_rename_invocation { $$ = $1; } /* 宏重命名 */
    | array_rename_invocation { $$ = $1; } /* 数组重命名 */
    | '*' { $$ = strdup("*"); }      /* 指针符号 */
    ;

/* 处理重命名宏，如 #define FN(x) x */
macro_rename_invocation
    : MACRO_RENAME '(' macro_arg_list_opt ')' {
        /* 展开宏以获取真实的标识符 */
        char *expanded = render_macro_expansion($1, $3);
        if (expanded) {
            $$ = expanded;
        } else {
            $$ = strdup($1);
        }
        free($1);
        arg_list_free($3);
    }
    ;

/* 处理数组索引，如 [MAX_SIZE * 2] */
array_index:
    /* empty */ { $$ = strdup(""); }
    | array_index token_chunk {
        $$ = concat($1, $2);
        free($1);
        free($2);
    }
    | array_index '*' {
        $$ = concat($1, "*");
        free($1);
    }
    | array_index '+' {
        $$ = concat($1, "+");
        free($1);
    }
    | array_index '-' {
        $$ = concat($1, "-");
        free($1);
    }
    ;

/* 处理特定数组重命名宏，如 ARRAY_RENAME(float) */
array_rename_invocation
    : ARRAY_RENAME '(' macro_arg ')' {
        /* 拼接前缀，例如变为 write_float_... */
        $$ = concat_with_array_prefix($3);
        free($3);
    }
    ;

/* ========================================================================== */
/* 括号嵌套处理 (Nested Parentheses)                                          */
/* ========================================================================== */

/* 处理参数列表中的复杂内容，支持多层括号嵌套 */
nested_parentheses:
    /* empty */ { $$ = strdup(""); }
    | nested_parentheses any_token_in_paren {
        $$ = concat_with_space($1, $2);
        free($1);
        free($2);
    }
    ;

any_token_in_paren:
    token_chunk { $$ = $1; }
    | ',' { $$ = strdup(","); }
    | '*' { $$ = strdup("*"); }
    | '=' { $$ = strdup("="); }
    | '[' { $$ = strdup("["); }
    | ']' { $$ = strdup("]"); }
    | '.' { $$ = strdup("."); }
    | '&' { $$ = strdup("&"); }
    | '-' { $$ = strdup("-"); }
    | '+' { $$ = strdup("+"); }
    | '(' nested_parentheses ')' {
        /* 递归处理嵌套括号 */
        char *temp = concat("(", $2);
        $$ = concat(temp, ")");
        free($2);
        free(temp);
    }
    ;

/* ========================================================================== */
/* 初始化器处理 (Initializer)                                                 */
/* ========================================================================== */

/* 处理 = 之后的内容，直到分号。支持嵌套块。 */
initializer:
    token_chunk { free($1); }
    | initializer token_chunk { free($2); }
    | BLOCK /* 初始化器中可能包含代码块，如结构体初始化 */
    | initializer ',' { }
    | initializer '*' { }
    ;

/* ========================================================================== */
/* 宏参数处理 (Macro Arguments)                                               */
/* ========================================================================== */

macro_arg
    : macro_arg_parts { $$ = $1; }
    ;

macro_arg_list_opt
    : /* empty */ { $$ = arg_list_new(); }
    | macro_arg_list { $$ = $1; }
    ;

macro_arg_list
    : macro_arg {
        $$ = arg_list_new();
        arg_list_add($$, $1);
    }
    | macro_arg_list ',' macro_arg {
        arg_list_add($1, $3);
        $$ = $1;
    }
    | macro_arg_list ',' {
        /* 处理尾部逗号的情况 */
        arg_list_add($1, strdup(""));
        $$ = $1;
    }
    ;

macro_arg_parts
    : macro_arg_piece { $$ = $1; }
    | macro_arg_parts macro_arg_piece {
        $$ = concat($1, $2);
        free($1);
        free($2);
    }
    ;

macro_arg_piece
    : token_chunk { $$ = $1; }
    | MACRO_CALL { $$ = $1; }
    | MACRO_RENAME { $$ = $1; }
    | MACRO_TEMPLATE { $$ = $1; }
    | '*' { $$ = strdup("*"); }
    | '+' { $$ = strdup("+"); }
    | '-' { $$ = strdup("-"); }
    | '=' { $$ = strdup("="); }
    | '(' macro_arg_group ')' {
        char *temp = concat("(", $2);
        $$ = concat(temp, ")");
        free(temp);
        free($2);
    }
    | '[' macro_arg_group ']' {
        char *temp = concat("[", $2);
        $$ = concat(temp, "]");
        free(temp);
        free($2);
    }
    ;

macro_arg_group
    : /* empty */ { $$ = strdup(""); }
    | macro_arg_group macro_arg_group_piece {
        $$ = concat($1, $2);
        free($1);
        free($2);
    }
    ;

macro_arg_group_piece
    : macro_arg_piece { $$ = $1; }
    | ',' { $$ = strdup(","); }
    ;

/* ========================================================================== */
/* 基础 Token 块 (Token Chunks)                                               */
/* ========================================================================== */

/* 将所有单一 Token 统一转换为字符串，便于上层拼接 */
token_chunk:
    IDENTIFIER
    | CONSTANT
    | STRING_LITERAL
    | TYPEDEF { $$ = strdup("typedef"); }
    | EXTERN { $$ = strdup("extern"); }
    | STATIC { $$ = strdup("static"); }
    | AUTO { $$ = strdup("auto"); }
    | REGISTER { $$ = strdup("register"); }
    | THREAD_LOCAL { $$ = strdup("_Thread_local"); }
    | VOID { $$ = strdup("void"); }
    | CHAR { $$ = strdup("char"); }
    | SHORT { $$ = strdup("short"); }
    | INT { $$ = strdup("int"); }
    | LONG { $$ = strdup("long"); }
    | FLOAT { $$ = strdup("float"); }
    | DOUBLE { $$ = strdup("double"); }
    | SIGNED { $$ = strdup("signed"); }
    | UNSIGNED { $$ = strdup("unsigned"); }
    | BOOL { $$ = strdup("_Bool"); }
    | COMPLEX { $$ = strdup("_Complex"); }
    | IMAGINARY { $$ = strdup("_Imaginary"); }
    | STRUCT { $$ = strdup("struct"); }
    | UNION { $$ = strdup("union"); }
    | ENUM { $$ = strdup("enum"); }
    | CONST { $$ = strdup("const"); }
    | VOLATILE { $$ = strdup("volatile"); }
    | RESTRICT { $$ = strdup("restrict"); }
    | ATOMIC { $$ = strdup("_Atomic"); }
    | INLINE { $$ = strdup("inline"); }
    | NORETURN { $$ = strdup("_Noreturn"); }
    | ALIGNAS { $$ = strdup("_Alignas"); }
    | TYPEOF { $$ = strdup("typeof"); }
    | ATTRIBUTE { $$ = strdup("__attribute__"); }
    | DECLSPEC { $$ = strdup("__declspec"); }
    | ASM { $$ = strdup("asm"); }
    | ELLIPSIS { $$ = strdup("..."); }
    | OTHER { $$ = strdup(""); }
    ;

%%

/* 错误处理函数：通常保持沉默，由上层逻辑判断解析结果 */
void yyerror(const char *s) {
    (void)s;
}

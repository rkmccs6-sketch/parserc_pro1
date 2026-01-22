%code requires {
void record_function(const char *name);
void parser_reset_state(void);
}

%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

int yylex(void);
void yyerror(const char *s);
void record_function(const char *name);

static char array_rename_prefix[64] = "write_float_";

static char *concat(const char *s1, const char *s2) {
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

static char *concat_with_space(const char *s1, const char *s2) {
    char *temp = concat(s1, " ");
    char *out = concat(temp, s2);
    free(temp);
    return out;
}

static void set_array_rename_prefix(const char *line) {
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

static void check_and_record(char *full_sig) {
    if (!full_sig) {
        return;
    }

    char *clean = trim_spaces(full_sig);
    if (!clean) {
        return;
    }

    char *p = strchr(clean, '(');
    if (!p) {
        free(clean);
        return;
    }

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

    record_function(name);
    free(name);
    free(clean);
}
%}

%union {
    char *str;
}

%token <str> IDENTIFIER
%token <str> CONSTANT STRING_LITERAL PP_DEFINE
%token FUN_MACRO DEFINE_OPT_SHOW_SECTION ARRAY_RENAME
%token TYPEDEF EXTERN STATIC AUTO REGISTER THREAD_LOCAL
%token VOID CHAR SHORT INT LONG FLOAT DOUBLE SIGNED UNSIGNED BOOL COMPLEX IMAGINARY
%token STRUCT UNION ENUM
%token CONST VOLATILE RESTRICT ATOMIC
%token INLINE NORETURN
%token ALIGNAS TYPEOF
%token ATTRIBUTE DECLSPEC ASM
%token ELLIPSIS
%token BLOCK
%token OTHER

%type <str> signature sig_element token_chunk nested_parentheses any_token_in_paren array_index
%type <str> macro_arg macro_arg_tokens macro_arg_token macro_skip macro_skip_token
%type <str> array_rename_invocation

%destructor { free($$); } <str>

%%

program:
    /* empty */
    | program element
    ;

element:
    func_definition
    | macro_fun
    | macro_define_opt_show
    | macro_definition
    | global_statement
    | error ';' { yyerrok; }
    | error BLOCK { yyerrok; }
    ;

macro_definition:
    PP_DEFINE { set_array_rename_prefix($1); free($1); }
    ;

func_definition:
    signature BLOCK {
        check_and_record($1);
        free($1);
    }
    ;

macro_fun
    : FUN_MACRO '(' macro_arg ',' macro_skip ',' macro_skip ')' {
        if ($3) {
            record_function($3);
        }
        free($3);
    }
    ;

macro_define_opt_show
    : DEFINE_OPT_SHOW_SECTION '(' macro_arg ',' macro_skip ')' {
        if ($3) {
            char *name = concat("opt_show_", $3);
            if (name) {
                record_function(name);
                free(name);
            }
        }
        free($3);
    }
    ;

global_statement:
    signature ';' { free($1); }
    | signature '=' initializer ';' { free($1); }
    | ';' { }
    ;

signature:
    sig_element { $$ = $1; }
    | signature sig_element {
        $$ = concat_with_space($1, $2);
        free($1);
        free($2);
    }
    | signature '(' nested_parentheses ')' {
        char *temp = concat($1, "(");
        char *temp2 = concat(temp, $3);
        $$ = concat(temp2, ")");
        free($1);
        free($3);
        free(temp);
        free(temp2);
    }
    | signature '[' array_index ']' {
        char *temp = concat($1, "[");
        char *temp2 = concat(temp, $3);
        $$ = concat(temp2, "]");
        free($1);
        free($3);
        free(temp);
        free(temp2);
    }
    ;

sig_element:
    token_chunk { $$ = $1; }
    | array_rename_invocation { $$ = $1; }
    | '*' { $$ = strdup("*"); }
    ;

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

array_rename_invocation
    : ARRAY_RENAME '(' macro_arg ')' {
        $$ = concat(array_rename_prefix, $3);
        free($3);
    }
    ;

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
        char *temp = concat("(", $2);
        $$ = concat(temp, ")");
        free($2);
        free(temp);
    }
    ;

initializer:
    token_chunk { free($1); }
    | initializer token_chunk { free($2); }
    | BLOCK
    | initializer ',' { }
    | initializer '*' { }
    ;

macro_arg
    : macro_arg_tokens { $$ = $1; }
    ;

macro_arg_tokens
    : macro_arg_token { $$ = $1; $1 = NULL; }
    | macro_arg_tokens macro_arg_token {
        $$ = concat($1, $2);
        free($1);
        free($2);
    }
    ;

macro_arg_token
    : IDENTIFIER { $$ = $1; $1 = NULL; }
    | CONSTANT { $$ = $1; $1 = NULL; }
    ;

macro_skip
    : /* empty */ { $$ = NULL; }
    | macro_skip macro_skip_token { $$ = NULL; }
    | macro_skip_token { $$ = NULL; }
    ;

macro_skip_token
    : token_chunk { free($1); $$ = NULL; }
    | '(' macro_skip ')' { $$ = NULL; }
    | '[' macro_skip ']' { $$ = NULL; }
    | ',' { $$ = NULL; }
    | '*' { $$ = NULL; }
    | '=' { $$ = NULL; }
    | '+' { $$ = NULL; }
    | '-' { $$ = NULL; }
    ;

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

void parser_reset_state(void) {
    strcpy(array_rename_prefix, "write_float_");
}

void yyerror(const char *s) {
    (void)s;
}

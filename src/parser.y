%code requires {
void record_function(const char *name);
void parser_reset_state(void);
}

%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

%type <str> declarator direct_declarator array_rename_invocation
%type <str> macro_arg macro_arg_tokens macro_arg_token

%destructor { free($$); } <str>

%%

translation_unit:
    /* empty */
    | translation_unit external_declaration
    ;

external_declaration:
    function_definition
    | macro_fun
    | macro_define_opt_show
    | pp_define
    | declaration
    | ';'
    | error ';' { yyerrok; }
    | error BLOCK { yyerrok; }
    ;

pp_define:
    PP_DEFINE { set_array_rename_prefix($1); free($1); }
    ;

function_definition:
    decl_specifiers declarator BLOCK {
        if ($2) {
            record_function($2);
            free($2);
        }
    }
    | declarator BLOCK {
        if ($1) {
            record_function($1);
            free($1);
        }
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

declaration:
    decl_specifiers init_declarator_list_opt ';'
    | decl_specifiers ';'
    | non_function_tokens ';'
    ;

init_declarator_list_opt:
    /* empty */
    | init_declarator_list
    ;

init_declarator_list:
    init_declarator
    | init_declarator_list ',' init_declarator
    ;

init_declarator:
    declarator
    | declarator '=' initializer
    ;

declarator:
    pointer_opt direct_declarator { $$ = $2; }
    ;

pointer_opt:
    /* empty */
    | pointer
    ;

pointer:
    '*' type_qualifier_list_opt
    | '*' type_qualifier_list_opt pointer
    ;

type_qualifier_list_opt:
    /* empty */
    | type_qualifier_list
    ;

type_qualifier_list:
    type_qualifier
    | type_qualifier_list type_qualifier
    ;

direct_declarator:
    IDENTIFIER { $$ = $1; }
    | array_rename_invocation { $$ = $1; }
    | '(' declarator ')' { $$ = $2; }
    | direct_declarator '(' param_tokens_opt ')' { $$ = $1; }
    | direct_declarator '[' param_tokens_opt ']' { $$ = $1; }
    ;

array_rename_invocation:
    ARRAY_RENAME '(' macro_arg ')' {
        $$ = concat(array_rename_prefix, $3);
        free($3);
    }
    ;

decl_specifiers:
    decl_specifier
    | decl_specifiers decl_specifier
    ;

decl_specifier:
    storage_class_specifier
    | type_specifier
    | type_qualifier
    | function_specifier
    | alignment_specifier
    | attribute_specifier
    ;

storage_class_specifier:
    TYPEDEF
    | EXTERN
    | STATIC
    | AUTO
    | REGISTER
    | THREAD_LOCAL
    ;

type_specifier:
    type_specifier_keyword
    | IDENTIFIER { free($1); }
    ;

type_specifier_keyword:
    VOID
    | CHAR
    | SHORT
    | INT
    | LONG
    | FLOAT
    | DOUBLE
    | SIGNED
    | UNSIGNED
    | BOOL
    | COMPLEX
    | IMAGINARY
    | STRUCT
    | UNION
    | ENUM
    | TYPEOF
    ;

type_qualifier:
    CONST
    | VOLATILE
    | RESTRICT
    | ATOMIC
    ;

function_specifier:
    INLINE
    | NORETURN
    ;

alignment_specifier:
    ALIGNAS
    ;

attribute_specifier:
    ATTRIBUTE
    | DECLSPEC
    | ASM
    ;

param_tokens_opt:
    /* empty */
    | param_tokens
    ;

param_tokens:
    param_tokens param_token
    | param_token
    ;

param_token:
    IDENTIFIER { free($1); }
    | CONSTANT { free($1); }
    | STRING_LITERAL { free($1); }
    | ELLIPSIS
    | type_specifier_keyword
    | type_qualifier
    | storage_class_specifier
    | function_specifier
    | alignment_specifier
    | attribute_specifier
    | FUN_MACRO
    | DEFINE_OPT_SHOW_SECTION
    | ARRAY_RENAME
    | '(' param_tokens_opt ')'
    | '[' param_tokens_opt ']'
    | '*' { }
    | ',' { }
    | '=' { }
    | OTHER { }
    ;

non_function_tokens:
    non_function_tokens non_function_token
    | non_function_token
    ;

non_function_token:
    IDENTIFIER { free($1); }
    | CONSTANT { free($1); }
    | STRING_LITERAL { free($1); }
    | ELLIPSIS
    | type_specifier_keyword
    | storage_class_specifier
    | type_qualifier
    | function_specifier
    | alignment_specifier
    | attribute_specifier
    | FUN_MACRO
    | DEFINE_OPT_SHOW_SECTION
    | ARRAY_RENAME
    | '(' non_function_tokens_opt ')'
    | '[' non_function_tokens_opt ']'
    | '*' { }
    | ',' { }
    | '=' { }
    | OTHER { }
    ;

non_function_tokens_opt:
    /* empty */
    | non_function_tokens
    ;

initializer:
    initializer_tokens
    | BLOCK
    ;

initializer_tokens:
    initializer_tokens initializer_token
    | initializer_token
    ;

initializer_token:
    IDENTIFIER { free($1); }
    | CONSTANT { free($1); }
    | STRING_LITERAL { free($1); }
    | ELLIPSIS
    | type_specifier_keyword
    | storage_class_specifier
    | type_qualifier
    | function_specifier
    | alignment_specifier
    | attribute_specifier
    | FUN_MACRO
    | DEFINE_OPT_SHOW_SECTION
    | ARRAY_RENAME
    | '(' initializer_tokens_opt ')'
    | '[' initializer_tokens_opt ']'
    | BLOCK
    | '*' { }
    | ',' { }
    | '=' { }
    | OTHER { }
    ;

initializer_tokens_opt:
    /* empty */
    | initializer_tokens
    ;

macro_arg:
    macro_arg_tokens { $$ = $1; }
    ;

macro_arg_tokens:
    macro_arg_token { $$ = $1; }
    | macro_arg_tokens macro_arg_token {
        $$ = concat($1, $2);
        free($1);
        free($2);
    }
    ;

macro_arg_token:
    IDENTIFIER { $$ = $1; }
    | CONSTANT { $$ = $1; }
    ;

macro_skip:
    /* empty */
    | macro_skip macro_skip_token
    | macro_skip_token
    ;

macro_skip_token:
    IDENTIFIER { free($1); }
    | CONSTANT { free($1); }
    | STRING_LITERAL { free($1); }
    | ELLIPSIS
    | type_specifier_keyword
    | storage_class_specifier
    | type_qualifier
    | function_specifier
    | alignment_specifier
    | attribute_specifier
    | FUN_MACRO
    | DEFINE_OPT_SHOW_SECTION
    | ARRAY_RENAME
    | '(' macro_skip ')'
    | '[' macro_skip ']'
    | '*' { }
    | ',' { }
    | '=' { }
    | OTHER { }
    ;

%%

void parser_reset_state(void) {
    strcpy(array_rename_prefix, "write_float_");
}

void yyerror(const char *s) {
    (void)s;
}

%{
#include <stdio.h>
#include <stdlib.h>

int yylex(void);
void yyerror(const char *s);
void record_function(const char *name);
%}

%define parse.error verbose

%union {
    char *str;
}

%token <str> IDENTIFIER
%token <str> CONSTANT STRING_LITERAL
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

%type <str> declarator direct_declarator

%destructor { free($$); } <str>

%%

translation_unit
    : /* empty */
    | translation_unit external_declaration
    ;

external_declaration
    : function_definition
    | declaration
    | ';'
    | error ';' { yyerrok; }
    | error BLOCK { yyerrok; }
    ;

function_definition
    : decl_specifiers declarator declaration_list_opt BLOCK
        { if ($2) record_function($2); }
    | declarator declaration_list_opt BLOCK
        { if ($1) record_function($1); }
    ;

declaration_list_opt
    : /* empty */
    | declaration_list
    ;

declaration_list
    : declaration
    | declaration_list declaration
    ;

declaration
    : decl_tokens ';'
    ;

decl_tokens
    : decl_token
    | decl_tokens decl_token
    ;

decl_token
    : decl_token_atom
    | paren_group
    | bracket_group
    | BLOCK
    ;

decl_token_atom
    : IDENTIFIER
    | CONSTANT
    | STRING_LITERAL
    | TYPEDEF
    | EXTERN
    | STATIC
    | AUTO
    | REGISTER
    | THREAD_LOCAL
    | VOID
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
    | CONST
    | VOLATILE
    | RESTRICT
    | ATOMIC
    | INLINE
    | NORETURN
    | ALIGNAS
    | TYPEOF
    | ATTRIBUTE
    | DECLSPEC
    | ASM
    | ELLIPSIS
    | OTHER
    | '*'
    | ','
    ;

decl_specifiers
    : decl_specifier
    | decl_specifiers decl_specifier
    ;

decl_specifier
    : storage_class_specifier
    | type_specifier
    | type_qualifier
    | function_specifier
    | alignment_specifier
    | attribute_specifier
    ;

storage_class_specifier
    : TYPEDEF
    | EXTERN
    | STATIC
    | AUTO
    | REGISTER
    | THREAD_LOCAL
    ;

type_specifier
    : VOID
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
    | struct_or_union_specifier
    | enum_specifier
    | TYPEOF paren_group
    | IDENTIFIER
    ;

type_qualifier
    : CONST
    | VOLATILE
    | RESTRICT
    | ATOMIC
    ;

function_specifier
    : INLINE
    | NORETURN
    ;

alignment_specifier
    : ALIGNAS paren_group
    ;

attribute_specifier_sequence
    : attribute_specifier
    | attribute_specifier_sequence attribute_specifier
    ;

attribute_specifier
    : ATTRIBUTE paren_group
    | DECLSPEC paren_group
    | ASM paren_group
    ;

asm_label
    : ASM paren_group
    ;

struct_or_union_specifier
    : struct_or_union IDENTIFIER BLOCK
    | struct_or_union BLOCK
    | struct_or_union IDENTIFIER
    ;

struct_or_union
    : STRUCT
    | UNION
    ;

enum_specifier
    : ENUM IDENTIFIER BLOCK
    | ENUM BLOCK
    | ENUM IDENTIFIER
    ;

declarator
    : pointer_opt direct_declarator { $$ = $2; }
    ;

pointer_opt
    : /* empty */
    | pointer
    ;

pointer
    : '*' type_qualifier_list_opt pointer_opt
    | '*' type_qualifier_list_opt attribute_specifier_sequence pointer_opt
    ;

type_qualifier_list_opt
    : /* empty */
    | type_qualifier_list
    ;

type_qualifier_list
    : type_qualifier
    | type_qualifier_list type_qualifier
    | type_qualifier_list attribute_specifier
    | attribute_specifier
    ;

direct_declarator
    : IDENTIFIER { $$ = $1; }
    | '(' declarator ')' { $$ = $2; }
    | direct_declarator paren_group { $$ = $1; }
    | direct_declarator bracket_group { $$ = $1; }
    | direct_declarator attribute_specifier_sequence { $$ = $1; }
    | direct_declarator asm_label { $$ = $1; }
    ;

paren_group
    : '(' paren_items_opt ')'
    ;

paren_items_opt
    : /* empty */
    | paren_items
    ;

paren_items
    : paren_items paren_item
    | paren_item
    ;

paren_item
    : paren_group
    | bracket_group
    | BLOCK
    | decl_token_atom
    ;

bracket_group
    : '[' bracket_items_opt ']'
    ;

bracket_items_opt
    : /* empty */
    | bracket_items
    ;

bracket_items
    : bracket_items bracket_item
    | bracket_item
    ;

bracket_item
    : paren_group
    | bracket_group
    | BLOCK
    | decl_token_atom
    ;

%%

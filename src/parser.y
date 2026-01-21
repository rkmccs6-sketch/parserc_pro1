%code requires {
enum token_kind {
    TOK_LPAREN = 1,
    TOK_RPAREN,
    TOK_LBRACKET,
    TOK_RBRACKET,
    TOK_COMMA,
    TOK_SEMI,
    TOK_ASSIGN,
    TOK_BLOCK,
    TOK_OTHER
};

void process_identifier(const char *name);
void process_token(enum token_kind kind);
}

%{
#include <stdio.h>
#include <stdlib.h>

int yylex(void);
void yyerror(const char *s);
%}

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

%destructor { free($$); } <str>

%%

translation_unit
    : /* empty */
    | translation_unit token
    ;

token
    : IDENTIFIER { process_identifier($1); }
    | CONSTANT { process_token(TOK_OTHER); }
    | STRING_LITERAL { process_token(TOK_OTHER); }
    | TYPEDEF { process_token(TOK_OTHER); }
    | EXTERN { process_token(TOK_OTHER); }
    | STATIC { process_token(TOK_OTHER); }
    | AUTO { process_token(TOK_OTHER); }
    | REGISTER { process_token(TOK_OTHER); }
    | THREAD_LOCAL { process_token(TOK_OTHER); }
    | VOID { process_token(TOK_OTHER); }
    | CHAR { process_token(TOK_OTHER); }
    | SHORT { process_token(TOK_OTHER); }
    | INT { process_token(TOK_OTHER); }
    | LONG { process_token(TOK_OTHER); }
    | FLOAT { process_token(TOK_OTHER); }
    | DOUBLE { process_token(TOK_OTHER); }
    | SIGNED { process_token(TOK_OTHER); }
    | UNSIGNED { process_token(TOK_OTHER); }
    | BOOL { process_token(TOK_OTHER); }
    | COMPLEX { process_token(TOK_OTHER); }
    | IMAGINARY { process_token(TOK_OTHER); }
    | STRUCT { process_token(TOK_OTHER); }
    | UNION { process_token(TOK_OTHER); }
    | ENUM { process_token(TOK_OTHER); }
    | CONST { process_token(TOK_OTHER); }
    | VOLATILE { process_token(TOK_OTHER); }
    | RESTRICT { process_token(TOK_OTHER); }
    | ATOMIC { process_token(TOK_OTHER); }
    | INLINE { process_token(TOK_OTHER); }
    | NORETURN { process_token(TOK_OTHER); }
    | ALIGNAS { process_token(TOK_OTHER); }
    | TYPEOF { process_token(TOK_OTHER); }
    | ATTRIBUTE { process_token(TOK_OTHER); }
    | DECLSPEC { process_token(TOK_OTHER); }
    | ASM { process_token(TOK_OTHER); }
    | ELLIPSIS { process_token(TOK_OTHER); }
    | '(' { process_token(TOK_LPAREN); }
    | ')' { process_token(TOK_RPAREN); }
    | '[' { process_token(TOK_LBRACKET); }
    | ']' { process_token(TOK_RBRACKET); }
    | ',' { process_token(TOK_COMMA); }
    | ';' { process_token(TOK_SEMI); }
    | '=' { process_token(TOK_ASSIGN); }
    | '*' { process_token(TOK_OTHER); }
    | BLOCK { process_token(TOK_BLOCK); }
    | OTHER { process_token(TOK_OTHER); }
    ;

%%

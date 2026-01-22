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
    TOK_DECL,
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
    | TYPEDEF { process_token(TOK_DECL); }
    | EXTERN { process_token(TOK_DECL); }
    | STATIC { process_token(TOK_DECL); }
    | AUTO { process_token(TOK_DECL); }
    | REGISTER { process_token(TOK_DECL); }
    | THREAD_LOCAL { process_token(TOK_DECL); }
    | VOID { process_token(TOK_DECL); }
    | CHAR { process_token(TOK_DECL); }
    | SHORT { process_token(TOK_DECL); }
    | INT { process_token(TOK_DECL); }
    | LONG { process_token(TOK_DECL); }
    | FLOAT { process_token(TOK_DECL); }
    | DOUBLE { process_token(TOK_DECL); }
    | SIGNED { process_token(TOK_DECL); }
    | UNSIGNED { process_token(TOK_DECL); }
    | BOOL { process_token(TOK_DECL); }
    | COMPLEX { process_token(TOK_DECL); }
    | IMAGINARY { process_token(TOK_DECL); }
    | STRUCT { process_token(TOK_DECL); }
    | UNION { process_token(TOK_DECL); }
    | ENUM { process_token(TOK_DECL); }
    | CONST { process_token(TOK_DECL); }
    | VOLATILE { process_token(TOK_DECL); }
    | RESTRICT { process_token(TOK_DECL); }
    | ATOMIC { process_token(TOK_DECL); }
    | INLINE { process_token(TOK_DECL); }
    | NORETURN { process_token(TOK_DECL); }
    | ALIGNAS { process_token(TOK_DECL); }
    | TYPEOF { process_token(TOK_DECL); }
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

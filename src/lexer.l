%option noyywrap nodefault nounput noinput

%{
#include "parser.tab.h"
#include <stdlib.h>
#include <string.h>

static int brace_depth = 0;
static char *pp_buffer = NULL;
static size_t pp_buf_len = 0;

int macro_lookup_token(const char *name);

static void pp_reset(void) {
    free(pp_buffer);
    pp_buffer = NULL;
    pp_buf_len = 0;
}

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

%x BRACE BRACE_COMMENT BRACE_STRING BRACE_CHAR COMMENT PREPROC PREPROC_DEFINE

%%

^[ \t]*#[ \t]*define[^\n]*\\\n { pp_reset(); pp_append(yytext); BEGIN(PREPROC_DEFINE); }
^[ \t]*#[ \t]*define[^\n]*\n { yylval.str = dup_text(yytext); return PP_DEFINE; }
^[ \t]*#[^\n]*\\\n    { BEGIN(PREPROC); }
^[ \t]*#[^\n]*\n      { /* skip preprocessor line */ }
<PREPROC>.*\\\n       { /* skip continued preprocessor line */ }
<PREPROC>.*\n         { BEGIN(INITIAL); }
<PREPROC><<EOF>>      { BEGIN(INITIAL); }
<PREPROC_DEFINE>.*\\\n { pp_append(yytext); }
<PREPROC_DEFINE>.*\n   { pp_append(yytext); yylval.str = pp_buffer; pp_buffer = NULL; pp_buf_len = 0; BEGIN(INITIAL); return PP_DEFINE; }
<PREPROC_DEFINE><<EOF>> {
                          if (pp_buffer) {
                              yylval.str = pp_buffer;
                              pp_buffer = NULL;
                              pp_buf_len = 0;
                              BEGIN(INITIAL);
                              return PP_DEFINE;
                          }
                          BEGIN(INITIAL);
                        }
[ \t\r\n]+            { /* skip whitespace */ }
"//".*                { /* skip line comment */ }
"/*"                  { BEGIN(COMMENT); }

<COMMENT>"*/"         { BEGIN(INITIAL); }
<COMMENT>.|\n         { /* skip */ }

"{"                   { brace_depth = 1; BEGIN(BRACE); }

<BRACE>"/*"           { BEGIN(BRACE_COMMENT); }
<BRACE>"//".*         { /* skip line comment */ }
<BRACE>"\""           { BEGIN(BRACE_STRING); }
<BRACE>"'"            { BEGIN(BRACE_CHAR); }
<BRACE>"{"            { brace_depth++; }
<BRACE>"}"            {
                          brace_depth--;
                          if (brace_depth == 0) {
                              BEGIN(INITIAL);
                              return BLOCK;
                          }
                      }
<BRACE>[ \t\r\n]+      { /* skip whitespace */ }
<BRACE>.              { /* skip other */ }

<BRACE_COMMENT>"*/"   { BEGIN(BRACE); }
<BRACE_COMMENT>.|\n   { /* skip */ }

<BRACE_STRING>\\(.)   { /* skip escaped */ }
<BRACE_STRING>"\""    { BEGIN(BRACE); }
<BRACE_STRING>.|\n    { /* skip */ }

<BRACE_CHAR>\\(.)     { /* skip escaped */ }
<BRACE_CHAR>"'"       { BEGIN(BRACE); }
<BRACE_CHAR>.|\n      { /* skip */ }

"typedef"             { return TYPEDEF; }
"ARRAY_RENAME"        { return ARRAY_RENAME; }
"extern"              { return EXTERN; }
"static"              { return STATIC; }
"auto"                { return AUTO; }
"register"            { return REGISTER; }
"_Thread_local"       { return THREAD_LOCAL; }
"__thread"            { return THREAD_LOCAL; }

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

"struct"              { return STRUCT; }
"union"               { return UNION; }
"enum"                { return ENUM; }

"const"               { return CONST; }
"volatile"            { return VOLATILE; }
"restrict"            { return RESTRICT; }
"_Atomic"             { return ATOMIC; }
"__const"             { return CONST; }
"__volatile__"        { return VOLATILE; }
"__restrict"          { return RESTRICT; }
"__restrict__"        { return RESTRICT; }

"inline"              { return INLINE; }
"__inline"            { return INLINE; }
"__inline__"          { return INLINE; }
"_Noreturn"           { return NORETURN; }

"_Alignas"            { return ALIGNAS; }
"__alignas"           { return ALIGNAS; }
"__alignas__"         { return ALIGNAS; }

"typeof"              { return TYPEOF; }
"__typeof__"          { return TYPEOF; }

"__attribute__"       { return ATTRIBUTE; }
"__attribute"         { return ATTRIBUTE; }
"__declspec"          { return DECLSPEC; }
"__asm__"             { return ASM; }
"__asm"               { return ASM; }
"asm"                 { return ASM; }

"..."                 { return ELLIPSIS; }

\"([^\\\n]|(\\.))*\"  { yylval.str = dup_text(yytext); return STRING_LITERAL; }
\'([^\\\n]|(\\.))*\'  { yylval.str = dup_text(yytext); return CONSTANT; }

0[xX][0-9a-fA-F]+[uUlL]*            { yylval.str = dup_text(yytext); return CONSTANT; }
[0-9]+([uUlL]*|[uUlL]+)             { yylval.str = dup_text(yytext); return CONSTANT; }
[0-9]+\\.[0-9]*([eE][+-]?[0-9]+)?[fFlL]* { yylval.str = dup_text(yytext); return CONSTANT; }
[0-9]*\\.[0-9]+([eE][+-]?[0-9]+)?[fFlL]* { yylval.str = dup_text(yytext); return CONSTANT; }

[a-zA-Z_][a-zA-Z0-9_]* {
    int token = macro_lookup_token(yytext);
    if (token != 0) {
        yylval.str = dup_text(yytext);
        return token;
    }
    yylval.str = dup_text(yytext);
    return IDENTIFIER;
}

";"                  { return ';'; }
","                  { return ','; }
"*"                  { return '*'; }
"="                  { return '='; }
"("                  { return '('; }
")"                  { return ')'; }
"["                  { return '['; }
"]"                  { return ']'; }

.                    { return OTHER; }

%%

void lexer_reset(void) {
    brace_depth = 0;
    pp_reset();
    BEGIN(INITIAL);
}

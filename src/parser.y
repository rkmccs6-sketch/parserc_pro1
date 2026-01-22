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

static char *last_identifier = NULL;
static char *paren_candidate = NULL;
static char *pending_name = NULL;
static int paren_depth = 0;
static int bracket_depth = 0;

static char array_rename_prefix[64] = "write_float_";
static int array_rename_capture = 0;
static int array_rename_depth = 0;
static char *array_rename_arg = NULL;

enum MacroMode {
    MACRO_NONE = 0,
    MACRO_FUN,
    MACRO_DEFINE_OPT_SHOW
};
static enum MacroMode macro_mode = MACRO_NONE;
static int macro_depth = 0;
static int macro_arg_index = 0;
static char *macro_first_arg = NULL;

static char *concat2(const char *a, const char *b) {
    size_t la = a ? strlen(a) : 0;
    size_t lb = b ? strlen(b) : 0;
    char *out = (char *)malloc(la + lb + 1);
    if (!out) {
        return NULL;
    }
    if (a) {
        memcpy(out, a, la);
    }
    if (b) {
        memcpy(out + la, b, lb);
    }
    out[la + lb] = '\0';
    return out;
}

static void clear_string(char **ptr) {
    if (*ptr) {
        free(*ptr);
        *ptr = NULL;
    }
}

static void append_to_buffer(char **buf, const char *text) {
    char *out = NULL;
    if (!text) {
        return;
    }
    if (!*buf) {
        *buf = strdup(text);
        return;
    }
    out = concat2(*buf, text);
    free(*buf);
    *buf = out;
}

static void reset_candidate_state(void) {
    clear_string(&last_identifier);
    clear_string(&paren_candidate);
    clear_string(&pending_name);
    paren_depth = 0;
    bracket_depth = 0;
}

static void reset_macro_state(void) {
    macro_mode = MACRO_NONE;
    macro_depth = 0;
    macro_arg_index = 0;
    clear_string(&macro_first_arg);
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

static void finalize_array_rename(void) {
    char *name = NULL;
    if (!array_rename_arg) {
        return;
    }
    clear_string(&last_identifier);
    name = concat2(array_rename_prefix, array_rename_arg);
    last_identifier = name;
    clear_string(&array_rename_arg);
}

static void record_macro_first_arg(void) {
    if (!macro_first_arg) {
        return;
    }
    if (macro_mode == MACRO_FUN) {
        record_function(macro_first_arg);
    } else if (macro_mode == MACRO_DEFINE_OPT_SHOW) {
        char *name = concat2("opt_show_", macro_first_arg);
        if (name) {
            record_function(name);
            free(name);
        }
    }
    clear_string(&macro_first_arg);
}

static void handle_identifier(const char *name) {
    if (array_rename_capture && array_rename_depth > 0) {
        append_to_buffer(&array_rename_arg, name);
        return;
    }
    if (macro_mode != MACRO_NONE && macro_arg_index == 0) {
        append_to_buffer(&macro_first_arg, name);
        return;
    }
    clear_string(&last_identifier);
    last_identifier = strdup(name);
}

static void handle_constant(const char *value) {
    if (array_rename_capture && array_rename_depth > 0) {
        append_to_buffer(&array_rename_arg, value);
    } else if (macro_mode != MACRO_NONE && macro_arg_index == 0) {
        append_to_buffer(&macro_first_arg, value);
    }
}

static void handle_decl_token(void) {
    if (paren_depth == 0 && bracket_depth == 0) {
        clear_string(&paren_candidate);
        clear_string(&pending_name);
    }
}

static void handle_lparen(void) {
    int started_array = 0;
    int started_macro = 0;

    if (paren_depth == 0 && last_identifier) {
        if (strcmp(last_identifier, "ARRAY_RENAME") == 0) {
            array_rename_capture = 1;
            array_rename_depth = 1;
            clear_string(&array_rename_arg);
            started_array = 1;
        } else if (strcmp(last_identifier, "FUN") == 0) {
            reset_macro_state();
            macro_mode = MACRO_FUN;
            macro_depth = 1;
            macro_arg_index = 0;
            started_macro = 1;
        } else if (strcmp(last_identifier, "DEFINE_OPT_SHOW_SECTION") == 0) {
            reset_macro_state();
            macro_mode = MACRO_DEFINE_OPT_SHOW;
            macro_depth = 1;
            macro_arg_index = 0;
            started_macro = 1;
        } else if (!pending_name && paren_depth == 0) {
            clear_string(&paren_candidate);
            paren_candidate = strdup(last_identifier);
        }
    }

    paren_depth++;
    if (array_rename_capture && !started_array) {
        array_rename_depth++;
    }
    if (macro_mode != MACRO_NONE && !started_macro) {
        macro_depth++;
    }
}

static void handle_rparen(void) {
    if (paren_depth > 0) {
        paren_depth--;
        if (paren_depth == 0 && !pending_name && paren_candidate) {
            pending_name = paren_candidate;
            paren_candidate = NULL;
        }
    }
    if (array_rename_capture && array_rename_depth > 0) {
        array_rename_depth--;
        if (array_rename_depth == 0) {
            array_rename_capture = 0;
            finalize_array_rename();
        }
    }
    if (macro_mode != MACRO_NONE && macro_depth > 0) {
        macro_depth--;
        if (macro_depth == 0) {
            reset_macro_state();
        }
    }
}

static void handle_lbracket(void) {
    bracket_depth++;
}

static void handle_rbracket(void) {
    if (bracket_depth > 0) {
        bracket_depth--;
    }
}

static void handle_comma(void) {
    if (macro_mode != MACRO_NONE && macro_depth == 1 && macro_arg_index == 0) {
        record_macro_first_arg();
        macro_arg_index++;
    } else if (paren_depth == 0 && bracket_depth == 0) {
        reset_candidate_state();
    }
}

static void handle_semi(void) {
    if (paren_depth == 0 && bracket_depth == 0) {
        reset_candidate_state();
        reset_macro_state();
    }
}

static void handle_assign(void) {
    if (paren_depth == 0 && bracket_depth == 0) {
        reset_candidate_state();
    }
}

static void handle_block(void) {
    if (paren_depth == 0 && bracket_depth == 0) {
        if (pending_name) {
            record_function(pending_name);
        }
        reset_candidate_state();
        reset_macro_state();
    }
}

%}

%union {
    char *str;
}

%token <str> IDENTIFIER
%token <str> CONSTANT STRING_LITERAL PP_DEFINE
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
    : IDENTIFIER { handle_identifier($1); free($1); }
    | CONSTANT { handle_constant($1); free($1); }
    | STRING_LITERAL { free($1); }
    | PP_DEFINE { set_array_rename_prefix($1); free($1); }
    | TYPEDEF { handle_decl_token(); }
    | EXTERN { handle_decl_token(); }
    | STATIC { handle_decl_token(); }
    | AUTO { handle_decl_token(); }
    | REGISTER { handle_decl_token(); }
    | THREAD_LOCAL { handle_decl_token(); }
    | VOID { handle_decl_token(); }
    | CHAR { handle_decl_token(); }
    | SHORT { handle_decl_token(); }
    | INT { handle_decl_token(); }
    | LONG { handle_decl_token(); }
    | FLOAT { handle_decl_token(); }
    | DOUBLE { handle_decl_token(); }
    | SIGNED { handle_decl_token(); }
    | UNSIGNED { handle_decl_token(); }
    | BOOL { handle_decl_token(); }
    | COMPLEX { handle_decl_token(); }
    | IMAGINARY { handle_decl_token(); }
    | STRUCT { handle_decl_token(); }
    | UNION { handle_decl_token(); }
    | ENUM { handle_decl_token(); }
    | CONST { handle_decl_token(); }
    | VOLATILE { handle_decl_token(); }
    | RESTRICT { handle_decl_token(); }
    | ATOMIC { handle_decl_token(); }
    | INLINE { handle_decl_token(); }
    | NORETURN { handle_decl_token(); }
    | ALIGNAS { handle_decl_token(); }
    | TYPEOF { handle_decl_token(); }
    | ATTRIBUTE { /* ignore */ }
    | DECLSPEC { /* ignore */ }
    | ASM { /* ignore */ }
    | ELLIPSIS { /* ignore */ }
    | '(' { handle_lparen(); }
    | ')' { handle_rparen(); }
    | '[' { handle_lbracket(); }
    | ']' { handle_rbracket(); }
    | ',' { handle_comma(); }
    | ';' { handle_semi(); }
    | '=' { handle_assign(); }
    | '*' { /* ignore */ }
    | BLOCK { handle_block(); }
    | OTHER { /* ignore */ }
    ;

%%

void parser_reset_state(void) {
    reset_candidate_state();
    reset_macro_state();
    clear_string(&array_rename_arg);
    array_rename_capture = 0;
    array_rename_depth = 0;
    strcpy(array_rename_prefix, "write_float_");
}

void yyerror(const char *s) {
    (void)s;
}

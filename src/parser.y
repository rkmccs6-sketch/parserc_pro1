%code requires {
typedef struct ArgList ArgList;
void record_function(const char *name);
void parser_reset_state(void);
void macro_register_definition(const char *line);
int macro_lookup_token(const char *name);
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

typedef struct ArgList {
    char **items;
    size_t count;
    size_t capacity;
} ArgList;

typedef struct {
    char *text;
    int is_param;
} NamePart;

typedef struct {
    NamePart *items;
    size_t count;
    size_t capacity;
} NamePartList;

typedef struct {
    char *name;
    char **params;
    size_t param_count;
    NamePartList *name_parts;
    NamePartList *expansion_parts;
} MacroDef;

typedef struct {
    MacroDef *items;
    size_t count;
    size_t capacity;
} MacroList;

static MacroList macro_list = {0};

static ArgList *arg_list_new(void) {
    ArgList *list = (ArgList *)calloc(1, sizeof(ArgList));
    return list;
}

static void arg_list_add(ArgList *list, char *value) {
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

static void arg_list_free(ArgList *list) {
    if (!list) {
        return;
    }
    for (size_t i = 0; i < list->count; i++) {
        free(list->items[i]);
    }
    free(list->items);
    free(list);
}

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
    macro->name = NULL;
    macro->params = NULL;
    macro->param_count = 0;
    macro->name_parts = NULL;
    macro->expansion_parts = NULL;
}

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

static MacroDef *macro_find(const char *name) {
    if (!name) {
        return NULL;
    }
    for (size_t i = macro_list.count; i > 0; i--) {
        MacroDef *macro = &macro_list.items[i - 1];
        if (macro->name && strcmp(macro->name, name) == 0) {
            return macro;
        }
    }
    return NULL;
}


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

static int is_reserved_name(const char *name) {
    static const char *reserved[] = {
        "if",
        "else",
        "for",
        "while",
        "do",
        "switch",
        "case",
        "default",
        "break",
        "continue",
        "return",
        "goto",
        "sizeof",
    };
    size_t count = sizeof(reserved) / sizeof(reserved[0]);
    for (size_t i = 0; i < count; i++) {
        if (strcmp(name, reserved[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

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
            if (i + 1 < len && text[i + 1] == '\n') {
                i += 2;
                continue;
            }
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

typedef enum {
    MACRO_TOK_EOF = 0,
    MACRO_TOK_IDENT,
    MACRO_TOK_PASTE,
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
        if (c == '/' && text[i + 1] == '/') {
            i = i + 2;
            while (text[i] && text[i] != '\n') {
                i++;
            }
            continue;
        }
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
        if (c == '#' && text[i + 1] == '#') {
            i += 2;
            *idx = i;
            return MACRO_TOK_PASTE;
        }
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
        i++;
        *idx = i;
        switch (c) {
        case '(':
            return MACRO_TOK_LPAREN;
        case ')':
            return MACRO_TOK_RPAREN;
        case '[':
            return MACRO_TOK_LBRACKET;
        case ']':
            return MACRO_TOK_RBRACKET;
        case '{':
            return MACRO_TOK_LBRACE;
        case '}':
            return MACRO_TOK_RBRACE;
        case ',':
            return MACRO_TOK_COMMA;
        case ';':
            return MACRO_TOK_SEMI;
        case '=':
            return MACRO_TOK_ASSIGN;
        default:
            return MACRO_TOK_OTHER;
        }
    }
    *idx = i;
    return MACRO_TOK_EOF;
}

static NamePartList *name_parts_from_ident(const char *ident, char **params, size_t param_count) {
    NamePartList *list = name_parts_new();
    if (!list) {
        return NULL;
    }
    int is_param = 0;
    for (size_t i = 0; i < param_count; i++) {
        if (strcmp(params[i], ident) == 0) {
            is_param = 1;
            break;
        }
    }
    name_parts_add(list, ident, is_param);
    return list;
}

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
                name_parts_free(parts);
                name_parts_free(piece);
                return NULL;
            }
            pending_paste = 0;
            continue;
        }
        name_parts_free(parts);
        return NULL;
    }
    if (pending_paste) {
        name_parts_free(parts);
        return NULL;
    }
    return parts;
}

static int parse_macro_definition(const char *line, char **name_out, char ***params_out, size_t *param_count, char **body_out) {
    const char *define_pos = strstr(line, "define");
    if (!define_pos) {
        return 0;
    }
    const char *p = define_pos + strlen("define");
    while (*p && isspace((unsigned char)*p)) {
        p++;
    }
    if (!isalpha((unsigned char)*p) && *p != '_') {
        return 0;
    }
    const char *name_start = p;
    while (*p && (isalnum((unsigned char)*p) || *p == '_')) {
        p++;
    }
    char *name = dup_range(name_start, p);
    if (!name) {
        return 0;
    }
    while (*p && isspace((unsigned char)*p)) {
        p++;
    }
    if (*p != '(') {
        free(name);
        return 0;
    }
    p++;

    size_t cap = 0;
    size_t count = 0;
    char **params = NULL;

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
        if (*p != ')') {
            while (*p && *p != ',' && *p != ')') {
                p++;
            }
        }
    }
    if (*p != ')') {
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

void macro_register_definition(const char *line) {
    char *name = NULL;
    char **params = NULL;
    size_t param_count = 0;
    char *body = NULL;
    if (!parse_macro_definition(line, &name, &params, &param_count, &body)) {
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
    NamePartList *name_parts = extract_function_name_template(body, params, param_count);
    NamePartList *expansion_parts = extract_macro_expansion_parts(body, params, param_count);
    free(body);
    if (name_parts && name_parts->count == 0) {
        name_parts_free(name_parts);
        name_parts = NULL;
    }
    if (expansion_parts && expansion_parts->count == 0) {
        name_parts_free(expansion_parts);
        expansion_parts = NULL;
    }
    MacroDef macro = {0};
    macro.name = name;
    macro.params = params;
    macro.param_count = param_count;
    macro.name_parts = name_parts;
    macro.expansion_parts = expansion_parts;
    macro_list_add(&macro);
}

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
        const char *text = part->is_param ? macro_arg_for_param(macro, args, part->text) : part->text;
        if (!text) {
            text = "";
        }
        size_t add = strlen(text);
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
    if (!is_valid_identifier(out) || is_reserved_name(out)) {
        free(out);
        return NULL;
    }
    return out;
}

static char *render_macro_name(const char *macro_name, const ArgList *args) {
    MacroDef *macro = macro_find(macro_name);
    return render_macro_parts(macro, args, macro ? macro->name_parts : NULL);
}

static char *render_macro_expansion(const char *macro_name, const ArgList *args) {
    MacroDef *macro = macro_find(macro_name);
    return render_macro_parts(macro, args, macro ? macro->expansion_parts : NULL);
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
    ArgList *args;
}

%token <str> IDENTIFIER
%token <str> CONSTANT STRING_LITERAL PP_DEFINE
%token <str> MACRO_TEMPLATE MACRO_RENAME MACRO_CALL
%token ARRAY_RENAME
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
%type <str> macro_arg macro_arg_parts macro_arg_piece macro_arg_group macro_arg_group_piece
%type <args> macro_arg_list macro_arg_list_opt
%type <str> array_rename_invocation macro_rename_invocation

%destructor { free($$); } <str>
%destructor { arg_list_free($$); } <args>

%%

program:
    /* empty */
    | program element
    ;

element:
    func_definition
    | macro_template_invocation
    | macro_call
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

macro_template_invocation
    : MACRO_TEMPLATE '(' macro_arg_list_opt ')' {
        char *name = render_macro_name($1, $3);
        if (name) {
            record_function(name);
            free(name);
        }
    }
    ;

macro_call
    : MACRO_CALL '(' macro_arg_list_opt ')' { }
    | MACRO_CALL '(' macro_arg_list_opt ')' ';' { }
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
    | macro_rename_invocation { $$ = $1; }
    | array_rename_invocation { $$ = $1; }
    | '*' { $$ = strdup("*"); }
    ;

macro_rename_invocation
    : MACRO_RENAME '(' macro_arg_list_opt ')' {
        char *expanded = render_macro_expansion($1, $3);
        if (expanded) {
            $$ = expanded;
        } else {
            $$ = strdup($1);
        }
    }
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
    : macro_arg_parts { $$ = $1; $1 = NULL; }
    ;

macro_arg_list_opt
    : /* empty */ { $$ = arg_list_new(); }
    | macro_arg_list { $$ = $1; }
    ;

macro_arg_list
    : macro_arg {
        $$ = arg_list_new();
        arg_list_add($$, $1);
        $1 = NULL;
    }
    | macro_arg_list ',' macro_arg {
        arg_list_add($1, $3);
        $3 = NULL;
        $$ = $1;
    }
    | macro_arg_list ',' {
        arg_list_add($1, strdup(""));
        $$ = $1;
    }
    ;

macro_arg_parts
    : macro_arg_piece { $$ = $1; $1 = NULL; }
    | macro_arg_parts macro_arg_piece {
        $$ = concat($1, $2);
        free($1);
        free($2);
        $1 = NULL;
        $2 = NULL;
    }
    ;

macro_arg_piece
    : token_chunk { $$ = $1; $1 = NULL; }
    | MACRO_CALL { $$ = $1; $1 = NULL; }
    | MACRO_RENAME { $$ = $1; $1 = NULL; }
    | MACRO_TEMPLATE { $$ = $1; $1 = NULL; }
    | '*' { $$ = strdup("*"); }
    | '+' { $$ = strdup("+"); }
    | '-' { $$ = strdup("-"); }
    | '=' { $$ = strdup("="); }
    | '(' macro_arg_group ')' {
        char *temp = concat("(", $2);
        $$ = concat(temp, ")");
        free(temp);
        free($2);
        $2 = NULL;
    }
    | '[' macro_arg_group ']' {
        char *temp = concat("[", $2);
        $$ = concat(temp, "]");
        free(temp);
        free($2);
        $2 = NULL;
    }
    ;

macro_arg_group
    : /* empty */ { $$ = strdup(""); }
    | macro_arg_group macro_arg_group_piece {
        $$ = concat($1, $2);
        free($1);
        free($2);
        $1 = NULL;
        $2 = NULL;
    }
    ;

macro_arg_group_piece
    : macro_arg_piece { $$ = $1; $1 = NULL; }
    | ',' { $$ = strdup(","); }
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

int macro_lookup_token(const char *name) {
    MacroDef *macro = macro_find(name);
    if (!macro) {
        return 0;
    }
    if (macro->name_parts && macro->name_parts->count > 0) {
        return MACRO_TEMPLATE;
    }
    if (macro->expansion_parts && macro->expansion_parts->count > 0) {
        return MACRO_RENAME;
    }
    return MACRO_CALL;
}

void parser_reset_state(void) {
    macro_list_reset();
    strcpy(array_rename_prefix, "write_float_");
}

void yyerror(const char *s) {
    (void)s;
}

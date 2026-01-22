#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "parser.tab.h"

extern int yyparse(void);
extern FILE *yyin;
extern void yyrestart(FILE *input_file);
extern void lexer_reset(void);
typedef struct yy_buffer_state *YY_BUFFER_STATE;
extern YY_BUFFER_STATE yy_scan_bytes(const char *bytes, int len);
extern void yy_delete_buffer(YY_BUFFER_STATE buffer);

static int parse_error_count = 0;

typedef struct function_list {
    char **items;
    size_t count;
    size_t capacity;
} StringList;

static StringList g_functions;

static char *last_identifier = NULL;
static char *paren_candidate = NULL;
static char *pending_name = NULL;
static int paren_depth = 0;
static int bracket_depth = 0;

static char *xstrdup(const char *s) {
    size_t len = 0;
    char *out = NULL;

    if (!s) {
        return NULL;
    }

    len = strlen(s);
    out = (char *)malloc(len + 1);
    if (!out) {
        return NULL;
    }
    memcpy(out, s, len + 1);
    return out;
}

static void string_list_init(StringList *list) {
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static void string_list_free(StringList *list) {
    size_t i = 0;
    for (i = 0; i < list->count; i++) {
        free(list->items[i]);
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static int string_list_contains(const StringList *list, const char *name) {
    size_t i = 0;
    for (i = 0; i < list->count; i++) {
        if (strcmp(list->items[i], name) == 0) {
            return 1;
        }
    }
    return 0;
}

static void string_list_add_copy(StringList *list, const char *name) {
    char *copy = NULL;
    size_t new_cap = 0;

    if (!name) {
        return;
    }

    copy = xstrdup(name);
    if (!copy) {
        return;
    }

    if (list->count == list->capacity) {
        new_cap = list->capacity == 0 ? 16 : list->capacity * 2;
        char **new_items = (char **)realloc(list->items, new_cap * sizeof(char *));
        if (!new_items) {
            free(copy);
            return;
        }
        list->items = new_items;
        list->capacity = new_cap;
    }

    list->items[list->count++] = copy;
}

static void string_list_add_unique(StringList *list, const char *name) {
    if (!string_list_contains(list, name)) {
        string_list_add_copy(list, name);
    }
}

static void clear_string(char **ptr) {
    if (*ptr) {
        free(*ptr);
        *ptr = NULL;
    }
}

static void add_function(const char *name) {
    string_list_add_copy(&g_functions, name);
}

void record_function(const char *name) {
    add_function(name);
}

void process_identifier(const char *name) {
    clear_string(&last_identifier);
    if (name) {
        last_identifier = xstrdup(name);
    }
}

static void reset_candidate_state(void) {
    clear_string(&last_identifier);
    clear_string(&paren_candidate);
    clear_string(&pending_name);
    paren_depth = 0;
    bracket_depth = 0;
}

void process_token(enum token_kind kind) {
    switch (kind) {
    case TOK_DECL:
        if (paren_depth == 0 && bracket_depth == 0) {
            clear_string(&paren_candidate);
            clear_string(&pending_name);
        }
        break;
    case TOK_LPAREN:
        if (!pending_name && paren_depth == 0) {
            clear_string(&paren_candidate);
            if (last_identifier) {
                paren_candidate = xstrdup(last_identifier);
            }
        }
        paren_depth++;
        break;
    case TOK_RPAREN:
        if (paren_depth > 0) {
            paren_depth--;
            if (paren_depth == 0 && !pending_name && paren_candidate) {
                pending_name = paren_candidate;
                paren_candidate = NULL;
            }
        }
        break;
    case TOK_LBRACKET:
        bracket_depth++;
        break;
    case TOK_RBRACKET:
        if (bracket_depth > 0) {
            bracket_depth--;
        }
        break;
    case TOK_BLOCK:
        if (paren_depth == 0 && bracket_depth == 0) {
            if (pending_name) {
                record_function(pending_name);
            }
            reset_candidate_state();
        }
        break;
    case TOK_SEMI:
    case TOK_COMMA:
    case TOK_ASSIGN:
        if (paren_depth == 0 && bracket_depth == 0) {
            reset_candidate_state();
        }
        break;
    case TOK_OTHER:
    default:
        break;
    }
}

void yyerror(const char *s) {
    (void)s;
    parse_error_count++;
}

static void free_functions(void) {
    string_list_free(&g_functions);
}

static void json_escape_and_print(const char *s) {
    const unsigned char *p = (const unsigned char *)s;
    putchar('"');
    while (*p) {
        unsigned char c = *p++;
        switch (c) {
        case '\\':
            fputs("\\\\", stdout);
            break;
        case '"':
            fputs("\\\"", stdout);
            break;
        case '\b':
            fputs("\\b", stdout);
            break;
        case '\f':
            fputs("\\f", stdout);
            break;
        case '\n':
            fputs("\\n", stdout);
            break;
        case '\r':
            fputs("\\r", stdout);
            break;
        case '\t':
            fputs("\\t", stdout);
            break;
        default:
            if (c < 0x20) {
                fprintf(stdout, "\\u%04x", c);
            } else {
                fputc(c, stdout);
            }
            break;
        }
    }
    putchar('"');
}

static void print_json_array_list(const StringList *list, int newline) {
    size_t i = 0;
    putchar('[');
    for (i = 0; i < list->count; i++) {
        if (i > 0) {
            putchar(',');
        }
        json_escape_and_print(list->items[i]);
    }
    putchar(']');
    if (newline) {
        putchar('\n');
    }
}

static void print_json_record(const char *path, const StringList *list) {
    fputs("{\"path\":", stdout);
    json_escape_and_print(path);
    fputs(",\"fc\":", stdout);
    print_json_array_list(list, 0);
    putchar('}');
    putchar('\n');
}

static const char *DECL_KEYWORDS[] = {
    "typedef",
    "extern",
    "static",
    "auto",
    "register",
    "_Thread_local",
    "__thread",
    "void",
    "char",
    "short",
    "int",
    "long",
    "float",
    "double",
    "signed",
    "unsigned",
    "_Bool",
    "_Complex",
    "_Imaginary",
    "struct",
    "union",
    "enum",
    "const",
    "volatile",
    "restrict",
    "_Atomic",
    "inline",
    "_Noreturn",
    "_Alignas",
    "typeof",
    "__typeof__",
    "__const",
    "__volatile__",
    "__restrict",
    "__restrict__",
    "__inline",
    "__inline__",
    "__alignas",
    "__alignas__",
    "__attribute__",
    "__attribute",
    "__declspec",
    "__asm__",
    "__asm",
    "asm",
    NULL
};

static const char *CONTROL_KEYWORDS[] = {
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
    NULL
};

static const char *C_KEYWORDS[] = {
    "auto",
    "break",
    "case",
    "char",
    "const",
    "continue",
    "default",
    "do",
    "double",
    "else",
    "enum",
    "extern",
    "float",
    "for",
    "goto",
    "if",
    "inline",
    "int",
    "long",
    "register",
    "restrict",
    "return",
    "short",
    "signed",
    "sizeof",
    "static",
    "struct",
    "switch",
    "typedef",
    "union",
    "unsigned",
    "void",
    "volatile",
    "while",
    "_Alignas",
    "_Alignof",
    "_Atomic",
    "_Bool",
    "_Complex",
    "_Generic",
    "_Imaginary",
    "_Noreturn",
    "_Static_assert",
    "_Thread_local",
    NULL
};

static int is_keyword(const char *name, const char *const *list) {
    size_t i = 0;
    if (!name) {
        return 0;
    }
    for (i = 0; list[i]; i++) {
        if (strcmp(name, list[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

static int is_c_keyword(const char *name) {
    return is_keyword(name, C_KEYWORDS);
}

typedef struct {
    char *data;
    size_t len;
    size_t capacity;
} StringBuffer;

static void buffer_init(StringBuffer *buf) {
    buf->data = NULL;
    buf->len = 0;
    buf->capacity = 0;
}

static void buffer_free(StringBuffer *buf) {
    free(buf->data);
    buf->data = NULL;
    buf->len = 0;
    buf->capacity = 0;
}

static void buffer_append_char(StringBuffer *buf, char c) {
    if (buf->len + 1 >= buf->capacity) {
        size_t new_cap = buf->capacity == 0 ? 64 : buf->capacity * 2;
        char *new_data = (char *)realloc(buf->data, new_cap);
        if (!new_data) {
            return;
        }
        buf->data = new_data;
        buf->capacity = new_cap;
    }
    buf->data[buf->len++] = c;
    buf->data[buf->len] = '\0';
}

static void buffer_append_slice(StringBuffer *buf, const char *start, size_t len) {
    size_t i = 0;
    for (i = 0; i < len; i++) {
        buffer_append_char(buf, start[i]);
    }
}

static char *copy_trimmed(const char *start, size_t len) {
    size_t left = 0;
    size_t right = len;
    while (left < len && isspace((unsigned char)start[left])) {
        left++;
    }
    while (right > left && isspace((unsigned char)start[right - 1])) {
        right--;
    }
    if (right <= left) {
        return xstrdup("");
    }
    return strndup(start + left, right - left);
}

static char *normalize_macro_arg(const char *arg) {
    size_t len = 0;
    size_t i = 0;
    size_t out_len = 0;
    char *out = NULL;

    if (!arg) {
        return xstrdup("");
    }
    len = strlen(arg);
    out = (char *)malloc(len + 1);
    if (!out) {
        return NULL;
    }
    for (i = 0; i < len; i++) {
        if (!isspace((unsigned char)arg[i])) {
            out[out_len++] = arg[i];
        }
    }
    out[out_len] = '\0';
    return out;
}

typedef struct {
    char *name;
    int count;
} NameCount;

typedef struct {
    NameCount *items;
    size_t count;
    size_t capacity;
} NameCountList;

static void name_count_init(NameCountList *list) {
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static void name_count_free(NameCountList *list) {
    size_t i = 0;
    for (i = 0; i < list->count; i++) {
        free(list->items[i].name);
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static void name_count_increment(NameCountList *list, const char *name) {
    size_t i = 0;
    for (i = 0; i < list->count; i++) {
        if (strcmp(list->items[i].name, name) == 0) {
            list->items[i].count++;
            return;
        }
    }
    if (list->count == list->capacity) {
        size_t new_cap = list->capacity == 0 ? 16 : list->capacity * 2;
        NameCount *new_items = (NameCount *)realloc(list->items, new_cap * sizeof(NameCount));
        if (!new_items) {
            return;
        }
        list->items = new_items;
        list->capacity = new_cap;
    }
    list->items[list->count].name = xstrdup(name);
    list->items[list->count].count = 1;
    list->count++;
}

static int name_count_get(const NameCountList *list, const char *name) {
    size_t i = 0;
    for (i = 0; i < list->count; i++) {
        if (strcmp(list->items[i].name, name) == 0) {
            return list->items[i].count;
        }
    }
    return 0;
}

static void name_count_decrement(NameCountList *list, const char *name) {
    size_t i = 0;
    for (i = 0; i < list->count; i++) {
        if (strcmp(list->items[i].name, name) == 0) {
            if (list->items[i].count > 0) {
                list->items[i].count--;
            }
            return;
        }
    }
}

typedef enum {
    PART_LITERAL,
    PART_PARAM
} PartKind;

typedef struct {
    PartKind kind;
    char *value;
} Part;

typedef struct {
    Part *items;
    size_t count;
    size_t capacity;
} PartList;

static void part_list_init(PartList *list) {
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static void part_list_free(PartList *list) {
    size_t i = 0;
    for (i = 0; i < list->count; i++) {
        free(list->items[i].value);
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static void part_list_append(PartList *list, PartKind kind, const char *value) {
    if (list->count == list->capacity) {
        size_t new_cap = list->capacity == 0 ? 8 : list->capacity * 2;
        Part *new_items = (Part *)realloc(list->items, new_cap * sizeof(Part));
        if (!new_items) {
            return;
        }
        list->items = new_items;
        list->capacity = new_cap;
    }
    list->items[list->count].kind = kind;
    list->items[list->count].value = xstrdup(value);
    list->count++;
}

static PartList *part_list_clone(const PartList *src) {
    PartList *out = (PartList *)malloc(sizeof(PartList));
    size_t i = 0;
    if (!out) {
        return NULL;
    }
    part_list_init(out);
    for (i = 0; i < src->count; i++) {
        part_list_append(out, src->items[i].kind, src->items[i].value);
    }
    return out;
}

static PartList *part_list_concat(const PartList *a, const PartList *b) {
    PartList *out = (PartList *)malloc(sizeof(PartList));
    size_t i = 0;
    if (!out) {
        return NULL;
    }
    part_list_init(out);
    for (i = 0; i < a->count; i++) {
        part_list_append(out, a->items[i].kind, a->items[i].value);
    }
    for (i = 0; i < b->count; i++) {
        part_list_append(out, b->items[i].kind, b->items[i].value);
    }
    return out;
}

static void part_list_free_ptr(PartList *list) {
    if (!list) {
        return;
    }
    part_list_free(list);
    free(list);
}

typedef enum {
    MTOK_IDENT,
    MTOK_PASTE,
    MTOK_SYMBOL
} MacroTokenKind;

typedef struct {
    MacroTokenKind kind;
    char *text;
    char symbol;
} MacroToken;

typedef struct {
    MacroToken *items;
    size_t count;
    size_t capacity;
} MacroTokenList;

static void token_list_init(MacroTokenList *list) {
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static void token_list_free(MacroTokenList *list) {
    size_t i = 0;
    for (i = 0; i < list->count; i++) {
        free(list->items[i].text);
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static void token_list_add_ident(MacroTokenList *list, const char *text) {
    if (list->count == list->capacity) {
        size_t new_cap = list->capacity == 0 ? 16 : list->capacity * 2;
        MacroToken *new_items = (MacroToken *)realloc(list->items, new_cap * sizeof(MacroToken));
        if (!new_items) {
            return;
        }
        list->items = new_items;
        list->capacity = new_cap;
    }
    list->items[list->count].kind = MTOK_IDENT;
    list->items[list->count].text = xstrdup(text);
    list->items[list->count].symbol = 0;
    list->count++;
}

static void token_list_add_symbol(MacroTokenList *list, char symbol) {
    if (list->count == list->capacity) {
        size_t new_cap = list->capacity == 0 ? 16 : list->capacity * 2;
        MacroToken *new_items = (MacroToken *)realloc(list->items, new_cap * sizeof(MacroToken));
        if (!new_items) {
            return;
        }
        list->items = new_items;
        list->capacity = new_cap;
    }
    list->items[list->count].kind = MTOK_SYMBOL;
    list->items[list->count].text = NULL;
    list->items[list->count].symbol = symbol;
    list->count++;
}

static void token_list_add_paste(MacroTokenList *list) {
    if (list->count == list->capacity) {
        size_t new_cap = list->capacity == 0 ? 16 : list->capacity * 2;
        MacroToken *new_items = (MacroToken *)realloc(list->items, new_cap * sizeof(MacroToken));
        if (!new_items) {
            return;
        }
        list->items = new_items;
        list->capacity = new_cap;
    }
    list->items[list->count].kind = MTOK_PASTE;
    list->items[list->count].text = NULL;
    list->items[list->count].symbol = 0;
    list->count++;
}

typedef struct {
    char *name;
    StringList params;
    PartList name_parts;
    PartList expansion_parts;
    int has_name_parts;
    int has_expansion_parts;
} MacroDef;

typedef struct {
    MacroDef *items;
    size_t count;
    size_t capacity;
} MacroList;

static void macro_list_init(MacroList *list) {
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static void macro_def_free(MacroDef *def) {
    if (!def) {
        return;
    }
    free(def->name);
    string_list_free(&def->params);
    part_list_free(&def->name_parts);
    part_list_free(&def->expansion_parts);
}

static void macro_list_free(MacroList *list) {
    size_t i = 0;
    for (i = 0; i < list->count; i++) {
        macro_def_free(&list->items[i]);
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static MacroDef *macro_list_add(MacroList *list, const char *name) {
    MacroDef *def = NULL;
    if (list->count == list->capacity) {
        size_t new_cap = list->capacity == 0 ? 8 : list->capacity * 2;
        MacroDef *new_items = (MacroDef *)realloc(list->items, new_cap * sizeof(MacroDef));
        if (!new_items) {
            return NULL;
        }
        list->items = new_items;
        list->capacity = new_cap;
    }
    def = &list->items[list->count++];
    def->name = xstrdup(name);
    string_list_init(&def->params);
    part_list_init(&def->name_parts);
    part_list_init(&def->expansion_parts);
    def->has_name_parts = 0;
    def->has_expansion_parts = 0;
    return def;
}

static MacroDef *macro_list_find(MacroList *list, const char *name, int require_name_parts, int require_expansion_parts) {
    size_t i = 0;
    for (i = list->count; i > 0; i--) {
        MacroDef *def = &list->items[i - 1];
        if (strcmp(def->name, name) != 0) {
            continue;
        }
        if (require_name_parts && !def->has_name_parts) {
            continue;
        }
        if (require_expansion_parts && !def->has_expansion_parts) {
            continue;
        }
        return def;
    }
    return NULL;
}

static int tokenize_macro_body(const char *body, MacroTokenList *tokens) {
    size_t i = 0;
    size_t len = strlen(body);
    token_list_init(tokens);
    while (i < len) {
        char c = body[i];
        if (isspace((unsigned char)c)) {
            i++;
            continue;
        }
        if (c == '/' && i + 1 < len && body[i + 1] == '/') {
            const char *nl = strchr(body + i, '\n');
            if (!nl) {
                break;
            }
            i = (size_t)(nl - body) + 1;
            continue;
        }
        if (c == '/' && i + 1 < len && body[i + 1] == '*') {
            const char *end = strstr(body + i + 2, "*/");
            if (!end) {
                break;
            }
            i = (size_t)(end - body) + 2;
            continue;
        }
        if (c == '"' || c == '\'') {
            char quote = c;
            i++;
            while (i < len) {
                if (body[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (body[i] == quote) {
                    i++;
                    break;
                }
                i++;
            }
            continue;
        }
        if (c == '#' && i + 1 < len && body[i + 1] == '#') {
            token_list_add_paste(tokens);
            i += 2;
            continue;
        }
        if (isalpha((unsigned char)c) || c == '_') {
            size_t start = i++;
            while (i < len && (isalnum((unsigned char)body[i]) || body[i] == '_')) {
                i++;
            }
            {
                char *name = strndup(body + start, i - start);
                if (name) {
                    token_list_add_ident(tokens, name);
                    free(name);
                }
            }
            continue;
        }
        if (strchr("(){}[];,=", c)) {
            token_list_add_symbol(tokens, c);
            i++;
            continue;
        }
        i++;
    }
    return 1;
}

static int extract_function_name_template(const char *body, const StringList *params, PartList *out_parts) {
    MacroTokenList tokens;
    PartList *last_parts = NULL;
    PartList *paren_candidate = NULL;
    PartList *pending_parts = NULL;
    int paren_depth = 0;
    int bracket_depth = 0;
    int pending_paste = 0;
    size_t i = 0;

    if (!tokenize_macro_body(body, &tokens)) {
        return 0;
    }

    for (i = 0; i < tokens.count; i++) {
        MacroToken *tok = &tokens.items[i];
        if (tok->kind == MTOK_PASTE) {
            pending_paste = last_parts != NULL;
            continue;
        }
        if (tok->kind == MTOK_IDENT) {
            PartList *parts = (PartList *)malloc(sizeof(PartList));
            if (!parts) {
                continue;
            }
            part_list_init(parts);
            if (string_list_contains(params, tok->text)) {
                part_list_append(parts, PART_PARAM, tok->text);
            } else {
                part_list_append(parts, PART_LITERAL, tok->text);
            }
            if (pending_paste && last_parts) {
                PartList *merged = part_list_concat(last_parts, parts);
                part_list_free_ptr(last_parts);
                part_list_free_ptr(parts);
                last_parts = merged;
            } else {
                part_list_free_ptr(last_parts);
                last_parts = parts;
            }
            pending_paste = 0;
            continue;
        }

        pending_paste = 0;
        if (tok->kind == MTOK_SYMBOL && tok->symbol == '(') {
            if (paren_depth == 0 && pending_parts == NULL) {
                part_list_free_ptr(paren_candidate);
                paren_candidate = last_parts ? part_list_clone(last_parts) : NULL;
            }
            paren_depth++;
        } else if (tok->kind == MTOK_SYMBOL && tok->symbol == ')') {
            if (paren_depth > 0) {
                paren_depth--;
                if (paren_depth == 0 && pending_parts == NULL && paren_candidate) {
                    pending_parts = paren_candidate;
                    paren_candidate = NULL;
                }
            }
        } else if (tok->kind == MTOK_SYMBOL && tok->symbol == '[') {
            bracket_depth++;
        } else if (tok->kind == MTOK_SYMBOL && tok->symbol == ']') {
            if (bracket_depth > 0) {
                bracket_depth--;
            }
        } else if (tok->kind == MTOK_SYMBOL && tok->symbol == '{') {
            if (paren_depth == 0 && bracket_depth == 0 && pending_parts) {
                part_list_free(out_parts);
                *out_parts = *pending_parts;
                free(pending_parts);
                pending_parts = NULL;
                token_list_free(&tokens);
                part_list_free_ptr(last_parts);
                part_list_free_ptr(paren_candidate);
                return 1;
            }
        } else if (tok->kind == MTOK_SYMBOL && (tok->symbol == ',' || tok->symbol == ';' || tok->symbol == '=')) {
            if (paren_depth == 0 && bracket_depth == 0) {
                part_list_free_ptr(last_parts);
                part_list_free_ptr(paren_candidate);
                part_list_free_ptr(pending_parts);
                last_parts = NULL;
                paren_candidate = NULL;
                pending_parts = NULL;
            }
        }
    }

    token_list_free(&tokens);
    part_list_free_ptr(last_parts);
    part_list_free_ptr(paren_candidate);
    part_list_free_ptr(pending_parts);
    return 0;
}

static int extract_macro_expansion_parts(const char *body, const StringList *params, PartList *out_parts) {
    MacroTokenList tokens;
    int pending_paste = 0;
    size_t i = 0;

    if (!tokenize_macro_body(body, &tokens)) {
        return 0;
    }

    for (i = 0; i < tokens.count; i++) {
        MacroToken *tok = &tokens.items[i];
        if (tok->kind == MTOK_PASTE) {
            pending_paste = 1;
            continue;
        }
        if (tok->kind == MTOK_IDENT) {
            if (out_parts->count == 0) {
                if (string_list_contains(params, tok->text)) {
                    part_list_append(out_parts, PART_PARAM, tok->text);
                } else {
                    part_list_append(out_parts, PART_LITERAL, tok->text);
                }
            } else if (pending_paste) {
                if (string_list_contains(params, tok->text)) {
                    part_list_append(out_parts, PART_PARAM, tok->text);
                } else {
                    part_list_append(out_parts, PART_LITERAL, tok->text);
                }
            } else {
                token_list_free(&tokens);
                return 0;
            }
            pending_paste = 0;
            continue;
        }
        token_list_free(&tokens);
        return 0;
    }

    token_list_free(&tokens);
    return out_parts->count > 0;
}

static int parse_macro_args(const char *text, size_t len, size_t start_idx, StringList *args, size_t *out_end) {
    size_t i = start_idx;
    int depth = 0;
    StringBuffer current;

    string_list_init(args);
    buffer_init(&current);

    if (start_idx >= len || text[start_idx] != '(') {
        buffer_free(&current);
        return 0;
    }

    depth = 1;
    i++;

    while (i < len) {
        char c = text[i];
        if (c == '(') {
            depth++;
            buffer_append_char(&current, c);
            i++;
            continue;
        }
        if (c == ')') {
            depth--;
            if (depth == 0) {
                if (current.len > 0 || args->count > 0) {
                    char *trimmed = copy_trimmed(current.data, current.len);
                    string_list_add_copy(args, trimmed);
                    free(trimmed);
                }
                buffer_free(&current);
                if (out_end) {
                    *out_end = i + 1;
                }
                return 1;
            }
            buffer_append_char(&current, c);
            i++;
            continue;
        }
        if (c == ',' && depth == 1) {
            char *trimmed = copy_trimmed(current.data, current.len);
            string_list_add_copy(args, trimmed);
            free(trimmed);
            buffer_free(&current);
            buffer_init(&current);
            i++;
            continue;
        }
        if (c == '/' && i + 1 < len && text[i + 1] == '/') {
            const char *nl = strchr(text + i, '\n');
            if (!nl) {
                break;
            }
            i = (size_t)(nl - text);
            continue;
        }
        if (c == '/' && i + 1 < len && text[i + 1] == '*') {
            const char *end = strstr(text + i + 2, "*/");
            if (!end) {
                break;
            }
            i = (size_t)(end - text) + 2;
            continue;
        }
        if (c == '"' || c == '\'') {
            char quote = c;
            buffer_append_char(&current, c);
            i++;
            while (i < len) {
                buffer_append_char(&current, text[i]);
                if (text[i] == '\\') {
                    if (i + 1 < len) {
                        i++;
                        buffer_append_char(&current, text[i]);
                    }
                    i++;
                    continue;
                }
                if (text[i] == quote) {
                    i++;
                    break;
                }
                i++;
            }
            continue;
        }
        buffer_append_char(&current, c);
        i++;
    }

    buffer_free(&current);
    return 0;
}

static char *render_macro_name(const PartList *parts, const StringList *params, const StringList *args) {
    size_t i = 0;
    size_t j = 0;
    StringList normalized_args;
    StringBuffer output;

    if (!parts || parts->count == 0) {
        return NULL;
    }

    string_list_init(&normalized_args);
    for (i = 0; i < args->count; i++) {
        char *norm = normalize_macro_arg(args->items[i]);
        if (!norm) {
            norm = xstrdup("");
        }
        string_list_add_copy(&normalized_args, norm);
        free(norm);
    }

    buffer_init(&output);

    for (i = 0; i < parts->count; i++) {
        const Part *part = &parts->items[i];
        if (part->kind == PART_LITERAL) {
            buffer_append_slice(&output, part->value, strlen(part->value));
        } else {
            for (j = 0; j < params->count; j++) {
                if (strcmp(params->items[j], part->value) == 0) {
                    if (j < normalized_args.count) {
                        buffer_append_slice(&output, normalized_args.items[j], strlen(normalized_args.items[j]));
                    }
                    break;
                }
            }
        }
    }

    string_list_free(&normalized_args);

    if (output.len == 0) {
        buffer_free(&output);
        return NULL;
    }

    if (!isalpha((unsigned char)output.data[0]) && output.data[0] != '_') {
        buffer_free(&output);
        return NULL;
    }
    for (i = 1; i < output.len; i++) {
        if (!isalnum((unsigned char)output.data[i]) && output.data[i] != '_') {
            buffer_free(&output);
            return NULL;
        }
    }

    if (is_c_keyword(output.data)) {
        buffer_free(&output);
        return NULL;
    }

    return output.data;
}

static int line_ends_with_backslash(const char *line, size_t len) {
    size_t i = len;
    while (i > 0 && (line[i - 1] == '\n' || line[i - 1] == '\r' || isspace((unsigned char)line[i - 1]))) {
        i--;
    }
    return i > 0 && line[i - 1] == '\\';
}

static void append_macro_line(StringBuffer *body, const char *line, size_t len, int strip_continuation) {
    size_t slice_len = len;
    if (strip_continuation) {
        while (slice_len > 0 && isspace((unsigned char)line[slice_len - 1])) {
            slice_len--;
        }
        if (slice_len > 0 && line[slice_len - 1] == '\\') {
            slice_len--;
        }
    }
    buffer_append_slice(body, line, slice_len);
}

static void parse_macro_definitions(const char *text, size_t len, MacroList *macros) {
    const char *line = text;
    const char *end = text + len;

    macro_list_init(macros);

    while (line < end) {
        const char *line_end = memchr(line, '\n', (size_t)(end - line));
        size_t line_len = line_end ? (size_t)(line_end - line) : (size_t)(end - line);
        const char *p = line;

        while (p < line + line_len && isspace((unsigned char)*p)) {
            p++;
        }
        if (p >= line + line_len || *p != '#') {
            line = line_end ? line_end + 1 : end;
            continue;
        }
        p++;
        while (p < line + line_len && isspace((unsigned char)*p)) {
            p++;
        }
        if (p + 6 > line + line_len || strncmp(p, "define", 6) != 0) {
            line = line_end ? line_end + 1 : end;
            continue;
        }
        p += 6;
        if (p < line + line_len && !isspace((unsigned char)*p)) {
            line = line_end ? line_end + 1 : end;
            continue;
        }
        while (p < line + line_len && isspace((unsigned char)*p)) {
            p++;
        }
        if (p >= line + line_len || !(isalpha((unsigned char)*p) || *p == '_')) {
            line = line_end ? line_end + 1 : end;
            continue;
        }
        const char *name_start = p;
        while (p < line + line_len && (isalnum((unsigned char)*p) || *p == '_')) {
            p++;
        }
        char *macro_name = strndup(name_start, (size_t)(p - name_start));
        while (p < line + line_len && isspace((unsigned char)*p)) {
            p++;
        }
        if (p >= line + line_len || *p != '(') {
            free(macro_name);
            line = line_end ? line_end + 1 : end;
            continue;
        }
        p++;
        StringList params;
        string_list_init(&params);
        StringBuffer param_buf;
        buffer_init(&param_buf);
        while (p < line + line_len) {
            if (*p == ')') {
                char *trimmed = copy_trimmed(param_buf.data, param_buf.len);
                if (trimmed && trimmed[0] != '\0') {
                    string_list_add_copy(&params, trimmed);
                }
                free(trimmed);
                p++;
                break;
            }
            if (*p == ',') {
                char *trimmed = copy_trimmed(param_buf.data, param_buf.len);
                if (trimmed && trimmed[0] != '\0') {
                    string_list_add_copy(&params, trimmed);
                }
                free(trimmed);
                buffer_free(&param_buf);
                buffer_init(&param_buf);
                p++;
                continue;
            }
            buffer_append_char(&param_buf, *p);
            p++;
        }
        buffer_free(&param_buf);

        StringBuffer body;
        buffer_init(&body);
        if (p < line + line_len) {
            append_macro_line(&body, p, (size_t)(line + line_len - p), line_ends_with_backslash(line, line_len));
        }

        while (line_ends_with_backslash(line, line_len)) {
            line = line_end ? line_end + 1 : end;
            if (line >= end) {
                break;
            }
            line_end = memchr(line, '\n', (size_t)(end - line));
            line_len = line_end ? (size_t)(line_end - line) : (size_t)(end - line);
            buffer_append_char(&body, '\n');
            append_macro_line(&body, line, line_len, line_ends_with_backslash(line, line_len));
        }

        MacroDef *def = macro_list_add(macros, macro_name);
        if (def) {
            size_t i = 0;
            for (i = 0; i < params.count; i++) {
                string_list_add_copy(&def->params, params.items[i]);
            }
            if (extract_function_name_template(body.data ? body.data : "", &def->params, &def->name_parts)) {
                def->has_name_parts = 1;
            }
            if (extract_macro_expansion_parts(body.data ? body.data : "", &def->params, &def->expansion_parts)) {
                def->has_expansion_parts = 1;
            }
        }
        string_list_free(&params);
        buffer_free(&body);
        free(macro_name);

        line = line_end ? line_end + 1 : end;
    }
}

static int skip_preprocessor_line(const char *text, size_t len, size_t start_idx, size_t *out_end) {
    size_t i = start_idx;
    while (i < len) {
        if (text[i] == '\n') {
            if (i > 0 && text[i - 1] == '\\') {
                i++;
                continue;
            }
            if (out_end) {
                *out_end = i + 1;
            }
            return 1;
        }
        i++;
    }
    if (out_end) {
        *out_end = len;
    }
    return 1;
}

static void scan_function_definitions(const char *text, size_t len, MacroList *macros, StringList *ordered_defs, StringList *macro_named_defs, StringList *macro_template_defs, StringList *macro_used_names) {
    size_t i = 0;
    int at_line_start = 1;
    int brace_depth = 0;
    int paren_depth = 0;
    int bracket_depth = 0;
    char *last_identifier = NULL;
    char *last_identifier_macro = NULL;
    char *paren_candidate = NULL;
    char *paren_candidate_macro = NULL;
    char *pending_name = NULL;
    char *pending_name_macro = NULL;

    string_list_init(ordered_defs);
    string_list_init(macro_named_defs);
    string_list_init(macro_template_defs);
    string_list_init(macro_used_names);

    while (i < len) {
        char c = text[i];
        if (at_line_start) {
            size_t j = i;
            while (j < len && (text[j] == ' ' || text[j] == '\t')) {
                j++;
            }
            if (j < len && text[j] == '#') {
                skip_preprocessor_line(text, len, j, &i);
                at_line_start = 1;
                continue;
            }
        }

        if (c == '\n') {
            at_line_start = 1;
            i++;
            continue;
        }
        at_line_start = 0;

        if (c == '/' && i + 1 < len && text[i + 1] == '/') {
            size_t nl = i;
            while (nl < len && text[nl] != '\n') {
                nl++;
            }
            i = nl;
            continue;
        }
        if (c == '/' && i + 1 < len && text[i + 1] == '*') {
            const char *end = strstr(text + i + 2, "*/");
            if (!end) {
                break;
            }
            i = (size_t)(end - text) + 2;
            continue;
        }
        if (c == '"' || c == '\'') {
            char quote = c;
            i++;
            while (i < len) {
                if (text[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (text[i] == quote) {
                    i++;
                    break;
                }
                i++;
            }
            continue;
        }

        if (isalpha((unsigned char)c) || c == '_') {
            size_t start = i++;
            while (i < len && (isalnum((unsigned char)text[i]) || text[i] == '_')) {
                i++;
            }
            char *ident = strndup(text + start, i - start);
            if (is_keyword(ident, CONTROL_KEYWORDS)) {
                clear_string(&last_identifier);
                clear_string(&last_identifier_macro);
                free(ident);
                continue;
            }
            if (is_keyword(ident, DECL_KEYWORDS)) {
                if (brace_depth == 0 && paren_depth == 0 && bracket_depth == 0) {
                    clear_string(&last_identifier);
                    clear_string(&last_identifier_macro);
                    clear_string(&paren_candidate);
                    clear_string(&paren_candidate_macro);
                    clear_string(&pending_name);
                    clear_string(&pending_name_macro);
                }
                free(ident);
                continue;
            }

            MacroDef *template_macro = macro_list_find(macros, ident, 1, 0);
            if (template_macro && brace_depth == 0) {
                size_t j = i;
                while (j < len && isspace((unsigned char)text[j])) {
                    j++;
                }
                if (j < len && text[j] == '(') {
                    StringList args;
                    size_t end_idx = 0;
                    if (parse_macro_args(text, len, j, &args, &end_idx)) {
                        char *name = render_macro_name(&template_macro->name_parts, &template_macro->params, &args);
                        if (name) {
                            string_list_add_copy(ordered_defs, name);
                            string_list_add_copy(macro_template_defs, name);
                            free(name);
                        }
                        string_list_free(&args);
                        i = end_idx;
                        clear_string(&last_identifier);
                        clear_string(&last_identifier_macro);
                        free(ident);
                        continue;
                    }
                }
            }

            MacroDef *name_macro = macro_list_find(macros, ident, 0, 1);
            if (name_macro) {
                size_t j = i;
                while (j < len && isspace((unsigned char)text[j])) {
                    j++;
                }
                if (j < len && text[j] == '(') {
                    StringList args;
                    size_t end_idx = 0;
                    if (parse_macro_args(text, len, j, &args, &end_idx)) {
                        char *expanded = render_macro_name(&name_macro->expansion_parts, &name_macro->params, &args);
                        if (expanded) {
                            clear_string(&last_identifier);
                            clear_string(&last_identifier_macro);
                            last_identifier = xstrdup(expanded);
                            last_identifier_macro = xstrdup(ident);
                            free(expanded);
                        }
                        string_list_free(&args);
                        i = end_idx;
                        free(ident);
                        continue;
                    }
                }
            }

            clear_string(&last_identifier);
            clear_string(&last_identifier_macro);
            last_identifier = xstrdup(ident);
            free(ident);
            continue;
        }

        if (c == '(') {
            if (paren_depth == 0 && !pending_name) {
                clear_string(&paren_candidate);
                clear_string(&paren_candidate_macro);
                if (last_identifier) {
                    paren_candidate = xstrdup(last_identifier);
                }
                if (last_identifier_macro) {
                    paren_candidate_macro = xstrdup(last_identifier_macro);
                }
            }
            paren_depth++;
            i++;
            continue;
        }
        if (c == ')') {
            if (paren_depth > 0) {
                paren_depth--;
                if (paren_depth == 0 && !pending_name && paren_candidate) {
                    pending_name = paren_candidate;
                    pending_name_macro = paren_candidate_macro;
                    paren_candidate = NULL;
                    paren_candidate_macro = NULL;
                }
            }
            i++;
            continue;
        }
        if (c == '[') {
            bracket_depth++;
            i++;
            continue;
        }
        if (c == ']') {
            if (bracket_depth > 0) {
                bracket_depth--;
            }
            i++;
            continue;
        }
        if (c == '{') {
            if (brace_depth == 0 && paren_depth == 0 && bracket_depth == 0 && pending_name) {
                string_list_add_copy(ordered_defs, pending_name);
                if (pending_name_macro) {
                    string_list_add_copy(macro_named_defs, pending_name);
                    string_list_add_unique(macro_used_names, pending_name_macro);
                }
                clear_string(&pending_name);
                clear_string(&pending_name_macro);
                clear_string(&paren_candidate);
                clear_string(&paren_candidate_macro);
                clear_string(&last_identifier);
                clear_string(&last_identifier_macro);
            }
            brace_depth++;
            i++;
            continue;
        }
        if (c == '}') {
            if (brace_depth > 0) {
                brace_depth--;
            }
            i++;
            continue;
        }
        if ((c == ';' || c == ',' || c == '=') && brace_depth == 0 && paren_depth == 0 && bracket_depth == 0) {
            clear_string(&pending_name);
            clear_string(&pending_name_macro);
            clear_string(&paren_candidate);
            clear_string(&paren_candidate_macro);
            clear_string(&last_identifier);
            clear_string(&last_identifier_macro);
            i++;
            continue;
        }

        i++;
    }

    clear_string(&last_identifier);
    clear_string(&last_identifier_macro);
    clear_string(&paren_candidate);
    clear_string(&paren_candidate_macro);
    clear_string(&pending_name);
    clear_string(&pending_name_macro);
}

static char *read_file_content(const char *path, size_t *out_len) {
    FILE *fp = fopen(path, "rb");
    char *buf = NULL;
    long size = 0;
    size_t read_len = 0;

    if (!fp) {
        return NULL;
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return NULL;
    }
    size = ftell(fp);
    if (size < 0) {
        fclose(fp);
        return NULL;
    }
    if (fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        return NULL;
    }
    buf = (char *)malloc((size_t)size + 1);
    if (!buf) {
        fclose(fp);
        return NULL;
    }
    read_len = fread(buf, 1, (size_t)size, fp);
    fclose(fp);
    buf[read_len] = '\0';
    if (out_len) {
        *out_len = read_len;
    }
    return buf;
}

static void reset_parser_state(void) {
    parse_error_count = 0;
    reset_candidate_state();
    free_functions();
}

static int parse_file(const char *path, int batch_mode) {
    int rc = 0;
    char *content = NULL;
    size_t content_len = 0;
    YY_BUFFER_STATE buffer_state = NULL;
    MacroList macros;
    StringList ordered_defs;
    StringList macro_named_defs;
    StringList macro_template_defs;
    StringList macro_used_names;
    StringList target_names;
    StringList final_list;
    NameCountList counts;
    size_t i = 0;

    reset_parser_state();

    content = read_file_content(path, &content_len);
    if (!content) {
        fprintf(stderr, "error: cannot open file: %s\n", path);
        string_list_init(&final_list);
        if (batch_mode) {
            print_json_record(path, &final_list);
        } else {
            print_json_array_list(&final_list, 1);
        }
        string_list_free(&final_list);
        reset_parser_state();
        return 2;
    }

    lexer_reset();
    buffer_state = yy_scan_bytes(content, (int)content_len);
    if (yyparse() != 0) {
        parse_error_count++;
        rc = 1;
    }
    yy_delete_buffer(buffer_state);

    parse_macro_definitions(content, content_len, &macros);
    scan_function_definitions(content, content_len, &macros, &ordered_defs, &macro_named_defs, &macro_template_defs, &macro_used_names);

    string_list_init(&target_names);
    name_count_init(&counts);
    for (i = 0; i < g_functions.count; i++) {
        if (!string_list_contains(&macro_used_names, g_functions.items[i])) {
            string_list_add_copy(&target_names, g_functions.items[i]);
            name_count_increment(&counts, g_functions.items[i]);
        }
    }
    for (i = 0; i < macro_named_defs.count; i++) {
        string_list_add_copy(&target_names, macro_named_defs.items[i]);
        name_count_increment(&counts, macro_named_defs.items[i]);
    }
    for (i = 0; i < macro_template_defs.count; i++) {
        string_list_add_copy(&target_names, macro_template_defs.items[i]);
        name_count_increment(&counts, macro_template_defs.items[i]);
    }

    string_list_init(&final_list);
    for (i = 0; i < ordered_defs.count; i++) {
        if (name_count_get(&counts, ordered_defs.items[i]) > 0) {
            string_list_add_copy(&final_list, ordered_defs.items[i]);
            name_count_decrement(&counts, ordered_defs.items[i]);
        }
    }

    for (i = 0; i < target_names.count; i++) {
        while (name_count_get(&counts, target_names.items[i]) > 0) {
            string_list_add_copy(&final_list, target_names.items[i]);
            name_count_decrement(&counts, target_names.items[i]);
        }
    }

    if (batch_mode) {
        print_json_record(path, &final_list);
    } else {
        print_json_array_list(&final_list, 1);
    }

    string_list_free(&final_list);
    string_list_free(&target_names);
    name_count_free(&counts);
    string_list_free(&ordered_defs);
    string_list_free(&macro_named_defs);
    string_list_free(&macro_template_defs);
    string_list_free(&macro_used_names);
    macro_list_free(&macros);
    free(content);

    reset_parser_state();

    return rc;
}

int main(int argc, char **argv) {
    int batch_mode = 0;
    int start_idx = 1;
    int rc = 0;

    if (argc < 2) {
        fprintf(stderr, "usage: cfc_parser [--batch] <file.c> [file2.c ...]\n");
        return 2;
    }

    if (strcmp(argv[1], "--batch") == 0) {
        batch_mode = 1;
        start_idx = 2;
    }

    if (start_idx >= argc) {
        fprintf(stderr, "usage: cfc_parser [--batch] <file.c> [file2.c ...]\n");
        return 2;
    }

    for (int i = start_idx; i < argc; i++) {
        int file_rc = parse_file(argv[i], batch_mode);
        if (file_rc != 0) {
            rc = file_rc;
        }
    }

    return rc;
}

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int yyparse(void);
extern FILE *yyin;
extern void yyrestart(FILE *input_file);
extern void lexer_reset(void);
extern void parser_reset_state(void);

typedef struct {
    char **items;
    size_t count;
    size_t capacity;
} FunctionList;

static FunctionList g_functions;

static void list_init(FunctionList *list) {
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static void list_free(FunctionList *list) {
    size_t i = 0;
    for (i = 0; i < list->count; i++) {
        free(list->items[i]);
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static void list_add(FunctionList *list, const char *name) {
    size_t new_cap = 0;
    char *copy = NULL;

    if (!name) {
        return;
    }

    copy = strdup(name);
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

void record_function(const char *name) {
    list_add(&g_functions, name);
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

static void print_json_array(const FunctionList *list, int newline) {
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

static void print_json_record(const char *path, const FunctionList *list) {
    fputs("{\"path\":", stdout);
    json_escape_and_print(path);
    fputs(",\"fc\":", stdout);
    print_json_array(list, 0);
    putchar('}');
    putchar('\n');
}

static int parse_file(const char *path, int batch_mode) {
    int rc = 0;

    list_free(&g_functions);
    list_init(&g_functions);

    yyin = fopen(path, "r");
    if (!yyin) {
        fprintf(stderr, "error: cannot open file: %s\n", path);
        if (batch_mode) {
            print_json_record(path, &g_functions);
        } else {
            print_json_array(&g_functions, 1);
        }
        return 2;
    }

    lexer_reset();
    parser_reset_state();
    yyrestart(yyin);
    if (yyparse() != 0) {
        rc = 1;
    }

    fclose(yyin);

    if (batch_mode) {
        print_json_record(path, &g_functions);
    } else {
        print_json_array(&g_functions, 1);
    }

    return rc;
}

int main(int argc, char **argv) {
    int batch_mode = 0;
    int start_idx = 1;
    int rc = 0;

    list_init(&g_functions);

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

    list_free(&g_functions);
    return rc;
}

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int yyparse(void);
extern FILE *yyin;

static int parse_error_count = 0;

struct function_list {
    char **items;
    size_t count;
    size_t capacity;
};

static struct function_list g_functions;

static void add_function(const char *name) {
    char *copy = NULL;
    size_t new_cap = 0;

    if (!name) {
        return;
    }

    copy = strdup(name);
    if (!copy) {
        return;
    }

    if (g_functions.count == g_functions.capacity) {
        new_cap = g_functions.capacity == 0 ? 16 : g_functions.capacity * 2;
        char **new_items = (char **)realloc(g_functions.items, new_cap * sizeof(char *));
        if (!new_items) {
            free(copy);
            return;
        }
        g_functions.items = new_items;
        g_functions.capacity = new_cap;
    }

    g_functions.items[g_functions.count++] = copy;
}

void record_function(const char *name) {
    add_function(name);
}

void yyerror(const char *s) {
    (void)s;
    parse_error_count++;
}

static void free_functions(void) {
    size_t i = 0;
    for (i = 0; i < g_functions.count; i++) {
        free(g_functions.items[i]);
    }
    free(g_functions.items);
    g_functions.items = NULL;
    g_functions.count = 0;
    g_functions.capacity = 0;
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

static void print_json_array(void) {
    size_t i = 0;
    putchar('[');
    for (i = 0; i < g_functions.count; i++) {
        if (i > 0) {
            putchar(',');
        }
        json_escape_and_print(g_functions.items[i]);
    }
    puts("]");
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: cfc_parser <file.c>\n");
        return 2;
    }

    yyin = fopen(argv[1], "r");
    if (!yyin) {
        fprintf(stderr, "error: cannot open file: %s\n", argv[1]);
        return 2;
    }

    if (yyparse() != 0) {
        parse_error_count++;
    }

    fclose(yyin);
    print_json_array();
    free_functions();

    if (parse_error_count > 0) {
        return 0;
    }

    return 0;
}

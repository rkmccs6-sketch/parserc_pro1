.PHONY: all clean install uninstall

CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -std=c11 -D_POSIX_C_SOURCE=200809L -Ibuild
LEX := flex
YACC := bison

SRC_DIR := src
BUILD_DIR := build
BIN_DIR := bin
PREFIX ?= /usr/local
INSTALL_BINDIR ?= $(PREFIX)/bin

PARSER := $(BUILD_DIR)/cfc_parser

all: $(BIN_DIR)/parsercfc $(PARSER)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

$(BUILD_DIR)/parser.tab.c $(BUILD_DIR)/parser.tab.h: $(SRC_DIR)/parser.y | $(BUILD_DIR)
	$(YACC) -d -o $(BUILD_DIR)/parser.tab.c $(SRC_DIR)/parser.y

$(BUILD_DIR)/lex.yy.c: $(SRC_DIR)/lexer.l $(BUILD_DIR)/parser.tab.h | $(BUILD_DIR)
	$(LEX) -o $(BUILD_DIR)/lex.yy.c $(SRC_DIR)/lexer.l

$(PARSER): $(BUILD_DIR)/parser.tab.c $(BUILD_DIR)/lex.yy.c $(SRC_DIR)/cfc_parser.c
	$(CC) $(CFLAGS) -o $(PARSER) \
		$(BUILD_DIR)/parser.tab.c \
		$(BUILD_DIR)/lex.yy.c \
		$(SRC_DIR)/cfc_parser.c \
		-lfl

$(BIN_DIR)/parsercfc: $(SRC_DIR)/parsercfc.py | $(BIN_DIR)
	cp $(SRC_DIR)/parsercfc.py $(BIN_DIR)/parsercfc
	chmod +x $(BIN_DIR)/parsercfc

clean:
	rm -rf $(BUILD_DIR) $(BIN_DIR)

install: all
	install -d $(INSTALL_BINDIR)
	install -m 755 $(BIN_DIR)/parsercfc $(INSTALL_BINDIR)/parsercfc
	install -m 755 $(PARSER) $(INSTALL_BINDIR)/cfc_parser

uninstall:
	rm -f $(INSTALL_BINDIR)/parsercfc $(INSTALL_BINDIR)/cfc_parser

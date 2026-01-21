.PHONY: all clean

CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -std=c11
LEX ?= flex
YACC ?= bison

SRC_DIR := src
BUILD_DIR := build
BIN_DIR := bin

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

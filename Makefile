# ===========================================================================
# parserc_pro1 构建脚本
# ===========================================================================

# --- 伪目标声明 ---
# 声明这些目标不是具体的文件名，而是操作指令
.PHONY: all compile clean install uninstall

# --- 编译器与工具配置 ---
CC ?= gcc
# CFLAGS: 编译选项
# -O2: 开启优化
# -Wall -Wextra: 开启常用警告
# -std=c11: 使用 C11 标准
# -D_POSIX_C_SOURCE=200809L: 启用 POSIX 特性 (如 strdup, fdopen)
# -Ibuild -Isrc: 指定头文件搜索路径，确保能找到 parser.tab.h 和 utils.h
CFLAGS ?= -O2 -Wall -Wextra -std=c11 -D_POSIX_C_SOURCE=200809L -Ibuild -Isrc

# 代码生成工具
LEX := flex
YACC := bison

# --- 目录定义 ---
SRC_DIR := src
BUILD_DIR := build
BIN_DIR := bin

# 安装路径配置 (默认为 /usr/local)
PREFIX ?= /usr/local
INSTALL_BINDIR ?= $(PREFIX)/bin

# --- 目标文件定义 ---
# 最终生成的 C 二进制解析器
PARSER_BIN := $(BUILD_DIR)/cfc_parser
# 最终生成的 Python 封装脚本
WRAPPER_SCRIPT := $(BIN_DIR)/parsercfc

# --- 默认目标 ---
# 当只运行 'make' 时，默认执行 install (需要 sudo)
# 或者您可以改为 'make all' 对应 compile
all: install

# --- 编译目标 (Compile) ---
compile: $(WRAPPER_SCRIPT) $(PARSER_BIN)

# 创建构建目录
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# 创建二进制输出目录
$(BIN_DIR):
	mkdir -p $(BIN_DIR)

# --- Bison 编译规则 ---
# 输入: src/parser.y
# 输出: build/parser.tab.c 和 build/parser.tab.h
# 依赖: build 目录必须存在
$(BUILD_DIR)/parser.tab.c $(BUILD_DIR)/parser.tab.h: $(SRC_DIR)/parser.y | $(BUILD_DIR)
	@echo " [BISON] Generating parser..."
	$(YACC) -d -o $(BUILD_DIR)/parser.tab.c $(SRC_DIR)/parser.y

# --- Flex 编译规则 ---
# 输入: src/lexer.l
# 输出: build/lex.yy.c
# 依赖: parser.tab.h (Lexer 需要引用 Token 定义)
$(BUILD_DIR)/lex.yy.c: $(SRC_DIR)/lexer.l $(BUILD_DIR)/parser.tab.h | $(BUILD_DIR)
	@echo " [FLEX]  Generating lexer..."
	$(LEX) -o $(BUILD_DIR)/lex.yy.c $(SRC_DIR)/lexer.l

# --- C 程序链接规则 ---
# 输入: 生成的 .c 文件 + 手写的 .c 文件 (cfc_parser.c, utils.c)
# 输出: build/cfc_parser
$(PARSER_BIN): $(BUILD_DIR)/parser.tab.c $(BUILD_DIR)/lex.yy.c $(SRC_DIR)/cfc_parser.c $(SRC_DIR)/utils.c
	@echo " [CC]    Compiling binary $(PARSER_BIN)..."
	$(CC) $(CFLAGS) -o $(PARSER_BIN) \
		$(BUILD_DIR)/parser.tab.c \
		$(BUILD_DIR)/lex.yy.c \
		$(SRC_DIR)/cfc_parser.c \
		$(SRC_DIR)/utils.c \
		-lfl

# --- Python 脚本准备规则 ---
# 简单的复制操作，并赋予执行权限
$(WRAPPER_SCRIPT): $(SRC_DIR)/parsercfc.py | $(BIN_DIR)
	@echo " [CP]    Preparing script $(WRAPPER_SCRIPT)..."
	cp $(SRC_DIR)/parsercfc.py $(WRAPPER_SCRIPT)
	chmod +x $(WRAPPER_SCRIPT)

# --- 清理目标 (Clean) ---
clean: uninstall
	@echo " [CLEAN] Removing build artifacts..."
	rm -rf $(BUILD_DIR) $(BIN_DIR)

# --- 安装目标 (Install) ---
install: compile
	@echo " [INSTALL] Installing to $(INSTALL_BINDIR)..."
	install -d $(INSTALL_BINDIR)
	# 安装 Python 脚本
	install -m 755 $(WRAPPER_SCRIPT) $(INSTALL_BINDIR)/parsercfc
	# 安装 C 二进制程序 (注意：脚本内部会查找这个名字)
	install -m 755 $(PARSER_BIN) $(INSTALL_BINDIR)/cfc_parser

# --- 卸载目标 (Uninstall) ---
uninstall:
	@echo " [UNINSTALL] Removing from $(INSTALL_BINDIR)..."
	-rm -f $(INSTALL_BINDIR)/parsercfc $(INSTALL_BINDIR)/cfc_parser

#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path


DECL_KEYWORDS = {
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
}

CONTROL_KEYWORDS = {
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
}


def default_workers():
    count = os.cpu_count() or 1
    return max(count - 1, 1)


def find_c_files(root_dir):
    root = Path(root_dir)
    files = []
    for path in root.rglob("*.c"):
        if path.is_file():
            files.append(str(path.resolve()))
    files.sort()
    return files


def resolve_function_list(path, parser_names, stderr_message=None):
    try:
        text = Path(path).read_text(encoding="utf-8", errors="ignore")
    except OSError as exc:
        err = stderr_message or ""
        err = err + "; " + f"macro scan failed: {exc}" if err else f"macro scan failed: {exc}"
        return (parser_names, err)

    macros = parse_macro_definitions(text)
    ordered_defs, macro_named_defs, macro_template_defs, macro_used_names = (
        scan_function_definitions(text, macros)
    )

    filtered_parser_names = [name for name in parser_names if name not in macro_used_names]
    target_names = filtered_parser_names + macro_named_defs + macro_template_defs

    counts = {}
    for name in target_names:
        counts[name] = counts.get(name, 0) + 1

    merged = []
    for name in ordered_defs:
        remaining = counts.get(name, 0)
        if remaining > 0:
            merged.append(name)
            counts[name] = remaining - 1

    if any(counts.values()):
        for name in target_names:
            remaining = counts.get(name, 0)
            if remaining > 0:
                merged.append(name)
                counts[name] = remaining - 1

    return (merged, None)


def parse_one_file(args):
    parser_bin, path = args
    try:
        result = subprocess.run(
            [parser_bin, path],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        return (path, [], f"spawn failed: {exc}")

    if result.returncode != 0:
        err = result.stderr.strip() or f"exit code {result.returncode}"
        return (path, [], err)

    output = result.stdout.strip() or "[]"
    try:
        names = json.loads(output)
        if not isinstance(names, list):
            raise ValueError("output is not a list")
    except Exception as exc:
        return (path, [], f"invalid output: {exc}")

    merged, err = resolve_function_list(path, names, result.stderr.strip())
    return (path, merged, err)


def parse_batch_files(args):
    parser_bin, paths = args
    cmd = [parser_bin, "--batch", *paths]
    try:
        result = subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        return [(path, [], f"spawn failed: {exc}") for path in paths]

    output_map = {}
    parse_error = None
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError("record is not an object")
            record_path = record.get("path")
            record_fc = record.get("fc")
            if not isinstance(record_path, str) or not isinstance(record_fc, list):
                raise ValueError("invalid record fields")
            output_map[record_path] = record_fc
        except Exception as exc:
            parse_error = f"invalid batch output: {exc}"
            break

    results = []
    stderr_message = result.stderr.strip()
    for path in paths:
        parser_names = output_map.get(path, [])
        err = None
        if parse_error:
            err = parse_error
        elif path not in output_map:
            err = "missing batch output"
        merged, merge_err = resolve_function_list(path, parser_names, stderr_message)
        if merge_err:
            err = merge_err if not err else f"{err}; {merge_err}"
        results.append((path, merged, err))

    return results


def chunk_list(items, size):
    for i in range(0, len(items), size):
        yield items[i : i + size]


def dedupe_preserve_order(items):
    seen = set()
    output = []
    for item in items:
        if item not in seen:
            seen.add(item)
            output.append(item)
    return output


def extract_macro_function_names(path):
    try:
        text = Path(path).read_text(encoding="utf-8", errors="ignore")
    except OSError as exc:
        return ([], set(), f"macro scan failed: {exc}")

    macros = parse_macro_definitions(text)
    if not macros:
        return ([], set(), None)

    macro_names = []
    macro_used_names = set()
    for macro in macros:
        if not macro["name_parts"]:
            continue
        for args in find_macro_invocations(text, macro["name"], len(macro["params"])):
            arg_map = build_arg_map(macro["params"], args)
            name = render_macro_name(macro["name_parts"], arg_map)
            if name:
                macro_names.append(name)

    macro_defs, used_names = extract_macro_named_definitions(text, macros)
    macro_names.extend(macro_defs)
    macro_used_names.update(used_names)

    return (dedupe_preserve_order(macro_names), macro_used_names, None)


def parse_macro_definitions(text):
    macros = []
    lines = text.splitlines()
    i = 0
    define_re = re.compile(
        r"^\s*#\s*define\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)(.*)$"
    )

    while i < len(lines):
        line = lines[i]
        match = define_re.match(line)
        if not match:
            i += 1
            continue

        name = match.group(1)
        params = [p.strip() for p in match.group(2).split(",") if p.strip()]
        body_parts = [match.group(3)]

        while line.rstrip().endswith("\\"):
            i += 1
            if i >= len(lines):
                break
            line = lines[i]
            body_parts.append(line)

        body = "\n".join(strip_line_continuation(p) for p in body_parts).strip()
        name_parts = extract_function_name_template(body, params)
        expansion_parts = extract_macro_expansion_parts(body, params)
        macros.append(
            {
                "name": name,
                "params": params,
                "name_parts": name_parts,
                "expansion_parts": expansion_parts,
            }
        )
        i += 1

    return macros


def strip_line_continuation(line):
    stripped = line.rstrip()
    if stripped.endswith("\\"):
        return stripped[:-1]
    return line


def extract_function_name_template(body, params):
    tokens = tokenize_macro_body(body)
    if not tokens:
        return None

    last_parts = None
    paren_candidate = None
    pending_parts = None
    pending_paste = False
    paren_depth = 0
    bracket_depth = 0

    def ident_parts(identifier):
        if identifier in params:
            return [("param", identifier)]
        return [("lit", identifier)]

    for token in tokens:
        if token == "##":
            pending_paste = last_parts is not None
            continue

        if isinstance(token, dict) and token.get("kind") == "ident":
            parts = ident_parts(token["value"])
            if pending_paste and last_parts is not None:
                last_parts = last_parts + parts
            else:
                last_parts = parts
            pending_paste = False
            continue

        pending_paste = False
        if token == "(":
            if paren_depth == 0 and pending_parts is None:
                paren_candidate = last_parts
            paren_depth += 1
        elif token == ")":
            if paren_depth > 0:
                paren_depth -= 1
                if paren_depth == 0 and pending_parts is None and paren_candidate:
                    pending_parts = paren_candidate
        elif token == "[":
            bracket_depth += 1
        elif token == "]":
            if bracket_depth > 0:
                bracket_depth -= 1
        elif token == "{":
            if paren_depth == 0 and bracket_depth == 0 and pending_parts:
                return pending_parts
        elif token in {",", ";", "="}:
            if paren_depth == 0 and bracket_depth == 0:
                last_parts = None
                paren_candidate = None
                pending_parts = None

    return None


def extract_macro_expansion_parts(body, params):
    tokens = tokenize_macro_body(body)
    if not tokens:
        return None

    parts = None
    pending_paste = False

    for token in tokens:
        if token == "##":
            pending_paste = True
            continue
        if isinstance(token, dict) and token.get("kind") == "ident":
            value = token["value"]
            new_parts = [("param", value)] if value in params else [("lit", value)]
            if parts is None:
                parts = new_parts
            elif pending_paste:
                parts += new_parts
            else:
                return None
            pending_paste = False
            continue
        return None

    return parts


def tokenize_macro_body(body):
    tokens = []
    i = 0
    length = len(body)
    while i < length:
        c = body[i]
        if c.isspace():
            i += 1
            continue
        if c == "/" and i + 1 < length and body[i + 1] == "/":
            i = body.find("\n", i)
            if i == -1:
                break
            continue
        if c == "/" and i + 1 < length and body[i + 1] == "*":
            end = body.find("*/", i + 2)
            if end == -1:
                break
            i = end + 2
            continue
        if c in ("'", '"'):
            quote = c
            i += 1
            while i < length:
                if body[i] == "\\":
                    i += 2
                    continue
                if body[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if c == "#" and i + 1 < length and body[i + 1] == "#":
            tokens.append("##")
            i += 2
            continue
        if c.isalpha() or c == "_":
            start = i
            i += 1
            while i < length and (body[i].isalnum() or body[i] == "_"):
                i += 1
            tokens.append({"kind": "ident", "value": body[start:i]})
            continue
        if c in "(){}[];,=":
            tokens.append(c)
            i += 1
            continue
        i += 1
    return tokens


def extract_macro_named_definitions(text, macros):
    macros_by_name = {
        macro["name"]: macro
        for macro in macros
        if macro["expansion_parts"] and macro["params"]
    }
    if not macros_by_name:
        return ([], set())

    names = []
    used_macro_names = set()

    i = 0
    length = len(text)
    at_line_start = True

    while i < length:
        c = text[i]

        if at_line_start:
            j = i
            while j < length and text[j] in " \t":
                j += 1
            if j < length and text[j] == "#":
                i = skip_preprocessor_line(text, j)
                at_line_start = True
                continue

        if c == "\n":
            at_line_start = True
            i += 1
            continue

        at_line_start = False

        if c == "/" and i + 1 < length and text[i + 1] == "/":
            i = text.find("\n", i)
            if i == -1:
                break
            continue
        if c == "/" and i + 1 < length and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            if end == -1:
                break
            i = end + 2
            continue
        if c in ("'", '"'):
            quote = c
            i += 1
            while i < length:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            continue

        if c.isalpha() or c == "_":
            start = i
            i += 1
            while i < length and (text[i].isalnum() or text[i] == "_"):
                i += 1
            ident = text[start:i]
            macro = macros_by_name.get(ident)
            if not macro:
                continue

            j = i
            while j < length and text[j].isspace():
                j += 1
            if j >= length or text[j] != "(":
                continue

            args, new_i = parse_macro_args(text, j)
            if args is None or len(args) != len(macro["params"]):
                i = new_i
                continue

            k = new_i
            while k < length and text[k].isspace():
                k += 1
            if k >= length or text[k] != "(":
                i = k
                continue

            end_k = skip_paren_group(text, k)
            if end_k is None:
                i = k
                continue

            k2 = end_k
            while k2 < length and text[k2].isspace():
                k2 += 1
            if k2 >= length or text[k2] != "{":
                i = k2
                continue

            arg_map = build_arg_map(macro["params"], args)
            name = render_macro_name(macro["expansion_parts"], arg_map)
            if name:
                names.append(name)
                used_macro_names.add(ident)

            i = k2 + 1
            continue

        i += 1

    return (names, used_macro_names)


def scan_function_definitions(text, macros):
    macro_name_map = {
        macro["name"]: macro
        for macro in macros
        if macro.get("expansion_parts") and macro.get("params")
    }
    macro_template_map = {
        macro["name"]: macro
        for macro in macros
        if macro.get("name_parts") and macro.get("params")
    }

    ordered_defs = []
    macro_named_defs = []
    macro_template_defs = []
    macro_used_names = set()

    i = 0
    length = len(text)
    at_line_start = True
    brace_depth = 0
    paren_depth = 0
    bracket_depth = 0

    last_identifier = None
    last_identifier_macro = None
    paren_candidate = None
    paren_candidate_macro = None
    pending_name = None
    pending_name_macro = None

    while i < length:
        c = text[i]

        if at_line_start:
            j = i
            while j < length and text[j] in " \t":
                j += 1
            if j < length and text[j] == "#":
                i = skip_preprocessor_line(text, j)
                at_line_start = True
                continue

        if c == "\n":
            at_line_start = True
            i += 1
            continue

        at_line_start = False

        if c == "/" and i + 1 < length and text[i + 1] == "/":
            i = text.find("\n", i)
            if i == -1:
                break
            continue
        if c == "/" and i + 1 < length and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            if end == -1:
                break
            i = end + 2
            continue
        if c in ("'", '"'):
            quote = c
            i += 1
            while i < length:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            continue

        if c.isalpha() or c == "_":
            start = i
            i += 1
            while i < length and (text[i].isalnum() or text[i] == "_"):
                i += 1
            ident = text[start:i]

            if ident in CONTROL_KEYWORDS:
                last_identifier = None
                last_identifier_macro = None
                continue

            if ident in DECL_KEYWORDS:
                if brace_depth == 0 and paren_depth == 0 and bracket_depth == 0:
                    last_identifier = None
                    last_identifier_macro = None
                    paren_candidate = None
                    paren_candidate_macro = None
                    pending_name = None
                    pending_name_macro = None
                continue

            template_macro = macro_template_map.get(ident)
            if template_macro and brace_depth == 0:
                j = i
                while j < length and text[j].isspace():
                    j += 1
                if j < length and text[j] == "(":
                    args, new_i = parse_macro_args(text, j)
                    if args is not None and len(args) == len(template_macro["params"]):
                        arg_map = build_arg_map(template_macro["params"], args)
                        name = render_macro_name(template_macro["name_parts"], arg_map)
                        if name:
                            ordered_defs.append(name)
                            macro_template_defs.append(name)
                    if args is not None:
                        i = new_i
                        last_identifier = None
                        last_identifier_macro = None
                        continue

            name_macro = macro_name_map.get(ident)
            if name_macro:
                j = i
                while j < length and text[j].isspace():
                    j += 1
                if j < length and text[j] == "(":
                    args, new_i = parse_macro_args(text, j)
                    if args is not None and len(args) == len(name_macro["params"]):
                        arg_map = build_arg_map(name_macro["params"], args)
                        expanded = render_macro_name(name_macro["expansion_parts"], arg_map)
                        if expanded:
                            last_identifier = expanded
                            last_identifier_macro = ident
                            i = new_i
                            continue

            last_identifier = ident
            last_identifier_macro = None
            continue

        if c == "(":
            if paren_depth == 0 and pending_name is None:
                paren_candidate = last_identifier
                paren_candidate_macro = last_identifier_macro
            paren_depth += 1
            i += 1
            continue

        if c == ")":
            if paren_depth > 0:
                paren_depth -= 1
                if paren_depth == 0 and pending_name is None and paren_candidate:
                    pending_name = paren_candidate
                    pending_name_macro = paren_candidate_macro
            i += 1
            continue

        if c == "[":
            bracket_depth += 1
            i += 1
            continue

        if c == "]":
            if bracket_depth > 0:
                bracket_depth -= 1
            i += 1
            continue

        if c == "{":
            if (
                brace_depth == 0
                and paren_depth == 0
                and bracket_depth == 0
                and pending_name
            ):
                ordered_defs.append(pending_name)
                if pending_name_macro:
                    macro_named_defs.append(pending_name)
                    macro_used_names.add(pending_name_macro)
                pending_name = None
                pending_name_macro = None
                paren_candidate = None
                paren_candidate_macro = None
                last_identifier = None
                last_identifier_macro = None
            brace_depth += 1
            i += 1
            continue

        if c == "}":
            if brace_depth > 0:
                brace_depth -= 1
            i += 1
            continue

        if c in ";,=" and brace_depth == 0 and paren_depth == 0 and bracket_depth == 0:
            pending_name = None
            pending_name_macro = None
            paren_candidate = None
            paren_candidate_macro = None
            last_identifier = None
            last_identifier_macro = None
            i += 1
            continue

        i += 1

    return ordered_defs, macro_named_defs, macro_template_defs, macro_used_names


def find_macro_invocations(text, macro_name, param_count):
    invocations = []
    i = 0
    length = len(text)
    at_line_start = True

    while i < length:
        c = text[i]

        if at_line_start:
            j = i
            while j < length and text[j] in " \t":
                j += 1
            if j < length and text[j] == "#":
                i = skip_preprocessor_line(text, j)
                at_line_start = True
                continue

        if c == "\n":
            at_line_start = True
            i += 1
            continue

        at_line_start = False

        if c == "/" and i + 1 < length and text[i + 1] == "/":
            i = text.find("\n", i)
            if i == -1:
                break
            continue
        if c == "/" and i + 1 < length and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            if end == -1:
                break
            i = end + 2
            continue
        if c in ("'", '"'):
            quote = c
            i += 1
            while i < length:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            continue

        if c.isalpha() or c == "_":
            start = i
            i += 1
            while i < length and (text[i].isalnum() or text[i] == "_"):
                i += 1
            ident = text[start:i]
            if ident != macro_name:
                continue
            j = i
            while j < length and text[j].isspace():
                j += 1
            if j >= length or text[j] != "(":
                continue
            args, new_i = parse_macro_args(text, j)
            if args is not None and len(args) == param_count:
                invocations.append(args)
            i = new_i
            continue

        i += 1

    return invocations


def skip_preprocessor_line(text, start_idx):
    i = start_idx
    length = len(text)
    while i < length:
        if text[i] == "\n":
            if i > 0 and text[i - 1] == "\\":
                i += 1
                continue
            return i + 1
        i += 1
    return length


def parse_macro_args(text, start_idx):
    args = []
    current = []
    i = start_idx
    length = len(text)
    depth = 0

    if text[i] != "(":
        return (None, i)
    depth = 1
    i += 1

    while i < length:
        c = text[i]
        if c == "(":
            depth += 1
            current.append(c)
            i += 1
            continue
        if c == ")":
            depth -= 1
            if depth == 0:
                arg = "".join(current).strip()
                if arg or args:
                    args.append(arg)
                return (args, i + 1)
            current.append(c)
            i += 1
            continue
        if c == "," and depth == 1:
            args.append("".join(current).strip())
            current = []
            i += 1
            continue
        if c == "/" and i + 1 < length and text[i + 1] == "/":
            i = text.find("\n", i)
            if i == -1:
                break
            continue
        if c == "/" and i + 1 < length and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            if end == -1:
                break
            i = end + 2
            continue
        if c in ("'", '"'):
            quote = c
            current.append(c)
            i += 1
            while i < length:
                current.append(text[i])
                if text[i] == "\\":
                    if i + 1 < length:
                        current.append(text[i + 1])
                        i += 2
                        continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        current.append(c)
        i += 1

    return (None, i)


def skip_paren_group(text, start_idx):
    i = start_idx
    length = len(text)
    depth = 0

    if i >= length or text[i] != "(":
        return None
    depth = 1
    i += 1

    while i < length:
        c = text[i]
        if c == "(":
            depth += 1
            i += 1
            continue
        if c == ")":
            depth -= 1
            i += 1
            if depth == 0:
                return i
            continue
        if c == "/" and i + 1 < length and text[i + 1] == "/":
            i = text.find("\n", i)
            if i == -1:
                break
            continue
        if c == "/" and i + 1 < length and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            if end == -1:
                break
            i = end + 2
            continue
        if c in ("'", '"'):
            quote = c
            i += 1
            while i < length:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        i += 1

    return None


def build_arg_map(params, args):
    normalized = [normalize_macro_arg(arg) for arg in args]
    return {name: normalized[idx] if idx < len(normalized) else "" for idx, name in enumerate(params)}


def normalize_macro_arg(arg):
    return re.sub(r"\s+", "", arg or "")


def render_macro_name(parts, arg_map):
    c_keywords = {
        "auto", "break", "case", "char", "const", "continue", "default",
        "do", "double", "else", "enum", "extern", "float", "for", "goto",
        "if", "inline", "int", "long", "register", "restrict", "return",
        "short", "signed", "sizeof", "static", "struct", "switch", "typedef",
        "union", "unsigned", "void", "volatile", "while",
        "_Alignas", "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic",
        "_Imaginary", "_Noreturn", "_Static_assert", "_Thread_local",
    }
    output = []
    for kind, value in parts:
        if kind == "param":
            output.append(arg_map.get(value, ""))
        else:
            output.append(value)
    name = "".join(output)
    if name and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
        if name in c_keywords:
            return None
        return name
    return None


def ensure_parent(path):
    parent = Path(path).resolve().parent
    parent.mkdir(parents=True, exist_ok=True)


def resolve_parser_binary(script_path):
    override = os.environ.get("PARSERCFC_PARSER")
    if override:
        return Path(override).expanduser().resolve()

    if script_path.parent.name in ("bin", "src"):
        repo_root = script_path.parent.parent
    else:
        repo_root = script_path.parent

    candidate = (repo_root / "build" / "cfc_parser").resolve()
    if candidate.exists():
        return candidate

    sibling = (script_path.parent / "cfc_parser").resolve()
    if sibling.exists():
        return sibling

    found = shutil.which("cfc_parser")
    if found:
        return Path(found).resolve()

    return None


def main():
    default_w = default_workers()
    parser = argparse.ArgumentParser(
        prog="parsercfc",
        usage="parsercfc [-h] [-w WORKERS] [-o-fc OUTPUT_FC] [-o-null_fc OUTPUT_NULL_FC] dir",
        description=(
            "获取指定文件夹路径下的所有.c文件定义的函数名，将每个.c文件中定义的函数声明保存到fc.json，"
            "没有C语言函数定义的.c文件路径保存到null_fc.json"
        ),
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument("dir", help="[必选] 要解析的源代码目录路径")
    parser.add_argument(
        "-w",
        "--workers",
        type=int,
        default=default_w,
        help=f"使用的线程数 (默认为 CPU核心数-1: {default_w})",
    )
    parser.add_argument(
        "-o-fc",
        dest="output_fc",
        default="fc.json",
        help="fc.json 的生成路径 (默认: 当前目录下 fc.json)",
    )
    parser.add_argument(
        "-o-null_fc",
        dest="output_null_fc",
        default="null_fc.json",
        help="null_fc.json 的生成路径 (默认: 当前目录下 null_fc.json)",
    )

    args = parser.parse_args()

    workers = args.workers
    if workers < 1:
        workers = 1

    target_dir = Path(args.dir).resolve()
    if not target_dir.exists():
        print(f"error: dir not found: {target_dir}", file=sys.stderr)
        return 2

    script_path = Path(__file__).resolve()
    parser_bin = resolve_parser_binary(script_path)
    if not parser_bin or not parser_bin.exists():
        print(
            "error: parser binary not found. Run `make`, or set PARSERCFC_PARSER, "
            "or install cfc_parser on PATH.",
            file=sys.stderr,
        )
        return 2

    files = find_c_files(target_dir)
    total_files = len(files)

    print(f"Scan dir: {target_dir}")
    print(f"Workers: {workers}")
    print(f"Found {total_files} .c files")
    print(f"Output fc.json: {args.output_fc}")
    print(f"Output null_fc.json: {args.output_null_fc}")

    results = {}
    null_files = []
    errors = []

    if total_files == 0:
        ensure_parent(args.output_fc)
        ensure_parent(args.output_null_fc)
        with open(args.output_fc, "w", encoding="utf-8") as fc_fp:
            json.dump(results, fc_fp, ensure_ascii=True, indent=2, sort_keys=True)
        with open(args.output_null_fc, "w", encoding="utf-8") as null_fp:
            json.dump(null_files, null_fp, ensure_ascii=True, indent=2)
        print("No .c files found, outputs created.")
        return 0

    start_time = time.time()
    report_every = max(1, total_files // 20)
    processed = 0

    env_batch = int(os.environ.get("PARSERCFC_BATCH_SIZE", "0") or 0)
    if env_batch > 0:
        batch_size = env_batch
    else:
        auto = max(1, total_files // (workers * 4)) if workers > 0 else 1
        batch_size = max(1, min(100, auto))

    with ProcessPoolExecutor(max_workers=workers) as executor:
        if batch_size <= 1:
            futures = {
                executor.submit(parse_one_file, (str(parser_bin), path)): 1
                for path in files
            }
        else:
            chunks = list(chunk_list(files, batch_size))
            futures = {
                executor.submit(parse_batch_files, (str(parser_bin), chunk)): len(chunk)
                for chunk in chunks
            }

        for future in as_completed(futures):
            result = future.result()
            if batch_size <= 1:
                file_path, names, err = result
                results[file_path] = {"fc": names}
                if not names:
                    null_files.append(file_path)
                if err:
                    errors.append((file_path, err))
                processed += 1
            else:
                for file_path, names, err in result:
                    results[file_path] = {"fc": names}
                    if not names:
                        null_files.append(file_path)
                    if err:
                        errors.append((file_path, err))
                processed += futures[future]

            if processed % report_every == 0 or processed == total_files:
                percent = (processed / total_files) * 100.0
                elapsed = time.time() - start_time
                print(f"[{processed}/{total_files}] {percent:.1f}% elapsed {elapsed:.1f}s")

    total_functions = sum(len(v["fc"]) for v in results.values())
    elapsed = time.time() - start_time

    ordered_results = {key: results[key] for key in sorted(results)}
    null_files_sorted = sorted(null_files)

    ensure_parent(args.output_fc)
    ensure_parent(args.output_null_fc)
    with open(args.output_fc, "w", encoding="utf-8") as fc_fp:
        json.dump(ordered_results, fc_fp, ensure_ascii=True, indent=2)
    with open(args.output_null_fc, "w", encoding="utf-8") as null_fp:
        json.dump(null_files_sorted, null_fp, ensure_ascii=True, indent=2)

    print("Done.")
    print(f"Elapsed: {elapsed:.2f}s")
    print(f"Total files: {total_files}")
    print(f"Total functions: {total_functions}")
    print(f"Files with no functions: {len(null_files)}")
    if errors:
        print(f"Parser errors: {len(errors)}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())

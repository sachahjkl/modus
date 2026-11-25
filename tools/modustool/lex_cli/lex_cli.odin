// Host CLI subcommands for canonical Lex formatting and static linting
// (`modustool lex fmt [--check] <file>...` and `modustool lex lint <file>...`).
package lex_cli

import "core:fmt"
import "core:os"
import "modus:lex_parser"
import "modus:lex_tools"
import "modustool:foundation"

// Plan value: diagnostic buffer capacity per linted file in the host CLI.
CLI_LINT_DIAGNOSTIC_CAPACITY :: 256

// Plan value: message formatting buffer for one lint diagnostic line.
CLI_MESSAGE_BUFFER_BYTES :: 256

// run_lex_cli dispatches `modustool lex fmt [--check] <file>...` and
// `modustool lex lint <file>...`.
run_lex_cli :: proc(args: []string) -> int {
	if len(args) == 0 {
		lex_cli_print_usage()
		return foundation.EXIT_USAGE
	}
	switch args[0] {
	case "fmt":
		return run_lex_fmt(args[1:])
	case "lint":
		return run_lex_lint(args[1:])
	case:
		fmt.eprintfln("modustool: lex: unknown subcommand %q", args[0])
		lex_cli_print_usage()
		return foundation.EXIT_USAGE
	}
}

@(private = "file")
lex_cli_print_usage :: proc() {
	fmt.eprintln("usage: modustool lex fmt [--check] <file>...")
	fmt.eprintln("       modustool lex lint <file>...")
}

// run_lex_fmt formats one or more `.lex` files in place, or verifies they
// match canonical formatting when `--check` is passed.
run_lex_fmt :: proc(args: []string) -> int {
	check_only := false
	files := make([dynamic]string, context.temp_allocator)
	for arg in args {
		if arg == "--check" {
			check_only = true
		} else if len(arg) > 0 && arg[0] == '-' {
			fmt.eprintfln("modustool: lex fmt: unknown option %q", arg)
			lex_cli_print_usage()
			return foundation.EXIT_USAGE
		} else {
			append(&files, arg)
		}
	}
	if len(files) == 0 {
		lex_cli_print_usage()
		return foundation.EXIT_USAGE
	}

	failed := false
	for path in files {
		if !lex_cli_format_one(path, check_only) {
			failed = true
		}
	}
	return failed ? foundation.EXIT_FAILURE : 0
}

@(private = "file")
lex_cli_format_one :: proc(path: string, check_only: bool) -> bool {
	source, read_ok := foundation.read_text_file(path)
	if !read_ok {
		return false
	}

	// Start with 4x source capacity and grow up to 2x declaration limit on deep indentation.
	cap_bytes := max(len(source) * 4 + 256, 4096)
	max_bytes := lex_parser.DECLARATION_TEXT_BYTES_MOST * 2
	for {
		buf := make([]u8, cap_bytes, context.allocator)
		written, err := lex_tools.lex_format(source, buf)
		if err == .Buffer_Too_Small && cap_bytes < max_bytes {
			delete(buf)
			cap_bytes = min(cap_bytes * 2, max_bytes)
			continue
		}
		if err != .None {
			delete(buf)
			fmt.eprintfln("modustool: lex fmt: %s: %s", path, lex_tools.format_error_name(err))
			return false
		}
		defer delete(buf)
		formatted := string(buf[:written])
		if check_only {
			if formatted != source {
				fmt.eprintfln("modustool: lex fmt: %s: not formatted", path)
				return false
			}
			return true
		}
		if formatted != source {
			if write_err := os.write_entire_file(path, buf[:written]); write_err != nil {
				fmt.eprintfln("modustool: lex fmt: cannot write %s: %v", path, write_err)
				return false
			}
		}
		return true
	}
}

// run_lex_lint checks one or more `.lex` files and prints diagnostics to stderr.
run_lex_lint :: proc(args: []string) -> int {
	files := make([dynamic]string, context.temp_allocator)
	for arg in args {
		if len(arg) > 0 && arg[0] == '-' {
			fmt.eprintfln("modustool: lex lint: unknown option %q", arg)
			lex_cli_print_usage()
			return foundation.EXIT_USAGE
		}
		append(&files, arg)
	}
	if len(files) == 0 {
		lex_cli_print_usage()
		return foundation.EXIT_USAGE
	}

	failed := false
	for path in files {
		if !lex_cli_lint_one(path) {
			failed = true
		}
	}
	return failed ? foundation.EXIT_FAILURE : 0
}

@(private = "file")
lex_cli_lint_one :: proc(path: string) -> bool {
	source, read_ok := foundation.read_text_file(path)
	if !read_ok {
		return false
	}

	node_cap := max(len(source) + 64, lex_tools.LINT_INLINE_NODE_CAPACITY)
	int_cap := max(len(source) / 4 + 32, lex_tools.LINT_INLINE_INT_CONST_CAPACITY)
	nodes := make([]lex_parser.Ast_Node, node_cap, context.allocator)
	extra := make([]lex_parser.Node_Index, node_cap, context.allocator)
	scratch := make([]lex_parser.Node_Index, node_cap, context.allocator)
	ints := make([]i64, int_cap, context.allocator)
	defer delete(nodes)
	defer delete(extra)
	defer delete(scratch)
	defer delete(ints)

	storage := lex_parser.Tree_Storage{
		nodes            = nodes,
		extra_children   = extra,
		scratch_children = scratch,
		int_consts       = ints,
	}
	diags: [CLI_LINT_DIAGNOSTIC_CAPACITY]lex_tools.Lint_Diagnostic
	count, truncated := lex_tools.lex_lint_with_storage(source, storage, diags[:])

	msg_buf: [CLI_MESSAGE_BUFFER_BYTES]u8
	for i in 0 ..< count {
		d := diags[i]
		msg := lex_tools.lint_diagnostic_message(d, msg_buf[:])
		fmt.eprintfln(
			"%s:%d:%d: %s: %s: %s",
			path,
			d.place.line,
			d.place.column,
			lex_tools.lint_severity_name(d.severity),
			lex_tools.lint_kind_name(d.kind),
			msg,
		)
	}
	if truncated {
		fmt.eprintfln("modustool: lex lint: %s: additional diagnostics omitted", path)
	}
	return count == 0
}

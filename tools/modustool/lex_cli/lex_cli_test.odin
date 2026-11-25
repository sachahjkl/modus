package lex_cli

import "core:fmt"
import "core:os"
import "core:testing"
import "modustool:foundation"

@(private = "file")
lex_cli_temp_dir :: proc(t: ^testing.T, tag: string) -> string {
	dir := fmt.tprintf("build/test_lex_cli_%s", tag)
	testing.expect(t, foundation.reset_folder(dir))
	return dir
}

@(test)
lex_cli_usage_refusals :: proc(t: ^testing.T) {
	testing.expect_value(t, run_lex_cli({}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_lex_cli({"unknown"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_lex_cli({"fmt"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_lex_cli({"fmt", "--check"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_lex_cli({"fmt", "--bogus", "a.lex"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_lex_cli({"lint"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_lex_cli({"lint", "--bogus", "a.lex"}), foundation.EXIT_USAGE)
}

@(test)
lex_cli_fmt_and_check_roundtrip :: proc(t: ^testing.T) {
	dir := lex_cli_temp_dir(t, "fmt")
	defer _ = os.remove_all(dir)

	file_path := foundation.join(dir, "/sample.lex")
	unformatted := "project{source=here(),outputs={default=catalog.c.module(\"main.c\")}}"
	testing.expect(t, os.write_entire_file(file_path, transmute([]u8)unformatted) == nil)

	// `--check` fails before formatting.
	testing.expect_value(t, run_lex_cli({"fmt", "--check", file_path}), foundation.EXIT_FAILURE)

	// `fmt` formats the file in place and succeeds.
	testing.expect_value(t, run_lex_cli({"fmt", file_path}), 0)

	// `--check` now passes on the formatted file.
	testing.expect_value(t, run_lex_cli({"fmt", "--check", file_path}), 0)

	// File contents match expected canonical spacing and trailing newline.
	after, ok := foundation.read_text_file(file_path)
	testing.expect(t, ok)
	testing.expect_value(t, after, "project { source = here(), outputs = { default = catalog.c.module(\"main.c\") } }\n")

	// Missing file returns EXIT_FAILURE.
	missing_path := foundation.join(dir, "/missing.lex")
	testing.expect_value(t, run_lex_cli({"fmt", missing_path}), foundation.EXIT_FAILURE)
}

@(test)
lex_cli_lint_clean_and_dirty :: proc(t: ^testing.T) {
	dir := lex_cli_temp_dir(t, "lint")
	defer _ = os.remove_all(dir)

	clean_path := foundation.join(dir, "/clean.lex")
	dirty_path := foundation.join(dir, "/dirty.lex")
	clean_src := "let x = 1 in x + 2\n"
	dirty_src := "let unused = 1, y = 2 in y\n"
	testing.expect(t, os.write_entire_file(clean_path, transmute([]u8)clean_src) == nil)
	testing.expect(t, os.write_entire_file(dirty_path, transmute([]u8)dirty_src) == nil)

	testing.expect_value(t, run_lex_cli({"lint", clean_path}), 0)
	testing.expect_value(t, run_lex_cli({"lint", dirty_path}), foundation.EXIT_FAILURE)
	testing.expect_value(t, run_lex_cli({"lint", clean_path, dirty_path}), foundation.EXIT_FAILURE)
}

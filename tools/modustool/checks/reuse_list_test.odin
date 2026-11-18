package checks

import "core:strings"
import "core:testing"
import "modustool:foundation"
import "modustool:build"

// Three works as the records of a repository give them: a font, the
// runtime of the compiler, and a portrait whose record gives no identifier.
@(private = "file")
reuse_test_works := [?]Reused_Work {
	{what = "Font A", place = "resources/fonts/a.ttf", license = "OFL-1.1", license_file = "resources/fonts/OFL.txt"},
	{what = "the runtime", place = REUSE_COMPILER_RUNTIME, license = "Zlib", license_file = "LICENSE.odin.txt"},
	{what = "a portrait", place = "resources/hall_of_fame/a.png", license = "", license_file = "CREDITS.md"},
}

@(private = "file")
reuse_test_every_file_exists :: proc(path: string) -> bool {
	return path == "resources/fonts/OFL.txt" || path == "LICENSE.odin.txt" || path == "CREDITS.md"
}

@(private = "file")
reuse_test_credits_are_gone :: proc(path: string) -> bool {
	return path != "CREDITS.md" && reuse_test_every_file_exists(path)
}

REUSE_TEST_HEAD :: "# Properties\n\nText.\n\n## Reuse list\n\nEach work of others.\n\n" + REUSE_LIST_HEADER_ROW + "\n|---|---|---|---|\n"

// The table of the next section is not a part of the list.
REUSE_TEST_TAIL :: "\n## Open decisions\n\n| A | table | of | another section |\n|---|---|---|---|\n| `x` | `y` | z | `w` |\n"

REUSE_TEST_GOOD_LIST :: REUSE_TEST_HEAD +
	"| Font A, as a subset | `resources/fonts/a.ttf` | OFL-1.1 | `resources/fonts/OFL.txt` |\n" +
	"| The runtime of the compiler | `base:runtime` | Zlib | `LICENSE.odin.txt` |\n" +
	"| A portrait: a credited frame | `resources/hall_of_fame/a.png` | NONE | `CREDITS.md` |\n" +
	REUSE_TEST_TAIL

// Four faults: the font has no row, a row names a font that is gone, the
// runtime has a wrong license, and (with reuse_test_credits_are_gone) the
// license file of the portrait does not exist.
REUSE_TEST_BAD_LIST :: REUSE_TEST_HEAD +
	"| A font that is gone | `resources/fonts/gone.ttf` | OFL-1.1 | `resources/fonts/OFL.txt` |\n" +
	"| The runtime of the compiler | `base:runtime` | MIT | `LICENSE.odin.txt` |\n" +
	"| A portrait: a credited frame | `resources/hall_of_fame/a.png` | NONE | `CREDITS.md` |\n" +
	REUSE_TEST_TAIL

@(private = "file")
reuse_test_some_problem_holds :: proc(problems: []string, words: ..string) -> bool {
	for problem in problems {
		holds_every_word := true
		for word in words {
			holds_every_word &&= strings.contains(problem, word)
		}
		if holds_every_word {
			return true
		}
	}
	return false
}

@(test)
reuse_list_good_list_has_no_problem :: proc(t: ^testing.T) {
	problems := reuse_list_problems(REUSE_TEST_GOOD_LIST, reuse_test_works[:], reuse_test_every_file_exists)
	testing.expect_value(t, len(problems), 0)
	for problem in problems {
		testing.expectf(t, false, "unexpected: %s", problem)
	}
}

@(test)
reuse_list_bad_list_has_each_fault :: proc(t: ^testing.T) {
	problems := reuse_list_problems(REUSE_TEST_BAD_LIST, reuse_test_works[:], reuse_test_credits_are_gone)
	testing.expect_value(t, len(problems), 4)
	testing.expect(t, reuse_test_some_problem_holds(problems, "resources/fonts/a.ttf", "has no row"))
	testing.expect(t, reuse_test_some_problem_holds(problems, "resources/fonts/gone.ttf", "does not ship"))
	testing.expect(t, reuse_test_some_problem_holds(problems, "base:runtime", "MIT", "Zlib"))
	testing.expect(t, reuse_test_some_problem_holds(problems, "CREDITS.md", "does not exist"))
}

@(test)
reuse_list_refuses_a_row_out_of_its_form :: proc(t: ^testing.T) {
	cases := [?]struct {
		row:   string,
		words: string,
	} {
		{"| Font A | `resources/fonts/a.ttf` | SIL OFL 1.1 | `resources/fonts/OFL.txt` |\n", "not an SPDX identifier"},
		{"| Font A | resources/fonts/a.ttf | OFL-1.1 | `resources/fonts/OFL.txt` |\n", "one code span"},
		{"| Font A | `resources/fonts/a.ttf` | OFL-1.1 |\n", "cells"},
		{"| Font A | `resources/fonts/a.ttf` | OFL-1.1 | `resources/fonts/OFL.txt` |\n| Font A again | `resources/fonts/a.ttf` | OFL-1.1 | `resources/fonts/OFL.txt` |\n", "a second time"},
	}
	for test_case in cases {
		problems := reuse_list_problems(strings.concatenate({REUSE_TEST_HEAD, test_case.row, REUSE_TEST_TAIL}, context.temp_allocator), reuse_test_works[:1], reuse_test_every_file_exists)
		testing.expectf(t, reuse_test_some_problem_holds(problems, test_case.words), "the row %q gives no problem with %q", test_case.row, test_case.words)
	}
	no_section := reuse_list_problems("# Properties\n\n## Open decisions\n", nil, reuse_test_every_file_exists)
	testing.expect(t, reuse_test_some_problem_holds(no_section, "no section"))
}

@(test)
reuse_license_expressions :: proc(t: ^testing.T) {
	testing.expect(t, reuse_license_is_spdx_expression("MIT"))
	testing.expect(t, reuse_license_is_spdx_expression("MIT OR Apache-2.0"))
	testing.expect(t, reuse_license_is_spdx_expression("CC-BY-SA-4.0"))
	testing.expect(t, reuse_license_is_spdx_expression(build.REUSE_LICENSE_NONE))
	testing.expect(t, !reuse_license_is_spdx_expression(""))
	testing.expect(t, !reuse_license_is_spdx_expression("MIT OR"))
	testing.expect(t, !reuse_license_is_spdx_expression("SIL OFL 1.1"))
	testing.expect(t, !reuse_license_is_spdx_expression("MIT, Zlib"))
	testing.expect_value(t, build.reuse_spdx_of_record_words("SIL OFL 1.1, no Reserved Font Name"), "OFL-1.1")
	testing.expect_value(t, build.reuse_spdx_of_record_words("CC BY-SA 4.0"), "CC-BY-SA-4.0")
	testing.expect_value(t, build.reuse_spdx_of_record_words("All rights reserved by its producers"), build.REUSE_LICENSE_NONE)
	testing.expect_value(t, build.reuse_spdx_of_record_words("words that name no license"), "")
}

@(test)
reuse_list_imports_of_the_core_library :: proc(t: ^testing.T) {
	imports := make([dynamic]string, context.temp_allocator)
	reuse_core_imports_of_source("package a\n\nimport \"base:intrinsics\"\nimport \"core:reflect\"\nimport other \"core:reflect\"\nimport \"modus:support/system\"\n// import \"core:fmt\"\n", &imports)
	testing.expect_value(t, len(imports), 1)
	if len(imports) == 1 {
		testing.expect_value(t, imports[0], "core:reflect")
	}
	testing.expect(t, reuse_source_is_host_only("#+build !freestanding\npackage a\n"))
	testing.expect(t, !reuse_source_is_host_only("// A comment.\npackage a\n"))
}

// The list of the repository holds against the records of the repository,
// as `modustool check` holds it.
@(test)
reuse_list_of_the_repository_is_whole :: proc(t: ^testing.T) {
	problems := make([dynamic]string, context.temp_allocator)
	works := reuse_works_read(&problems)
	document, ok := foundation.read_text_file_quiet(REUSE_LIST_DOCUMENT)
	testing.expect(t, ok)
	append(&problems, ..reuse_list_problems(document, works, reuse_file_exists))
	for problem in problems {
		testing.expectf(t, false, "%s", problem)
	}
	testing.expect_value(t, len(problems), 0)
	runtime_found := false
	for work in works {
		runtime_found ||= work.place == REUSE_COMPILER_RUNTIME
	}
	testing.expect(t, runtime_found)
}

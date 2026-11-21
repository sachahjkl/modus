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
	switch path {
	case "resources/fonts/a.ttf",
		"resources/fonts/OFL.txt",
		"LICENSE.odin.txt",
		"resources/hall_of_fame/a.png",
		"CREDITS.md",
		"src/kernel/schedule.odin":
		return true
	}
	return false
}

@(private = "file")
reuse_test_credits_are_gone :: proc(path: string) -> bool {
	return path != "CREDITS.md" && reuse_test_every_file_exists(path)
}

REUSE_TEST_HEAD :: "# Credits and licences\n\n" + REUSE_LIST_HEADING + "\n\n" + REUSE_LIST_HEADER_ROW + "\n|---|---|---|---|---|---|---|\n"

REUSE_TEST_ALGO_SECTION :: "\n" + CREDITS_ALGORITHMS_HEADING + "\n\n" + CREDITS_ALGORITHMS_HEADER_ROW + "\n|---|---|---|---|---|---|\n" +
	"| EEVDF | Stoica | Linux | Paper | `src/kernel/schedule.odin` | — |\n"

REUSE_TEST_INSP_SECTION :: "\n" + CREDITS_INSPIRATIONS_HEADING + "\n\n" + CREDITS_INSPIRATIONS_HEADER_ROW + "\n|---|---|---|---|---|\n" +
	"| seL4 | seL4 Foundation | Took microkernel; left proofs. | https://sel4.systems/ | https://sel4.systems/Foundation/Donate/ |\n"

REUSE_TEST_TAIL :: REUSE_TEST_ALGO_SECTION + REUSE_TEST_INSP_SECTION

REUSE_TEST_GOOD_LIST :: REUSE_TEST_HEAD +
	"| Font A, as a subset | `resources/fonts/a.ttf` | Font A | Author A | OFL-1.1 | `resources/fonts/OFL.txt` | — |\n" +
	"| The runtime of the compiler | `base:runtime` | Odin | Ginger Bill | Zlib | `LICENSE.odin.txt` | https://github.com/sponsors/gingerBill |\n" +
	"| A portrait: a credited frame | `resources/hall_of_fame/a.png` | Portrait | Author P | NONE | `CREDITS.md` | — |\n" +
	REUSE_TEST_TAIL

// Five faults: the font has no row, a row names a font that is gone (and does
// not exist), the runtime has a wrong license, and (with
// reuse_test_credits_are_gone) the license file of the portrait does not exist.
REUSE_TEST_BAD_LIST :: REUSE_TEST_HEAD +
	"| A font that is gone | `resources/fonts/gone.ttf` | Font G | Author G | OFL-1.1 | `resources/fonts/OFL.txt` | — |\n" +
	"| The runtime of the compiler | `base:runtime` | Odin | Ginger Bill | MIT | `LICENSE.odin.txt` | — |\n" +
	"| A portrait: a credited frame | `resources/hall_of_fame/a.png` | Portrait | Author P | NONE | `CREDITS.md` | — |\n" +
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
	testing.expect(t, reuse_test_some_problem_holds(problems, "resources/fonts/a.ttf", "has no row"))
	testing.expect(t, reuse_test_some_problem_holds(problems, "resources/fonts/gone.ttf", "does not ship"))
	testing.expect(t, reuse_test_some_problem_holds(problems, "resources/fonts/gone.ttf", "does not exist"))
	testing.expect(t, reuse_test_some_problem_holds(problems, "base:runtime", "MIT", "Zlib"))
	testing.expect(t, reuse_test_some_problem_holds(problems, "CREDITS.md", "does not exist"))
}

@(test)
reuse_list_refuses_a_row_out_of_its_form :: proc(t: ^testing.T) {
	cases := [?]struct {
		row:   string,
		words: string,
	} {
		{"| Font A | `resources/fonts/a.ttf` | Font A | Author A | SIL OFL 1.1 | `resources/fonts/OFL.txt` | — |\n", "not an SPDX identifier"},
		{"| Font A | resources/fonts/a.ttf | Font A | Author A | OFL-1.1 | `resources/fonts/OFL.txt` | — |\n", "one code span"},
		{"| Font A | `resources/fonts/a.ttf` | Font A | Author A | OFL-1.1 | `resources/fonts/OFL.txt` |\n", "cells"},
		{"| Font A | `resources/fonts/a.ttf` | Font A | Author A | OFL-1.1 | `resources/fonts/OFL.txt` | |\n", "empty Funding"},
		{"| Font A | `resources/fonts/a.ttf` | Font A | | OFL-1.1 | `resources/fonts/OFL.txt` | — |\n", "empty Authors"},
		{"| Font A | `resources/fonts/a.ttf` | Font A | Author A | OFL-1.1 | `resources/fonts/OFL.txt` | — |\n| Font A again | `resources/fonts/a.ttf` | Font A | Author A | OFL-1.1 | `resources/fonts/OFL.txt` | — |\n", "a second time"},
	}
	for test_case in cases {
		problems := reuse_list_problems(strings.concatenate({REUSE_TEST_HEAD, test_case.row, REUSE_TEST_TAIL}, context.temp_allocator), reuse_test_works[:1], reuse_test_every_file_exists)
		testing.expectf(t, reuse_test_some_problem_holds(problems, test_case.words), "the row %q gives no problem with %q", test_case.row, test_case.words)
	}
	no_sections := reuse_list_problems("# Credits\n", nil, reuse_test_every_file_exists)
	testing.expect(t, reuse_test_some_problem_holds(no_sections, "no section", REUSE_LIST_HEADING))
	testing.expect(t, reuse_test_some_problem_holds(no_sections, "no section", CREDITS_ALGORITHMS_HEADING))
	testing.expect(t, reuse_test_some_problem_holds(no_sections, "no section", CREDITS_INSPIRATIONS_HEADING))
}

@(test)
credits_refuses_broken_algorithms_and_inspirations :: proc(t: ^testing.T) {
	REUSED_ONE :: REUSE_TEST_HEAD + "| Font A | `resources/fonts/a.ttf` | Font A | Author A | OFL-1.1 | `resources/fonts/OFL.txt` | — |\n"

	// Broken path in Reimplemented algorithms.
	bad_algo_path := REUSED_ONE +
		"\n" + CREDITS_ALGORITHMS_HEADING + "\n\n" + CREDITS_ALGORITHMS_HEADER_ROW + "\n|---|---|---|---|---|---|\n" +
		"| EEVDF | Stoica | Linux | Paper | `src/kernel/does_not_exist.odin` | — |\n" +
		REUSE_TEST_INSP_SECTION
	problems := reuse_list_problems(bad_algo_path, reuse_test_works[:1], reuse_test_every_file_exists)
	testing.expect(t, reuse_test_some_problem_holds(problems, "src/kernel/does_not_exist.odin", "does not exist"))

	// Duplicate algorithm.
	dup_algo := REUSED_ONE +
		"\n" + CREDITS_ALGORITHMS_HEADING + "\n\n" + CREDITS_ALGORITHMS_HEADER_ROW + "\n|---|---|---|---|---|---|\n" +
		"| EEVDF | Stoica | Linux | Paper | `src/kernel/schedule.odin` | — |\n" +
		"| EEVDF | Stoica | Linux | Paper | `src/kernel/schedule.odin` | — |\n" +
		REUSE_TEST_INSP_SECTION
	problems = reuse_list_problems(dup_algo, reuse_test_works[:1], reuse_test_every_file_exists)
	testing.expect(t, reuse_test_some_problem_holds(problems, "EEVDF", "a second time"))

	// Missing column in Reimplemented algorithms.
	short_algo := REUSED_ONE +
		"\n" + CREDITS_ALGORITHMS_HEADING + "\n\n" + CREDITS_ALGORITHMS_HEADER_ROW + "\n|---|---|---|---|---|---|\n" +
		"| EEVDF | Stoica | Linux | Paper | `src/kernel/schedule.odin` |\n" +
		REUSE_TEST_INSP_SECTION
	problems = reuse_list_problems(short_algo, reuse_test_works[:1], reuse_test_every_file_exists)
	testing.expect(t, reuse_test_some_problem_holds(problems, "Reimplemented algorithms", "cells"))

	// Duplicate inspiration and empty column in Inspirations.
	bad_insp := REUSED_ONE + REUSE_TEST_ALGO_SECTION +
		"\n" + CREDITS_INSPIRATIONS_HEADING + "\n\n" + CREDITS_INSPIRATIONS_HEADER_ROW + "\n|---|---|---|---|---|\n" +
		"| seL4 | seL4 Foundation | Took microkernel. | https://sel4.systems/ | — |\n" +
		"| seL4 | seL4 Foundation | Took microkernel. | https://sel4.systems/ | — |\n" +
		"| Nix | Eelco | Took store. | https://nixos.org/ | |\n"
	problems = reuse_list_problems(bad_insp, reuse_test_works[:1], reuse_test_every_file_exists)
	testing.expect(t, reuse_test_some_problem_holds(problems, "seL4", "a second time"))
	testing.expect(t, reuse_test_some_problem_holds(problems, "Inspirations", "empty Funding"))
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

package machine

import "core:fmt"
import "core:strings"
import "core:testing"

// The first failed step of a build log: the first line of the tool that
// says it, never a line of the log of a machine (four spaces before it),
// and the log of the machine that the tool printed after it.
@(test)
the_first_failed_step_of_a_part_log_is_found :: proc(t: ^testing.T) {
	log := "modustool: test passed: the boot\n" +
		"    [errors] modustool: test failed: a line of the machine\n" +
		"modustool: test failed: step 1275: the machine did not print \"storage: opened\" within 2m0s\r\n" +
		"modustool: test failed: the machine printed \"panic\"\n" +
		"modustool: the log of the kernel of build/test_output.txt, 3 lines (nix log of the part keeps it whole):\n" +
		"    kernel: ok\n" +
		"modustool: the log of the kernel of build/other.txt, 1 lines\n"
	failure := part_log_failure(log)
	testing.expect_value(t, failure.first_failure, "modustool: test failed: step 1275: the machine did not print \"storage: opened\" within 2m0s")
	testing.expect_value(t, failure.machine_log, "build/test_output.txt")
	// A log with no failed line, an empty log, a log of a machine before
	// the failed line.
	testing.expect_value(t, part_log_failure("modustool: all fine\n"), Part_Failure{})
	testing.expect_value(t, part_log_failure(""), Part_Failure{})
	before := part_log_failure("modustool: the log of the kernel of build/a.txt, 1 lines\nmodustool: test failed: x\n")
	testing.expect_value(t, before, Part_Failure{first_failure = "modustool: test failed: x"})
	// The host checks that stop at a compile error say no step: the last
	// line of the tool that says that something failed.
	compile := part_log_failure("modustool: the host tests of a: 1.0 s\n/build/source/a_test.odin(457:49) Syntax Error: Illegal byte order mark\nmodustool: odin failed (code 1)\n")
	testing.expect_value(t, compile, Part_Failure{first_failure = "modustool: odin failed (code 1)"})
}

@(test)
the_line_of_a_failed_part_names_its_step_and_its_log :: proc(t: ^testing.T) {
	failed := failed_part_line("main", .Failed, {first_failure = "modustool: test failed: step 3: x", machine_log = "build/test_output.txt"}, "build/failed_parts/main.log", "/nix/store/a.drv")
	testing.expect_value(t, failed, "modustool: main failed: modustool: test failed: step 3: x; the machine test_output; its whole log: build/failed_parts/main.log")
	silent := failed_part_line("tcp", .Failed, {}, "build/failed_parts/tcp.log", "/nix/store/b.drv")
	testing.expect_value(t, silent, "modustool: tcp failed: no line says which check failed: read the end of its log; its whole log: build/failed_parts/tcp.log")
	not_run := failed_part_line("quic", .Not_Run, {}, "", "/nix/store/c.drv")
	testing.expect_value(t, not_run, "modustool: quic did not run: a derivation that it needs failed, or the build stopped before it (/nix/store/c.drv)")
}

// A sample of a full check that failed in two places: the host checks at a
// compile error, and the part `main` at a Wait. Every other part passed.
// The store holds the outputs of the parts that passed and the build logs
// of the two failures, under the derivations that the build built.
@(private = "file")
SAMPLE_HOST_CHECKS_DERIVATION :: "/nix/store/krkw3045ifc3h1wgf6h53swmla93m96g-modus-host-checks.drv"
@(private = "file")
SAMPLE_MAIN_DERIVATION :: "/nix/store/7msb9csdw72i8y9hr785nx9wscz963nm-machine-test-main.drv"
@(private = "file")
SAMPLE_HOST_CHECKS_LOG :: "/build/source/src/library/contract/palette_table/palette_table_test.odin(457:49) Syntax Error: Illegal byte order mark\nmodustool: odin failed (code 1)\n"
@(private = "file")
SAMPLE_MAIN_LOG :: "modustool: test passed: the boot\nmodustool: test failed: step 291: the machine did not print \"console: the palette marks .spleen for settings.set font\" within 2m0s\nmodustool: the log of the kernel of build/test_output.txt, 765 lines (nix log of the part keeps it whole):\n    kernel: ok\n"

// sample_evaluation gives the evaluation of the check, each derivation and
// output named by a hash prefix: "built" for the evaluation that the build
// built, "moved" for one of the work tree after a change.
@(private = "file")
sample_evaluation :: proc(prefix: string) -> Flake_Check_Evaluation {
	members := make([dynamic]Check_Derivation, context.temp_allocator)
	append(&members, Check_Derivation{name = FAILED_PARTS_HOST_CHECKS, derivation = fmt.tprintf("/nix/store/%s-modus-host-checks.drv", prefix), output = fmt.tprintf("/nix/store/%s-modus-host-checks", prefix)})
	for part in test_parts {
		append(&members, Check_Derivation{name = part.name, derivation = fmt.tprintf("/nix/store/%s-machine-test-%s.drv", prefix, part.name), output = fmt.tprintf("/nix/store/%s-machine-test-%s", prefix, part.name)})
	}
	if prefix == "built" {
		members[0].derivation = SAMPLE_HOST_CHECKS_DERIVATION
		for &member in members {
			if member.name == "main" {
				member.derivation = SAMPLE_MAIN_DERIVATION
			}
		}
	}
	return {check_derivation = fmt.tprintf("/nix/store/%s-kernel-boot-test.drv", prefix), members = members[:]}
}

// The store of the sample: the outputs of the built parts that passed, and
// the logs of the two failures.
@(private = "file")
sample_reader := Check_Store_Reader {
	output_valid = proc(path: string) -> bool {
		return strings.has_prefix(path, "/nix/store/built-machine-test-") && !strings.has_suffix(path, "-machine-test-main")
	},
	build_log = proc(derivation: string) -> (log: string, ok: bool) {
		switch derivation {
		case SAMPLE_HOST_CHECKS_DERIVATION:
			return SAMPLE_HOST_CHECKS_LOG, true
		case SAMPLE_MAIN_DERIVATION:
			return SAMPLE_MAIN_LOG, true
		}
		return "", false
	},
}

// The fault of the first real failure: the list evaluated the work tree
// again after the build, and the tree had changed, so it read derivations
// that nothing built: every part "did not run", the parts that passed too,
// and no log. The list of that evaluation must say that it is not the
// check that ran.
@(test)
a_list_of_derivations_that_nothing_built_says_so :: proc(t: ^testing.T) {
	moved := sample_evaluation("moved")
	list := failed_parts_list(moved, sample_reader)
	parts := len(test_parts)
	testing.expect_value(t, list.counts[.Not_Run], parts + 1)
	testing.expect_value(t, len(list.logs), 0)
	testing.expect_value(t, list.lines[0], "modustool: host_checks did not run: a derivation that it needs failed, or the build stopped before it (/nix/store/moved-modus-host-checks.drv)")
	testing.expect_value(t, list.lines[parts + 1], fmt.tprintf("modustool: the check of the flake: 0 failed, %d did not run, 0 passed (the host checks and %d parts)", parts + 1, parts))
	testing.expect_value(t, list.lines[parts + 2], "modustool: no derivation of the evaluation /nix/store/moved-kernel-boot-test.drv ran or is in the store: it is not the check that the build built (a work tree that changed after the build names other derivations), or the build stopped before any of them")
}

// The list of the evaluation that the build built names the two failures,
// each with its first failed line and its log, and every other part as
// passed.
@(test)
the_list_of_the_built_evaluation_names_both_failures :: proc(t: ^testing.T) {
	list := failed_parts_list(sample_evaluation("built"), sample_reader)
	parts := len(test_parts)
	testing.expect_value(t, list.counts[.Failed], 2)
	testing.expect_value(t, list.counts[.Not_Run], 0)
	testing.expect_value(t, list.counts[.Passed], parts - 1)
	testing.expect_value(t, len(list.lines), 3)
	testing.expect_value(t, list.lines[0], "modustool: host_checks failed: modustool: odin failed (code 1); its whole log: build/failed_parts/host_checks.log")
	testing.expect_value(t, list.lines[1], "modustool: main failed: modustool: test failed: step 291: the machine did not print \"console: the palette marks .spleen for settings.set font\" within 2m0s; the machine test_output; its whole log: build/failed_parts/main.log")
	testing.expect_value(t, list.lines[2], fmt.tprintf("modustool: the check of the flake: 2 failed, 0 did not run, %d passed (the host checks and %d parts)", parts - 1, parts))
	testing.expect_value(t, len(list.logs), 2)
	if len(list.logs) == 2 {
		testing.expect_value(t, list.logs[0], Failed_Log{path = "build/failed_parts/host_checks.log", log = SAMPLE_HOST_CHECKS_LOG})
		testing.expect_value(t, list.logs[1], Failed_Log{path = "build/failed_parts/main.log", log = SAMPLE_MAIN_LOG})
	}
}

// The answer of the one evaluation: each part of the table, the host
// checks first; a part that the answer lacks, or a text that is no
// derivation, is refused.
@(test)
the_evaluation_of_the_check_is_read_whole :: proc(t: ^testing.T) {
	build_answer :: proc(skip: string) -> string {
		builder := strings.builder_make(context.temp_allocator)
		strings.write_string(&builder, `{"check": "/nix/store/c-kernel-boot-test.drv", "host": "/nix/store/h-modus-host-checks.drv", "hostOutput": "/nix/store/h-modus-host-checks", "parts": {`)
		written := 0
		for part in test_parts {
			if part.name == skip {
				continue
			}
			fmt.sbprintf(&builder, `%s"%s": "/nix/store/p-machine-test-%s.drv"`, written == 0 ? "" : ", ", part.name, part.name)
			written += 1
		}
		strings.write_string(&builder, `}, "outputs": {`)
		for part, index in test_parts {
			fmt.sbprintf(&builder, `%s"%s": "/nix/store/p-machine-test-%s"`, index == 0 ? "" : ", ", part.name, part.name)
		}
		strings.write_string(&builder, "}}")
		return strings.to_string(builder)
	}
	evaluation, ok := flake_check_evaluation_of_json(build_answer(""))
	testing.expect(t, ok, "a whole answer is read")
	testing.expect_value(t, len(evaluation.members), len(test_parts) + 1)
	testing.expect_value(t, evaluation.check_derivation, "/nix/store/c-kernel-boot-test.drv")
	if len(evaluation.members) > 1 {
		testing.expect_value(t, evaluation.members[0], Check_Derivation{name = FAILED_PARTS_HOST_CHECKS, derivation = "/nix/store/h-modus-host-checks.drv", output = "/nix/store/h-modus-host-checks"})
		testing.expect_value(t, evaluation.members[1].name, test_parts[0].name)
	}
	_, lacks_ok := flake_check_evaluation_of_json(build_answer("main"))
	testing.expect(t, !lacks_ok, "an answer that lacks a part is refused")
	for refused in ([]string{"", "[]", "{}", `{"check": "x"}`, "not json"}) {
		_, refused_ok := flake_check_evaluation_of_json(refused)
		testing.expectf(t, !refused_ok, "%q is refused", refused)
	}
}

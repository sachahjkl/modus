package machine

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
}

@(test)
the_line_of_a_failed_part_names_its_step_and_its_log :: proc(t: ^testing.T) {
	failed := failed_part_line("main", .Failed, {first_failure = "modustool: test failed: step 3: x", machine_log = "build/test_output.txt"}, "build/failed_parts/main.log", "/nix/store/a.drv")
	testing.expect_value(t, failed, "modustool: main failed: modustool: test failed: step 3: x; the machine test_output; its whole log: build/failed_parts/main.log")
	silent := failed_part_line("tcp", .Failed, {}, "build/failed_parts/tcp.log", "/nix/store/b.drv")
	testing.expect_value(t, silent, "modustool: tcp failed: no line says which check failed: read the end of its log; its whole log: build/failed_parts/tcp.log")
	not_run := failed_part_line("quic", .Not_Run, {}, "", "/nix/store/c.drv")
	testing.expect_value(t, not_run, "modustool: quic did not run: a derivation that it needs failed (/nix/store/c.drv)")
}

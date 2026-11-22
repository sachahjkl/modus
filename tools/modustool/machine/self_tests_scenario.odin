package machine

import "core:fmt"
import "modustool:build"

self_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	for test in build.self_tests {
		steps := make([dynamic]Step)
		append(&steps, Step{kind = .Wait, text = "kernel: ok"})
		append(&steps, Step{kind = .Wait, text = fmt.aprintf("kernel: self test: %s", test.does)})
		for report in test.reports {
			append(&steps, Step{kind = .Wait, text = report, any_order = true})
		}
		if !machine_test(part, steps[:], {volume = self_test_file(build.BOOT_VOLUME_SELF_TEST, test.number), output = self_test_file(TEST_OUTPUT_SELF_TEST, test.number), exit_status = test.stop}) {
			return false
		}
	}
	return true
}

// A binary of the tool runs the test part self_tests only when it holds this file
// (test_parts.odin, test_part_scenario_register).
@(init)
self_tests_test_part_register :: proc "contextless" () {
	test_part_scenario_register("self_tests", self_tests_run)
}

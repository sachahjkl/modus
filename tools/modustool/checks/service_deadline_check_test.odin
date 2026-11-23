#+build !freestanding
package checks

import "core:testing"

@(test)
service_deadline_check_finds_each_name_once_and_no_comment :: proc(t: ^testing.T) {
	source := `package sample

DEADLINE :: system.TEST_HANG_BOUND_MILLISECONDS

wait :: proc() -> u64 {
	return TEST_PROGRESS_OVERALL_BOUND_MILLISECONDS + system.ANSWER_BOUND_MILLISECONDS
}
`
	uses, parsed := service_deadline_uses_of_source("sample.odin", source)
	testing.expect(t, parsed)
	testing.expect_value(t, len(uses), 2)
	if len(uses) == 2 {
		testing.expect_value(t, uses[0].line, 3)
		testing.expect_value(t, uses[0].name, "TEST_HANG_BOUND_MILLISECONDS")
		testing.expect_value(t, uses[1].line, 6)
		testing.expect_value(t, uses[1].name, "TEST_PROGRESS_OVERALL_BOUND_MILLISECONDS")
	}
	plain := `package sample

// TEST_HANG_BOUND_MILLISECONDS in a comment
words :: "TEST_HANG_BOUND_MILLISECONDS"
TEST_HANG_BOUND :: 120
`
	uses, parsed = service_deadline_uses_of_source("plain.odin", plain)
	testing.expect(t, parsed)
	testing.expect_value(t, len(uses), 0)
	_, parsed = service_deadline_uses_of_source("broken.odin", "package sample\nuse :: proc( {")
	testing.expect(t, !parsed)
}

@(test)
service_deadline_check_allows_the_tests_only :: proc(t: ^testing.T) {
	testing.expect(t, !service_deadline_path_allowed("src/modules/system/sound/main.odin"))
	testing.expect(t, !service_deadline_path_allowed("src/library/modus/system/answer_wait.odin"))
	testing.expect(t, !service_deadline_path_allowed("src/library/internal/wiring/wiring_core/wiring_core.odin"))
	testing.expect(t, !service_deadline_path_allowed("src/modulus/process.odin"))
	testing.expect(t, !service_deadline_path_allowed("src/modules/testsuite/main.odin"))
	testing.expect(t, service_deadline_path_allowed("src/library/modus/system/test_bounds.odin"))
	testing.expect(t, service_deadline_path_allowed("src/library/modus/system/answer_wait_test.odin"))
	testing.expect(t, service_deadline_path_allowed("src/modules/tests/plan_applier/main.odin"))
	testing.expect(t, service_deadline_path_allowed("src/modules/demonstrations/locks/main.odin"))
}

// The sources of the repository hold the rule: no service and no library
// names a bound of the tests.
@(test)
service_deadline_check_holds_on_the_repository :: proc(t: ^testing.T) {
	testing.expect(t, service_deadline_check())
}

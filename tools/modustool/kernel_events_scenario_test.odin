package modustool

import "core:strings"
import "core:testing"

// The log of a machine whose kernel found its counters, with each line of
// that outcome.
@(private = "file")
log_counted :: proc() -> string {
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, THREAD_COUNTERS_BOOT_LINE + " (a guest of a hypervisor): AMD core counters, the counters 0 to 3" + THREAD_COUNTERS_TRIAL_PASSED)
	for line in thread_counters_lines_counted {
		append(&lines, line)
	}
	return strings.join(lines[:], "\n", context.temp_allocator)
}

// The boot line decides the outcome: a plan asks for the lines of the
// counts, no plan for the line of Unsupported.
@(test)
the_boot_line_decides_the_outcome_of_the_thread_counters :: proc(t: ^testing.T) {
	counted, missing, ok := thread_counters_outcome_check(log_counted())
	testing.expect(t, ok)
	testing.expect(t, counted)
	testing.expect_value(t, missing, "")

	none := strings.concatenate({THREAD_COUNTERS_BOOT_LINE, THREAD_COUNTERS_NONE, "AMD with no core counter extension\n", thread_counters_lines_unsupported[0]}, context.temp_allocator)
	counted, missing, ok = thread_counters_outcome_check(none)
	testing.expect(t, ok)
	testing.expect(t, !counted)
}

// A processor whose trial fails after the first one writes a later line:
// that line decides, and the machine has no counters.
@(test)
a_later_processor_that_refuses_decides_the_outcome :: proc(t: ^testing.T) {
	log := strings.concatenate({
		THREAD_COUNTERS_BOOT_LINE, ": AMD core counters, the counters 0 to 3", THREAD_COUNTERS_TRIAL_PASSED, "\n",
		THREAD_COUNTERS_BOOT_LINE, THREAD_COUNTERS_NONE, "on the processor 1, CPUID lists the counters, and the processor refused a trial access with a protection fault, to the register 00000000c0010200\n",
		thread_counters_lines_unsupported[0],
	}, context.temp_allocator)
	counted, missing, ok := thread_counters_outcome_check(log)
	testing.expect(t, ok)
	testing.expect(t, !counted)
	testing.expect_value(t, missing, "")
}

// A plan whose line does not say that the first processor passed the trial
// of its registers fails, and names the missing part.
@(test)
a_plan_with_no_trial_fails :: proc(t: ^testing.T) {
	no_trial := strings.concatenate({THREAD_COUNTERS_BOOT_LINE, ": AMD core counters\n", thread_counters_lines_counted[0]}, context.temp_allocator)
	counted, missing, ok := thread_counters_outcome_check(no_trial)
	testing.expect(t, !ok)
	testing.expect(t, counted)
	testing.expect_value(t, missing, THREAD_COUNTERS_TRIAL_PASSED)
}

// A machine whose kernel found its counters and whose program said
// Unsupported fails, and names the first line that did not come; so does
// a log with no boot line.
@(test)
an_outcome_that_disagrees_with_the_boot_line_fails :: proc(t: ^testing.T) {
	wrong := strings.concatenate({THREAD_COUNTERS_BOOT_LINE, ": AMD core counters", THREAD_COUNTERS_TRIAL_PASSED, "\n", thread_counters_lines_unsupported[0]}, context.temp_allocator)
	counted, missing, ok := thread_counters_outcome_check(wrong)
	testing.expect(t, !ok)
	testing.expect(t, counted)
	testing.expect_value(t, missing, thread_counters_lines_counted[0])

	_, missing, ok = thread_counters_outcome_check(thread_counters_lines_unsupported[0])
	testing.expect(t, !ok)
	testing.expect_value(t, missing, THREAD_COUNTERS_BOOT_LINE)
}

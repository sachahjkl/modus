package machine

import "core:strings"
import "core:testing"
import "modustool:build"
import "modustool:foundation"
import "modustool:checks"

// Each required number is a line that a scenario of the full check waits
// for, in the log that the table names; the second build is the one other
// required source.
@(test)
measure_record_required_numbers_are_waited_for :: proc(t: ^testing.T) {
	waits :: proc(steps: []Step, pattern: string) -> bool {
		for step in steps {
			if step.kind == .Wait && strings.contains(step.text, pattern) {
				return true
			}
		}
		return false
	}
	for measure in checks.measure_entries {
		if !measure.required {
			continue
		}
		waited := false
		for path in measure.files {
			switch path {
			case checks.TEST_OUTPUT:
				waited ||= waits(scenario[:], measure.pattern)
			case checks.TEST_OUTPUT_MEASURE:
				waited ||= waits(scenario_measure[:], measure.pattern)
			case checks.TEST_OUTPUT_MEASURE_SCHEDULER:
				waited ||= waits(scenario_measure_scheduler[:], measure.pattern)
			case checks.TEST_OUTPUT_MEASURE_CLOCK, checks.TEST_OUTPUT_MEASURE_DISK:
				// The log of the measure run of one process of the table.
				for process in measure_processes {
					if path == strings.concatenate({foundation.BUILD_FOLDER, "/test_output_measure_", process.name, ".txt"}, context.temp_allocator) {
						steps := make([dynamic]Step, context.temp_allocator)
						measure_process_steps(process, &steps)
						waited ||= waits(steps[:], measure.pattern)
					}
				}
			case checks.TEST_OUTPUT_NETWORK:
				waited ||= waits(scenario_network[:], measure.pattern)
			case checks.TEST_OUTPUT_TCP_REAL:
				waited ||= waits(scenario_tcp_real[:], measure.pattern)
			case checks.TEST_OUTPUT_CRYPTOGRAPHY:
				waited ||= waits(scenario_cryptography[:], measure.pattern)
			case foundation.BUILD_FOLDER + "/test_output_persist_1.txt":
				waited ||= waits(scenario_persist_first[:], measure.pattern)
			case build.REPRODUCIBLE_BUILD_RECORD:
				waited = true
			}
		}
		testing.expectf(t, waited, "the required number %q is not a line that a scenario of the full check waits for", measure.sentence)
	}
}

// Each part that the scenario of the measure run waits for is a line that
// the check reads, and each is a number of the measure record.
@(test)
processor_frame_parts_are_waited_for_and_recorded :: proc(t: ^testing.T) {
	for part in checks.processor_frame_parts {
		waited := false
		for step in scenario_measure {
			waited ||= step.kind == .Wait && step.text == part
		}
		testing.expectf(t, waited, "the scenario of the measure run does not wait for %q", part)
		recorded := false
		for measure in checks.measure_entries {
			recorded ||= measure.pattern == part && measure.files[0] == checks.TEST_OUTPUT_MEASURE
		}
		testing.expectf(t, recorded, "no number of the measure record reads %q", part)
	}
}

// Each line that the scenario of the measure run waits for is a line that
// the check reads, and the measured lines are numbers of the measure record.
@(test)
quality_lines_are_waited_for_and_recorded :: proc(t: ^testing.T) {
	for text in ([]string{checks.QUALITY_PROFILE_LINE, checks.QUALITY_WINDOW_START_LOCKS, checks.QUALITY_FRAME, checks.QUALITY_KEY}) {
		waited := false
		for step in scenario_measure {
			waited ||= step.kind == .Wait && step.text == text
		}
		testing.expectf(t, waited, "the scenario of the measure run does not wait for %q", text)
	}
	for text in ([]string{checks.QUALITY_WINDOW_START_LOCKS, checks.QUALITY_FRAME, checks.QUALITY_KEY}) {
		recorded := false
		for measure in checks.measure_entries {
			recorded ||= measure.pattern == text && measure.files[0] == checks.TEST_OUTPUT_MEASURE
		}
		testing.expectf(t, recorded, "no number of the measure record reads %q", text)
	}
}

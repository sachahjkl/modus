package machine

import "core:strings"
import "core:testing"
import "modustool:foundation"

// The line of a lost record fails every scenario: common_failure_line finds
// the whole line that holds it, after a line before it and with the end of
// the line of the serial port, and finds nothing in a log with no such line.
@(test)
a_lost_record_is_a_common_failure :: proc(t: ^testing.T) {
	LOST :: "kernel: 12 records of the log did not reach the serial port"
	LOG :: "[console] started\r\n" + LOST + "\r\n[root] root: ok\r\n"
	testing.expect_value(t, common_failure_line(LOG, 0), LOST)
	testing.expect_value(t, common_failure_line("[console] started\r\nroot: ok\r\n", 0), "")
}

// A line of a process that quotes the text is not the line of the kernel:
// it starts with the name of the process, and fails nothing. The line of
// the kernel after it is found.
@(test)
a_quoted_failure_text_is_not_a_failure :: proc(t: ^testing.T) {
	QUOTED :: "[console] the line kernel: 4 records of the log did not reach the serial port, in a note\r\n"
	ECHOED :: "[console] kernel: 4 records of the log did not reach the serial port\r\n"
	LOST :: "kernel: 4 records of the log did not reach the serial port"
	testing.expect_value(t, common_failure_line(QUOTED + ECHOED, 0), "")
	testing.expect_value(t, common_failure_line(QUOTED + ECHOED + LOST + "\r\n", 0), LOST)
}

// A read of the log that ends in the middle of the line still finds it at
// the next read, which starts where the first one ended. A line that ended
// before the line of the place of the read is not read again.
@(test)
a_common_failure_cut_by_two_reads_is_found :: proc(t: ^testing.T) {
	LOST :: "kernel: 3 records of the log did not reach the serial port"
	BEFORE :: "[console] started\r\n"
	LOG :: BEFORE + LOST + "\r\n"
	whole_log: string = LOG
	first_read := len(BEFORE) + 20
	testing.expect_value(t, common_failure_line(whole_log[:first_read], 0), "")
	testing.expect_value(t, common_failure_line(whole_log, first_read), LOST)
	LATER :: LOG + "[root] root: a line after the lost records\r\n"
	testing.expect_value(t, common_failure_line(LATER, len(LATER)), "")
}

// A stall of the path of a key fails a machine with a TPM at the report of
// 60 s, and only there: the report of 30 s, a report of 600 s (which only
// comes after the one of 60 s), a line that has not ended, and a machine
// with no TPM fail nothing. The failure quotes the whole line, which names
// the step, and a line that two reads cut is found at the second one.
@(test)
a_wait_of_60_seconds_of_the_tpm_path_fails_a_machine_with_a_tpm :: proc(t: ^testing.T) {
	THIRTY :: "[tpm] tpm: a wait passed 30 s: the end of the command, for the TPM command 000000000000017e in locality 0, in the pin read; waited 30001 ms\r\n"
	SIXTY :: "[tpm] tpm: a wait passed 60 s: the end of the command, for the TPM command 000000000000017e in locality 0, in the pin read; waited 60002 ms"
	CLIENT :: "[unlock] unlock: the wait for the TPM service passed 60 s: the pin read request, tag 4; waited 60010 ms"
	LATE :: "[tpm] tpm: a wait passed 600 s: the end of the command, for the TPM command 000000000000017e in locality 0, in the pin read; waited 600002 ms\r\n"
	line, stall := machine_failure_line(THIRTY, 0, true)
	testing.expect(t, line == "" && !stall)
	line, stall = machine_failure_line(LATE, 0, true)
	testing.expect(t, line == "" && !stall)
	// A line that has not ended: not yet.
	line, stall = machine_failure_line(THIRTY + SIXTY, 0, true)
	testing.expect(t, line == "" && !stall)
	// A machine with no TPM: never.
	line, stall = machine_failure_line(THIRTY + SIXTY + "\r\n", 0, false)
	testing.expect(t, line == "" && !stall)
	// A line that two reads cut: the second read, from the place of the
	// first, finds it whole.
	whole := THIRTY + SIXTY + "\r\n"
	cut := len(THIRTY) + 25
	line, stall = machine_failure_line(whole[:cut], 0, true)
	testing.expect(t, line == "" && !stall)
	line, stall = machine_failure_line(whole, cut, true)
	testing.expect_value(t, line, SIXTY)
	testing.expect(t, stall)
	// The report of the client fails the same way.
	line, stall = machine_failure_line(THIRTY + CLIENT + "\r\n", 0, true)
	testing.expect_value(t, line, CLIENT)
	testing.expect(t, stall)
	// A failure of the kernel comes first, and is no stall.
	LOST :: "kernel: 2 records of the log did not reach the serial port"
	line, stall = machine_failure_line(LOST + "\r\n" + SIXTY + "\r\n", 0, true)
	testing.expect_value(t, line, LOST)
	testing.expect(t, !stall)
}

// Each text of TPM_STALL_TEXTS is the start of the sentence of the report
// of 60 s of its fact: the template of the fact, with 60 in place of its
// seconds, holds it. A change of a sentence breaks this test, not a run of
// a machine that would wait for a text that no line has.
@(test)
the_stall_texts_are_the_sentences_of_their_facts :: proc(t: ^testing.T) {
	Source :: struct {
		file:     string,
		template: string,
	}
	sources := [?]Source {
		{"src/modules/system/tpm/facts.odin", "tpm: a wait passed {passed_seconds} s:"},
		{"src/modules/system/unlock/facts.odin", "unlock: the wait for the TPM service passed {passed_seconds} s:"},
	}
	stall_texts := TPM_STALL_TEXTS
	testing.expect_value(t, len(stall_texts), len(sources))
	for source, index in sources {
		text, read := foundation.read_text_file(source.file)
		testing.expectf(t, read, "%s cannot be read", source.file)
		testing.expectf(t, strings.contains(text, strings.concatenate({"@(log_fact = \"", source.template}, context.temp_allocator)), "%s has no fact whose template starts with %q", source.file, source.template)
		sixty, _ := strings.replace_all(source.template, "{passed_seconds}", "60", context.temp_allocator)
		testing.expect_value(t, stall_texts[index], sixty)
	}
}

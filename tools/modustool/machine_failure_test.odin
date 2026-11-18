package modustool

import "core:testing"

// The line of a lost record fails every scenario: common_failure_line finds
// the whole line that holds it, after a line before it and with the end of
// the line of the serial port, and finds nothing in a log with no such line.
@(test)
a_lost_record_is_a_common_failure :: proc(t: ^testing.T) {
	LOST :: "kernel: 12 records of the log did not reach the serial port"
	LOG :: "[console] started\r\n" + LOST + "\r\n[root:processes] root: ok\r\n"
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
	LATER :: LOG + "[root:processes] root: a line after the lost records\r\n"
	testing.expect_value(t, common_failure_line(LATER, len(LATER)), "")
}

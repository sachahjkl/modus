#+build !freestanding
package disk_program

import "core:testing"
import op "modus:contract/operation"

// A report of a page fault at address 0 in a module at 0x400000, three
// frames in the module and one frame that no module record holds: a word
// of the stack.
@(private = "file")
test_report :: proc() -> (report: op.Stop_Report) {
	report.code = op.STOP_CODE_FAULT + 14
	report.vector = 14
	report.instruction = 0x401010
	report.module = {base = 0x400000, size = 0x2000}
	report.frame_count = 4
	report.frames[0] = {address = 0x401010, base = 0x400000}
	report.frames[1] = {address = 0x401100, base = 0x400000}
	report.frames[2] = {address = 0x7fff_1234_5678, base = 0}
	report.frames[3] = {address = 0x401200, base = 0x400000}
	report.program_serial = 9
	return
}

// The frames that a module record holds stay; a word of the stack goes,
// and is counted. The address 0 of a null read stays.
@(test)
a_hidden_report_keeps_the_frames_of_the_modules :: proc(t: ^testing.T) {
	report := test_report()
	stop_report_hide(&report)
	testing.expect_value(t, report.instruction, u64(0x401010))
	testing.expect_value(t, report.address, u64(0))
	testing.expect_value(t, report.frames[1].address, u64(0x401100))
	testing.expect(t, report.frames[2] == op.Stop_Frame{}, "the word of the stack is hidden")
	testing.expect_value(t, report.frames[3].address, u64(0x401200))
	testing.expect_value(t, report.hidden_value_count, u64(1))
	testing.expect_value(t, report.program_serial, u64(0))
}

// The address of a page fault outside the first page and outside the
// module of the instruction can be a word of memory: it is hidden. An
// instruction that no module holds is hidden too. A count of frames past
// the capacity is cut.
@(test)
a_hidden_report_takes_out_the_words_of_memory :: proc(t: ^testing.T) {
	report := test_report()
	report.address = 0x7fff_0000_0000
	report.instruction = 0x9000_0000
	report.frame_count = 1000
	stop_report_hide(&report)
	testing.expect_value(t, report.address, u64(0))
	testing.expect_value(t, report.instruction, u64(0))
	testing.expect_value(t, report.frame_count, u64(op.STOP_FRAME_CAPACITY))
	testing.expect_value(t, report.hidden_value_count, u64(3))
	inside := test_report()
	inside.address = 0x401800
	stop_report_hide(&inside)
	testing.expect_value(t, inside.address, u64(0x401800))
}

// A new fault of a nickname replaces its report; a full table gives the
// place of the oldest; two principals with one nickname have two reports.
@(test)
the_kept_reports_by_principal_and_nickname :: proc(t: ^testing.T) {
	table: Kept_Stop_Reports
	report := test_report()
	hash: [HASH_SIZE]u8
	hash[0] = 1
	testing.expect(t, kept_stop_report_keep(&table, 0, "outsider", hash, &report))
	testing.expect(t, !kept_stop_report_keep(&table, 0, "", hash, &report))
	testing.expect(t, !kept_stop_report_keep(&table, 0, "twenty_four_bytes_long__", hash, &report))
	testing.expect(t, kept_stop_report_find(&table, 1, "outsider") == nil, "another principal reads nothing")
	report.vector = 6
	hash[0] = 2
	testing.expect(t, kept_stop_report_keep(&table, 0, "outsider", hash, &report))
	found := kept_stop_report_find(&table, 0, "outsider")
	if testing.expect(t, found != nil) {
		testing.expect_value(t, found.report.vector, u32(6))
		testing.expect_value(t, found.module_hash[0], u8(2))
	}
	used := 0
	for place in table.places {
		if place.sequence != 0 {
			used += 1
		}
	}
	testing.expect_value(t, used, 1)
	names := [?]string{"a", "b", "c", "d", "e", "f", "g", "h"}
	for name in names {
		testing.expect(t, kept_stop_report_keep(&table, 0, name, hash, &report))
	}
	testing.expect(t, kept_stop_report_find(&table, 0, "outsider") == nil, "the oldest report gave its place")
	testing.expect(t, kept_stop_report_find(&table, 0, "a") != nil)
	testing.expect(t, kept_stop_report_find(&table, 0, "h") != nil)
}

// A reader of the record output of `output_counter`, for the wiring list
// that the console gives a start (src/md/features/module_outputs.md, "The
// console form"). The console starts it with a list whose row wires
// `output_counter.counts`, with the condition `status = 404`, to its record
// input `counts`, before its first instruction.
//
// It reads the joined record, then three records, and checks each one: the
// status 404, a serial that leaves 2 when divided by 3, and a serial past
// the one before. The writer leaves out the records that fail the
// condition, so the serials of its ring jump by 3: the border of this
// reader takes them only because the end of its wiring says that the ring
// has a condition.
//
// **Start**: by the console, with a wiring list. **What a reader sees**: no
// window; one line "output_count_reader: ...: as it must", or a line
// "output_count_reader: WRONG: ...". It stops itself with the outcome
// Done, or Failed after a WRONG line.
package output_count_reader

import "modus:system"

// The record of output_counter: the same record description, so the root
// service wires the two.
Counted :: struct {
	serial: u64,
	status: u64,
}

// The records of output_counter that its starter wires here.
counts: system.Record_Input(Counted)

// The records that it reads past the joined record.
RECORDS_READ :: 3
STATUS_NOT_FOUND :: 404

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	record: Counted
	joined, joined_status := system.input_read(&counts, &record, deadline)
	if joined_status != .Ok || joined.kind != .Joined {
		wrong("the first compartment is not a joined record; the status", u64(joined_status))
	}
	serials: [RECORDS_READ]u64
	for index in 0 ..< RECORDS_READ {
		item, status := system.input_read(&counts, &record, deadline)
		if status != .Ok || item.kind != .Record {
			wrong("a record did not come; the status", u64(status))
		}
		if record.status != STATUS_NOT_FOUND || record.serial % 3 != 2 || record.serial != u64(item.serial) {
			wrong("a record that the condition leaves out came; its serial", record.serial)
		}
		if index > 0 && record.serial <= serials[index - 1] {
			wrong("a serial does not move forward:", record.serial)
		}
		serials[index] = record.serial
	}
	system.log_fact(.Info, Counts_Read{joined_serial = u64(joined.serial), records = RECORDS_READ, first_serial = serials[0], second_serial = serials[1], third_serial = serials[2]})
	system.stop(.Done)
}

// The tool counts the module and thread stack; working memory holds the wiring
// ring mappings and tables.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 256}

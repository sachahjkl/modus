// The reader of a pair of modules that the start list wires together. The
// design: src/md/features/module_outputs.md, "The wiring rows of a start
// list".
// The default start list starts this module before `wired_writer`, whose
// start carries the wiring row of `wired_writer.numbers` to `numbers`.
//
// It waits for its writer, then reads the joined record of 0, the
// NUMBERS_WRITTEN numbers in order, each with its square, and a clean end
// record, and stops itself with Done. A joined record past 0 says that the
// writer ran before its reader: the start list wired the pair in the wrong
// order.
//
// **Start**: by the default start policy. **What a reader sees**: no
// window; one line "wired_reader: read the joined record of 0, the 16
// numbers of wired_writer in order, and a clean end: ...". With no writer
// within the hang bound, the fact "wired_reader: no writer came ..." and
// the stop Done. A record that breaks the order gives a line
// "wired_reader: WRONG: ..." and the stop Failed.
package wired_reader

import "modus:system"

// One number and its square, as wired_writer describes it.
Wired_Number :: struct {
	number: u64,
	square: u64,
}

// The numbers that wired_writer writes.
NUMBERS_WRITTEN :: 16

// The numbers of wired_writer.
numbers: system.Record_Input(Wired_Number)

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// The writer starts after this process: its end comes in the wiring
	// ring, and the state is read again after each wait. The start policy
	// starts the writer right after this process, and the writer writes its
	// numbers at once, so each wait ends within the hang bound.
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for !system.input_has_writer(&numbers) {
		// A writer that the start policy does not start, or whose wiring
		// the root service refuses, is a state of the machine, not a fault
		// of this reader: one plain fact, and a clean stop.
		if system.time() >= deadline {
			system.log_fact(.Info, No_Writer_Came{milliseconds = system.TEST_HANG_BOUND_MILLISECONDS})
			system.stop(.Done)
		}
		system.wiring_wait(deadline)
	}
	number: Wired_Number
	item, status := system.input_read(&numbers, &number, deadline)
	if status != .Ok || item.kind != .Joined || item.serial != 0 {
		wrong("the first compartment is not the joined record of 0; its serial", u64(item.serial))
	}
	for serial in u32(0) ..< NUMBERS_WRITTEN {
		item, status = system.input_read(&numbers, &number, deadline)
		if status != .Ok || item.kind != .Record || item.serial != serial || number.number != u64(serial) || number.square != u64(serial) * u64(serial) {
			wrong("a number is not the next one; the serial", u64(serial))
		}
	}
	item, status = system.input_read(&numbers, &number, deadline)
	if status != .Ended || item.kind != .End || item.error.kind != 0 || item.serial != NUMBERS_WRITTEN {
		wrong("numbers did not end with a clean end record; the status", u64(status))
	}
	system.log_fact(.Info, Numbers_Read{numbers = NUMBERS_WRITTEN})
	system.stop(.Done)
}

// Measure pending: the 2048 pages of the least budget in which it ran
// before its floor was counted. The first machine pass with the check of
// the floors (the check boot-test of the flake) writes the peak of its
// budget at its first state of work; modustool floors measured on the log
// of that pass gives the working memory that replaces this number
// (src/md/features/module_budget_request.md, "The first state of work").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2048}

// The writer of a pair of modules that the start list wires together. The
// design: src/md/features/module_outputs.md, "The wiring rows of a start
// list".
// The default start list starts `wired_reader`, then this module, and its
// wiring row joins `numbers` to `wired_reader.numbers` at this start: the
// root service gives the ring before the first instruction, so the reader
// reads every record from the serial 0.
//
// It writes NUMBERS_WRITTEN numbers, each with its square, ends `numbers`
// with a clean end record, and stops itself with Done. With no reader, as
// from a console that starts it with no list, each write gives No_Reader
// and the records go to nothing, with their count.
//
// **Start**: by the default start policy, or by `start("wired_writer")`.
// **What a reader sees**: no window; one line "wired_writer: wrote 16
// numbers to 1 reader, and ended numbers".
package wired_writer

import "modus:system"

// One number and its square. wired_reader declares the same record: the
// root service compares the two descriptions at the wiring.
Wired_Number :: struct {
	number: u64,
	square: u64,
}

// The numbers that it writes, from 0. wired_reader shares the count.
NUMBERS_WRITTEN :: 16

// Each number from 0, and its square.
numbers: system.Record_Output(Wired_Number)

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// The ends of the list of its start are the first records of its
	// wiring ring: the count of the readers is known before the first
	// write.
	readers := system.output_reader_count(&numbers)
	for number in u64(0) ..< NUMBERS_WRITTEN {
		_ = system.output_write(&numbers, Wired_Number{number = number, square = number * number})
	}
	_ = system.output_end(&numbers)
	system.log_fact(.Info, Numbers_Written{numbers = NUMBERS_WRITTEN, readers = u64(readers)})
	system.stop(.Done)
}

// The least budget of 2048 pages, in which it ran before its floor was
// counted. It leaves when the peak of its budget at its first state of
// work is read (src/md/features/module_budget_request.md, "State").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2048}

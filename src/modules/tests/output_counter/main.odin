// A writer of one record output for the streams of the console
// (src/md/features/module_outputs.md, "The console form"). The console
// starts it, and reads its record output by its typed name:
// `output_counter.counts`.
//
// It writes one record each COUNT_INTERVAL_MILLISECONDS while a reader is
// wired, and none while no reader is: it waits for a wiring, so the serial
// of each record is the count of the records before it, and no record is
// discarded. A record whose serial leaves 2 when divided by 3 has the
// status 404, each other one the status 200, so a condition on the status
// keeps one record of three.
//
// **Start**: `start("output_counter")` in the console. **What a reader
// sees**: no window; one line when it starts, and one line each time its
// reader leaves. It runs until a principal stops it: `stop("output_counter")`.
package output_counter

import "modus:system"

// One record of the count: its serial, and a status of the form of the
// status of an HTTP answer.
Counted :: struct {
	serial: u64,
	status: u64,
}

// One record each time the writer counts, while a reader is wired.
counts: system.Record_Output(Counted)

// The time between two records: a reader sees the rows come one by one.
COUNT_INTERVAL_MILLISECONDS :: 200

// The two statuses: one record of three is 404.
STATUS_FOUND :: 200
STATUS_NOT_FOUND :: 404

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	system.log_fact(.Info, Running{interval_milliseconds = COUNT_INTERVAL_MILLISECONDS})
	had_reader := false
	// The start is done: the first state of work of the process
	// (src/md/features/module_budget_request.md, "The first state of work").
	system.ready()
	for {
		if !system.output_read_by(&counts) {
			if had_reader {
				system.log_fact(.Info, Reader_Left{records = u64(counts.next_serial)})
				had_reader = false
			}
			// A wiring brings an end in the wiring ring, which ends the wait.
			system.wiring_wait(system.WAIT_FOREVER, counts.index)
			continue
		}
		had_reader = true
		serial := u64(counts.next_serial)
		record := Counted {
			serial = serial,
			status = serial % 3 == 2 ? STATUS_NOT_FOUND : STATUS_FOUND,
		}
		// The write waits while the ring is full; a reader that closes its
		// end ends the wait with its end word.
		system.output_write(&counts, record)
		// The next record after the interval, or at once when the reader
		// leaves: the wait ends on the end word of its ring.
		system.wiring_wait(system.time() + COUNT_INTERVAL_MILLISECONDS, counts.index)
	}
}

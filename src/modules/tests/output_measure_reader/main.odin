// A reader of the measure 2 of the record outputs
// (src/md/features/module_outputs.md, "The measures that decide it").
// The test module `output_measure` starts it, then starts
// `output_measure_writer` with a wiring list whose rows wire `samples` to
// this record input.
//
// It reads each record of the run in order, and checks its serial and its
// count. In the run of one reader, it measures the wake: for each record
// of the first part, which the writer writes one at a time, the cycles
// from the write to its read; for the burst, its wakes, as each read that
// finds its ring empty waits once. Each measure is printed, never
// asserted.
//
// **Start**: by `output_measure` only. **What a reader sees**: no window;
// one line of measures in the run of one reader, or a line
// "output_measure_reader: WRONG: ...". It stops itself with the outcome
// Done, or Failed after a WRONG line.
package output_measure_reader

import "modus:contract/output"
import "modus:contract/value_kinds"
import "modus:system"

// The record of the writer: the type check of the root service compares
// the two descriptions at the wiring.
Sample :: struct {
	readers: u64,
	stamp:   u64,
	size:    u64,
	method:  [8]u8,
	target:  [56]u8,
	peer:    [32]u8,
}

// The records of the measures.
samples: system.Record_Input(Sample)

// The counts of the writer.
WAKE_SAMPLES :: 200
BURST_SAMPLES :: 1000
TIMED_SAMPLES :: 1000
SAMPLES_OF_A_RUN :: WAKE_SAMPLES + BURST_SAMPLES + TIMED_SAMPLES

@(private = "file")
hang_deadline :: proc "contextless" () -> u64 {
	return system.time() + system.TEST_HANG_BOUND_MILLISECONDS
}

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}

times: [WAKE_SAMPLES]u64

@(private = "file")
least_and_median :: proc "contextless" (values: []u64) -> (least, median: u64) {
	for index in 1 ..< len(values) {
		value := values[index]
		place := index
		for place > 0 && values[place - 1] > value {
			values[place] = values[place - 1]
			place -= 1
		}
		values[place] = value
	}
	return values[0], values[len(values) / 2]
}

// read reads the record of a serial: wakes counts one when the ring was
// empty and the read waited.
@(private = "file")
read :: proc "contextless" (serial: u32, sample: ^Sample, wakes: ^u64 = nil) {
	item, status := system.input_read(&samples, sample, system.time())
	if status == .No_Record {
		if wakes != nil {
			wakes^ += 1
		}
		item, status = system.input_read(&samples, sample, hang_deadline())
	}
	if status != .Ok || item.kind != .Record || item.serial != serial {
		system.log_fact(.Error, Wrong_Record{wanted_serial = u64(serial), status_word = u64(status), kind_word = u64(item.kind), serial = u64(item.serial)})
		system.stop(.Failed)
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	sample: Sample
	item, status := system.input_read(&samples, &sample, hang_deadline())
	if status != .Ok || item.kind != .Joined || item.serial != 0 {
		wrong("the first compartment is not the joined record of 0; the status word", u64(status))
	}
	serial := u32(0)
	for index in 0 ..< WAKE_SAMPLES {
		read(serial, &sample)
		times[index] = system.cycles() - sample.stamp
		serial += 1
	}
	wakes: u64
	for _ in 0 ..< BURST_SAMPLES {
		read(serial, &sample, &wakes)
		serial += 1
	}
	for _ in 0 ..< TIMED_SAMPLES {
		read(serial, &sample)
		serial += 1
	}
	item, status = system.input_read(&samples, &sample, hang_deadline())
	if status != .Ended || item.kind != .End || item.error.kind != 0 || item.serial != SAMPLES_OF_A_RUN {
		system.log_fact(.Error, Wrong_End{records = SAMPLES_OF_A_RUN, status_word = u64(status), end_word = value_kinds.text_field(output.end_word_names[item.end_word], END_WORD_FIELD_BYTES)})
		system.stop(.Failed)
	}
	if sample.readers == 1 {
		least, median := least_and_median(times[:])
		system.log_fact(.Info, Wake_Measured{least = least, median = median, wake_records = WAKE_SAMPLES, burst_records = BURST_SAMPLES, wakes = wakes})
	}
	system.stop(.Done)
}

// The least budget of 2048 pages, in which it ran before its floor was
// counted. It leaves when the peak of its budget at its first state of
// work is read (src/md/features/module_budget_request.md, "State").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2048}

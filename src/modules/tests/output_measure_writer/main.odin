// The writer of the measures 1, 2 and 4 of the record outputs
// (src/md/features/module_outputs.md, "The measures that decide it"). The
// test module `output_measure` starts it with a wiring list
// whose rows wire its record output `samples` to each of its readers, so
// each ring exists before its first instruction and each reader joins at 0.
//
// It writes, in this order, with a wait for room in each write:
//
// 1. WAKE_SAMPLES records one at a time, each after a pause that lets each
//    reader wait again: the reader measures the time from the write to its
//    read (measure 2). The pause paces the writes; nothing reads a time to
//    decide.
// 2. BURST_SAMPLES records back to back: the reader counts its wakes
//    (measure 2).
// 3. TIMED_SAMPLES records, each write timed in cycles (measures 1 and 4,
//    with the count of the readers of this run).
//
// Then, with one reader only, LOG_FACT_SAMPLES log facts of the same record,
// each timed (measure 1), and as many lines of text, each timed. In the run
// whose wiring list also wires the record output `log` of this process,
// the same facts and lines go to that ring too: the two runs give measure 9,
// the cost of a log call with and without the wiring. Then the end record.
// Each measure is printed, never asserted.
//
// **Start**: by `output_measure` only. **What a reader sees**: no window;
// one line for each measure, or a line "output_measure_writer: WRONG: ...".
// It stops itself with the outcome Done, or Failed after a WRONG line.
package output_measure_writer

import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:system"

// One record of the measures: the size and the Text fields of the access
// record of `server`, with the count of the readers of the run and the
// cycle counter at the write in its two first words.
Sample :: struct {
	readers: u64, // The readers of this run of the writer.
	stamp:   u64, // The cycle counter of the processor of the writer at the write.
	size:    u64, // The size of an answer: 0.
	method:  [8]u8,
	target:  [56]u8,
	peer:    [32]u8,
}

// The same record as a log fact, for the time of the log against the time
// of a record output.
@(log_fact = "output_measure_writer: a sample of {readers} readers, {stamp}, {size}, {method} {target} {peer}")
Sample_Logged :: struct {
	readers: u64,
	stamp:   u64,
	size:    u64,
	method:  [8]u8,
	target:  [56]u8,
	peer:    [32]u8,
}

// The records of the measures.
samples: system.Record_Output(Sample)

// The counts of each part. The reader shares them, and checks the order
// and the count of each record.
WAKE_SAMPLES :: 200
BURST_SAMPLES :: 1000
TIMED_SAMPLES :: 1000
SAMPLES_OF_A_RUN :: WAKE_SAMPLES + BURST_SAMPLES + TIMED_SAMPLES
// Log facts, and as many lines, within the log records of one second of
// this process (1000).
LOG_FACT_SAMPLES :: 200
// The pause between two writes of the first part.
WAKE_PAUSE_MILLISECONDS :: 1

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}

times: [TIMED_SAMPLES]u64

// least_and_median sorts the times in place and gives the least and the
// median.
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

@(private = "file")
sample_of :: proc "contextless" (readers: u64) -> Sample {
	sample := Sample{readers = readers, stamp = system.cycles()}
	copy(sample.method[:], "GET")
	copy(sample.target[:], "/counts.json")
	copy(sample.peer[:], "10.0.2.2 port 49200")
	return sample
}

@(private = "file")
write :: proc "contextless" (sample: Sample) {
	if status := system.output_write(&samples, sample); status != .Ok {
		wrong("a write of samples gave the status word", u64(status))
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	readers := u64(system.output_reader_count(&samples))
	if readers == 0 {
		wrong("samples has no reader at the first instruction", 0)
	}
	for _ in 0 ..< WAKE_SAMPLES {
		write(sample_of(readers))
		wait := system.wait_begin()
		system.wait_end(&wait, system.time() + WAKE_PAUSE_MILLISECONDS)
	}
	for _ in 0 ..< BURST_SAMPLES {
		write(sample_of(readers))
	}
	for index in 0 ..< TIMED_SAMPLES {
		sample := sample_of(readers)
		start := system.cycles()
		write(sample)
		times[index] = system.cycles() - start
	}
	least, median := least_and_median(times[:])
	system.log_fact(.Info, Write_Measured{readers = readers, record_bytes = size_of(Sample), least = least, median = median, writes = TIMED_SAMPLES})
	if readers == 1 {
		for index in 0 ..< LOG_FACT_SAMPLES {
			sample := sample_of(readers)
			start := system.cycles()
			system.log_fact(.Info, Sample_Logged{readers = sample.readers, stamp = sample.stamp, size = sample.size, method = sample.method, target = sample.target, peer = sample.peer})
			times[index] = system.cycles() - start
		}
		least, median = least_and_median(times[:LOG_FACT_SAMPLES])
		// The context says if the start wired log: the root service writes
		// the handle of its ring there, and 0 else.
		wired := ctx.handles[op.CONTEXT_LOG_OUTPUT] != 0
		log_state := value_kinds.text_field(wired ? "wired" : "not wired", LOG_STATE_FIELD_BYTES)
		if !wired {
			system.log_fact(.Info, Log_Fact_Measured{least = least, median = median, facts = LOG_FACT_SAMPLES})
		}
		system.log_fact(.Info, Measure_Nine_Fact{least = least, median = median, facts = LOG_FACT_SAMPLES, log_state = log_state})
		for index in 0 ..< LOG_FACT_SAMPLES {
			start := system.cycles()
			// The line of text is the subject of this measure, against the
			// fact above: it stays text.
			system.log(.Info, "output_measure_writer: a line of the measure ", u64(index))
			times[index] = system.cycles() - start
		}
		least, median = least_and_median(times[:LOG_FACT_SAMPLES])
		system.log_fact(.Info, Measure_Nine_Line{least = least, median = median, lines = LOG_FACT_SAMPLES, log_state = log_state})
	}
	if status := system.output_end(&samples, deadline = system.time() + system.TEST_HANG_BOUND_MILLISECONDS); status != .Ok {
		wrong("the end of samples gave the status word", u64(status))
	}
	system.stop(.Done)
}

// Measure pending: the 2048 pages of the least budget in which it ran
// before its floor was counted. The first machine pass with the check of
// the floors (the check boot-test of the flake) writes the peak of its
// budget at its first state of work; modustool floors measured on the log
// of that pass gives the working memory that replaces this number
// (src/md/features/module_budget_request.md, "The first state of work").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2048}

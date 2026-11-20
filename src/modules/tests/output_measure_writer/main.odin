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
// each timed (measure 1). Then the end record. Each measure is printed,
// never asserted.
//
// **Start**: by `output_measure` only. **What a reader sees**: no window;
// one line for each measure, or a line "output_measure_writer: WRONG: ...".
// It stops itself with the outcome Done, or Failed after a WRONG line.
package output_measure_writer

import "modus:support/system"

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
// Log facts within the log records of one second of this process (1000).
LOG_FACT_SAMPLES :: 200
// The pause between two writes of the first part.
WAKE_PAUSE_MILLISECONDS :: 1

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log(.Error, "output_measure_writer: WRONG: ", text, " ", value)
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
	system.log(.Info, "output_measure_writer: ", readers, " readers: one write of a record of ", u64(size_of(Sample)), " bytes into the ring of each reader: least ", least, ", median ", median, " cycles, of ", u64(TIMED_SAMPLES), " writes")
	if readers == 1 {
		for index in 0 ..< LOG_FACT_SAMPLES {
			sample := sample_of(readers)
			start := system.cycles()
			system.log_fact(.Info, Sample_Logged{readers = sample.readers, stamp = sample.stamp, size = sample.size, method = sample.method, target = sample.target, peer = sample.peer})
			times[index] = system.cycles() - start
		}
		least, median = least_and_median(times[:LOG_FACT_SAMPLES])
		system.log(.Info, "output_measure_writer: one log fact of the same record: least ", least, ", median ", median, " cycles, of ", u64(LOG_FACT_SAMPLES), " facts")
	}
	if status := system.output_end(&samples, deadline = system.time() + system.TEST_HANG_BOUND_MILLISECONDS); status != .Ok {
		wrong("the end of samples gave the status word", u64(status))
	}
	system.stop(.Done)
}

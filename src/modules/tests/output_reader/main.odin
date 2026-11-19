// The reader of the machine test of the record outputs
// (src/md/features/module_outputs.md, "How a test waits on a record
// output"). The test module `output_wiring` starts it, then wires one of
// its record inputs, and the first record input that has a writer chooses
// what it reads:
//
// - `probes`: the joined record, the probes from the serial that it names
//   to the last one in order, and a clean end record. The reader of the
//   start of the writer joins at 0; the reader that a Wire adds after five
//   probes joins at 5.
// - `unended`: the joined record of 0, one probe, then the end word
//   Writer_Stopped of a writer that stopped with no end record.
// - `watched`: the joined record and one probe, then the stop of this
//   process: the writer reads the end word Reader_Stopped.
//
// It declares one record output, `echo`, which no row wires: the test of a
// wiring of one process to itself names it.
//
// **Start**: by `output_wiring` only. **What a reader sees**: no window;
// one line "output_reader: ...: as it must", or a line "output_reader:
// WRONG: ...". It stops with the code 0.
package output_reader

import op "modus:contract/operation"
import "modus:contract/output"
import "modus:support/system"

// One probe, as the writer describes it: the type check compares the two
// descriptions.
Probe :: struct {
	serial: u64,
	mark:   u64,
}

// The probes of the case of the joined record.
probes: system.Record_Input(Probe)

// One probe, then the end word of a writer that stopped.
unended: system.Record_Input(Probe)

// One probe, then the stop of this process.
watched: system.Record_Input(Probe)

// A record output of this process: a wiring of it to a record input of
// this process is refused.
echo: system.Record_Output(Probe)

PROBE_MARK :: 0x5052_4F42_0000_0000
PROBES_OF_THE_STREAM :: 8

@(private = "file")
hang_deadline :: proc "contextless" () -> u64 {
	return system.time() + system.TEST_HANG_BOUND_MILLISECONDS
}

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log(.Error, "output_reader: WRONG: ", text, " ", value)
	system.stop(.Failed)
}

// entry waits for the first record input that has a writer, and reads it.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	deadline := hang_deadline()
	for {
		switch {
		case system.input_has_writer(&probes):
			probes_read()
			system.stop(.Done)
		case system.input_has_writer(&unended):
			unended_read()
			system.stop(.Done)
		case system.input_has_writer(&watched):
			// The joined record and the probe, then the stop: the writer
			// reads Reader_Stopped.
			probe: Probe
			first, _ := system.input_read(&watched, &probe, hang_deadline())
			second, status := system.input_read(&watched, &probe, hang_deadline())
			if first.kind != .Joined || status != .Ok || second.kind != .Record {
				wrong("watched did not give the joined record and one probe; the status", u64(status))
			}
			system.log(.Info, "output_reader: watched: the joined record and one probe, then this reader stops: as it must")
			system.stop(.Done)
		}
		if system.time() >= deadline {
			wrong("no record input had a writer within the hang bound", 0)
		}
		system.wiring_wait(deadline)
	}
}

// probes_read reads the joined record, each probe in order, and the end.
@(private = "file")
probes_read :: proc "contextless" () {
	probe: Probe
	item, status := system.input_read(&probes, &probe, hang_deadline())
	if status != .Ok || item.kind != .Joined {
		wrong("the first compartment of probes is not a joined record; the status", u64(status))
	}
	joined := item.serial
	for serial in joined ..< PROBES_OF_THE_STREAM {
		item, status = system.input_read(&probes, &probe, hang_deadline())
		if status != .Ok || item.kind != .Record || item.serial != serial || probe.serial != u64(serial) || probe.mark != PROBE_MARK | u64(serial) {
			wrong("a probe is not the next one; the serial", u64(item.serial))
		}
	}
	item, status = system.input_read(&probes, &probe, hang_deadline())
	if status != .Ended || item.kind != .End || item.error.kind != 0 || item.serial != PROBES_OF_THE_STREAM {
		wrong("probes did not end with a clean end record; the status", u64(status))
	}
	system.log(.Info, "output_reader: probes: joined after ", u64(joined), " records, the probes ", u64(joined), " to ", u64(PROBES_OF_THE_STREAM - 1), " in order, and a clean end: as it must")
}

// unended_read reads the joined record of 0, one probe, and the end word
// of a writer that stopped.
@(private = "file")
unended_read :: proc "contextless" () {
	probe: Probe
	first, _ := system.input_read(&unended, &probe, hang_deadline())
	second, second_status := system.input_read(&unended, &probe, hang_deadline())
	if first.kind != .Joined || first.serial != 0 || second_status != .Ok || second.kind != .Record {
		wrong("unended did not give the joined record of 0 and one probe; the status", u64(second_status))
	}
	end, status := system.input_read(&unended, &probe, hang_deadline())
	if status != .Ended || end.end_word != .Writer_Stopped {
		wrong("unended did not end with Writer_Stopped; the end word", u64(end.end_word))
	}
	// The writer stops itself with Done after its probe: the end words
	// carry the stop that the kernel recorded, not a word of the writer.
	if end.stop_cause != .Itself || end.stop_outcome != .Done {
		wrong("unended did not carry the stop itself, Done; the stop cause", u64(end.stop_cause))
	}
	system.log(.Info, "output_reader: unended: the joined record of 0, one probe, then the end word ", output.end_word_names[end.end_word], " with the stop ", op.STOP_CAUSE_TEXTS[end.stop_cause], ", ", op.STOP_OUTCOME_TEXTS[end.stop_outcome], ": as it must")
}

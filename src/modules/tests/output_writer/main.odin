// The writer of the machine test of the record outputs
// (src/md/features/module_outputs.md, "How a test waits on a record
// output"). The test module `output_wiring` starts it, with a wiring list
// or with none, and the record output that the list wires at its start
// chooses what it does: the ends of a wiring list are in its wiring ring
// before its first instruction.
//
// - `probes` wired at the start: it writes the probes 0 to 4, waits for a
//   second reader, which a Wire adds, writes the probes 5 to 7, ends the
//   record output, and stops.
// - `unended` wired: it writes one probe, and stops with no end record:
//   its reader reads the end word Writer_Stopped.
// - `watched` wired: it writes one probe, and waits until its reader
//   stops: the end word is Reader_Stopped.
// - `asked` wired: it writes one probe, and waits until its asker stops:
//   the end word is Asker_Stopped.
// - nothing wired: its asker wires `large` to itself, as many times as the
//   limit of an asker allows, then revokes its wirings: it waits until each
//   ring ended, and each end word is Revoked.
//
// **Start**: by `output_wiring` only. **What a reader sees**: no window;
// one line "output_writer: ...: as it must" for each case, or a line
// "output_writer: WRONG: ...". It stops itself with the outcome Done, or
// Failed after a WRONG line.
package output_writer

import "modus:contract/output"
import "modus:contract/value_kinds"
import "modus:system"

// One probe: its serial in the record output, and a mark of it.
Probe :: struct {
	serial: u64,
	mark:   u64,
}

// A record of another type: a wiring of it to a record input of probes is
// refused by the type check.
Other :: struct {
	serial: u64,
}

// The largest record: its rings take the most pages.
Large :: struct {
	serial: u64,
	note:   [248]u8,
}

// The probes of the case of the joined record: to a reader of the start,
// then to a reader that a Wire adds.
probes: system.Record_Output(Probe)

// One probe, then the stop with no end record.
unended: system.Record_Output(Probe)

// One probe, then a wait for the stop of the reader.
watched: system.Record_Output(Probe)

// One probe, then a wait for the stop of the asker.
asked: system.Record_Output(Probe)

// A record output of another type than the probes.
others: system.Record_Output(Other)

// The record output that the asker wires up to its limit.
large: system.Record_Output(Large)

// The mark of each probe: its serial, and a constant.
PROBE_MARK :: 0x5052_4F42_0000_0000

// The probes before the second reader, and the whole stream.
PROBES_BEFORE_THE_SECOND_READER :: 5
PROBES_OF_THE_STREAM :: 8

@(private = "file")
hang_deadline :: proc "contextless" () -> u64 {
	return system.time() + system.TEST_HANG_BOUND_MILLISECONDS
}

@(private = "file")
probe_of :: proc "contextless" (serial: u64) -> Probe {
	return {serial = serial, mark = PROBE_MARK | serial}
}

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}

// entry chooses its case by the record output that its start wired.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	switch {
	case system.output_read_by(&probes):
		probes_case()
	case system.output_read_by(&unended):
		// One probe, then the stop: the reader reads the end word.
		if status := system.output_write(&unended, probe_of(0)); status != .Ok {
			wrong("the probe of unended gave the status", u64(status))
		}
		system.log_fact(.Info, Unended_Written{})
	case system.output_read_by(&watched):
		ended_case(&watched, .Reader_Stopped, "watched")
	case system.output_read_by(&asked):
		ended_case(&asked, .Asker_Stopped, "asked")
	case:
		revoked_case()
	}
	system.stop(.Done)
}

// probes_case writes the probes before and after the second reader.
@(private = "file")
probes_case :: proc "contextless" () {
	for serial in 0 ..< u64(PROBES_BEFORE_THE_SECOND_READER) {
		if status := system.output_write(&probes, probe_of(serial)); status != .Ok {
			wrong("a probe before the second reader gave the status", u64(status))
		}
	}
	deadline := hang_deadline()
	for system.output_reader_count(&probes) < 2 {
		if system.time() >= deadline {
			wrong("no second reader came within the hang bound; readers:", u64(system.output_reader_count(&probes)))
		}
		system.wiring_wait(deadline)
	}
	for serial in u64(PROBES_BEFORE_THE_SECOND_READER) ..< PROBES_OF_THE_STREAM {
		if status := system.output_write(&probes, probe_of(serial), deadline = hang_deadline()); status != .Ok {
			wrong("a probe after the second reader gave the status", u64(status))
		}
	}
	if status := system.output_end(&probes, deadline = hang_deadline()); status != .Ok {
		wrong("the end of probes gave the status", u64(status))
	}
	if status := system.output_write(&probes, probe_of(PROBES_OF_THE_STREAM)); status != .Ended {
		wrong("a write after the end gave the status", u64(status))
	}
	system.log_fact(.Info, Probes_Written{probes = PROBES_OF_THE_STREAM, probes_before_second = PROBES_BEFORE_THE_SECOND_READER})
}

// ended_case writes one probe, then waits until the ring ends with the end
// word that the case names.
@(private = "file")
ended_case :: proc "contextless" (stream: ^system.Record_Output(Probe), wanted: output.End_Word, name: string) {
	if status := system.output_write(stream, probe_of(0)); status != .Ok {
		wrong("the probe gave the status", u64(status))
	}
	deadline := hang_deadline()
	for system.output_reader_count(stream) > 0 {
		if system.time() >= deadline {
			wrong("the ring did not end within the hang bound; the end word:", u64(stream.last_end))
		}
		system.wiring_wait(deadline, stream.index)
	}
	if stream.last_end != wanted {
		wrong("the ring ended with the end word", u64(stream.last_end))
	}
	system.log_fact(.Info, Ring_Ended{case_name = value_kinds.text_field(name, CASE_FIELD_BYTES), end_word = value_kinds.text_field(output.end_word_names[wanted], END_WORD_FIELD_BYTES)})
}

// The wirings of `large` that the asker makes: the limit of the wirings of
// an asker in the root service.
LARGE_WIRINGS :: 8

// revoked_case waits until each wiring of its asker on `large` came and
// ended. The count of the rings that ended does not depend on whether this
// process took an end before or after its revocation.
@(private = "file")
revoked_case :: proc "contextless" () {
	deadline := hang_deadline()
	for {
		count := system.output_reader_count(&large)
		if large.rings_ended >= LARGE_WIRINGS && count == 0 {
			break
		}
		if system.time() >= deadline {
			wrong("the wirings of large did not come and end within the hang bound; the rings that ended:", large.rings_ended)
		}
		system.wiring_wait(deadline, large.index)
	}
	if large.rings_ended != LARGE_WIRINGS || large.last_end != .Revoked {
		wrong("the rings of large ended with the end word", u64(large.last_end))
	}
	system.log_fact(.Info, Large_Rings_Revoked{rings = LARGE_WIRINGS})
}

// A side of a wiring that writes its own words in its wiring ring, past
// the library (src/md/features/module_outputs.md, "The wiring and its
// rights"). The test module `output_wiring` starts it with a wiring list
// whose row wires its record output to the asker, then wires it once more
// with Wire. It answers:
//
// 1. the end of its start with a refusal: the root service ends that
//    wiring with the end word Refused;
// 2. once it holds the end of the Wire, a word Closed for a number that
//    names no wiring of it: the root service drops it, with one line;
// 3. the end of the Wire with Taken, then Taken again, one probe and
//    Closed: the root service drops the second Taken, with one line.
//
// The words 2 and 3 are in one ring, in that order, and the root service
// reads them in order: the end word Side_Closed that the asker reads
// comes from the Closed of 3, so the root service read each word before.
//
// Then it reads no command: its wiring ring fills, and the root service
// refuses the next end for it with Busy. Its asker stops it.
//
// **Start**: by `output_wiring` only. **What a reader sees**: no window;
// one line "output_side: ...: as it must", or a line "output_side: WRONG:
// ...". Its asker stops it.
package output_side

import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:support/system"

// The record of its record output, as the asker reads it.
Probe :: struct {
	serial: u64,
	mark:   u64,
}

// The record output that the asker wires. This process writes no record
// in it: only the commands of its wiring ring matter.
echo: system.Record_Output(Probe)

// A number that names no wiring of this process.
NUMBER_OF_NO_WIRING :: 0x7FFF_0000

wiring: ring.Ring

@(private = "file")
hang_deadline :: proc "contextless" () -> u64 {
	return system.time() + system.TEST_HANG_BOUND_MILLISECONDS
}

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log(.Error, "output_side: WRONG: ", text, " ", value)
	system.stop(.Failed)
}

// command_wait takes the next command of the wiring ring: the end of a
// record output of this process.
@(private = "file")
command_wait :: proc "contextless" () -> ring.Record {
	deadline := hang_deadline()
	for {
		wait := system.wait_begin()
		if record, received := system.receive(&wiring.commands); received {
			if record.kind != u32(output.Wiring_Command.Writer_End) {
				wrong("a command of the wiring ring is not a writer end; its kind", u64(record.kind))
			}
			return record
		}
		if system.time() >= deadline {
			wrong("no end came within the hang bound, in milliseconds:", system.TEST_HANG_BOUND_MILLISECONDS)
		}
		system.wait_records(&wait, &wiring.commands)
		system.wait_end(&wait, deadline)
	}
}

// answer writes one word in the completion queue of the wiring ring.
@(private = "file")
answer :: proc "contextless" (record: ring.Record) {
	if !system.send(&wiring.completions, record) {
		wrong("the completion queue of the wiring ring is full; the tag", u64(record.tag))
	}
}

// probe_write writes, past the library, the joined record of 0 and the
// probe 0 into the output ring of a writer end, and wakes its reader.
@(private = "file")
probe_write :: proc "contextless" (command: ring.Record) {
	memory := system.Handle(command.values[output.WIRING_VALUE_RING])
	pages, size_status := system.memory_size(memory)
	address, map_status := system.memory_map(memory)
	if size_status != .Ok || map_status != .Ok {
		wrong("the output ring does not map; the status", u64(map_status))
	}
	size := output.compartment_size(size_of(Probe))
	opened, ok := ring.compartment_open(address, pages, size)
	if !ok {
		wrong("the output ring is no ring of compartments of the probe; its pages", pages)
	}
	buffer: [output.COMPARTMENT_SIZE_MOST]u8
	compartment := buffer[:size]
	probe := Probe{serial = 0, mark = 0x5052_4F42_0000_0000}
	if !output.joined_compartment(compartment, 0) || !ring.compartment_push(&opened.commands, compartment) {
		wrong("the joined record does not fit the output ring", 0)
	}
	if !output.record_compartment(compartment, 0, ([^]u8)(&probe)[:size_of(Probe)]) || !ring.compartment_push(&opened.commands, compartment) {
		wrong("the probe does not fit the output ring", 0)
	}
	system.word_wake(&opened.commands.counters.write, system.WAKE_ALL)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	opened, status := system.ring_open(ctx.handles[op.CONTEXT_WIRING_RING])
	if status != .Ok {
		wrong("no wiring ring; the status", u64(status))
	}
	wiring = opened
	first := command_wait()
	answer(output.wiring_completion(first.tag, .Bad_State, errors.error_make(.Refused, .Wirings)))
	second := command_wait()
	// The word for no wiring comes while this process holds the end of the
	// Wire: the root service keeps the wiring ring mapped then, and reads
	// the word. After the refusal of the only end, the root service
	// unmaps the ring at the end of its pass, and drops each word that
	// waits in it when a later end maps it again, with no line.
	answer(output.wiring_closed_completion(NUMBER_OF_NO_WIRING))
	answer(output.wiring_completion(second.tag, .Ok))
	// The second answer comes before Closed, so the wiring runs when the
	// root service reads it, whatever the order of its passes: it drops it.
	answer(output.wiring_completion(second.tag, .Ok))
	// One probe before Closed: the asker reads it, then the end word
	// Side_Closed, which says that the root service took the Closed of
	// this side and kept the wiring for the asker.
	probe_write(second)
	answer(output.wiring_closed_completion(second.tag))
	system.log(.Info, "output_side: refused the end of its start; for the end of a Wire, wrote Closed for a number of no wiring, then Taken, Taken again, one probe and Closed; it reads no more commands: as it must")
	deadline := hang_deadline()
	for system.time() < deadline {
		wait := system.wait_begin()
		system.wait_end(&wait, deadline)
	}
	wrong("the asker did not stop this process within the hang bound, in milliseconds:", system.TEST_HANG_BOUND_MILLISECONDS)
}

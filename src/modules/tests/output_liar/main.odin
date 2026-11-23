// A writer that lies about the condition of its wiring
// (src/md/features/module_outputs.md, "The condition of a wiring"). It
// takes the end of its record output past the library, answers Taken, and
// writes into the ring the joined record of 0 and one record of the status
// 200, whatever the condition of the wiring says. The console, which
// reads `output_liar.counts |> where(status = 404)`, must refuse that
// record as a fault of the writer, never drop it in silence.
//
// **Start**: `start("output_liar")` in the console. **What a reader
// sees**: no window; one line "output_liar: ...: as it must", or a line
// "output_liar: WRONG: ...". Its starter stops it.
package output_liar

import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:system"

// The record of output_counter: the console reads it with the same
// condition.
Counted :: struct {
	serial: u64,
	status: u64,
}

// The record output that the console wires. The library never writes it:
// this process writes its ring itself.
counts: system.Record_Output(Counted)

// The status of the record that it writes: not the 404 of the condition.
STATUS_FOUND :: 200

wiring: ring.Ring

@(private = "file")
hang_deadline :: proc "contextless" () -> u64 {
	return system.time() + system.TEST_HANG_BOUND_MILLISECONDS
}

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}

// command_wait takes the next command of the wiring ring: the end of the
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

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	opened, status := system.ring_open(ctx.handles[op.CONTEXT_WIRING_RING], receive_handles = true)
	if status != .Ok {
		wrong("no wiring ring; the status", u64(status))
	}
	wiring = opened
	system.log_fact(.Info, Waits_For_Reader{})
	command := command_wait()
	if command.values[output.WIRING_VALUE_TERMS] == 0 {
		wrong("the end came with no condition; the tag", u64(command.tag))
	}
	if !system.send(&wiring.completions, output.wiring_completion(command.tag, .Ok)) {
		wrong("the completion queue of the wiring ring is full; the tag", u64(command.tag))
	}
	memory := system.Handle(command.values[output.WIRING_VALUE_RING])
	pages, size_status := system.memory_size(memory)
	address, map_status := system.memory_map(memory)
	if size_status != .Ok || map_status != .Ok {
		wrong("the output ring does not map; the status", u64(map_status))
	}
	size := output.compartment_size(size_of(Counted))
	output_ring, ok := ring.compartment_open(address, pages, size)
	if !ok {
		wrong("the output ring is no ring of compartments of the record; its pages", pages)
	}
	buffer: [output.COMPARTMENT_SIZE_MOST]u8
	compartment := buffer[:size]
	record := Counted{serial = 0, status = STATUS_FOUND}
	if !output.joined_compartment(compartment, 0) || !ring.compartment_push(&output_ring.commands, compartment) {
		wrong("the joined record does not fit the output ring", 0)
	}
	if !output.record_compartment(compartment, 0, ([^]u8)(&record)[:size_of(Counted)]) || !ring.compartment_push(&output_ring.commands, compartment) {
		wrong("the record does not fit the output ring", 0)
	}
	system.word_wake(&output_ring.commands.counters.write, system.WAKE_ALL)
	system.log_fact(.Info, Record_Written_Past_Condition{})
	// Its starter stops it; it reads no more commands.
	deadline := hang_deadline()
	for system.time() < deadline {
		wait := system.wait_begin()
		system.wait_end(&wait, deadline)
	}
	wrong("the starter did not stop this process within the hang bound, in milliseconds:", system.TEST_HANG_BOUND_MILLISECONDS)
}

// Measure pending: the 2048 pages of the least budget in which it ran
// before its floor was counted. The first machine pass with the check of
// the floors (the check boot-test of the flake) writes the peak of its
// budget at its first state of work; modustool floors measured on the log
// of that pass gives the working memory that replaces this number
// (src/md/features/module_budget_request.md, "The first state of work").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2048}

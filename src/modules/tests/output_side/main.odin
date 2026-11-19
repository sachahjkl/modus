// A side of a wiring that writes its own words in its wiring ring, past
// the library (src/md/features/module_outputs.md, "The wiring and its
// rights"). The test module `output_wiring` starts it with a wiring list
// whose row wires its record output to the asker, then wires it once more
// with Wire. It answers:
//
// 1. the end of its start with a refusal: the root service ends that
//    wiring with the end word Refused;
// 2. a word Closed for a number that names no wiring of it: the root
//    service drops it;
// 3. the end of the Wire with Taken, then Closed, then Closed again: the
//    root service drops the third word.
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
			wrong("no end came within the hang bound", 0)
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

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	opened, status := system.ring_open(ctx.handles[op.CONTEXT_WIRING_RING])
	if status != .Ok {
		wrong("no wiring ring; the status", u64(status))
	}
	wiring = opened
	first := command_wait()
	answer(output.wiring_completion(first.tag, .Bad_State, errors.error_make(.Refused, .Wirings)))
	answer(output.wiring_closed_completion(NUMBER_OF_NO_WIRING))
	second := command_wait()
	answer(output.wiring_completion(second.tag, .Ok))
	answer(output.wiring_closed_completion(second.tag))
	answer(output.wiring_closed_completion(second.tag))
	system.log(.Info, "output_side: refused the end of its start, wrote Closed for a number of no wiring, then Taken, Closed and Closed again for the end of a Wire; it reads no more commands: as it must")
	deadline := hang_deadline()
	for system.time() < deadline {
		wait := system.wait_begin()
		system.wait_end(&wait, deadline)
	}
	wrong("the asker did not stop this process within the hang bound", 0)
}

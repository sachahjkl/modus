// A test process that writes to its terminal three records whose kind
// names no record, then one line, and stops.
//
// The three words are None, the word one past the last kind, and the
// largest word of the field. The terminal decides each one at its border,
// which a host test gives the same words (terminal.kind_of_ring_word). This
// process shows that the terminal answers what its border decided: it
// counts each refused record, writes one line at the first one, and the
// count when the process stops. It sends no answer on the ring, so this
// process checks what it can see: the terminal read the three records and
// the line after them.
//
// **What it is for.** A record of the terminal ring comes from another
// process. A word that names no record must not stop the terminal, nor
// become a record that the process did not write.
//
// **Start**: `start("hostile_terminal")` in the console. The machine test
// starts it after `flood`.
//
// **Its grant**: **Terminal**: the terminal ring and the text region that
// it shares with its terminal. Nothing else.
//
// **What a reader sees**: a terminal with one line. The log has
// `hostile_terminal: the terminal read the kind words 0, 9 and 4294967295,
// and the line after them: as it must`, then the two lines of the
// terminal: `terminal: hostile_terminal sent a record of the kind 0, which
// names no record: it is refused` and, at the stop, `terminal:
// hostile_terminal stopped after 3 records whose kind names no record`.
package hostile_terminal

import "base:intrinsics"
import "modus:contract/ring"
import "modus:support/system"
import terminal "modus:support/terminal"

// The words of the kind of a record that name no record.
@(rodata)
refused_kind_words := [3]u32{u32(terminal.Kind.None), u32(max(terminal.Kind)) + 1, max(u32)}

// entry writes the three records and the line, waits until the terminal
// read them, writes the result on the log, and stops with the code 0. With
// no terminal it writes `hostile_terminal: no terminal` and stops with the
// code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	output, ok := terminal.open(ctx)
	if !ok {
		system.log("hostile_terminal: no terminal")
		system.stop(1)
	}
	// A tag of 0: a record whose kind names no record takes no byte of the
	// text region, so the line after it starts at the first byte.
	for word in refused_kind_words {
		for !system.send(&output.ring.commands, ring.Record{kind = word}) {
			list: system.Wait
			system.wait_room(&list, &output.ring.commands)
			system.wait_end(&list)
		}
	}
	terminal.line(&output, {"three records whose kind names no record came before this line", {}})
	counters := output.ring.commands.counters
	written := intrinsics.atomic_load_explicit(&counters.write, .Relaxed)
	// The terminal wakes a writer only when its ring has room again after
	// it was half full, so this wait reads the count of the records read,
	// once each millisecond. The bound only ends a hang.
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for i32(intrinsics.atomic_load_explicit(&counters.read, .Relaxed) - written) < 0 && system.time() < deadline {
		system.sleep(system.time() + 1)
	}
	if i32(intrinsics.atomic_load_explicit(&counters.read, .Relaxed) - written) >= 0 {
		system.log("hostile_terminal: the terminal read the kind words ", u64(refused_kind_words[0]), ", ", u64(refused_kind_words[1]), " and ", u64(refused_kind_words[2]), ", and the line after them: as it must")
	} else {
		system.log("hostile_terminal: WRONG: the terminal did not read its records in ", u64(system.TEST_HANG_BOUND_MILLISECONDS), " ms")
	}
	system.stop(0)
}

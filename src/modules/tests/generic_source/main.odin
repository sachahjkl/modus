// The writer of the machine test of the generic record inputs
// (src/md/features/module_outputs.md, "Generic record inputs and the
// utility modules"). The test module `generic_wiring` starts it with no
// list, then wires its record outputs:
//
// - `left` and `right`, of the record Probe, the two sources of `merge`;
// - `other`, of the record Other, the source of another record, which a
//   second source of `merge` cannot be.
//
// It waits, by a state, until `left` and `right` each have a reader, then
// writes PROBES_OF_A_SIDE probes into each, one in turn, ends both, and
// stops itself with Done. The mark of a probe is its number modulo 2, so
// `filter` with the condition mark = 1 keeps half of them.
//
// **Start**: by `generic_wiring` only. **What a reader sees**: no window;
// one line when it wrote, or "generic_source: WRONG: ...".
package generic_source

import "modus:system"

// One probe: its side (1: left, 2: right), its number on its side, and its
// mark.
Probe :: struct {
	side:   u64,
	number: u64,
	mark:   u64,
}

// A record of another description than Probe.
Other :: struct {
	number: u64,
}

// The probes of each side. generic_wiring shares the count.
PROBES_OF_A_SIDE :: 20

left: system.Record_Output(Probe)
right: system.Record_Output(Probe)
other: system.Record_Output(Other)

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log(.Error, "generic_source: WRONG: ", text, " ", value)
	system.stop(.Failed)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// Each end comes in the wiring ring: the state is read again after
	// each wait, and a wait ends at each new end.
	for system.output_reader_count(&left) == 0 || system.output_reader_count(&right) == 0 {
		system.wiring_wait(system.WAIT_FOREVER)
	}
	for number in u64(0) ..< PROBES_OF_A_SIDE {
		for side in u64(1) ..= 2 {
			stream := side == 1 ? &left : &right
			if status := system.output_write(stream, Probe{side = side, number = number, mark = number % 2}); status != .Ok {
				wrong("a write of a probe gave the status word", u64(status))
			}
		}
	}
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	if system.output_end(&left, deadline = deadline) != .Ok || system.output_end(&right, deadline = deadline) != .Ok {
		wrong("the end of left and right did not reach their readers within the hang bound, in milliseconds:", system.TEST_HANG_BOUND_MILLISECONDS)
	}
	// other is wired in no list that the root service takes: the read
	// keeps its variable in the link, so its row has a place.
	if system.output_reader_count(&other) != 0 {
		wrong("other has a reader, which no list of the test gives it:", u64(system.output_reader_count(&other)))
	}
	system.log(.Info, "generic_source: wrote ", u64(PROBES_OF_A_SIDE), " probes into left and into right, and ended both")
	system.stop(.Done)
}

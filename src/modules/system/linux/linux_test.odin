#+build !freestanding
package linux_shell

import "core:testing"
import "modus:contract/guest_os"
import "modus:display"
import terminal "modus:terminal"

// The keys that send nothing first: a function key, Control with a key that
// is no letter, a character past the last code point, a surrogate, and a
// control character with no key of its own.
@(test)
key_bytes_refuses_what_has_no_byte :: proc(t: ^testing.T) {
	refused := [?]terminal.Key{
		{code = 0x3B}, // F1, no character.
		{code = 0x02, character = '1', modifiers = display.MODIFIER_CONTROL},
		{code = 0x39, character = ' ', modifiers = display.MODIFIER_CONTROL},
		{character = 0x110000},
		{character = 0xD800},
		{character = 0xDFFF},
		{character = 0x7F},
		{character = 0x1F},
		{character = -1},
	}
	for pressed in refused {
		_, count := key_bytes(pressed)
		testing.expectf(t, count == 0, "the key %v sends nothing", pressed)
	}
}

// The keys of a shell, and each length of UTF-8 at its edges.
@(test)
key_bytes_of_a_shell :: proc(t: ^testing.T) {
	expect :: proc(t: ^testing.T, pressed: terminal.Key, wanted: string) {
		bytes, count := key_bytes(pressed)
		testing.expectf(t, string(bytes[:count]) == wanted, "the key %v sends %q, not %q", pressed, string(bytes[:count]), wanted)
	}
	// The code wins over the character that a key carries.
	expect(t, {code = display.KEY_ENTER, character = '\n'}, "\r")
	expect(t, {code = display.KEY_BACKSPACE, character = '\b'}, "\x7f")
	expect(t, {code = display.KEY_TAB, character = '\t'}, "\t")
	expect(t, {code = display.KEY_ESCAPE}, "\x1b")
	expect(t, {code = display.KEY_UP}, "\x1b[A")
	expect(t, {code = display.KEY_DOWN}, "\x1b[B")
	expect(t, {code = display.KEY_RIGHT}, "\x1b[C")
	expect(t, {code = display.KEY_LEFT}, "\x1b[D")
	expect(t, {character = 'c', modifiers = display.MODIFIER_CONTROL}, "\x03")
	expect(t, {character = 'C', modifiers = display.MODIFIER_CONTROL}, "\x03")
	expect(t, {character = 'a', modifiers = display.MODIFIER_CONTROL}, "\x01")
	expect(t, {character = 'z', modifiers = display.MODIFIER_CONTROL}, "\x1a")
	// The successful cases last: each length of UTF-8 at its edges.
	expect(t, {character = ' '}, " ")
	expect(t, {character = '~'}, "~")
	expect(t, {character = 0x80}, "\u0080")
	expect(t, {character = 0x7FF}, "\u07ff")
	expect(t, {character = 0x800}, "\u0800")
	expect(t, {character = 0xFFFF}, "\uffff")
	expect(t, {character = 0x10000}, "\U00010000")
	expect(t, {character = 0x10FFFF}, "\U0010ffff")
}

// The conversions of the time between the timer of the guest and the
// machine: a wait never ends before its tick, and no product overflows.
@(test)
time_conversions_at_their_edges :: proc(t: ^testing.T) {
	testing.expect_value(t, ticks_as_milliseconds(0), u64(0))
	testing.expect_value(t, ticks_as_milliseconds(1), u64(1))
	testing.expect_value(t, ticks_as_milliseconds(guest_os.TIMER_TICKS_PER_SECOND), u64(1000))
	testing.expect_value(t, ticks_as_milliseconds(guest_os.TIMER_TICKS_PER_SECOND + 1), u64(1001))
	testing.expect(t, ticks_as_milliseconds(max(u64)) > 0)
	testing.expect_value(t, nanoseconds_as_ticks(0), u64(0))
	testing.expect_value(t, nanoseconds_as_ticks(1_000_000_000), guest_os.TIMER_TICKS_PER_SECOND)
	testing.expect(t, nanoseconds_as_ticks(max(u64)) > 0)
	testing.expect(t, nanoseconds_as_ticks(max(u64)) <= (u64(1) << 40) * guest_os.TIMER_TICKS_PER_SECOND / 1_000_000_000)
}

// The memory of the guest fits the budget, with room for its tables.
@(test)
budget_holds_the_guest :: proc(t: ^testing.T) {
	testing.expect(t, MODULE_BUDGET.working_memory_pages >= GUEST_MEMORY_PAGES + 1024)
	// This process and its guest process.
	testing.expect(t, MODULE_BUDGET.processes >= 2)
}
// The keys of moving in a line: Home, End and Delete send the sequences
// that the line editor of a shell reads.
@(test)
key_bytes_of_moving_in_a_line :: proc(t: ^testing.T) {
	cases := [?]struct {
		code:   u32,
		wanted: string,
	}{{display.KEY_HOME, "\x1b[H"}, {display.KEY_END, "\x1b[F"}, {display.KEY_DELETE, "\x1b[3~"}}
	for each in cases {
		bytes, count := key_bytes({code = each.code})
		testing.expect_value(t, string(bytes[:count]), each.wanted)
		testing.expect(t, count <= KEY_BYTES_MOST)
	}
}

// A paste larger than the receive queue of the serial port loses no byte:
// a key that does not fit the queue is refused whole, the port takes what
// it has room for, and the rest goes as the guest reads, in order.
@(test)
pending_input_paces_a_paste :: proc(t: ^testing.T) {
	machine := new(guest_os.Linux_Machine)
	defer free(machine)
	guest_os.linux_machine_start(machine, {}, nil, nil)
	waiting := new(Pending_Input)
	defer free(waiting)

	// Nothing waits: nothing moves.
	testing.expect_value(t, pending_feed(waiting, machine), 0)
	// The edges of the queue: a full queue refuses one more byte, and a key
	// of four bytes with three free refuses all four.
	filler: [PENDING_INPUT_BYTES]u8
	for &value, index in filler {
		value = u8('a' + index % 26)
	}
	too_long := make([]u8, PENDING_INPUT_BYTES + 1)
	defer delete(too_long)
	testing.expect(t, !pending_push(waiting, too_long))
	testing.expect_value(t, waiting.count, 0)
	testing.expect(t, pending_push(waiting, filler[:PENDING_INPUT_BYTES - 3]))
	testing.expect(t, !pending_push(waiting, []u8{0x1B, '[', '3', '~'}))
	testing.expect_value(t, pending_room(waiting), 3)
	testing.expect(t, pending_push(waiting, filler[PENDING_INPUT_BYTES - 3:]))
	testing.expect_value(t, pending_room(waiting), 0)
	testing.expect(t, !pending_push(waiting, []u8{'x'}))

	// The port takes what its queue holds, and no byte past it.
	moved := pending_feed(waiting, machine)
	testing.expect_value(t, moved, guest_os.SERIAL_RECEIVE_BYTES)
	testing.expect_value(t, guest_os.linux_machine_serial_receive_room(machine), 0)
	testing.expect_value(t, waiting.count, PENDING_INPUT_BYTES - guest_os.SERIAL_RECEIVE_BYTES)
	testing.expect_value(t, pending_feed(waiting, machine), 0)

	// The guest reads its queue; the rest goes in order, around the end of
	// the ring.
	received: [dynamic]u8
	defer delete(received)
	for waiting.count > 0 || machine.serial.receive_count > 0 {
		for machine.serial.receive_count > 0 {
			append(&received, guest_os.serial_read(&machine.serial, 0))
		}
		if waiting.count > 0 {
			testing.expect(t, pending_feed(waiting, machine) > 0)
		}
	}
	testing.expect_value(t, len(received), PENDING_INPUT_BYTES)
	testing.expect(t, string(received[:]) == string(filler[:]), "the bytes reach the guest in order")
}

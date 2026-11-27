#+build !freestanding
package linux_shell

import "core:testing"
import gb "modus:contract/guest_builder"
import "modus:contract/guest_os"
import "modus:display"
import "modus:system"
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

// The memory of the guest comes from the pages that the budget has left:
// below the least the guest does not start, one page less than the least
// guest budget gives nothing, the least budget gives the least guest, a larger
// budget a larger guest in whole MiB, and the contract bounds the most.
@(test)
guest_memory_follows_the_budget :: proc(t: ^testing.T) {
	least := LEAST_GUEST_BUDGET_PAGES
	for free in ([?]u64{0, 1, PROCESS_RESERVE_PAGES + 64, least - 1}) {
		testing.expectf(t, guest_memory_pages_of(free) == 0, "%d pages left give no guest", free)
	}
	testing.expect_value(t, guest_memory_pages_of(least), GUEST_MEMORY_PAGES_LEAST)
	larger := guest_memory_pages_of(4 * least)
	testing.expect(t, larger > GUEST_MEMORY_PAGES_LEAST && larger % 256 == 0, "a larger budget gives a larger guest in whole MiB")
	testing.expect(t, larger + larger / 512 + 64 + PROCESS_RESERVE_PAGES <= 4 * least, "the guest and its table fit the budget")
	testing.expect_value(t, guest_memory_pages_of(max(u64)), gb.MAX_GUEST_MEMORY_PAGES)
	// This process and its guest process; guest memory comes from the plan row, not the floor.
	testing.expect_value(t, MODULE_BUDGET, system.Stated_Budget{processes = 2, threads = 1})
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

// A scripted guest that takes at most scripted_room bytes, as a driver
// that posted buffers of that many bytes, and keeps them in order.
@(private = "file")
scripted_room: int
@(private = "file")
scripted_received: [2 * PENDING_INPUT_BYTES]u8
@(private = "file")
scripted_count: int

@(private = "file")
scripted_take :: proc "contextless" (machine: ^guest_os.Linux_Machine, bytes: []u8) -> (taken: int) {
	taken = min(len(bytes), scripted_room, len(scripted_received) - scripted_count)
	copy(scripted_received[scripted_count:], bytes[:taken])
	scripted_count += taken
	scripted_room -= taken
	return taken
}

// A paste larger than what the guest takes at once loses no byte: a key
// that does not fit the queue is refused whole, the guest takes what its
// buffers hold, a push after a partial feed writes around the end of the
// queue, and the rest goes as the guest posts buffers, in order. A guest
// whose driver is not ready takes nothing.
@(test)
pending_input_paces_a_paste :: proc(t: ^testing.T) {
	machine := new(guest_os.Linux_Machine)
	defer free(machine)
	guest_os.linux_machine_start(machine, {}, nil, nil)
	waiting := new(Pending_Input)
	defer free(waiting)
	scripted_room, scripted_count = 0, 0

	// Nothing waits: nothing moves.
	testing.expect_value(t, pending_feed(waiting, machine, scripted_take), 0)
	// The edges of the queue: a full queue refuses one more byte, and a key
	// of four bytes with three free refuses all four.
	filler: [PENDING_INPUT_BYTES + 300]u8
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
	testing.expect(t, pending_push(waiting, filler[PENDING_INPUT_BYTES - 3:PENDING_INPUT_BYTES]))
	testing.expect_value(t, pending_room(waiting), 0)
	testing.expect(t, !pending_push(waiting, []u8{'x'}))

	// The virtio console of a guest whose driver is not ready takes nothing.
	testing.expect_value(t, pending_feed(waiting, machine), 0)
	testing.expect_value(t, waiting.count, PENDING_INPUT_BYTES)

	// The guest takes 300 bytes; 300 more are pushed, and they wrap around
	// the end of the queue.
	scripted_room = 300
	testing.expect_value(t, pending_feed(waiting, machine, scripted_take), 300)
	testing.expect_value(t, pending_feed(waiting, machine, scripted_take), 0)
	testing.expect(t, pending_push(waiting, filler[PENDING_INPUT_BYTES:]))
	testing.expect_value(t, waiting.count, PENDING_INPUT_BYTES)
	testing.expect(t, (waiting.first + waiting.count) % PENDING_INPUT_BYTES == 300, "the write index wrapped")

	// The guest posts buffers of 1000 bytes at a time; the rest goes in
	// order, in two runs where the queue wraps.
	for waiting.count > 0 {
		scripted_room = 1000
		testing.expect(t, pending_feed(waiting, machine, scripted_take) > 0)
	}
	testing.expect_value(t, scripted_count, len(filler))
	testing.expect(t, string(scripted_received[:scripted_count]) == string(filler[:]), "the bytes reach the guest in order")
}

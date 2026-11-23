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

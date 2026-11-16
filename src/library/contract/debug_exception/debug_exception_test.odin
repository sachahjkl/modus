#+build !freestanding
package debug_exception

import op "modus:contract/operation"
import "core:testing"

INT1 :: Program_Byte{value = INT1_OPCODE, readable = true}
NO_BYTE :: Program_Byte{} // A byte that the program cannot read.

byte_of :: proc(value: u8) -> Program_Byte {
	return {value = value, readable = true}
}

// A status bit names a breakpoint or a single step: never dropped, also at
// an int1 whose byte before is not F1 or cannot be read.
@(test)
a_status_bit_keeps_the_exception :: proc(t: ^testing.T) {
	statuses := [?]u64{op.DEBUG_STATUS_STEP, 1, 2, 4, 8, op.DEBUG_STATUS_BREAKPOINTS, op.DEBUG_STATUS_STEP | 1, max(u64)}
	for status in statuses {
		testing.expectf(t, !int1_given_again(status, INT1, byte_of(0x90)), "the status %x was dropped", status)
		testing.expectf(t, !int1_given_again(status, INT1, NO_BYTE), "the status %x was dropped with no byte before", status)
	}
}

// An address that holds no int1 is kept, also when the program cannot read
// it, and when the byte before cannot be read either.
@(test)
no_int1_at_the_address_keeps_the_exception :: proc(t: ^testing.T) {
	for value in ([?]u8{0x00, 0xCC, 0xF0, 0xF2, 0xFF, 0x66}) {
		testing.expectf(t, !int1_given_again(0, byte_of(value), byte_of(0x90)), "the byte %x was taken for an int1", value)
		testing.expectf(t, !int1_given_again(0, byte_of(value), NO_BYTE), "the byte %x was taken for an int1 with no byte before", value)
	}
	// A byte at the address that the program cannot read, whatever its value.
	unreadable_int1 := Program_Byte{value = INT1_OPCODE, readable = false}
	testing.expect(t, !int1_given_again(0, unreadable_int1, byte_of(0x90)))
	testing.expect(t, !int1_given_again(0, NO_BYTE, NO_BYTE))
}

// A byte F1 before the address keeps the exception: the true trap of an
// int1 there (two int1 in a row), or an instruction whose last byte is F1
// (89 F1, mov ecx, esi), in the page or at the end of the page before.
@(test)
a_byte_f1_before_keeps_the_exception :: proc(t: ^testing.T) {
	testing.expect(t, !int1_given_again(0, INT1, INT1))
}

// An unreadable byte F1 before is no int1 that ended there: its value is
// not read.
@(test)
an_unreadable_byte_before_is_not_f1 :: proc(t: ^testing.T) {
	unreadable_int1 := Program_Byte{value = INT1_OPCODE, readable = false}
	testing.expect(t, int1_given_again(0, INT1, unreadable_int1))
}

// The success cases last: an int1 with no status, and a byte before that
// is not F1, or that the program cannot read (the first byte of a page
// whose page before is not mapped, or the address 0).
@(test)
an_int1_given_again_is_dropped :: proc(t: ^testing.T) {
	for before in ([?]u8{0x00, 0x66, 0x90, 0xC3, 0xF0, 0xF2, 0xFF}) {
		testing.expectf(t, int1_given_again(0, INT1, byte_of(before)), "the byte before %x kept the exception", before)
	}
	testing.expect(t, int1_given_again(0, INT1, NO_BYTE))
}

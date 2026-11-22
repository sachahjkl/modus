#+build !freestanding
package guest_rules

import "core:testing"
import op "modus:contract/operation"

// The word of EVENTINJ, bit by bit, for each kind (the AMD manual, volume
// 2, "Event Injection").
@(test)
event_injection_word_bits :: proc(t: ^testing.T) {
	testing.expect_value(t, event_injection_word(.None, 0, false, 0), u64(0))
	// The kind None gives no event, whatever the other fields hold.
	testing.expect_value(t, event_injection_word(.None, max(u8), true, max(u32)), u64(0))
	testing.expect_value(t, event_injection_word(.External_Interrupt, 0x20, false, 0), u64(0x8000_0020))
	testing.expect_value(t, event_injection_word(.External_Interrupt, max(u8), false, 0), u64(0x8000_00FF))
	testing.expect_value(t, event_injection_word(.External_Interrupt, 0, false, 0), u64(0x8000_0000))
	testing.expect_value(t, event_injection_word(.Non_Maskable_Interrupt, 2, false, 0), u64(0x8000_0202))
	testing.expect_value(t, event_injection_word(.Exception, 6, false, 0), u64(0x8000_0306))
	// #GP with the error code 0x10: EV (bit 11), the code in the high half.
	testing.expect_value(t, event_injection_word(.Exception, 13, true, 0x10), u64(0x0000_0010_8000_0B0D))
	testing.expect_value(t, event_injection_word(.Exception, 14, true, max(u32)), u64(0xFFFF_FFFF_8000_0B0E))
	testing.expect_value(t, event_injection_word(.Exception, 8, true, 0), u64(0x8000_0B08))
	testing.expect_value(t, event_injection_word(.Software_Interrupt, 0x80, false, 0), u64(0x8000_0480))
	// Each word that the kernel writes is valid, and the processor gives it
	// back unchanged as an event to deliver again, but for an instruction.
	for kind in op.Guest_Inject_Kind {
		word := event_injection_word(kind, 13, false, 0)
		testing.expectf(t, (word & EVENT_VALID != 0) == (kind != .None), "kind %v valid bit", kind)
		testing.expectf(t, word & ~u64(0xFFFF_FFFF_8000_0FFF) == 0, "kind %v sets no reserved bit", kind)
	}
}

// An event that an exit interrupted goes to the next entry, but the events
// of an instruction, which runs again.
@(test)
event_to_deliver_again_keeps_the_events_of_the_machine :: proc(t: ^testing.T) {
	testing.expect_value(t, event_to_deliver_again(0), u64(0))
	// Not valid: nothing, whatever the other bits say.
	testing.expect_value(t, event_to_deliver_again(max(u64) &~ EVENT_VALID), u64(0))
	// int n, int3 and into run again.
	testing.expect_value(t, event_to_deliver_again(event_injection_word(.Software_Interrupt, 0x80, false, 0)), u64(0))
	testing.expect_value(t, event_to_deliver_again(event_injection_word(.Exception, GUEST_VECTOR_BREAKPOINT, false, 0)), u64(0))
	testing.expect_value(t, event_to_deliver_again(event_injection_word(.Exception, GUEST_VECTOR_OVERFLOW, false, 0)), u64(0))
	// The types 1, 5, 6 and 7 name no event that the kernel delivers.
	for type in ([?]u64{1, 5, 6, 7}) {
		testing.expectf(t, event_to_deliver_again(EVENT_VALID | type << EVENT_TYPE_SHIFT) == 0, "type %v", type)
	}
	// The successful cases last.
	for word in ([?]u64{event_injection_word(.External_Interrupt, 0x30, false, 0), event_injection_word(.Non_Maskable_Interrupt, 2, false, 0), event_injection_word(.Exception, 14, true, 2), event_injection_word(.Exception, 0, false, 0)}) {
		testing.expectf(t, event_to_deliver_again(word) == word, "word %x", word)
	}
}

// The segments of each mode load.
@(test)
mode_segments_of_each_mode :: proc(t: ^testing.T) {
	_, loaded := mode_segments(.Keep, max(u16), max(u16))
	testing.expect(t, !loaded)
	real, real_loaded := mode_segments(.Real_16, 0xF000, max(u16))
	testing.expect(t, real_loaded)
	testing.expect_value(t, real.code, Segment{0xF000, 0x9B, 0xFFFF, 0xF_0000})
	testing.expect_value(t, real.data, Segment{max(u16), 0x93, 0xFFFF, 0xF_FFF0})
	zero, _ := mode_segments(.Real_16, 0, 0)
	testing.expect_value(t, zero.code, Segment{0, 0x9B, 0xFFFF, 0})
	protected, _ := mode_segments(.Protected_32, 0x08, 0x10)
	testing.expect_value(t, protected.code, Segment{0x08, 0xC9B, 0xFFFF_FFFF, 0})
	testing.expect_value(t, protected.data, Segment{0x10, 0xC93, 0xFFFF_FFFF, 0})
	long, _ := mode_segments(.Long_64, 0x08, 0x10)
	testing.expect_value(t, long.code, Segment{0x08, 0xA9B, 0xFFFF_FFFF, 0})
	testing.expect_value(t, long.data, Segment{0x10, 0xC93, 0xFFFF_FFFF, 0})
	// The processor refuses a code segment with L and D/B together.
	testing.expect(t, long.code.attributes & SEGMENT_LONG != 0 && long.code.attributes & SEGMENT_THIRTY_TWO == 0)
}

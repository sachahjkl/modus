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

// An injected software interrupt that a nested page fault interrupted is
// delivered again; the same event from an int n of the guest is not, since
// the guest is still at that instruction.
@(test)
injected_software_interrupt_is_delivered_again :: proc(t: ^testing.T) {
	injected := event_injection_word(.Software_Interrupt, 0x80, false, 0)
	pending := Pending_Injection{event = injected, address = 0x1002}
	// The int n of the guest: no injection pending.
	next, still := event_after_exit(injected, 0x1000, {})
	testing.expect_value(t, next, u64(0))
	testing.expect_value(t, still, Pending_Injection{})
	// The injection, interrupted at its address: delivered again, still pending.
	next, still = event_after_exit(injected, 0x1002, pending)
	testing.expect_value(t, next, injected)
	testing.expect_value(t, still, pending)
	// The guest moved: the injection was delivered, and this event is an int n of the guest.
	next, still = event_after_exit(injected, 0x1000, pending)
	testing.expect_value(t, next, u64(0))
	testing.expect_value(t, still, Pending_Injection{})
	// Another vector or another type is not the injection.
	next, still = event_after_exit(event_injection_word(.Software_Interrupt, 0x81, false, 0), 0x1002, pending)
	testing.expect_value(t, next, u64(0))
	testing.expect_value(t, still, Pending_Injection{})
	next, still = event_after_exit(event_injection_word(.Exception, 0x0D, true, 0), 0x1002, pending)
	testing.expect_value(t, next, event_injection_word(.Exception, 0x0D, true, 0))
	testing.expect_value(t, still, Pending_Injection{})
	// No event at the exit: the injection was delivered.
	next, still = event_after_exit(0, 0x1002, pending)
	testing.expect_value(t, next, u64(0))
	testing.expect_value(t, still, Pending_Injection{})
	// An injected int3 and into are delivered again too; the same events of the guest are not.
	for vector in ([?]u8{GUEST_VECTOR_BREAKPOINT, GUEST_VECTOR_OVERFLOW}) {
		word := event_injection_word(.Exception, vector, false, 0)
		next, still = event_after_exit(word, 0x2000, {event = word, address = 0x2000})
		testing.expectf(t, next == word && still.event == word, "injected exception %v", vector)
		next, _ = event_after_exit(word, 0x2000, {})
		testing.expectf(t, next == 0, "exception %v of the guest", vector)
	}
	// An injected external interrupt stays pending while it is interrupted.
	external := event_injection_word(.External_Interrupt, 0x30, false, 0)
	next, still = event_after_exit(external, 0x3000, {event = external, address = 0x3000})
	testing.expect_value(t, next, external)
	testing.expect_value(t, still.event, external)
	// events_match: invalid words never match, and the error code does not count.
	testing.expect(t, !events_match(0, 0))
	testing.expect(t, !events_match(injected &~ EVENT_VALID, injected &~ EVENT_VALID))
	testing.expect(t, events_match(event_injection_word(.Exception, 14, true, 2), event_injection_word(.Exception, 14, true, 7)))
}

// The address for CONTROL_NEXT_INSTRUCTION: only for a pending injected
// event of an instruction.
@(test)
next_instruction_only_for_injected_instruction_events :: proc(t: ^testing.T) {
	for word in ([?]u64{event_injection_word(.Software_Interrupt, 0x80, false, 0), event_injection_word(.Software_Interrupt, 0, false, 0), event_injection_word(.Exception, GUEST_VECTOR_BREAKPOINT, false, 0), event_injection_word(.Exception, GUEST_VECTOR_OVERFLOW, false, 0)}) {
		testing.expectf(t, event_needs_next_instruction(word), "word %x needs it", word)
		address, needed := next_instruction_of_injection(word, {event = word, address = 0x7C02})
		testing.expectf(t, needed && address == 0x7C02, "word %x", word)
		// Not the pending injection: none.
		_, needed = next_instruction_of_injection(word, {})
		testing.expectf(t, !needed, "word %x with no injection", word)
	}
	for word in ([?]u64{0, max(u64) &~ EVENT_VALID, event_injection_word(.External_Interrupt, 0x80, false, 0), event_injection_word(.Non_Maskable_Interrupt, 2, false, 0), event_injection_word(.Exception, 6, false, 0), event_injection_word(.Exception, 14, true, 0)}) {
		testing.expectf(t, !event_needs_next_instruction(word), "word %x needs none", word)
		_, needed := next_instruction_of_injection(word, {event = word, address = 1})
		testing.expectf(t, !needed, "word %x", word)
	}
}

// The offsets of the 64-bit system state in the control block, from the
// AMD manual, volume 2, table B-2: each field lands on its own eight bytes,
// and no other byte of the block changes.
@(test)
system_registers_offsets :: proc(t: ^testing.T) {
	testing.expect_value(t, STATE_FS_BASE, 0x448)
	testing.expect_value(t, STATE_GS_BASE, 0x458)
	testing.expect_value(t, STATE_SYSTEM_CALL_TARGET, 0x600)
	testing.expect_value(t, STATE_LONG_SYSTEM_CALL_TARGET, 0x608)
	testing.expect_value(t, STATE_COMPATIBILITY_SYSTEM_CALL_TARGET, 0x610)
	testing.expect_value(t, STATE_SYSTEM_CALL_FLAGS_MASK, 0x618)
	testing.expect_value(t, STATE_KERNEL_GS_BASE, 0x620)
	block: [CONTROL_BLOCK_BYTES]u8
	for &value in block {
		value = 0xA5
	}
	registers := op.Guest_Registers {
		fs_base        = 0x1111_2222_3333_4444 & 0x0000_7FFF_FFFF_FFFF,
		gs_base        = 0xFFFF_8000_0000_1000,
		star           = 0x0023_0010_DEAD_BEEF,
		lstar          = 0xFFFF_FFFF_8100_0000,
		sfmask         = 0x0004_7700,
		kernel_gs_base = 0x0000_0000_0123_4000,
	}
	system_registers_write(block[:], registers)
	Written :: struct {
		offset: int,
		value:  u64,
	}
	expected := [?]Written{{0x448, registers.fs_base}, {0x458, registers.gs_base}, {0x600, registers.star}, {0x608, registers.lstar}, {0x618, registers.sfmask}, {0x620, registers.kernel_gs_base}}
	for offset := 0; offset < CONTROL_BLOCK_BYTES; offset += 8 {
		word := u64(0)
		for index in 0 ..< 8 {
			word |= u64(block[offset + index]) << (u64(index) * 8)
		}
		value, written := u64(0), false
		for entry in expected {
			if entry.offset == offset {
				value, written = entry.value, true
			}
		}
		if written {
			testing.expectf(t, word == value, "offset %x holds %x, not %x", offset, word, value)
		} else {
			testing.expectf(t, word == 0xA5A5_A5A5_A5A5_A5A5, "offset %x is not changed", offset)
		}
	}
	// The read gives the same record back.
	back := op.Guest_Registers{}
	system_registers_read(block[:], &back)
	testing.expect_value(t, back.fs_base, registers.fs_base)
	testing.expect_value(t, back.gs_base, registers.gs_base)
	testing.expect_value(t, back.star, registers.star)
	testing.expect_value(t, back.lstar, registers.lstar)
	testing.expect_value(t, back.sfmask, registers.sfmask)
	testing.expect_value(t, back.kernel_gs_base, registers.kernel_gs_base)
}

// The read masks what a block can hold that the rules refuse: an address
// that is not canonical comes back canonical, and the reserved bits of
// SFMASK come back clear, so the record passes the checks again.
@(test)
system_registers_read_masks :: proc(t: ^testing.T) {
	block: [CONTROL_BLOCK_BYTES]u8
	for &value in block {
		value = 0xFF
	}
	for offset in ([?]int{STATE_FS_BASE, STATE_GS_BASE, STATE_LONG_SYSTEM_CALL_TARGET, STATE_KERNEL_GS_BASE}) {
		for index in 0 ..< 8 {
			block[offset + index] = index == 5 ? 0x80 : 0
		}
	}
	registers := op.Guest_Registers{}
	system_registers_read(block[:], &registers)
	testing.expect_value(t, registers.fs_base, u64(0xFFFF_8000_0000_0000))
	testing.expect_value(t, registers.lstar, u64(0xFFFF_8000_0000_0000))
	testing.expect_value(t, registers.sfmask, u64(0xFFFF_FFFF))
	testing.expect_value(t, registers.star, max(u64))
	_, refusal := op.guest_registers_check(registers)
	testing.expect_value(t, refusal, op.Guest_Registers_Refusal.None)
	// With five-level paging, the same bit 47 is inside the width.
	registers.cr4 = op.GUEST_CONTROL_4_FIVE_LEVEL_PAGING
	system_registers_read(block[:], &registers)
	testing.expect_value(t, registers.fs_base, u64(0x0000_8000_0000_0000))
}

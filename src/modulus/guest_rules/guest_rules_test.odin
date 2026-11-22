#+build !freestanding
package guest_rules

import "core:testing"
import "modus:contract/byte_order"
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

// The intercepts of rdtsc and rdtscp and the word of the interrupt state,
// from the AMD manual, volume 2, table B-1: bit 14 of the word at 0x00C,
// bit 7 of the word at 0x010, bit 0 of the word at 0x068.
@(test)
time_stamp_counter_intercepts_and_interrupt_state_offsets :: proc(t: ^testing.T) {
	testing.expect_value(t, INTERCEPT_TIME_STAMP_COUNTER, u32(0x4000))
	testing.expect_value(t, INTERCEPT_TIME_STAMP_COUNTER_AND_PROCESSOR, u32(0x80))
	testing.expect_value(t, CONTROL_INTERRUPT_STATE, 0x068)
	testing.expect_value(t, INTERRUPT_SHADOW, u64(1))
	// The interrupt state is in the control area, before the save area.
	testing.expect(t, CONTROL_INTERRUPT_STATE + 8 <= 0x400)
}

// The interrupt shadow lands on bit 0 of the word at 0x068 and on no other
// byte of the block; the read gives 0 or 1 whatever the word holds, so the
// record passes the checks again.
@(test)
interrupt_shadow_write_and_read :: proc(t: ^testing.T) {
	for shadow in ([?]u8{0, 1}) {
		block: [CONTROL_BLOCK_BYTES]u8
		for &value in block {
			value = 0xA5
		}
		interrupt_shadow_write(block[:], {interrupt_shadow = shadow})
		for value, offset in block {
			switch {
			case offset == CONTROL_INTERRUPT_STATE:
				testing.expectf(t, value == shadow, "shadow %v: the first byte holds %x", shadow, value)
			case offset > CONTROL_INTERRUPT_STATE && offset < CONTROL_INTERRUPT_STATE + 8:
				// Bit 1 is the mask of the guest, which vmrun ignores: the
				// kernel writes 0 there, and no reserved bit.
				testing.expectf(t, value == 0, "shadow %v: byte %x holds %x", shadow, offset, value)
			case:
				testing.expectf(t, value == 0xA5, "shadow %v: byte %x is not changed", shadow, offset)
			}
		}
		back := op.Guest_Registers{interrupt_shadow = 7}
		interrupt_shadow_read(block[:], &back)
		testing.expect_value(t, back.interrupt_shadow, shadow)
	}
	// A word with the guest mask (bit 1) and every other bit set: the shadow
	// alone comes back.
	block: [CONTROL_BLOCK_BYTES]u8
	for offset in CONTROL_INTERRUPT_STATE ..< CONTROL_INTERRUPT_STATE + 8 {
		block[offset] = 0xFF
	}
	registers := op.Guest_Registers{}
	interrupt_shadow_read(block[:], &registers)
	testing.expect_value(t, registers.interrupt_shadow, u8(1))
	block[CONTROL_INTERRUPT_STATE] = 0xFE
	interrupt_shadow_read(block[:], &registers)
	testing.expect_value(t, registers.interrupt_shadow, u8(0))
	_, refusal := op.guest_registers_check(registers)
	testing.expect_value(t, refusal, op.Guest_Registers_Refusal.None)
}

// The exit codes of an exit Other whose instruction the process completes:
// each other code gives no next instruction.
@(test)
instruction_exit_lengths :: proc(t: ^testing.T) {
	for code in ([?]u64{0, 0x41, 0x51, 0x6D, 0x6F, 0x72, 0x78, 0x7B, 0x7D, 0x86, 0x88, 0x400, max(u64)}) {
		_, named := instruction_exit_length(code)
		testing.expectf(t, !named, "exit code %x names no instruction of the list", code)
	}
	// The successful cases last.
	length, named := instruction_exit_length(0x6E)
	testing.expect(t, named && length == 2)
	length, named = instruction_exit_length(0x7C)
	testing.expect(t, named && length == 2)
	length, named = instruction_exit_length(0x87)
	testing.expect(t, named && length == 3)
}
// The interrupt window: opened, the intercept VINTR and the request of a
// virtual interrupt at the highest priority, whatever the task priority;
// closed, none of them. The other bits of the two words stay.
@(test)
interrupt_window_bits :: proc(t: ^testing.T) {
	block: [CONTROL_BLOCK_BYTES]u8
	interrupt_window_write(block[:], true)
	testing.expect_value(t, byte_order.read_u32_little_endian(block[:], CONTROL_INTERCEPT_INSTRUCTIONS), u32(0x10))
	testing.expect_value(t, byte_order.read_u32_little_endian(block[:], CONTROL_VIRTUAL_INTERRUPT), u32(0x001F_0100))
	interrupt_window_write(block[:], false)
	testing.expect_value(t, byte_order.read_u32_little_endian(block[:], CONTROL_INTERCEPT_INSTRUCTIONS), u32(0))
	testing.expect_value(t, byte_order.read_u32_little_endian(block[:], CONTROL_VIRTUAL_INTERRUPT), u32(0))
	// Each other byte of the block is untouched.
	for byte_value, offset in block {
		testing.expectf(t, byte_value == 0, "byte %x", offset)
	}
	// Every other bit of the two words set: the window changes only its own.
	byte_order.write_u32_little_endian(block[:], CONTROL_INTERCEPT_INSTRUCTIONS, max(u32) &~ INTERCEPT_VIRTUAL_INTERRUPT)
	byte_order.write_u32_little_endian(block[:], CONTROL_VIRTUAL_INTERRUPT, max(u32) &~ VIRTUAL_INTERRUPT_WINDOW)
	interrupt_window_write(block[:], false)
	testing.expect_value(t, byte_order.read_u32_little_endian(block[:], CONTROL_INTERCEPT_INSTRUCTIONS), max(u32) &~ INTERCEPT_VIRTUAL_INTERRUPT)
	testing.expect_value(t, byte_order.read_u32_little_endian(block[:], CONTROL_VIRTUAL_INTERRUPT), max(u32) &~ VIRTUAL_INTERRUPT_WINDOW)
	interrupt_window_write(block[:], true)
	testing.expect_value(t, byte_order.read_u32_little_endian(block[:], CONTROL_INTERCEPT_INSTRUCTIONS), max(u32))
	testing.expect_value(t, byte_order.read_u32_little_endian(block[:], CONTROL_VIRTUAL_INTERRUPT), max(u32))
	// Open twice, closed once: closed.
	interrupt_window_write(block[:], true)
	interrupt_window_write(block[:], false)
	testing.expect_value(t, byte_order.read_u32_little_endian(block[:], CONTROL_INTERCEPT_INSTRUCTIONS) & INTERCEPT_VIRTUAL_INTERRUPT, u32(0))
	testing.expect_value(t, byte_order.read_u32_little_endian(block[:], CONTROL_VIRTUAL_INTERRUPT) & VIRTUAL_INTERRUPT_WINDOW, u32(0))
	// The interrupt masking of the kernel (bit 24) is not a bit of the
	// window, and the exit code is VMEXIT_VINTR.
	testing.expect_value(t, VIRTUAL_INTERRUPT_WINDOW & (u32(1) << 24), u32(0))
	testing.expect_value(t, EXIT_VIRTUAL_INTERRUPT, u64(0x64))
	testing.expect_value(t, CONTROL_VIRTUAL_INTERRUPT, 0x060)
	testing.expect_value(t, CONTROL_INTERRUPT_STATE, CONTROL_VIRTUAL_INTERRUPT + 8)
}

// How a run serves the event of a record: an event that an exit
// interrupted goes first; an external interrupt waits for the window while
// the guest takes none; each other kind goes in at once.
@(test)
event_service_of_each_state :: proc(t: ^testing.T) {
	INTERRUPT_FLAG :: op.GUEST_FLAGS_INTERRUPT
	open := op.Guest_Registers{rflags = INTERRUPT_FLAG}
	closed := op.Guest_Registers{}
	shadow := op.Guest_Registers{rflags = INTERRUPT_FLAG, interrupt_shadow = 1}
	closed_in_shadow := op.Guest_Registers{interrupt_shadow = 1}
	// No request: nothing, whatever the state.
	for registers in ([?]op.Guest_Registers{open, closed, shadow, closed_in_shadow}) {
		for held in ([?]bool{false, true}) {
			testing.expectf(t, event_service(registers, .None, held) == .None, "none with %v held %v", registers.rflags, held)
		}
	}
	// A held event goes first, for each kind; an external interrupt behind
	// it also opens the window, so the run ends when the guest takes
	// interrupts again, not at the next interrupt of the machine.
	for kind in ([?]op.Guest_Inject_Kind{.Non_Maskable_Interrupt, .Exception, .Software_Interrupt}) {
		for registers in ([?]op.Guest_Registers{open, closed, shadow, closed_in_shadow}) {
			testing.expectf(t, event_service(registers, kind, true) == .Wait, "%v behind a held event", kind)
		}
	}
	for registers in ([?]op.Guest_Registers{open, closed, shadow, closed_in_shadow}) {
		testing.expectf(t, event_service(registers, .External_Interrupt, true) == .Wait_Then_Window, "external interrupt behind a held event, flags %x", registers.rflags)
	}
	// The interrupt flag clear, the shadow, or both: the window opens.
	testing.expect_value(t, event_service(closed, .External_Interrupt, false), Event_Service.Open_Window)
	testing.expect_value(t, event_service(shadow, .External_Interrupt, false), Event_Service.Open_Window)
	testing.expect_value(t, event_service(closed_in_shadow, .External_Interrupt, false), Event_Service.Open_Window)
	// The other kinds do not wait for the window: an exception and a
	// software interrupt do not look at the interrupt flag, and the rules
	// refuse the non-maskable interrupt in the shadow.
	for kind in ([?]op.Guest_Inject_Kind{.Non_Maskable_Interrupt, .Exception, .Software_Interrupt}) {
		testing.expectf(t, event_service(closed, kind, false) == .Inject, "%v with the flag clear", kind)
	}
	// The successful case last: the guest takes interrupts.
	testing.expect_value(t, event_service(open, .External_Interrupt, false), Event_Service.Inject)
	testing.expect_value(t, event_service({rflags = op.GUEST_FLAGS_DEFINED}, .External_Interrupt, false), Event_Service.Inject)
}

// The window of each way to serve an event, and the window of one run
// closed again at the next run that does not ask for it: the block holds
// what the last run wrote, and nothing of the run before.
@(test)
interrupt_window_follows_each_run :: proc(t: ^testing.T) {
	testing.expect(t, !interrupt_window_open(.None))
	testing.expect(t, !interrupt_window_open(.Inject))
	testing.expect(t, !interrupt_window_open(.Wait))
	testing.expect(t, interrupt_window_open(.Open_Window))
	testing.expect(t, interrupt_window_open(.Wait_Then_Window))
	is_open :: proc(block: []u8) -> bool {
		intercept := byte_order.read_u32_little_endian(block, CONTROL_INTERCEPT_INSTRUCTIONS) & INTERCEPT_VIRTUAL_INTERRUPT != 0
		request := byte_order.read_u32_little_endian(block, CONTROL_VIRTUAL_INTERRUPT) & VIRTUAL_INTERRUPT_REQUEST != 0
		return intercept && request
	}
	is_closed :: proc(block: []u8) -> bool {
		return byte_order.read_u32_little_endian(block, CONTROL_INTERCEPT_INSTRUCTIONS) & INTERCEPT_VIRTUAL_INTERRUPT == 0 && byte_order.read_u32_little_endian(block, CONTROL_VIRTUAL_INTERRUPT) & VIRTUAL_INTERRUPT_WINDOW == 0
	}
	block: [CONTROL_BLOCK_BYTES]u8
	closed := op.Guest_Registers{}
	open := op.Guest_Registers{rflags = op.GUEST_FLAGS_INTERRUPT}
	// Run 1: the guest takes no interrupt, the window opens.
	interrupt_window_write(block[:], interrupt_window_open(event_service(closed, .External_Interrupt, false)))
	testing.expect(t, is_open(block[:]))
	// Run 2: no request (the process withdrew it): the window closes.
	interrupt_window_write(block[:], interrupt_window_open(event_service(closed, .None, false)))
	testing.expect(t, is_closed(block[:]))
	// Run 3: behind a held event, the window opens again.
	interrupt_window_write(block[:], interrupt_window_open(event_service(open, .External_Interrupt, true)))
	testing.expect(t, is_open(block[:]))
	// Run 4: the guest takes interrupts and the kernel injects: closed.
	interrupt_window_write(block[:], interrupt_window_open(event_service(open, .External_Interrupt, false)))
	testing.expect(t, is_closed(block[:]))
	// Run 5: an exception behind a held event waits with no window.
	interrupt_window_write(block[:], interrupt_window_open(event_service(closed, .Exception, true)))
	testing.expect(t, is_closed(block[:]))
}

// An injected external interrupt that an exit interrupted before its
// delivery comes back in EXITINTINFO: the next entry delivers it again, so
// the guest loses no interrupt.
@(test)
undelivered_external_interrupt_is_delivered_again :: proc(t: ^testing.T) {
	injected := event_injection_word(.External_Interrupt, 0x30, false, 0)
	pending := Pending_Injection{event = injected, address = 0x1000}
	next, still := event_after_exit(injected, 0x1000, pending)
	testing.expect_value(t, next, injected)
	testing.expect_value(t, still, pending)
	// An external interrupt of the machine in EXITINTINFO, with no
	// injection: delivered again too.
	next, still = event_after_exit(injected, 0x2000, {})
	testing.expect_value(t, next, injected)
	testing.expect_value(t, still, Pending_Injection{})
	// Delivered: EXITINTINFO not valid, nothing goes again.
	next, still = event_after_exit(0, 0x1000, pending)
	testing.expect_value(t, next, u64(0))
	testing.expect_value(t, still, Pending_Injection{})
}

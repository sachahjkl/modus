// The encodings of the AMD form of a guest (SVM) that the kernel writes in
// the control block of a guest processor: the word of an event to deliver,
// and the segments of the load of a mode (src/md/features/guest.md). The
// records of the process are checked before, by the rules of the contract
// (operation.guest_registers_check): these procedures take checked values.
//
// This package holds no state and runs no instruction of the processor, so
// a host test checks each encoding.
package guest_rules

import "modus:contract/byte_order"
import "modus:contract/enum_word"
import op "modus:contract/operation"

// An event in EXITINTINFO and in EVENTINJ (the AMD manual, volume 2,
// "Event Injection"): bits 0 to 7 the vector, 8 to 10 the type, bit 11 an
// error code to push, bit 31 valid, bits 32 to 63 the error code.
EVENT_VALID :: u64(1) << 31
EVENT_ERROR_CODE_VALID :: u64(1) << 11
EVENT_TYPE_SHIFT :: 8
EVENT_ERROR_CODE_SHIFT :: 32

// The type of an event, bits 8 to 10 of the word.
Event_Type :: enum u64 {
	External_Interrupt     = 0,
	Non_Maskable_Interrupt = 2,
	Exception              = 3,
	Software_Interrupt     = 4,
}

GUEST_VECTOR_BREAKPOINT :: 3 // int3: an instruction, which runs again.
GUEST_VECTOR_OVERFLOW :: 4 // into: an instruction, which runs again.

// event_injection_word gives the word of EVENTINJ for an event of a record
// that the rules of the contract accepted, or 0 for the kind None.
event_injection_word :: proc "contextless" (kind: op.Guest_Inject_Kind, vector: u8, error_code_valid: bool, error_code: u32) -> u64 {
	type: Event_Type
	switch kind {
	case .None:
		return 0
	case .External_Interrupt:
		type = .External_Interrupt
	case .Non_Maskable_Interrupt:
		type = .Non_Maskable_Interrupt
	case .Exception:
		type = .Exception
	case .Software_Interrupt:
		type = .Software_Interrupt
	}
	word := EVENT_VALID | u64(type) << EVENT_TYPE_SHIFT | u64(vector)
	if error_code_valid {
		word |= EVENT_ERROR_CODE_VALID | u64(error_code) << EVENT_ERROR_CODE_SHIFT
	}
	return word
}

// event_to_deliver_again gives the event that an exit interrupted, for the
// next entry, or 0. An exit can come while the guest delivers an event: a
// page on first use of its interrupt table or of its stack, or an interrupt
// of the machine. The next entry delivers it again, so the guest loses
// none. An event of an instruction of the guest (int n, int3, into) is not
// given: the guest is still at that instruction, which runs again. An event
// that the process injected goes through event_after_exit.
event_to_deliver_again :: proc "contextless" (event: u64) -> u64 {
	if event & EVENT_VALID == 0 {
		return 0
	}
	type := event >> EVENT_TYPE_SHIFT & 0b111
	vector := event & 0xFF
	switch {
	case type == u64(Event_Type.External_Interrupt) || type == u64(Event_Type.Non_Maskable_Interrupt):
		return event
	case type == u64(Event_Type.Exception) && vector != GUEST_VECTOR_BREAKPOINT && vector != GUEST_VECTOR_OVERFLOW:
		return event
	}
	return 0
}

// An event that the process injected and that the guest did not receive
// yet: the word that the kernel wrote in EVENTINJ, and the instruction
// address of the guest at the injection. The guest returns to that address
// after a software interrupt, int3 or into that the process injected.
Pending_Injection :: struct {
	event:   u64, // 0: none.
	address: u64,
}

// events_match says if two event words name one event: both valid, with
// the same type and the same vector. The error code does not count: the
// processor gives it back as it pushed it.
events_match :: proc "contextless" (first: u64, second: u64) -> bool {
	EVENT_TYPE_AND_VECTOR :: u64(0b111) << EVENT_TYPE_SHIFT | 0xFF
	return first & EVENT_VALID != 0 && second & EVENT_VALID != 0 && first & EVENT_TYPE_AND_VECTOR == second & EVENT_TYPE_AND_VECTOR
}

// event_needs_next_instruction says if the delivery of an event pushes the
// address after an instruction: a software interrupt, or the exception of
// int3 or into. With NRIPS, the processor takes that address from
// CONTROL_NEXT_INSTRUCTION (the AMD manual, volume 2, "Event Injection").
event_needs_next_instruction :: proc "contextless" (event: u64) -> bool {
	if event & EVENT_VALID == 0 {
		return false
	}
	type := event >> EVENT_TYPE_SHIFT & 0b111
	vector := event & 0xFF
	return type == u64(Event_Type.Software_Interrupt) || type == u64(Event_Type.Exception) && (vector == GUEST_VECTOR_BREAKPOINT || vector == GUEST_VECTOR_OVERFLOW)
}

// next_instruction_of_injection gives the address that the kernel writes in
// CONTROL_NEXT_INSTRUCTION before an entry that delivers the event in
// EVENTINJ, or false when the entry needs none. Only an injected event of
// an instruction needs it, and the kernel delivers such an event again only
// while it is the pending injection.
next_instruction_of_injection :: proc "contextless" (event: u64, pending: Pending_Injection) -> (address: u64, needed: bool) {
	if !event_needs_next_instruction(event) || !events_match(event, pending.event) {
		return 0, false
	}
	return pending.address, true
}

// event_after_exit gives the event for the next entry after an exit, and
// the injection that is still pending. An injected event that the exit
// interrupted (the same type and vector in EXITINTINFO, with the guest still
// at the address of the injection) is delivered again, whatever its type:
// the guest is not at an instruction that would raise it again. Each other
// event follows event_to_deliver_again, and the injection was delivered.
event_after_exit :: proc "contextless" (exit_event: u64, exit_address: u64, pending: Pending_Injection) -> (next: u64, still_pending: Pending_Injection) {
	if pending.event != 0 && events_match(exit_event, pending.event) && exit_address == pending.address {
		return exit_event, pending
	}
	return event_to_deliver_again(exit_event), {}
}

// The attributes of a segment in the control block: bits 0 to 7 the type,
// the kind (code or data), the privilege level and present, as bits 40 to
// 47 of a descriptor; bits 8 to 11 AVL, L (64-bit code), D/B (32-bit) and G
// (a limit in pages), as bits 52 to 55.
SEGMENT_CODE :: u16(0x9B) // Present, code, readable, accessed.
SEGMENT_DATA :: u16(0x93) // Present, data, writable, accessed.
SEGMENT_LONG :: u16(1) << 9 // L.
SEGMENT_THIRTY_TWO :: u16(1) << 10 // D/B.
SEGMENT_PAGES :: u16(1) << 11 // G.
SEGMENT_LOCAL_TABLE :: u16(0x82) // Present, a local descriptor table.
SEGMENT_TASK :: u16(0x8B) // Present, a busy task state of 32 or 64 bits.
REAL_MODE_LIMIT :: u32(0xFFFF)
FLAT_LIMIT :: u32(0xFFFF_FFFF)

// One segment in the control block: what the kernel writes for it.
Segment :: struct {
	selector:   u16,
	attributes: u16,
	limit:      u32,
	base:       u64,
}

// The segments of the load of a mode: the code segment, and the data
// segment that es, ss, ds, fs and gs take.
Mode_Segments :: struct {
	code: Segment,
	data: Segment,
}

// mode_segments gives the segments of the load of a mode, or false for
// Keep, which loads none. Real mode puts each segment at its selector times
// 16, as the processor does; the other modes are flat from 0, and the guest
// loads its own descriptor table to change them.
mode_segments :: proc "contextless" (load: op.Guest_Mode_Load, code_selector: u16, data_selector: u16) -> (segments: Mode_Segments, loaded: bool) {
	switch load {
	case .Keep:
		return {}, false
	case .Real_16:
		segments.code = {code_selector, SEGMENT_CODE, REAL_MODE_LIMIT, u64(code_selector) << 4}
		segments.data = {data_selector, SEGMENT_DATA, REAL_MODE_LIMIT, u64(data_selector) << 4}
	case .Protected_32:
		segments.code = {code_selector, SEGMENT_CODE | SEGMENT_THIRTY_TWO | SEGMENT_PAGES, FLAT_LIMIT, 0}
		segments.data = {data_selector, SEGMENT_DATA | SEGMENT_THIRTY_TWO | SEGMENT_PAGES, FLAT_LIMIT, 0}
	case .Long_64:
		// L with D/B clear: 64-bit code; the processor refuses L with D/B.
		segments.code = {code_selector, SEGMENT_CODE | SEGMENT_LONG | SEGMENT_PAGES, FLAT_LIMIT, 0}
		segments.data = {data_selector, SEGMENT_DATA | SEGMENT_THIRTY_TWO | SEGMENT_PAGES, FLAT_LIMIT, 0}
	}
	return segments, true
}

// The places of the 64-bit system state in the save area of the control
// block (the AMD manual, volume 2, appendix B, table B-2, "VMCB Layout,
// State Save Area"). Offsets in bytes from the start of the control block.
// vmrun does not load them: vmload loads them before vmrun, and vmsave
// keeps them after the exit (guest_enter in processor.asm).
STATE_FS_BASE :: 0x448 // The base of the segment fs, whose record starts at 0x440.
STATE_GS_BASE :: 0x458 // The base of the segment gs, whose record starts at 0x450.
STATE_SYSTEM_CALL_TARGET :: 0x600 // STAR.
STATE_LONG_SYSTEM_CALL_TARGET :: 0x608 // LSTAR.
STATE_COMPATIBILITY_SYSTEM_CALL_TARGET :: 0x610 // CSTAR: not in the record.
STATE_SYSTEM_CALL_FLAGS_MASK :: 0x618 // SFMASK.
STATE_KERNEL_GS_BASE :: 0x620 // KernelGsBase.
CONTROL_BLOCK_BYTES :: 4096

// The intercepts of the time stamp counter (the AMD manual, volume 2,
// appendix B, table B-1, "VMCB Layout, Control Area"): bit 14 of the word
// of instructions at 0x00C, and bit 7 of the second word at 0x010. A guest
// that reads the counter of the machine measures the time of the machine,
// and rdtscp gives the processor number in TSC_AUX: each read exits, and the
// process answers it from its own clock.
INTERCEPT_TIME_STAMP_COUNTER :: u32(1) << 14 // rdtsc.
INTERCEPT_TIME_STAMP_COUNTER_AND_PROCESSOR :: u32(1) << 7 // rdtscp.
INTERCEPT_READ_PROCESSOR_REGISTER :: u32(1) << 14 // rdpru (MPERF/APERF on Zen 2+).

// The word of the interrupt state in the control area (table B-1): bit 0
// the interrupt shadow, bit 1 the global interrupt mask of the guest, which
// the processor writes at the exit and ignores at vmrun.
CONTROL_INTERRUPT_STATE :: 0x068
INTERRUPT_SHADOW :: u64(1) << 0

// interrupt_shadow_write writes the interrupt shadow of a record that the
// rules of the contract accepted into a control block, for the next entry.
interrupt_shadow_write :: proc "contextless" (block: []u8, registers: op.Guest_Registers) {
	byte_order.write_u64_little_endian(block, CONTROL_INTERRUPT_STATE, u64(registers.interrupt_shadow) & INTERRUPT_SHADOW)
}

// interrupt_shadow_read reads the interrupt shadow of a control block after
// an exit into a record: 0 or 1, whatever the other bits of the word hold,
// so that a process can always pass the record back.
interrupt_shadow_read :: proc "contextless" (block: []u8, registers: ^op.Guest_Registers) {
	registers.interrupt_shadow = u8(byte_order.read_u64_little_endian(block, CONTROL_INTERRUPT_STATE) & INTERRUPT_SHADOW)
}

// The exit codes of the intercepted instructions whose exit gives the
// process the address of the next instruction, in the exit Other (the AMD
// manual, volume 2, appendix C, "SVM Intercept Exit Codes").
Instruction_Exit :: enum u64 {
	Time_Stamp_Counter               = 0x6E, // rdtsc: 0F 31.
	Model_Specific_Register          = 0x7C, // rdmsr and wrmsr: 0F 32 and 0F 30.
	Time_Stamp_Counter_And_Processor = 0x87, // rdtscp: 0F 01 F9.
}

// instruction_exit_length gives the length of the instruction of an exit
// Other with no prefix, or false for an exit code that names no instruction
// of Instruction_Exit. Without NRIPS, the kernel gives the address of the
// instruction plus this length, as for hlt and cpuid.
instruction_exit_length :: proc "contextless" (code: u64) -> (length: u64, ok: bool) {
	instruction := enum_word.member_of_word(Instruction_Exit, code) or_return
	switch instruction {
	case .Time_Stamp_Counter, .Model_Specific_Register:
		return 2, true
	case .Time_Stamp_Counter_And_Processor:
		return 3, true
	}
	return 0, false
}

// system_registers_write writes the 64-bit system state of a record that
// the rules of the contract accepted into a control block.
system_registers_write :: proc "contextless" (block: []u8, registers: op.Guest_Registers) {
	byte_order.write_u64_little_endian(block, STATE_FS_BASE, registers.fs_base)
	byte_order.write_u64_little_endian(block, STATE_GS_BASE, registers.gs_base)
	byte_order.write_u64_little_endian(block, STATE_SYSTEM_CALL_TARGET, registers.star)
	byte_order.write_u64_little_endian(block, STATE_LONG_SYSTEM_CALL_TARGET, registers.lstar)
	byte_order.write_u64_little_endian(block, STATE_SYSTEM_CALL_FLAGS_MASK, registers.sfmask)
	byte_order.write_u64_little_endian(block, STATE_KERNEL_GS_BASE, registers.kernel_gs_base)
}

// system_registers_read reads the 64-bit system state of a control block
// after an exit into a record. The masks keep the record within the rules
// of the contract whatever the block holds, so that a process can always
// pass it back: the addresses in their canonical form, the reserved bits of
// SFMASK cleared.
system_registers_read :: proc "contextless" (block: []u8, registers: ^op.Guest_Registers) {
	five_level := registers.cr4 & op.GUEST_CONTROL_4_FIVE_LEVEL_PAGING != 0
	registers.fs_base = op.guest_address_canonical_of(byte_order.read_u64_little_endian(block, STATE_FS_BASE), five_level)
	registers.gs_base = op.guest_address_canonical_of(byte_order.read_u64_little_endian(block, STATE_GS_BASE), five_level)
	registers.star = byte_order.read_u64_little_endian(block, STATE_SYSTEM_CALL_TARGET)
	registers.lstar = op.guest_address_canonical_of(byte_order.read_u64_little_endian(block, STATE_LONG_SYSTEM_CALL_TARGET), five_level)
	registers.sfmask = byte_order.read_u64_little_endian(block, STATE_SYSTEM_CALL_FLAGS_MASK) & op.GUEST_SYSTEM_CALL_MASK_DEFINED
	registers.kernel_gs_base = op.guest_address_canonical_of(byte_order.read_u64_little_endian(block, STATE_KERNEL_GS_BASE), five_level)
}

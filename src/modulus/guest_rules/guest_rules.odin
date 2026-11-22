// The encodings of the AMD form of a guest (SVM) that the kernel writes in
// the control block of a guest processor: the word of an event to deliver,
// and the segments of the load of a mode (src/md/features/guest.md). The
// records of the process are checked before, by the rules of the contract
// (operation.guest_registers_check): these procedures take checked values.
//
// This package holds no state and runs no instruction of the processor, so
// a host test checks each encoding.
package guest_rules

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
// none. An event of an instruction (int n, int3, into) is not given: the
// guest is still at that instruction, which runs again.
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

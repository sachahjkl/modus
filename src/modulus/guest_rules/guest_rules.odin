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

// The interrupt window of a guest processor (the AMD manual, volume 2,
// "Virtual Interrupts" and table B-1): the kernel asks the processor for a
// virtual interrupt (V_IRQ) at the highest priority, whatever the task
// priority of the guest (V_IGN_TPR), and intercepts it (VINTR). With the
// interrupts masked by the flag of the kernel (V_INTR_MASKING, which the
// kernel always sets), the guest takes the virtual interrupt when its own
// interrupt flag is set and it is out of its interrupt shadow: the processor
// exits then, with the exit code EXIT_VIRTUAL_INTERRUPT, and the guest
// receives nothing.
CONTROL_INTERCEPT_INSTRUCTIONS :: 0x00C // u32: the first vector of instructions and events.
CONTROL_VIRTUAL_INTERRUPT :: 0x060 // u32: the low half of the virtual interrupt control.
INTERCEPT_VIRTUAL_INTERRUPT :: u32(1) << 4 // VINTR.
VIRTUAL_INTERRUPT_REQUEST :: u32(1) << 8 // V_IRQ.
VIRTUAL_INTERRUPT_PRIORITY_HIGHEST :: u32(0xF) << 16 // V_INTR_PRIO.
VIRTUAL_INTERRUPT_IGNORE_TASK_PRIORITY :: u32(1) << 20 // V_IGN_TPR.
VIRTUAL_INTERRUPT_WINDOW :: VIRTUAL_INTERRUPT_REQUEST | VIRTUAL_INTERRUPT_PRIORITY_HIGHEST | VIRTUAL_INTERRUPT_IGNORE_TASK_PRIORITY
EXIT_VIRTUAL_INTERRUPT :: u64(0x64) // VMEXIT_VINTR.

// interrupt_window_write opens or closes the interrupt window in a control
// block, for the next entry. It changes only its own bits of the two words:
// the other intercepts and the interrupt masking of the kernel stay.
interrupt_window_write :: proc "contextless" (block: []u8, open: bool) {
	intercepts := byte_order.read_u32_little_endian(block, CONTROL_INTERCEPT_INSTRUCTIONS)
	control := byte_order.read_u32_little_endian(block, CONTROL_VIRTUAL_INTERRUPT)
	if open {
		intercepts |= INTERCEPT_VIRTUAL_INTERRUPT
		control |= VIRTUAL_INTERRUPT_WINDOW
	} else {
		intercepts &~= INTERCEPT_VIRTUAL_INTERRUPT
		control &~= VIRTUAL_INTERRUPT_WINDOW
	}
	byte_order.write_u32_little_endian(block, CONTROL_INTERCEPT_INSTRUCTIONS, intercepts)
	byte_order.write_u32_little_endian(block, CONTROL_VIRTUAL_INTERRUPT, control)
}

// The request of an event of a run, as the kernel serves it.
Event_Service :: enum u8 {
	None        = 0, // No request: the entry delivers no event of the record.
	Inject      = 1, // The entry delivers the event of the record (EVENTINJ).
	Wait        = 2, // An event that an exit interrupted goes first: the request stays in the record.
	Open_Window = 3, // An external interrupt that the guest does not take now: the entry opens the interrupt window, and the request stays in the record.
	// An external interrupt behind an event that an exit interrupted: the entry delivers that event, and
	// opens the interrupt window, so the run ends when the guest takes interrupts again, not at the next
	// interrupt of the machine. The request stays in the record.
	Wait_Then_Window = 4,
}

// interrupt_window_open says if the entries of a run open the interrupt
// window for the way that the run serves its event.
interrupt_window_open :: proc "contextless" (service: Event_Service) -> bool {
	switch service {
	case .Open_Window, .Wait_Then_Window:
		return true
	case .None, .Inject, .Wait:
		return false
	}
	return false
}

// event_service says how a run serves the event of a record that the rules
// of the contract accepted: event_held is true when the control block holds
// an event that an exit interrupted.
event_service :: proc "contextless" (registers: op.Guest_Registers, kind: op.Guest_Inject_Kind, event_held: bool) -> Event_Service {
	switch kind {
	case .None:
		return .None
	case .External_Interrupt:
		if event_held {
			return .Wait_Then_Window
		}
		return op.guest_external_interrupt_taken(registers) ? .Inject : .Open_Window
	case .Non_Maskable_Interrupt, .Exception, .Software_Interrupt:
		return event_held ? .Wait : .Inject
	}
	return .None
}

// The switch of a page of a switching mapping (src/md/features/guest.md,
// "The switch of a page"): each page is writable or executable, never both,
// and a nested page fault that asks for the other access switches that one
// page. The bits of an entry of the long mode page table that the switch
// writes; the kernel checks that they are its own.
ENTRY_WRITE :: u64(1) << 1
ENTRY_NO_EXECUTE :: u64(1) << 63

// switched_entry_bits gives the access bits of the entry of a page that a
// fault asks for: a write gives Write and no execute, a fetch gives execute
// and no Write. A fault that asks for both, or for neither (a read, which
// switches nothing), is refused.
switched_entry_bits :: proc "contextless" (write: bool, execute: bool) -> (bits: u64, ok: bool) {
	if write == execute {
		return 0, false
	}
	return write ? ENTRY_WRITE | ENTRY_NO_EXECUTE : 0, true
}

// switching_page_of gives the page of an address in a mapping of
// page_count pages at mapping_address, or false for an address outside it:
// below its first byte, or at its end and past it.
switching_page_of :: proc "contextless" (mapping_address: u64, page_count: u64, address: u64) -> (page: u64, ok: bool) {
	PAGE_BYTES :: 4096
	if address < mapping_address {
		return 0, false
	}
	page = (address - mapping_address) / PAGE_BYTES
	if page >= page_count {
		return 0, false
	}
	return page, true
}

// The switches of one guest processor, to find an instruction that writes
// the page that holds it: the last switch, and how many times in a row the
// same page switched to the other access at the same instruction of the
// same address space of the guest (rip and cr3).
Switch_Watch :: struct {
	page:         u64, // The guest physical address of the page of the last switch.
	address:      u64, // The rip of the guest at the last switch.
	space:        u64, // The cr3 of the guest at the last switch.
	write:        bool, // The last switch gave Write.
	noted:        bool, // A switch was noted since the last loop.
	alternations: u32,
}

// SWITCH_ALTERNATIONS_OF_A_LOOP: the alternations at one instruction that
// mean that the instruction writes its own page. A fetch then a write of
// one page at one rip happen once when an instruction writes a page of
// code; twice in a row, the instruction never completes.
SWITCH_ALTERNATIONS_OF_A_LOOP :: 2

// switch_watch_forget ends the row of the watch: a switch that does not
// count (switch_counts) is between two that do.
switch_watch_forget :: proc "contextless" (watch: ^Switch_Watch) {
	watch^ = {}
}

// switch_watch_note notes one switch, and says if the instruction writes
// the page that holds it. The loop is found at a write only, so the exit
// gives the address that the instruction writes, and the process can do
// that write for it.
switch_watch_note :: proc "contextless" (watch: ^Switch_Watch, page: u64, address: u64, space: u64, write: bool) -> (writes_own_page: bool) {
	if watch.noted && page == watch.page && address == watch.address && space == watch.space && write != watch.write {
		watch.alternations += 1
	} else {
		watch.alternations = 0
	}
	watch.page, watch.address, watch.space, watch.write, watch.noted = page, address, space, write, true
	if watch.alternations >= SWITCH_ALTERNATIONS_OF_A_LOOP && write {
		watch^ = {}
		return true
	}
	return false
}

// FAULT_DURING_TABLE_WALK: bit 33 of the first exit information of a
// nested page fault (the AMD manual, volume 2, "Nested Page Faults"): the
// processor faulted while it walked the page table of the guest, not at the
// access of the instruction. The bit 32 says the access of the instruction.
FAULT_DURING_TABLE_WALK :: u64(1) << 33

// switch_counts says if a switch counts toward the watch: not a fault of a
// walk of the page table of the guest, and not a fault while the processor
// delivered an event (exit_event, EXITINTINFO, is valid): in both, the
// fault is not the access of the instruction at rip. A switch that does not
// count ends the row: the watch forgets it.
switch_counts :: proc "contextless" (information_1: u64, exit_event: u64) -> bool {
	return information_1 & FAULT_DURING_TABLE_WALK == 0 && exit_event & EVENT_VALID == 0
}

// The facts of a nested page fault of a guest that decide its answer
// (guest_page_answer in the kernel reads them under the guest lock).
Fault_Facts :: struct {
	mapped:         bool, // A mapping of the guest process covers the address.
	switching:      bool, // The mapping was made with Write, Execute and No_Access.
	has_access:     bool, // The protection of the whole mapping is not No_Access.
	slot_no_access: bool, // The page has the mark No_Access in its slot.
	committed:      bool, // The page is committed (an object made Uncommitted).
	has_entry:      bool, // The page table holds a 4 KiB entry of the page.
	present:        bool, // The entry is present.
	allows:         bool, // The present entry already allows the access of the fault.
	write:          bool, // The fault is a write.
	execute:        bool, // The fault is a fetch.
}

// What the kernel does at a nested page fault.
Fault_Answer :: enum u8 {
	Refused        = 0, // The run ends with the exit Memory.
	Page_Give      = 1, // The rule of a process: page_give gives a page on first use, or refuses.
	Allowed        = 2, // The entry allows the access: a translation that a switch removed. Run again.
	Give_Switched  = 3, // A page on first use of a switching mapping gets its frame with the access of the fault.
	Switch         = 4, // A present page of a switching mapping gets the other access.
}

// fault_answer decides the answer of a nested page fault from its facts.
// A switching mapping switches only for a fault of one access (a write or a
// fetch, not both, not a read), on small pages, while the whole mapping has
// access; inside it, a page that its slot or its commit refuses is refused.
fault_answer :: proc "contextless" (facts: Fault_Facts) -> Fault_Answer {
	if !facts.mapped {
		return .Refused
	}
	_, asks_one_access := switched_entry_bits(facts.write, facts.execute)
	if !facts.switching || !asks_one_access || !facts.has_access {
		return .Page_Give
	}
	if facts.slot_no_access || !facts.committed || !facts.has_entry {
		return .Refused
	}
	if facts.present && facts.allows {
		return .Allowed
	}
	return facts.present ? .Switch : .Give_Switched
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

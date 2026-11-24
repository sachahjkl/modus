package kernel

import "modulus:budget_peak"
import "base:intrinsics"
import op "modus:contract/operation"
import "modulus:extended_switch"
import "modulus:guest_rules"

// A guest (src/md/features/guest.md; docs/ARCHITECTURE.md, "A guest"): a
// process whose page table is the nested page table of a guest processor,
// and the operation Guest_Run that runs that processor on the calling
// thread. This is the AMD form (SVM): the control block of the processor
// (the VMCB) and the instructions vmrun, vmload and vmsave (guest_enter in
// processor.asm). The kernel holds the mechanism only: no exit is emulated
// here but the page on first use; each other exit goes back to the process.

// The model-specific registers of SVM (the AMD manual, volume 2, "SVM
// Related MSRs").
MSR_EXTENDED_FEATURES :: 0xC000_0080 // EFER.
EFER_SECURE_VIRTUAL_MACHINE :: u64(1) << 12 // SVME: vmrun and its instructions work.
MSR_VIRTUAL_MACHINE_CONTROL :: 0xC001_0114 // VM_CR.
VIRTUAL_MACHINE_CONTROL_DISABLED :: u64(1) << 4 // SVMDIS: the firmware turned SVM off.
MSR_HOST_SAVE_AREA :: 0xC001_0117 // VM_HSAVE_PA: where vmrun keeps the state of the kernel.

// The places of the control block that the kernel writes or reads (the AMD
// manual, volume 2, appendix B, "VMCB Layout"). Offsets in bytes.
CONTROL_INTERCEPT_DEBUG_REGISTERS :: 0x004 // u32: bits 0 to 15 the reads, 16 to 31 the writes.
CONTROL_INTERCEPT_EXCEPTIONS :: 0x008 // u32: bit n the exception n.
CONTROL_INTERCEPT_INSTRUCTIONS :: 0x00C // u32: the first vector of instructions and events.
CONTROL_INTERCEPT_MORE_INSTRUCTIONS :: 0x010 // u32: the instructions of virtualization and others.
CONTROL_PORT_MAP :: 0x040 // u64: the physical address of the map of the ports.
CONTROL_REGISTER_MAP :: 0x048 // u64: the physical address of the map of the model-specific registers.
CONTROL_ADDRESS_SPACE :: 0x058 // u32: the address space identifier of the guest.
CONTROL_TRANSLATION_FLUSH :: 0x05C // u8: what vmrun flushes of the translations.
CONTROL_INTERRUPTS :: 0x060 // u32: bit 24 masks the interrupts of the machine by the flag of the kernel, not of the guest.
CONTROL_EXIT_CODE :: 0x070 // u64
CONTROL_EXIT_INFORMATION_1 :: 0x078 // u64
CONTROL_EXIT_INFORMATION_2 :: 0x080 // u64
CONTROL_EXIT_EVENT :: 0x088 // u64: EXITINTINFO, the event that the guest delivered when it exited.
CONTROL_EVENT_INJECTION :: 0x0A8 // u64: EVENTINJ, the event that the next entry delivers to the guest.
CONTROL_NESTED :: 0x090 // u64: bit 0 turns nested paging on.
CONTROL_NESTED_TABLE :: 0x0B0 // u64: the top table of the nested page table.
CONTROL_CLEAN :: 0x0C0 // u32: the parts that the processor may keep from the last run: 0, none.
CONTROL_NEXT_INSTRUCTION :: 0x0C8 // u64: the address after the instruction of the exit (with next_instruction).
STATE_SEGMENT_ES :: 0x400 // Each segment: u16 selector, u16 attributes, u32 limit, u64 base.
STATE_SEGMENT_CS :: 0x410
STATE_SEGMENT_SS :: 0x420
STATE_SEGMENT_DS :: 0x430
STATE_SEGMENT_FS :: 0x440
STATE_SEGMENT_GS :: 0x450
STATE_SEGMENT_GDTR :: 0x460
STATE_SEGMENT_LDTR :: 0x470
STATE_SEGMENT_IDTR :: 0x480
STATE_SEGMENT_TR :: 0x490
STATE_PRIVILEGE_LEVEL :: 0x4CB // u8: CPL.
STATE_EFER :: 0x4D0
STATE_CR4 :: 0x548
STATE_CR3 :: 0x550
STATE_CR0 :: 0x558
STATE_DR7 :: 0x560
STATE_DR6 :: 0x568
STATE_RFLAGS :: 0x570
STATE_RIP :: 0x578
STATE_RSP :: 0x5D8
STATE_RAX :: 0x5F8
STATE_PAGE_ATTRIBUTES :: 0x668 // The page attribute table of the guest under nested paging.
// The 64-bit system state is written by guest_rules, which a host test
// checks: its bases are the bases of the segment records above.
#assert(guest_rules.STATE_FS_BASE == STATE_SEGMENT_FS + 8)
#assert(guest_rules.STATE_GS_BASE == STATE_SEGMENT_GS + 8)
#assert(guest_rules.STATE_SYSTEM_CALL_TARGET == STATE_RAX + 8)
#assert(guest_rules.CONTROL_BLOCK_BYTES == PAGE_SIZE)
// The interrupt state lies between the interrupt control and the exit code
// (the AMD manual, volume 2, table B-1).
#assert(guest_rules.CONTROL_INTERRUPT_STATE == 0x068)
#assert(guest_rules.CONTROL_INTERRUPT_STATE == CONTROL_INTERRUPTS + 8)
#assert(guest_rules.CONTROL_INTERRUPT_STATE == CONTROL_EXIT_CODE - 8)
#assert(CONTROL_INTERCEPT_INSTRUCTIONS == 0x00C)
#assert(CONTROL_INTERCEPT_MORE_INSTRUCTIONS == 0x010)
#assert(guest_rules.INTERCEPT_TIME_STAMP_COUNTER == 1 << 14)
#assert(guest_rules.INTERCEPT_TIME_STAMP_COUNTER_AND_PROCESSOR == 1 << 7)
// The interrupt window: guest_rules writes its bits in the two words of the
// control block that the kernel writes here, and no bit of the kernel.
#assert(guest_rules.CONTROL_INTERCEPT_INSTRUCTIONS == CONTROL_INTERCEPT_INSTRUCTIONS)
#assert(guest_rules.CONTROL_VIRTUAL_INTERRUPT == CONTROL_INTERRUPTS)
#assert(INTERCEPT_INSTRUCTIONS & guest_rules.INTERCEPT_VIRTUAL_INTERRUPT == 0)
#assert(INTERRUPTS_MASKED_BY_THE_KERNEL & guest_rules.VIRTUAL_INTERRUPT_WINDOW == 0)

// What the guest may not do alone. The first vector: the interrupt, the
// non-maskable interrupt, the system management interrupt and INIT of the
// machine (0 to 3), rdpmc (15), cpuid (18), invd (22), hlt (24), invlpga
// (26), each port (27), each model-specific register (28) and the shutdown
// (31). rdpmc would read the performance counters of the processor, which
// hold the counts of another thread. rdtsc (14) would read the time of the
// machine: the process answers it from the clock of the guest.
INTERCEPT_INSTRUCTIONS :: u32(1 << 0 | 1 << 1 | 1 << 2 | 1 << 3 | 1 << 15 | 1 << 18 | 1 << 22 | 1 << 24 | 1 << 26 | 1 << 27 | 1 << 28 | 1 << 31) | guest_rules.INTERCEPT_TIME_STAMP_COUNTER
// The second vector: vmrun (which the processor requires), vmmcall, vmload,
// vmsave, stgi, clgi, skinit (0 to 6), rdtscp (7: the time of the machine
// and the processor number in TSC_AUX), icebp (8: the int1 instruction, whose
// debug exception the exception intercept does not cover), wbinvd (9),
// monitor, mwait and its conditional form (10 to 12), xsetbv (13). xsetbv
// would change the XCR0 of the kernel, which the exit does not restore.
INTERCEPT_MORE_INSTRUCTIONS :: u32(0b111_1111 | 1 << 8 | 1 << 9 | 1 << 10 | 1 << 11 | 1 << 12 | 1 << 13) | guest_rules.INTERCEPT_TIME_STAMP_COUNTER_AND_PROCESSOR | guest_rules.INTERCEPT_READ_PROCESSOR_REGISTER
// Each read and each write of a debug register: the exit does not restore
// DR0 to DR3, which hold the breakpoints of threads.
INTERCEPT_DEBUG_REGISTERS :: u32(0xFFFF_FFFF)
// The machine check: a fault of the machine, which stops it, as in a process.
// The alignment check and the debug exception: a guest that owns its
// descriptor table and its stack can make the delivery of one of them raise
// it again, so the processor loops in the delivery, takes no interrupt and
// never exits; each processor that then waits for it stops too. Each one
// exits, and the process gets it as an exit of the kind Other.
GUEST_VECTOR_DEBUG :: 1
GUEST_VECTOR_ALIGNMENT_CHECK :: 17
INTERCEPT_EXCEPTIONS :: u32(1 << VECTOR_MACHINE_CHECK | 1 << GUEST_VECTOR_DEBUG | 1 << GUEST_VECTOR_ALIGNMENT_CHECK)
INTERRUPTS_MASKED_BY_THE_KERNEL :: u32(1) << 24 // V_INTR_MASKING.
NESTED_PAGING_ON :: u64(1)
// Every guest has the address space identifier 1, which each entry flushes:
// nested KVM gives 8 identifiers only (src/md/features/guest.md, "Subtle
// points").
GUEST_ADDRESS_SPACE_IDENTIFIER :: 1
TRANSLATION_FLUSH_ALL :: u8(1)
TRANSLATION_FLUSH_THE_GUEST :: u8(3) // With the feature FlushByAsid.
PAGE_ATTRIBUTES_AT_RESET :: u64(0x0007_0406_0007_0406)
CR0_OF_A_GUEST_AT_START :: u64(CR0_EXTENSION_TYPE) // Real mode, caches on.
FLAGS_ALWAYS_SET :: u64(1) << 1

// The exit codes (the AMD manual, volume 2, appendix C, "SVM Intercept
// Exit Codes").
GUEST_EXIT_MACHINE_CHECK :: u64(0x40 + VECTOR_MACHINE_CHECK)
GUEST_EXIT_INTERRUPT :: u64(0x60)
GUEST_EXIT_NON_MASKABLE_INTERRUPT :: u64(0x61)
GUEST_EXIT_MANAGEMENT_INTERRUPT :: u64(0x62)
GUEST_EXIT_INIT :: u64(0x63)
GUEST_EXIT_VIRTUAL_INTERRUPT :: guest_rules.EXIT_VIRTUAL_INTERRUPT
GUEST_EXIT_CPUID :: u64(0x72)
GUEST_EXIT_HALT :: u64(0x78)
GUEST_EXIT_PORT :: u64(0x7B)
GUEST_EXIT_SHUTDOWN :: u64(0x7F)
GUEST_EXIT_NESTED_PAGE_FAULT :: u64(0x400)
GUEST_EXIT_REFUSED_STATE :: max(u64) // VMEXIT_INVALID: -1.

// The first exit information of a port: bit 0 an `in`, bit 2 a string
// instruction, bit 3 a `rep`, bits 4 to 6 the size, bits 16 to 31 the port.
PORT_READ :: u64(1) << 0
PORT_STRING :: u64(1) << 2
PORT_REPEAT :: u64(1) << 3
PORT_ONE_BYTE :: u64(1) << 4
PORT_TWO_BYTES :: u64(1) << 5
// The first exit information of a nested page fault: the error code of the
// access, as a page fault gives it.
NESTED_FAULT_ACCESS :: u64(FAULT_PRESENT | FAULT_WRITE | FAULT_EXECUTE)

// The pages of the two maps that every guest shares: the map of the ports
// (12 KiB) and the map of the model-specific registers (8 KiB). Every bit
// is 1: each access exits.
GUEST_PORT_MAP_PAGES :: 3
GUEST_REGISTER_MAP_PAGES :: 2

// The pages on first use that one Guest_Run gives before it ends with
// Interrupted: a bound on the work of one operation, should a page that the
// kernel gave fault again.
GUEST_PAGES_IN_ONE_RUN :: 64

// What the processors can do for a guest. Written by the first processor
// at its setup, and cleared by another processor that cannot do the same,
// before any process runs.
Guest_Support :: struct {
	ready:               bool, // Each processor that runs threads can run a guest.
	next_instruction:    bool, // NRIPS: the exit gives the address after the instruction.
	flush_by_identifier: bool, // FlushByAsid: an entry can flush the guest only.
	identifiers:         u32, // The address space identifiers of the processor.
	refusal:             string, // Why no guest runs: a line of the log.
}
guest_support: Guest_Support
guest_reserved_bit_faults: u64 // Atomic: the nested page faults with the reserved bit, of every guest.

guest_port_map: u64 // Physical: GUEST_PORT_MAP_PAGES pages of ones.
guest_register_map: u64 // Physical: GUEST_REGISTER_MAP_PAGES pages of ones.
// For each processor, the page where guest_enter keeps the fs, gs, task and
// system call state of the kernel (vmsave), and the page of the processor
// for vmrun (MSR_HOST_SAVE_AREA). Physical.
guest_host_areas: [PROCESSOR_CAPACITY]u64
guest_host_save_areas: [PROCESSOR_CAPACITY]u64
// For each processor, the nested page table of the guest that it runs now,
// or 0 (atomic). processors_with_table reads it: an unmap in a guest process
// reaches the processor that runs the guest, whose cr3 is another table.
guest_tables_running: [PROCESSOR_CAPACITY]u64

// One guest processor of a guest. Its pages exist from its first run to the
// end of the guest. A run owns the whole record while running is true: no
// other run reads or writes its control block or its extended state.
Guest_Processor :: struct {
	running:       bool, // A thread runs this guest processor now. Process lock of the guest.
	control_block: u64, // Physical: the control block of the guest processor, one page. 0: not made yet.
	state_area:    u64, // Physical: the extended state of the guest processor, one page.
	// The event that the process injected and that the guest did not
	// receive yet: it lives across runs, as the word of EVENTINJ does.
	pending_injection: guest_rules.Pending_Injection,
	// The switches of pages of this guest processor, to find an instruction
	// that writes the page that holds it. It lives across runs: the loop
	// can span the bound of one run.
	switch_watch:      guest_rules.Switch_Watch,
}

// The guest processors of a process, by the index of the process. One for
// each process slot: a guest is a process. The guest processors share the
// nested page table, which is the table of the process; each has its own
// state, so threads run different guest processors at once.
Guest :: struct {
	process_serial: u32, // The serial of the process that is this guest. 0: no guest in the slot.
	processors:     [op.GUEST_PROCESSOR_CAPACITY]Guest_Processor,
	page_switches:  u64, // The pages that switched between Write and Execute: a measure. Process lock of the guest.
	own_page_writes: u64, // The runs that ended with Writes_Own_Page: a measure. Process lock of the guest.
}
guests: [PROCESS_CAPACITY_MOST]Guest

// The general registers of a guest processor that the control block does
// not keep, in the order of guest_enter in processor.asm.
Guest_General_Registers :: struct {
	rbx, rcx, rdx, rsi, rdi, rbp: u64,
	r8, r9, r10, r11, r12, r13, r14, r15: u64,
}
#assert(offset_of(Guest_General_Registers, rsi) == 24)
#assert(offset_of(Guest_General_Registers, r8) == 48)
#assert(offset_of(Guest_General_Registers, r15) == 104)
#assert(size_of(Extended_State_Area) <= PAGE_SIZE)

// One exit of a guest processor, as the control block gives it.
Guest_Exit :: struct {
	code:          u64,
	information_1: u64,
	information_2: u64,
	next:          u64, // The address after the instruction of the exit, from the processor; 0 without next_instruction.
	// A nested page fault of an instruction that writes the page that
	// holds it: the run ends with the exit Writes_Own_Page.
	writes_own_page: bool,
	code_64:         bool, // The code segment of the guest is 64-bit (L, in long mode): b of Writes_Own_Page.
}

// guest_support_read says what the processor that runs it can do for a
// guest.
guest_support_read :: proc "contextless" () -> (support: Guest_Support) {
	highest, _, _, _ := processor_identification_read(0x8000_0000, 0)
	if highest < 0x8000_000A {
		support.refusal = "the processor has no SVM"
		return
	}
	_, _, extended_features, _ := processor_identification_read(0x8000_0001, 0)
	if extended_features & (1 << 2) == 0 {
		support.refusal = "the processor has no SVM"
		return
	}
	// The register exists on each processor with SVM.
	if model_specific_register_read(MSR_VIRTUAL_MACHINE_CONTROL) & VIRTUAL_MACHINE_CONTROL_DISABLED != 0 {
		support.refusal = "the firmware turned SVM off"
		return
	}
	_, identifiers, _, features := processor_identification_read(0x8000_000A, 0)
	NESTED_PAGING :: 1 << 0
	NEXT_INSTRUCTION :: 1 << 3
	FLUSH_BY_IDENTIFIER :: 1 << 6
	if features & NESTED_PAGING == 0 {
		support.refusal = "the processor has SVM with no nested paging"
		return
	}
	// The identifier 0 is the kernel's: a guest needs one more.
	if identifiers < 2 {
		support.refusal = "the processor has fewer than two address space identifiers"
		return
	}
	support.ready = true
	support.identifiers = identifiers
	support.next_instruction = features & NEXT_INSTRUCTION != 0
	support.flush_by_identifier = features & FLUSH_BY_IDENTIFIER != 0
	return
}

// guest_processor_setup prepares the processor that runs it for a guest:
// SVM on, and its two pages. The first processor reads the support and makes
// the two maps. A processor that cannot run a guest turns the support off
// for the machine: a thread can run on any processor. It runs at the setup
// of each processor, before any process.
guest_processor_setup :: proc "contextless" (cpu: ^Processor) {
	if cpu.index == 0 {
		guest_support = guest_support_read()
		if guest_support.ready {
			guest_port_map = frames_allocate(GUEST_PORT_MAP_PAGES)
			guest_register_map = frames_allocate(GUEST_REGISTER_MAP_PAGES)
			if guest_port_map == 0 || guest_register_map == 0 {
				guest_support.ready = false
				guest_support.refusal = "no memory for the maps of the ports and of the registers"
			} else {
				// Each bit set: each access to a port or to a register exits.
				port_words := ([^]u64)(direct(guest_port_map, u64))[:GUEST_PORT_MAP_PAGES * PAGE_SIZE / 8]
				for &word in port_words {
					word = max(u64)
				}
				register_words := ([^]u64)(direct(guest_register_map, u64))[:GUEST_REGISTER_MAP_PAGES * PAGE_SIZE / 8]
				for &word in register_words {
					word = max(u64)
				}
			}
		}
		if guest_support.ready {
			log("kernel: guest: AMD SVM with nested paging, ", u64(guest_support.identifiers), " address space identifiers", guest_support.flush_by_identifier ? string(", a flush of one identifier") : string(", a flush of all the translations at each entry"))
		} else {
			log("kernel: guest: no guest runs: ", guest_support.refusal)
		}
	} else if intrinsics.atomic_load(&guest_support.ready) {
		other := guest_support_read()
		if !other.ready || other.next_instruction != guest_support.next_instruction || other.flush_by_identifier != guest_support.flush_by_identifier {
			intrinsics.atomic_store(&guest_support.ready, false)
			log("kernel: guest: no guest runs: the processor ", u64(cpu.index), " cannot run a guest as the first processor does")
		}
	}
	if !intrinsics.atomic_load(&guest_support.ready) {
		return
	}
	host_area := frames_allocate(1)
	host_save_area := frames_allocate(1)
	if host_area == 0 || host_save_area == 0 {
		intrinsics.atomic_store(&guest_support.ready, false)
		log("kernel: guest: no guest runs: no memory for the host pages of the processor ", u64(cpu.index))
		return
	}
	guest_host_areas[cpu.index] = host_area
	guest_host_save_areas[cpu.index] = host_save_area
	model_specific_register_write(MSR_EXTENDED_FEATURES, model_specific_register_read(MSR_EXTENDED_FEATURES) | EFER_SECURE_VIRTUAL_MACHINE)
	model_specific_register_write(MSR_HOST_SAVE_AREA, host_save_area)
}

// process_is_guest says if a process is a guest now: Process_Start refuses
// it, because its page table has no kernel half. The caller holds the
// process lock.
process_is_guest :: proc "contextless" (index: u32) -> bool {
	serial := guests[index].process_serial
	return serial != 0 && serial == processes[index].serial
}

// process_holds_guest_memory says if a process holds a mapping that only a
// guest takes: one at the address 0, or one whose pages switch between
// Write and Execute (map_region). Process_Start refuses such a process: a
// thread there would run with no fault at the address 0, or on pages that
// it can write and then execute. The caller holds the process lock.
process_holds_guest_memory :: proc "contextless" (process: ^Process) -> bool {
	for mapping in process.mappings {
		if mapping.page_count == 0 {
			continue
		}
		if mapping.address == 0 || mapping.limit_bits & PAGE_WRITE != 0 && mapping.limit_bits & PAGE_NO_EXECUTE == 0 {
			return true
		}
	}
	return false
}

// guest_segment_write writes one segment of the state of a guest processor.
guest_segment_write :: proc "contextless" (block: u64, offset: u64, segment: guest_rules.Segment) {
	direct(block + offset, u16)^ = segment.selector
	direct(block + offset + 2, u16)^ = segment.attributes
	direct(block + offset + 4, u32)^ = segment.limit
	direct(block + offset + 8, u64)^ = segment.base
}

// guest_mode_write writes the segments of a mode in the state of a guest
// processor: the code segment, the five data segments and the privilege
// level 0. The descriptor tables, the task and the local table stay. With
// Keep, nothing changes.
guest_mode_write :: proc "contextless" (block: u64, load: op.Guest_Mode_Load, code_selector: u16, data_selector: u16) -> (loaded: bool) {
	segments := guest_rules.mode_segments(load, code_selector, data_selector) or_return
	guest_segment_write(block, STATE_SEGMENT_CS, segments.code)
	for offset in ([?]u64{STATE_SEGMENT_ES, STATE_SEGMENT_SS, STATE_SEGMENT_DS, STATE_SEGMENT_FS, STATE_SEGMENT_GS}) {
		guest_segment_write(block, offset, segments.data)
	}
	direct(block + STATE_PRIVILEGE_LEVEL, u8)^ = 0
	return true
}

// guest_control_block_write writes the control block of a new guest
// processor in a zero page: what it may not do alone, its nested page table,
// and the state of a processor in real mode with every segment at 0.
guest_control_block_write :: proc "contextless" (block: u64, table: u64) {
	direct(block + CONTROL_INTERCEPT_DEBUG_REGISTERS, u32)^ = INTERCEPT_DEBUG_REGISTERS
	direct(block + CONTROL_INTERCEPT_EXCEPTIONS, u32)^ = INTERCEPT_EXCEPTIONS
	direct(block + CONTROL_INTERCEPT_INSTRUCTIONS, u32)^ = INTERCEPT_INSTRUCTIONS
	direct(block + CONTROL_INTERCEPT_MORE_INSTRUCTIONS, u32)^ = INTERCEPT_MORE_INSTRUCTIONS
	direct(block + CONTROL_PORT_MAP, u64)^ = guest_port_map
	direct(block + CONTROL_REGISTER_MAP, u64)^ = guest_register_map
	direct(block + CONTROL_ADDRESS_SPACE, u32)^ = GUEST_ADDRESS_SPACE_IDENTIFIER
	direct(block + CONTROL_INTERRUPTS, u32)^ = INTERRUPTS_MASKED_BY_THE_KERNEL
	direct(block + CONTROL_NESTED, u64)^ = NESTED_PAGING_ON
	direct(block + CONTROL_NESTED_TABLE, u64)^ = table
	guest_mode_write(block, .Real_16, 0, 0)
	guest_segment_write(block, STATE_SEGMENT_GDTR, {limit = guest_rules.REAL_MODE_LIMIT})
	guest_segment_write(block, STATE_SEGMENT_IDTR, {limit = guest_rules.REAL_MODE_LIMIT})
	guest_segment_write(block, STATE_SEGMENT_LDTR, {attributes = guest_rules.SEGMENT_LOCAL_TABLE, limit = guest_rules.REAL_MODE_LIMIT})
	guest_segment_write(block, STATE_SEGMENT_TR, {attributes = guest_rules.SEGMENT_TASK, limit = guest_rules.REAL_MODE_LIMIT})
	// vmrun refuses a guest with SVME clear in its EFER.
	direct(block + STATE_EFER, u64)^ = EFER_SECURE_VIRTUAL_MACHINE
	direct(block + STATE_CR0, u64)^ = CR0_OF_A_GUEST_AT_START
	direct(block + STATE_DR7, u64)^ = DR7_NO_BREAKPOINT
	direct(block + STATE_DR6, u64)^ = DR6_CLEAR
	direct(block + STATE_RFLAGS, u64)^ = FLAGS_ALWAYS_SET
	direct(block + STATE_PAGE_ATTRIBUTES, u64)^ = PAGE_ATTRIBUTES_AT_RESET
}

// guest_frame_return gives a page that the budget of a process paid back to
// that budget, as address_space_free does for a table.
guest_frame_return :: proc "contextless" (process: ^Process, frame: u64) {
	lock_take(&frame_lock, .Frame)
	frames_free_held(frame, 1)
	budget_peak.give_back(&budgets[process.budget].amounts.pages, 1)
	lock_free(&frame_lock, .Frame)
}

// guest_processor_create makes one guest processor of a process, at its
// first Guest_Run: the budget of the process pays the control block and the
// extended state. Nothing changes when the budget cannot pay. The caller
// holds the process lock.
guest_processor_create :: proc "contextless" (process: ^Process) -> (processor: Guest_Processor, status: Operation_Outcome) {
	control_block := frame_paid(&process.budget)
	if control_block == 0 {
		return {}, .Budget_Or_Capacity_Exhausted
	}
	state_area := frame_paid(&process.budget)
	if state_area == 0 {
		guest_frame_return(process, control_block)
		return {}, .Budget_Or_Capacity_Exhausted
	}
	extended_state_start(direct(state_area, Extended_State_Area))
	guest_control_block_write(control_block, process.table)
	return {control_block = control_block, state_area = state_area}, .Succeeded
}

// guest_create makes a process a guest, at its first Guest_Run, with the
// guest processor of that run: the time page and the own log ring leave the
// process, and the kernel half leaves its top table, so that the guest
// reaches only what its process mapped. Nothing changes when the budget
// cannot pay the guest processor. The caller holds the process lock; the
// process is Created, with no thread.
guest_create :: proc "contextless" (index: u32, processor_index: u32) -> Operation_Outcome {
	process := &processes[index]
	first := guest_processor_create(process) or_return
	for &mapping in process.mappings {
		if mapping.page_count != 0 && mapping.address == op.TIME_ADDRESS {
			unmap(process, &mapping)
			break
		}
	}
	// A guest has no thread, so it never writes a log record: its own log
	// ring returns to its budget, as the time page leaves it.
	own_log_ring_end(process)
	// No processor uses this table as its cr3: the process has no thread,
	// and Process_Start refuses it from now.
	for &entry in direct(process.table, [512]u64)^[256:] {
		entry = 0
	}
	guests[index] = {process_serial = process.serial}
	guests[index].processors[processor_index] = first
	return .Succeeded
}

// guest_end gives back the pages of the guest of a process that ends. The
// caller is process_cleanup, with the process lock: no run holds the
// process any more.
guest_end :: proc "contextless" (index: u32) {
	if !process_is_guest(index) {
		return
	}
	guest := &guests[index]
	if guest.page_switches != 0 {
		log("kernel: the guest of process ", Module_Name{process_name(&processes[index])}, " switched ", guest.page_switches, " pages between Write and Execute, and ", guest.own_page_writes, " instructions wrote the page that held them")
	}
	for processor in guest.processors {
		if processor.control_block != 0 {
			guest_frame_return(&processes[index], processor.control_block)
			guest_frame_return(&processes[index], processor.state_area)
		}
	}
	guest^ = {}
}

// guest_enter_once enters the guest processor once, with the registers of
// the record, and gives its exit; the record has the registers after the
// exit. The requests of the record (the mode load and the event) are not
// read here: guest_run serves them once before the first entry. The
// extended state of the thread leaves the processor during the guest, and
// comes back after it: the kernel has no vector instruction of its own, so
// the registers of the thread are live here.
guest_enter_once :: proc "contextless" (cpu: ^Processor, thread: ^Thread, processor: ^Guest_Processor, process: ^Process, registers: ^op.Guest_Registers) -> (exit: Guest_Exit) {
	// Before the entry, and seen by an unmap that cleared its entries, or
	// by a stop: then either the unmap or the stop sends its interrupt
	// here, or this entry sees what it wrote: the cleared entries, or the
	// state Stopped below (processors_with_table, process_stop). Each side
	// writes, then reads the word of the other side.
	intrinsics.atomic_store(&guest_tables_running[cpu.index], process.table)
	if intrinsics.atomic_load(&process.state) == .Stopped {
		intrinsics.atomic_store(&guest_tables_running[cpu.index], 0)
		return {code = GUEST_EXIT_INTERRUPT} // The process stopped: no instruction of the guest runs after its stop.
	}
	block := processor.control_block
	direct(block + STATE_RAX, u64)^ = registers.rax
	direct(block + STATE_RSP, u64)^ = registers.rsp
	direct(block + STATE_RIP, u64)^ = registers.rip
	direct(block + STATE_RFLAGS, u64)^ = registers.rflags | FLAGS_ALWAYS_SET
	// The process answers a write of a control register or of EFER by the
	// record; the bits that the processor needs are set here, whatever the
	// record says.
	direct(block + STATE_CR0, u64)^ = registers.cr0 | CR0_EXTENSION_TYPE
	direct(block + STATE_CR3, u64)^ = registers.cr3
	direct(block + STATE_CR4, u64)^ = registers.cr4
	direct(block + STATE_EFER, u64)^ = registers.efer | EFER_SECURE_VIRTUAL_MACHINE
	// The system call targets and the bases of fs and gs: vmload loads them
	// from the block before vmrun, and vmsave keeps them after the exit. The
	// record wins over a mode load, which wrote the bases of its segments.
	guest_rules.system_registers_write(direct(block, [guest_rules.CONTROL_BLOCK_BYTES]u8)[:], registers^)
	// A process that completed the instruction of the exit cleared the
	// shadow in the record; vmrun loads it from here.
	guest_rules.interrupt_shadow_write(direct(block, [guest_rules.CONTROL_BLOCK_BYTES]u8)[:], registers^)
	// Every guest has one identifier, and a guest can run on another
	// processor than before: each entry flushes its translations.
	direct(block + CONTROL_TRANSLATION_FLUSH, u8)^ = guest_support.flush_by_identifier ? TRANSLATION_FLUSH_THE_GUEST : TRANSLATION_FLUSH_ALL
	direct(block + CONTROL_CLEAN, u32)^ = 0
	// With NRIPS, the delivery of an injected software interrupt, int3 or
	// into pushes the address in this word, which the last exit wrote: the
	// address of the injection goes there, so that the guest returns to it.
	if guest_support.next_instruction {
		if address, needed := guest_rules.next_instruction_of_injection(direct(block + CONTROL_EVENT_INJECTION, u64)^, processor.pending_injection); needed {
			direct(block + CONTROL_NEXT_INSTRUCTION, u64)^ = address
		}
	}
	general := Guest_General_Registers {
		rbx = registers.rbx, rcx = registers.rcx, rdx = registers.rdx, rsi = registers.rsi, rdi = registers.rdi, rbp = registers.rbp,
		r8 = registers.r8, r9 = registers.r9, r10 = registers.r10, r11 = registers.r11, r12 = registers.r12, r13 = registers.r13, r14 = registers.r14, r15 = registers.r15,
	}
	state_area := direct(processor.state_area, Extended_State_Area)
	extended_state_save(&thread.extended_state, extended_state_form)
	// Running a guest replaces the hardware extended state registers on this
	// processor, so drop any cached thread identity on this processor.
	extended_state_invalidate_cpu(cpu)
	thread.extended_switch.last_extended_cpu = extended_switch.NO_PROCESSOR
	extended_state_restore(state_area, extended_state_form)
	guest_enter(block, &general, guest_host_areas[cpu.index])
	intrinsics.atomic_store(&guest_tables_running[cpu.index], 0)
	guest_form := extended_state_form == .Fxsave ? Extended_State_Form.Fxsave : Extended_State_Form.Xsave
	extended_state_save(state_area, guest_form)
	extended_state_restore(&thread.extended_state, extended_state_form)
	// The exit leaves no breakpoint on: the breakpoints of the thread come
	// back, and the status of the guest leaves.
	debug_register_6_write(DR6_CLEAR)
	if cpu.breakpoints_loaded {
		breakpoints_load(cpu, thread)
	} else {
		debug_register_7_write(DR7_NO_BREAKPOINT)
	}
	registers.rax, registers.rbx, registers.rcx, registers.rdx = direct(block + STATE_RAX, u64)^, general.rbx, general.rcx, general.rdx
	registers.rsi, registers.rdi, registers.rbp, registers.rsp = general.rsi, general.rdi, general.rbp, direct(block + STATE_RSP, u64)^
	registers.r8, registers.r9, registers.r10, registers.r11 = general.r8, general.r9, general.r10, general.r11
	registers.r12, registers.r13, registers.r14, registers.r15 = general.r12, general.r13, general.r14, general.r15
	registers.rip = direct(block + STATE_RIP, u64)^
	registers.rflags = direct(block + STATE_RFLAGS, u64)^ & op.GUEST_FLAGS_DEFINED
	// The guest writes its control registers itself: the record gives them
	// back, so that the next run loads what the guest left. The masks keep
	// the record within its rules whatever the processor wrote.
	registers.cr0 = direct(block + STATE_CR0, u64)^ & op.GUEST_CONTROL_0_DEFINED
	registers.cr3 = direct(block + STATE_CR3, u64)^ & op.GUEST_CONTROL_3_DEFINED
	registers.cr4 = direct(block + STATE_CR4, u64)^ & op.GUEST_CONTROL_4_DEFINED
	registers.efer = direct(block + STATE_EFER, u64)^ & op.GUEST_EFER_DEFINED
	guest_rules.system_registers_read(direct(block, [guest_rules.CONTROL_BLOCK_BYTES]u8)[:], registers)
	guest_rules.interrupt_shadow_read(direct(block, [guest_rules.CONTROL_BLOCK_BYTES]u8)[:], registers)
	registers.code_selector = direct(block + STATE_SEGMENT_CS, u16)^
	registers.data_selector = direct(block + STATE_SEGMENT_DS, u16)^
	exit = {
		code          = direct(block + CONTROL_EXIT_CODE, u64)^,
		information_1 = direct(block + CONTROL_EXIT_INFORMATION_1, u64)^,
		information_2 = direct(block + CONTROL_EXIT_INFORMATION_2, u64)^,
	}
	if guest_support.next_instruction {
		exit.next = direct(block + CONTROL_NEXT_INSTRUCTION, u64)^
	}
	// The event that the exit interrupted goes to the next entry, in this
	// run or in the next one; with none, the next entry delivers nothing.
	// An injected event that the exit interrupted goes again whatever its
	// type: the guest is at no instruction that raises it again.
	// After a refused state, the processor entered nothing and the word can
	// hold an old event: it is not delivered again at each run.
	if exit.code == GUEST_EXIT_REFUSED_STATE {
		direct(block + CONTROL_EVENT_INJECTION, u64)^ = 0
		processor.pending_injection = {}
	} else {
		next_event, still_pending := guest_rules.event_after_exit(direct(block + CONTROL_EXIT_EVENT, u64)^, registers.rip, processor.pending_injection)
		direct(block + CONTROL_EVENT_INJECTION, u64)^ = next_event
		processor.pending_injection = still_pending
	}
	// An interrupt of another processor that waits in processor_sync is
	// held until the return to the process: the answer comes now.
	sync_acknowledge(cpu)
	return exit
}

// The bits of an entry that guest_rules writes at a switch are the bits of
// this kernel.
#assert(guest_rules.ENTRY_WRITE == PAGE_WRITE)
#assert(guest_rules.ENTRY_NO_EXECUTE == PAGE_NO_EXECUTE)

// mapping_is_switching says if a mapping is guest memory whose pages switch
// between Write and Execute: made with Write, Execute and No_Access, which
// map_region gives only to guest memory.
mapping_is_switching :: proc "contextless" (mapping: ^Mapping) -> bool {
	return mapping.limit_bits & PAGE_WRITE != 0 && mapping.limit_bits & PAGE_NO_EXECUTE == 0
}

// What the kernel did at a nested page fault of a guest.
Guest_Page_Answer :: enum u8 {
	Refused  = 0, // The mapping refuses the access: the run ends with the exit Memory.
	Given    = 1, // A page on first use got its frame, or the entry already allows the access.
	Switched = 2, // A present page of a switching mapping got the other access.
}

// guest_page_answer answers a nested page fault of a guest at a guest
// physical address (src/md/features/guest.md, "The switch of a page"). A
// page of a switching mapping (made with Write, Execute and No_Access) gets
// the access of the fault, Write and no execute, or execute and no Write,
// never both; a page on first use gets its frame with that access. Each
// other mapping follows page_give. The caller holds the lock of the guest
// process.
guest_page_answer :: proc "contextless" (process: ^Process, address: u64, write: bool, execute: bool) -> Guest_Page_Answer {
	facts := guest_rules.Fault_Facts{write = write, execute = execute}
	mapping := mapping_at(process, address)
	facts.mapped = mapping != nil
	page: u64
	region: ^Region
	entry: ^u64
	if mapping != nil {
		facts.switching = mapping_is_switching(mapping)
		facts.large = mapping.large
		facts.has_access = mapping.bits != 0
		inside: bool
		page, inside = guest_rules.switching_page_of(mapping.address, mapping.page_count, address)
		facts.mapped = inside
		if inside && !mapping.large {
			region = &regions[mapping.region]
			state := region_page_state(region, mapping.first + page)
			facts.slot_no_access = state & SLOT_NO_ACCESS != 0
			facts.committed = page_committed(region, state)
			entry = page_entry(process.table, mapping.address + page * PAGE_SIZE)
			facts.has_entry = entry != nil
			if entry != nil {
				facts.present = entry^ & PAGE_PRESENT != 0
				facts.allows = (!write || entry^ & PAGE_WRITE != 0) && (!execute || entry^ & PAGE_NO_EXECUTE == 0)
			}
		}
	}
	access_bits, _ := guest_rules.switched_entry_bits(write, execute)
	switch guest_rules.fault_answer(facts) {
	case .Refused:
		return .Refused
	case .Page_Give:
		return page_give(process, address, write, execute) ? .Given : .Refused
	case .Allowed:
		// A translation that an earlier switch removed: the entry allows
		// the access now, and the instruction runs again.
		return .Given
	case .Give_Switched:
		frame := region_frame(region, mapping.first + page, true)
		if frame == 0 {
			return .Refused
		}
		entry^ = frame | PAGE_PRESENT | PAGE_USER | mapping.limit_bits & PAGE_CACHE_TYPE_BITS | access_bits
		mapping.present_page_count += 1 // Under the process lock: the caller holds it.
		mapping.entries_4k += 1
		return .Given
	case .Switch:
		entry^ = entry^ & PAGE_ADDRESS | PAGE_PRESENT | PAGE_USER | mapping.limit_bits & PAGE_CACHE_TYPE_BITS | access_bits
		// The switch took an access away: each other processor that runs a
		// guest processor of this guest leaves its run, and its next entry
		// flushes the translations of the guest. This processor flushes them
		// at its next entry too. The entry is written before the read of the
		// processors that run the guest: a processor that enters after the
		// read sees the new entry (guest_enter_once writes its word, then
		// reads), as for an unmap.
		intrinsics.atomic_thread_fence(.Seq_Cst)
		processor_sync(processors_with_table(process.table))
		return .Switched
	}
	return .Refused
}

// guest_next_instruction gives the address after the instruction of an
// exit: the address that the processor gave, or, without it, the address of
// the instruction plus its length with no prefix.
guest_next_instruction :: proc "contextless" (given: u64, instruction: u64, length: u64) -> u64 {
	return given != 0 ? given : instruction + length
}

// guest_exit_results writes the results of Guest_Run for one exit that
// ends the operation (op.Guest_Exit_Kind).
guest_exit_results :: proc "contextless" (exit: Guest_Exit, registers: ^op.Guest_Registers, results: ^[7]u64) {
	kind := op.Guest_Exit_Kind.Other
	if exit.writes_own_page {
		results[0] = u64(op.Guest_Exit_Kind.Writes_Own_Page)
		results[1] = exit.information_2 // The address that the instruction writes.
		results[2] = exit.code_64 ? 1 : 0
		results[5] = exit.code
		results[6] = exit.information_1
		return
	}
	switch exit.code {
	case GUEST_EXIT_PORT:
		information := exit.information_1
		if information & (PORT_STRING | PORT_REPEAT) != 0 {
			break // A string of ports reads or writes guest memory: the process decodes it (Other).
		}
		size := u64(4)
		if information & PORT_ONE_BYTE != 0 {
			size = 1
		} else if information & PORT_TWO_BYTES != 0 {
			size = 2
		}
		results[1] = information >> 16 & 0xFFFF
		results[2] = size
		results[4] = exit.information_2 // The address after the instruction, for every port exit.
		if information & PORT_READ != 0 {
			kind = .Port_Read
		} else {
			kind = .Port_Write
			results[3] = registers.rax & (u64(1) << (size * 8) - 1)
		}
	case GUEST_EXIT_HALT:
		kind = .Halt
		results[4] = guest_next_instruction(exit.next, registers.rip, 1) // f4
	case GUEST_EXIT_CPUID:
		kind = .Cpuid
		results[4] = guest_next_instruction(exit.next, registers.rip, 2) // 0f a2
	case GUEST_EXIT_NESTED_PAGE_FAULT:
		kind = .Memory
		results[1] = exit.information_2
		results[2] = exit.information_1 & NESTED_FAULT_ACCESS
	case GUEST_EXIT_INTERRUPT, GUEST_EXIT_NON_MASKABLE_INTERRUPT, GUEST_EXIT_MANAGEMENT_INTERRUPT, GUEST_EXIT_INIT:
		kind = .Interrupted
	case GUEST_EXIT_VIRTUAL_INTERRUPT:
		kind = .Interrupt_Window
	case GUEST_EXIT_SHUTDOWN:
		kind = .Shutdown
	case GUEST_EXIT_REFUSED_STATE:
		kind = .Refused_State
	case:
		// rdmsr, wrmsr, rdtsc and rdtscp: the process completes the
		// instruction, so it needs the address after it.
		if length, named := guest_rules.instruction_exit_length(exit.code); named {
			results[4] = guest_next_instruction(exit.next, registers.rip, length)
		}
	}
	results[0] = u64(kind)
	results[5] = exit.code
	results[6] = exit.information_1
}

// guest_run runs the operation Guest_Run (src/md/features/guest.md, "The
// run, step by step"). It takes its own locks: the lock of the caller for
// the handle and the record, the lock of the guest process for its state,
// for the flag running of the guest processor and for each page on first
// use, and no lock while the guest runs. The flag running gives the run the
// guest processor alone: another thread runs another guest processor of the
// same guest at the same time, with its own control block and extended
// state; the nested page table is the one that they share, and the lock of
// the guest process orders its changes. A run holds the guest process as a
// thread on a processor holds its process: a stop during the run cleans the
// process up after it.
guest_run :: proc "contextless" (index: u32, v: [7]u64, results: ^[7]u64) -> Operation_Outcome {
	if !intrinsics.atomic_load(&guest_support.ready) {
		return .Operation_Unsupported
	}
	thread := &threads[index]
	caller_index := thread.process
	caller := &processes[caller_index]
	registers: op.Guest_Registers
	guest_index, guest_serial: u32
	caller_taken := process_lock(caller_index)
	slot, found := handle_find(caller, v[0], .Process, {.Control})
	readable := found == .Succeeded && user_range(caller, v[1], size_of(op.Guest_Registers), true)
	if readable {
		// A copy, checked after: the process can change its memory meanwhile.
		user_copy_from_process(&registers, v[1], size_of(registers))
		guest_index = slot.object
		// The handle holds the process: its slot serves no other process
		// while the handle lives.
		guest_serial = intrinsics.atomic_load(&processes[guest_index].serial)
	}
	process_unlock(caller_index, caller_taken)
	if found != .Succeeded {
		return found
	}
	if !readable {
		return .Argument_Refused
	}
	if guest_index == caller_index {
		return .Wrong_State
	}
	requests, refusal := op.guest_registers_check(registers)
	if refusal != .None {
		return .Argument_Refused
	}
	processor_index, processor_known := op.guest_processor_of_word(v[2])
	if !processor_known {
		return .Argument_Refused
	}

	guest_process := &processes[guest_index]
	guest := &guests[guest_index]
	guest_taken := process_lock(guest_index)
	// The handle can have closed since: the serial names the process.
	if intrinsics.atomic_load(&guest_process.serial) != guest_serial || guest_process.state != .Created || guest_process.thread_count != 0 {
		process_unlock(guest_index, guest_taken)
		return .Wrong_State
	}
	if !process_is_guest(guest_index) {
		if status := guest_create(guest_index, processor_index); status != .Succeeded {
			process_unlock(guest_index, guest_taken)
			return status
		}
	} else if guest.processors[processor_index].control_block == 0 {
		made, status := guest_processor_create(guest_process)
		if status != .Succeeded {
			process_unlock(guest_index, guest_taken)
			return status
		}
		guest.processors[processor_index] = made
	}
	processor := &guest.processors[processor_index]
	if processor.running {
		process_unlock(guest_index, guest_taken)
		return .Wrong_State // One thread runs a guest processor at a time.
	}
	processor.running = true
	intrinsics.atomic_add(&guest_process.holds, 1)
	process_unlock(guest_index, guest_taken)

	// The requests of the record, once for the operation. The flag running
	// gives this run the control block alone.
	block := processor.control_block
	mode_loaded := guest_mode_write(block, requests.mode_load, registers.code_selector, registers.data_selector)
	// An event that an exit interrupted goes first, as the processor would
	// deliver it: the request of the process waits in the record for a
	// later run. An external interrupt that the guest does not take now
	// waits for the interrupt window: the processor would deliver it with no
	// check of the interrupt flag of the guest.
	injected := false
	service := guest_rules.event_service(registers, requests.inject_kind, direct(block + CONTROL_EVENT_INJECTION, u64)^ & guest_rules.EVENT_VALID != 0)
	switch service {
	case .Inject:
		injection := guest_rules.event_injection_word(requests.inject_kind, registers.inject_vector, registers.inject_error_code_valid == 1, registers.inject_error_code)
		direct(block + CONTROL_EVENT_INJECTION, u64)^ = injection
		processor.pending_injection = {event = injection, address = registers.rip}
		injected = true
	case .None, .Wait, .Open_Window, .Wait_Then_Window:
	}
	// Each run sets the window again: a window of an earlier run that the
	// guest did not open must not end this run.
	guest_rules.interrupt_window_write(direct(block, [guest_rules.CONTROL_BLOCK_BYTES]u8)[:], guest_rules.interrupt_window_open(service))

	cpu := processor_self()
	exit: Guest_Exit
	pages_given := 0
	for {
		exit = guest_enter_once(cpu, thread, processor, guest_process, &registers)
		if exit.code == GUEST_EXIT_MACHINE_CHECK {
			fault_report_begin()
			log("kernel: machine check while a guest of process ", Module_Name{process_name(caller)}, " ran: a fault of the machine, not of the guest: the machine stops")
			machine_stop(.Fault)
		}
		if exit.code == GUEST_EXIT_NESTED_PAGE_FAULT && exit.information_1 & FAULT_RESERVED_BIT != 0 {
			// The guest can perhaps cause it with an address past the
			// width of the nested table: an exit that a guest can cause
			// never stops the machine. The run ends, and the process gets
			// the exit of a memory fault.
			// One line at each power of two of the count, as the faults of
			// a device: a guest repeats it at each run.
			reserved_faults := intrinsics.atomic_add(&guest_reserved_bit_faults, 1) + 1
			if reserved_faults & (reserved_faults - 1) == 0 do log("kernel: a nested page fault with the reserved bit (", reserved_faults, " in all) in a guest of process ", Module_Name{process_name(caller)}, ": error ", Hex(exit.information_1), " guest address ", Hex(exit.information_2), "; the run ends")
			break
		}
		if exit.code != GUEST_EXIT_NESTED_PAGE_FAULT || intrinsics.atomic_load(&thread.stop_requested) {
			break
		}
		// A page on first use of a mapping of the guest, as for a process,
		// or the switch of a page of a switching mapping
		// (src/md/features/guest.md, "The switch of a page").
		write := exit.information_1 & FAULT_WRITE != 0
		execute := exit.information_1 & FAULT_EXECUTE != 0
		page_taken := process_lock(guest_index)
		running := guest_process.state == .Created
		answer := Guest_Page_Answer.Refused
		if running {
			answer = guest_page_answer(guest_process, exit.information_2, write, execute)
		}
		if answer == .Switched {
			guest.page_switches += 1
		}
		process_unlock(guest_index, page_taken)
		if !running {
			exit = {code = GUEST_EXIT_INTERRUPT} // The process stopped: the run ends with nothing to answer.
			break
		}
		if answer == .Refused {
			break
		}
		// The page switched back at the same instruction twice in a row: the
		// instruction writes the page that holds it, and never completes.
		counts := guest_rules.switch_counts(exit.information_1, direct(processor.control_block + CONTROL_EXIT_EVENT, u64)^)
		if answer == .Switched && !counts {
			guest_rules.switch_watch_forget(&processor.switch_watch)
		}
		if answer == .Switched && counts && guest_rules.switch_watch_note(&processor.switch_watch, exit.information_2 &~ u64(PAGE_SIZE - 1), registers.rip, registers.cr3, write) {
			exit.writes_own_page = true
			exit.code_64 = registers.efer & op.GUEST_EFER_LONG_MODE_ACTIVE != 0 && direct(processor.control_block + STATE_SEGMENT_CS + 2, u16)^ & guest_rules.SEGMENT_LONG != 0
			break
		}
		pages_given += 1
		if pages_given == GUEST_PAGES_IN_ONE_RUN {
			exit = {code = GUEST_EXIT_INTERRUPT}
			break
		}
	}

	// The process learns that the next entry delivers an event first, so
	// that it knows why its request waits, and that the guest lost none.
	// Read once after the last entry, on each path out of the loop: a run
	// that a stop ended before its entry gives the word too.
	registers.event_pending = direct(block + CONTROL_EVENT_INJECTION, u64)^ & guest_rules.EVENT_VALID != 0 ? 1 : 0

	// A served request leaves the record. After a refused state, the
	// processor delivered nothing and the kernel dropped the event: the
	// request stays, so that the process sees it.
	if mode_loaded {
		registers.mode_load = u8(op.Guest_Mode_Load.Keep)
	}
	if injected && exit.code != GUEST_EXIT_REFUSED_STATE {
		registers.inject_kind = u8(op.Guest_Inject_Kind.None)
		registers.inject_vector = 0
		registers.inject_error_code_valid = 0
		registers.inject_error_code = 0
	}

	release_taken := process_lock(guest_index)
	if exit.writes_own_page {
		guest.own_page_writes += 1
	}
	processor.running = false
	process_unlock(guest_index, release_taken)
	// A stop of the guest process during the run waited for this hold.
	if process_leave(guest_index) {
		control_take()
		process_cleanup(guest_index)
		control_free()
	}

	guest_exit_results(exit, &registers, results)
	caller_taken = process_lock(caller_index)
	writable := user_range(caller, v[1], size_of(op.Guest_Registers), true)
	if writable {
		user_copy_to_process(v[1], &registers, size_of(registers))
	}
	process_unlock(caller_index, caller_taken)
	if !writable {
		results^ = {}
		return .Argument_Refused
	}
	return .Succeeded
}

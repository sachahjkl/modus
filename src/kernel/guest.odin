package kernel

import "base:intrinsics"
import op "modus:contract/operation"

// A guest (src/md/features/guest.md; docs/ARCHITECTURE.md, "A guest"): a
// program whose page table is the nested page table of a guest processor,
// and the operation Guest_Run that runs that processor on the calling
// thread. This is the AMD form (SVM): the control block of the processor
// (the VMCB) and the instructions vmrun, vmload and vmsave (guest_enter in
// processor.asm). The kernel holds the mechanism only: no exit is emulated
// here but the page on first use; each other exit goes back to the program.

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
STATE_EFER :: 0x4D0
STATE_CR0 :: 0x558
STATE_DR7 :: 0x560
STATE_DR6 :: 0x568
STATE_RFLAGS :: 0x570
STATE_RIP :: 0x578
STATE_RSP :: 0x5D8
STATE_RAX :: 0x5F8
STATE_PAGE_ATTRIBUTES :: 0x668 // The page attribute table of the guest under nested paging.

// What the guest may not do alone. The first vector: the interrupt, the
// non-maskable interrupt, the system management interrupt and INIT of the
// machine (0 to 3), rdpmc (15), cpuid (18), invd (22), hlt (24), invlpga
// (26), each port (27), each model-specific register (28) and the shutdown
// (31). rdpmc would read the performance counters of the machine, which
// count the work of the kernel and of other programs.
INTERCEPT_INSTRUCTIONS :: u32(1 << 0 | 1 << 1 | 1 << 2 | 1 << 3 | 1 << 15 | 1 << 18 | 1 << 22 | 1 << 24 | 1 << 26 | 1 << 27 | 1 << 28 | 1 << 31)
// The second vector: vmrun (which the processor requires), vmmcall, vmload,
// vmsave, stgi, clgi, skinit (0 to 6), wbinvd (9), monitor, mwait and its
// conditional form (10 to 12), xsetbv (13). xsetbv would change the XCR0 of
// the kernel, which the exit does not restore.
INTERCEPT_MORE_INSTRUCTIONS :: u32(0b111_1111 | 1 << 9 | 1 << 10 | 1 << 11 | 1 << 12 | 1 << 13)
// Each read and each write of a debug register: the exit does not restore
// DR0 to DR3, which hold the breakpoints of threads.
INTERCEPT_DEBUG_REGISTERS :: u32(0xFFFF_FFFF)
// The machine check: a fault of the machine, which stops it, as in a program.
// The alignment check and the debug exception: a guest that owns its
// descriptor table and its stack can make the delivery of one of them raise
// it again, so the processor loops in the delivery, takes no interrupt and
// never exits; each processor that then waits for it stops too. Each one
// exits, and the program gets it as an exit of the kind Other.
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
// The attributes of a segment: bits 0 to 3 the type, bit 4 code or data,
// bit 7 present.
SEGMENT_CODE :: u16(0x9B) // Present, code, readable, accessed.
SEGMENT_DATA :: u16(0x93) // Present, data, writable, accessed.
SEGMENT_LOCAL_TABLE :: u16(0x82) // Present, a local descriptor table.
SEGMENT_TASK :: u16(0x8B) // Present, a busy task state of 32 bits.
CR0_OF_A_GUEST_AT_START :: u64(CR0_EXTENSION_TYPE) // Real mode, caches on.
FLAGS_ALWAYS_SET :: u64(1) << 1

// The exit codes (the AMD manual, volume 2, appendix C, "SVM Intercept
// Exit Codes").
GUEST_EXIT_MACHINE_CHECK :: u64(0x40 + VECTOR_MACHINE_CHECK)
GUEST_EXIT_INTERRUPT :: u64(0x60)
GUEST_EXIT_NON_MASKABLE_INTERRUPT :: u64(0x61)
GUEST_EXIT_MANAGEMENT_INTERRUPT :: u64(0x62)
GUEST_EXIT_INIT :: u64(0x63)
GUEST_EXIT_CPUID :: u64(0x72)
GUEST_EXIT_HALT :: u64(0x78)
GUEST_EXIT_PORT :: u64(0x7B)
GUEST_EXIT_SHUTDOWN :: u64(0x7F)
GUEST_EXIT_NESTED_PAGE_FAULT :: u64(0x400)
GUEST_EXIT_REFUSED_STATE :: max(u64) // VMEXIT_INVALID: -1.

// An event in EXITINTINFO and in EVENTINJ: bits 0 to 7 the vector, 8 to 10
// the type, bit 31 valid.
EVENT_VALID :: u64(1) << 31
EVENT_TYPE_EXTERNAL_INTERRUPT :: 0
EVENT_TYPE_NON_MASKABLE_INTERRUPT :: 2
EVENT_TYPE_EXCEPTION :: 3
GUEST_VECTOR_BREAKPOINT :: 3 // int3: an instruction, which runs again.
GUEST_VECTOR_OVERFLOW :: 4 // into: an instruction, which runs again.

// guest_event_to_deliver_again gives the event that an exit interrupted,
// for the next entry, or 0. An exit can come while the guest delivers an
// event: a page on first use of its interrupt table or of its stack, or an
// interrupt of the machine. The next entry delivers it again, so the guest
// loses none. An event of an instruction (int n, int3, into) is not given:
// the guest is still at that instruction, which runs again.
guest_event_to_deliver_again :: proc "contextless" (event: u64) -> u64 {
	if event & EVENT_VALID == 0 {
		return 0
	}
	kind := event >> 8 & 0b111
	vector := event & 0xFF
	switch {
	case kind == EVENT_TYPE_EXTERNAL_INTERRUPT || kind == EVENT_TYPE_NON_MASKABLE_INTERRUPT:
		return event
	case kind == EVENT_TYPE_EXCEPTION && vector != GUEST_VECTOR_BREAKPOINT && vector != GUEST_VECTOR_OVERFLOW:
		return event
	}
	return 0
}

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
// before any program runs.
Guest_Support :: struct {
	ready:               bool, // Each processor that runs threads can run a guest.
	next_instruction:    bool, // NRIPS: the exit gives the address after the instruction.
	flush_by_identifier: bool, // FlushByAsid: an entry can flush the guest only.
	identifiers:         u32, // The address space identifiers of the processor.
	refusal:             string, // Why no guest runs: a line of the log.
}
guest_support: Guest_Support

guest_port_map: u64 // Physical: GUEST_PORT_MAP_PAGES pages of ones.
guest_register_map: u64 // Physical: GUEST_REGISTER_MAP_PAGES pages of ones.
// For each processor, the page where guest_enter keeps the fs, gs, task and
// system call state of the kernel (vmsave), and the page of the processor
// for vmrun (MSR_HOST_SAVE_AREA). Physical.
guest_host_areas: [PROCESSOR_CAPACITY]u64
guest_host_save_areas: [PROCESSOR_CAPACITY]u64
// For each processor, the nested page table of the guest that it runs now,
// or 0 (atomic). processors_with_table reads it: an unmap in a guest program
// reaches the processor that runs the guest, whose cr3 is another table.
guest_tables_running: [PROCESSOR_CAPACITY]u64

// The guest processor of a program, by the index of the program. One for
// each program slot: a guest is a program.
Guest :: struct {
	program_serial: u32, // The serial of the program that is this guest. 0: no guest in the slot.
	running:        bool, // A thread runs the guest processor now. Program lock of the guest.
	control_block:  u64, // Physical: the control block of the guest processor, one page.
	state_area:     u64, // Physical: the extended state of the guest processor, one page.
}
guests: [PROGRAM_CAPACITY]Guest

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

foreign _ {
	// The entry of a guest processor, with interrupts on and held by clgi,
	// until its exit. It saves and loads the state that the exit does not
	// restore (processor.asm).
	guest_enter :: proc "c" (control_block: u64, general: ^Guest_General_Registers, host_area: u64) ---
}

// One exit of a guest processor, as the control block gives it.
Guest_Exit :: struct {
	code:          u64,
	information_1: u64,
	information_2: u64,
	next:          u64, // The address after the instruction of the exit, from the processor; 0 without next_instruction.
}

// guest_support_read says what the processor that runs it can do for a
// guest.
guest_support_read :: proc "contextless" () -> (support: Guest_Support) {
	highest, _, _, _ := intrinsics.x86_cpuid(0x8000_0000, 0)
	if highest < 0x8000_000A {
		support.refusal = "the processor has no SVM"
		return
	}
	_, _, extended_features, _ := intrinsics.x86_cpuid(0x8000_0001, 0)
	if extended_features & (1 << 2) == 0 {
		support.refusal = "the processor has no SVM"
		return
	}
	// The register exists on each processor with SVM.
	if model_specific_register_read(MSR_VIRTUAL_MACHINE_CONTROL) & VIRTUAL_MACHINE_CONTROL_DISABLED != 0 {
		support.refusal = "the firmware turned SVM off"
		return
	}
	_, identifiers, _, features := intrinsics.x86_cpuid(0x8000_000A, 0)
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
// of each processor, before any program.
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

// program_is_guest says if a program is a guest now: Program_Start refuses
// it, because its page table has no kernel half. The caller holds the
// program lock.
program_is_guest :: proc "contextless" (index: u32) -> bool {
	serial := guests[index].program_serial
	return serial != 0 && serial == programs[index].serial
}

// guest_segment_write writes one segment of the state of a guest processor:
// the selector 0, the base 0 and the limit of 64 KiB of real mode.
guest_segment_write :: proc "contextless" (block: u64, offset: u64, attributes: u16) {
	direct(block + offset, u16)^ = 0
	direct(block + offset + 2, u16)^ = attributes
	direct(block + offset + 4, u32)^ = 0xFFFF
	direct(block + offset + 8, u64)^ = 0
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
	guest_segment_write(block, STATE_SEGMENT_ES, SEGMENT_DATA)
	guest_segment_write(block, STATE_SEGMENT_SS, SEGMENT_DATA)
	guest_segment_write(block, STATE_SEGMENT_DS, SEGMENT_DATA)
	guest_segment_write(block, STATE_SEGMENT_FS, SEGMENT_DATA)
	guest_segment_write(block, STATE_SEGMENT_GS, SEGMENT_DATA)
	guest_segment_write(block, STATE_SEGMENT_CS, SEGMENT_CODE)
	guest_segment_write(block, STATE_SEGMENT_GDTR, 0)
	guest_segment_write(block, STATE_SEGMENT_IDTR, 0)
	guest_segment_write(block, STATE_SEGMENT_LDTR, SEGMENT_LOCAL_TABLE)
	guest_segment_write(block, STATE_SEGMENT_TR, SEGMENT_TASK)
	// vmrun refuses a guest with SVME clear in its EFER.
	direct(block + STATE_EFER, u64)^ = EFER_SECURE_VIRTUAL_MACHINE
	direct(block + STATE_CR0, u64)^ = CR0_OF_A_GUEST_AT_START
	direct(block + STATE_DR7, u64)^ = DR7_NO_BREAKPOINT
	direct(block + STATE_DR6, u64)^ = DR6_CLEAR
	direct(block + STATE_RFLAGS, u64)^ = FLAGS_ALWAYS_SET
	direct(block + STATE_PAGE_ATTRIBUTES, u64)^ = PAGE_ATTRIBUTES_AT_RESET
}

// guest_frame_return gives a page that the budget of a program paid back to
// that budget, as address_space_free does for a table.
guest_frame_return :: proc "contextless" (program: ^Program, frame: u64) {
	lock_take(&frame_lock, .Frame)
	frames_free_held(frame, 1)
	budgets[program.budget].amounts.pages += 1
	lock_free(&frame_lock, .Frame)
}

// guest_create makes a program a guest, at its first Guest_Run: the budget
// of the program pays the control block and the extended state; the time
// page leaves the program, and the kernel half leaves its top table, so
// that the guest reaches only what its program mapped. Nothing changes when
// the budget cannot pay. The caller holds the program lock; the program is
// Created, with no thread.
guest_create :: proc "contextless" (index: u32) -> op.Status {
	program := &programs[index]
	control_block := frame_paid(&program.budget)
	if control_block == 0 {
		return .No_Budget
	}
	state_area := frame_paid(&program.budget)
	if state_area == 0 {
		guest_frame_return(program, control_block)
		return .No_Budget
	}
	extended_state_start(direct(state_area, Extended_State_Area))
	guest_control_block_write(control_block, program.table)
	for &mapping in program.mappings {
		if mapping.page_count != 0 && mapping.address == op.TIME_ADDRESS {
			unmap(program, &mapping)
			break
		}
	}
	// No processor uses this table as its cr3: the program has no thread,
	// and Program_Start refuses it from now.
	for &entry in direct(program.table, [512]u64)^[256:] {
		entry = 0
	}
	guests[index] = {program_serial = program.serial, control_block = control_block, state_area = state_area}
	return .Ok
}

// guest_end gives back the pages of the guest of a program that ends. The
// caller is program_cleanup, with the program lock: no run holds the
// program any more.
guest_end :: proc "contextless" (index: u32) {
	if !program_is_guest(index) {
		return
	}
	guest := &guests[index]
	guest_frame_return(&programs[index], guest.control_block)
	guest_frame_return(&programs[index], guest.state_area)
	guest^ = {}
}

// guest_enter_once enters the guest processor once, with the registers of
// the record, and gives its exit; the record has the registers after the
// exit. The extended state of the thread leaves the processor during the
// guest, and comes back after it: the kernel has no vector instruction of
// its own, so the registers of the thread are live here.
guest_enter_once :: proc "contextless" (cpu: ^Processor, thread: ^Thread, guest: ^Guest, program: ^Program, registers: ^op.Guest_Registers) -> (exit: Guest_Exit) {
	// Before the entry, and seen by an unmap that cleared its entries, or
	// by a stop: then either the unmap or the stop sends its interrupt
	// here, or this entry sees what it wrote: the cleared entries, or the
	// state Stopped below (processors_with_table, program_stop). Each side
	// writes, then reads the word of the other side.
	intrinsics.atomic_store(&guest_tables_running[cpu.index], program.table)
	if intrinsics.atomic_load(&program.state) == .Stopped {
		intrinsics.atomic_store(&guest_tables_running[cpu.index], 0)
		return {code = GUEST_EXIT_INTERRUPT} // The program stopped: no instruction of the guest runs after its stop.
	}
	block := guest.control_block
	direct(block + STATE_RAX, u64)^ = registers.rax
	direct(block + STATE_RSP, u64)^ = registers.rsp
	direct(block + STATE_RIP, u64)^ = registers.rip
	direct(block + STATE_RFLAGS, u64)^ = registers.rflags | FLAGS_ALWAYS_SET
	// Every guest has one identifier, and a guest can run on another
	// processor than before: each entry flushes its translations.
	direct(block + CONTROL_TRANSLATION_FLUSH, u8)^ = guest_support.flush_by_identifier ? TRANSLATION_FLUSH_THE_GUEST : TRANSLATION_FLUSH_ALL
	direct(block + CONTROL_CLEAN, u32)^ = 0
	general := Guest_General_Registers {
		rbx = registers.rbx, rcx = registers.rcx, rdx = registers.rdx, rsi = registers.rsi, rdi = registers.rdi, rbp = registers.rbp,
		r8 = registers.r8, r9 = registers.r9, r10 = registers.r10, r11 = registers.r11, r12 = registers.r12, r13 = registers.r13, r14 = registers.r14, r15 = registers.r15,
	}
	state_area := direct(guest.state_area, Extended_State_Area)
	extended_state_save(&thread.extended_state, extended_state_form)
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
	registers^ = {
		rax = direct(block + STATE_RAX, u64)^, rbx = general.rbx, rcx = general.rcx, rdx = general.rdx,
		rsi = general.rsi, rdi = general.rdi, rbp = general.rbp, rsp = direct(block + STATE_RSP, u64)^,
		r8 = general.r8, r9 = general.r9, r10 = general.r10, r11 = general.r11,
		r12 = general.r12, r13 = general.r13, r14 = general.r14, r15 = general.r15,
		rip = direct(block + STATE_RIP, u64)^,
		rflags = direct(block + STATE_RFLAGS, u64)^ & op.GUEST_FLAGS_DEFINED,
	}
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
	direct(block + CONTROL_EVENT_INJECTION, u64)^ = guest_event_to_deliver_again(direct(block + CONTROL_EXIT_EVENT, u64)^)
	// An interrupt of another processor that waits in processor_sync is
	// held until the return to the program: the answer comes now.
	sync_acknowledge(cpu)
	return exit
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
	switch exit.code {
	case GUEST_EXIT_PORT:
		information := exit.information_1
		if information & (PORT_STRING | PORT_REPEAT) != 0 {
			break // A string of ports reads or writes guest memory: the program decodes it (Other).
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
	case GUEST_EXIT_SHUTDOWN:
		kind = .Shutdown
	case GUEST_EXIT_REFUSED_STATE:
		kind = .Refused_State
	}
	results[0] = u64(kind)
	results[5] = exit.code
	results[6] = exit.information_1
}

// guest_run runs the operation Guest_Run (src/md/features/guest.md, "The
// run, step by step"). It takes its own locks: the lock of the caller for
// the handle and the record, the lock of the guest program for its state and
// for each page on first use, and no lock while the guest runs. A run holds
// the guest program as a thread on a processor holds its program: a stop
// during the run cleans the program up after it.
guest_run :: proc "contextless" (index: u32, v: [7]u64, results: ^[7]u64) -> op.Status {
	if !intrinsics.atomic_load(&guest_support.ready) {
		return .Bad_Operation
	}
	thread := &threads[index]
	caller_index := thread.program
	caller := &programs[caller_index]
	registers: op.Guest_Registers
	guest_index, guest_serial: u32
	caller_taken := program_lock(caller_index)
	slot, found := handle_find(caller, v[0], .Program, {.Control})
	readable := found == .Ok && user_range(caller, v[1], size_of(op.Guest_Registers), true)
	if readable {
		// A copy, checked after: the program can change its memory meanwhile.
		user_copy(&registers, rawptr(uintptr(v[1])), size_of(registers))
		guest_index = slot.object
		// The handle holds the program: its slot serves no other program
		// while the handle lives.
		guest_serial = intrinsics.atomic_load(&programs[guest_index].serial)
	}
	program_unlock(caller_index, caller_taken)
	if found != .Ok {
		return found
	}
	if !readable {
		return .Bad_Address
	}
	if guest_index == caller_index {
		return .Bad_State
	}
	if op.guest_registers_refusal(registers) {
		return .Bad_Operation
	}

	guest_program := &programs[guest_index]
	guest := &guests[guest_index]
	guest_taken := program_lock(guest_index)
	// The handle can have closed since: the serial names the program.
	if intrinsics.atomic_load(&guest_program.serial) != guest_serial || guest_program.state != .Created || guest_program.thread_count != 0 {
		program_unlock(guest_index, guest_taken)
		return .Bad_State
	}
	if !program_is_guest(guest_index) {
		if status := guest_create(guest_index); status != .Ok {
			program_unlock(guest_index, guest_taken)
			return status
		}
	}
	if guest.running {
		program_unlock(guest_index, guest_taken)
		return .Bad_State // One guest processor: one thread runs it at a time.
	}
	guest.running = true
	intrinsics.atomic_add(&guest_program.holds, 1)
	program_unlock(guest_index, guest_taken)

	cpu := processor_self()
	exit: Guest_Exit
	pages_given := 0
	for {
		exit = guest_enter_once(cpu, thread, guest, guest_program, &registers)
		if exit.code == GUEST_EXIT_MACHINE_CHECK {
			fault_report_begin()
			log("kernel: machine check while a guest of program ", Module_Name{program_name(caller)}, " ran: a fault of the machine, not of the guest: the machine stops")
			machine_stop(2)
		}
		if exit.code == GUEST_EXIT_NESTED_PAGE_FAULT && exit.information_1 & FAULT_RESERVED_BIT != 0 {
			// The guest can perhaps cause it with an address past the
			// width of the nested table: an exit that a guest can cause
			// never stops the machine. The run ends, and the program gets
			// the exit of a memory fault.
			log("kernel: a nested page fault with the reserved bit in a guest of program ", Module_Name{program_name(caller)}, ": error ", Hex(exit.information_1), " guest address ", Hex(exit.information_2), "; the run ends")
			break
		}
		if exit.code != GUEST_EXIT_NESTED_PAGE_FAULT || intrinsics.atomic_load(&thread.stop_requested) {
			break
		}
		// A page on first use of a mapping of the guest, as for a program.
		page_taken := program_lock(guest_index)
		running := guest_program.state == .Created
		given := running && page_give(guest_program, exit.information_2, exit.information_1 & FAULT_WRITE != 0, exit.information_1 & FAULT_EXECUTE != 0)
		program_unlock(guest_index, page_taken)
		if !running {
			exit = {code = GUEST_EXIT_INTERRUPT} // The program stopped: the run ends with nothing to answer.
			break
		}
		if !given {
			break
		}
		pages_given += 1
		if pages_given == GUEST_PAGES_IN_ONE_RUN {
			exit = {code = GUEST_EXIT_INTERRUPT}
			break
		}
	}

	release_taken := program_lock(guest_index)
	guest.running = false
	program_unlock(guest_index, release_taken)
	// A stop of the guest program during the run waited for this hold.
	if program_leave(guest_index) {
		control_take()
		program_cleanup(guest_index)
		control_free()
	}

	guest_exit_results(exit, &registers, results)
	caller_taken = program_lock(caller_index)
	writable := user_range(caller, v[1], size_of(op.Guest_Registers), true)
	if writable {
		user_copy(rawptr(uintptr(v[1])), &registers, size_of(registers))
	}
	program_unlock(caller_index, caller_taken)
	if !writable {
		results^ = {}
		return .Bad_Address
	}
	return .Ok
}

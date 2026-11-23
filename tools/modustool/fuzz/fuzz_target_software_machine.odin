package fuzz

import "core:mem"
import "core:slice"
import "modus:contract/software_machine"

// The fuzz target of the software processor (src/md/features/browser_machine.md,
// "The software MMU"): the browser machine runs the x86-64 code of a
// module through page tables in a slice of memory, so any byte stream must
// end each step with a clean outcome, and must write no byte that its pages
// do not let it write. The input is the sixteen general registers, then the
// code of two pages.

// The machine of the target: frames of one memory, each with one role. A
// frame index is a place in the memory, so it stays a constant.
FUZZ_MACHINE_FRAME_COUNT :: 12
FUZZ_MACHINE_MEMORY_BYTES :: FUZZ_MACHINE_FRAME_COUNT * int(software_machine.PAGE_SIZE)
FUZZ_MACHINE_FRAME_LEVEL_4 :: 1 // The root of the page tables.
FUZZ_MACHINE_FRAME_LEVEL_3 :: 2
FUZZ_MACHINE_FRAME_LEVEL_2 :: 3
FUZZ_MACHINE_FRAME_LEVEL_1 :: 4
FUZZ_MACHINE_FRAME_CODE :: 5 // Two frames: the code, readable and executable.
FUZZ_MACHINE_FRAME_DATA :: 7 // Writable, not executable.
FUZZ_MACHINE_FRAME_READ_ONLY :: 8
FUZZ_MACHINE_FRAME_SUPERVISOR :: 9 // Writable, but not for the user.
FUZZ_MACHINE_FRAME_STACK :: 10 // Writable, not executable.
FUZZ_MACHINE_FRAME_UNMAPPED :: 11 // In the memory, in no page table.

// The virtual places: the pages follow each other from the code, with one
// hole before the stack and none after it.
FUZZ_MACHINE_CODE_ADDRESS :: u64(0x40_0000)
FUZZ_MACHINE_DATA_ADDRESS :: u64(0x40_2000)
FUZZ_MACHINE_READ_ONLY_ADDRESS :: u64(0x40_3000)
FUZZ_MACHINE_SUPERVISOR_ADDRESS :: u64(0x40_4000)
FUZZ_MACHINE_STACK_ADDRESS :: u64(0x40_6000)
FUZZ_MACHINE_STACK_TOP :: FUZZ_MACHINE_STACK_ADDRESS + software_machine.PAGE_SIZE

FUZZ_MACHINE_REGISTER_BYTES :: 16 * size_of(u64)
FUZZ_MACHINE_CODE_BYTES :: 2 * int(software_machine.PAGE_SIZE)
FUZZ_MACHINE_INPUT_LIMIT :: FUZZ_MACHINE_REGISTER_BYTES + FUZZ_MACHINE_CODE_BYTES
// The steps of one execution: a loop of the input meets the budget.
FUZZ_MACHINE_STEP_LIMIT :: 256
// The fill of the code after the input: a breakpoint, so a short input
// ends with a trap and not with the zero bytes of an add.
FUZZ_MACHINE_CODE_FILL :: u8(0xCC)
// The fill of the other frames: a byte that no page table and no step writes.
FUZZ_MACHINE_FRAME_FILL :: u8(0xA5)

// The flags that a user step can hold: the arithmetic flags, the
// direction, and the two bits that are always set.
FUZZ_MACHINE_FLAGS_KNOWN :: software_machine.RFLAGS_CF | software_machine.RFLAGS_RESERVED_ONE | software_machine.RFLAGS_PF | software_machine.RFLAGS_AF | software_machine.RFLAGS_ZF | software_machine.RFLAGS_SF | software_machine.RFLAGS_IF | software_machine.RFLAGS_DF | software_machine.RFLAGS_OF
FUZZ_MACHINE_FAULT_BITS_KNOWN :: software_machine.PAGE_FAULT_PRESENT | software_machine.PAGE_FAULT_WRITE | software_machine.PAGE_FAULT_USER | software_machine.PAGE_FAULT_RESERVED | software_machine.PAGE_FAULT_INSTRUCTION

// Two machines: one steps one instruction at a time, the other runs the
// budget in one call, with a cache of decoded blocks, so each input also
// compares the decoded blocks with the steps. The memories are large for
// the stack of an execution.
@(private = "file")
fuzz_machine_state: struct {
	memory:         [FUZZ_MACHINE_MEMORY_BYTES]u8,
	initial:        [FUZZ_MACHINE_MEMORY_BYTES]u8,
	before_fault:   [FUZZ_MACHINE_MEMORY_BYTES]u8,
	run_memory:     [FUZZ_MACHINE_MEMORY_BYTES]u8,
	processor:      software_machine.Processor_State,
	before_step:    software_machine.Processor_State,
	run_processor:  software_machine.Processor_State,
	run_blocks:     software_machine.Block_Cache,
}

@(private = "file")
fuzz_machine_frame :: proc(memory: []u8, frame: int) -> []u8 {
	size := int(software_machine.PAGE_SIZE)
	return memory[frame * size:][:size]
}

@(private = "file")
fuzz_machine_entry_write :: proc(memory: []u8, table_frame: int, index: u64, value: u64) {
	entry := value
	mem.copy(&fuzz_machine_frame(memory, table_frame)[index * 8], &entry, size_of(entry))
}

@(private = "file")
fuzz_machine_map :: proc(memory: []u8, virtual_address: u64, frame: int, flags: u64) {
	index := (virtual_address >> 12) & software_machine.PAGE_TABLE_INDEX_MASK
	fuzz_machine_entry_write(memory, FUZZ_MACHINE_FRAME_LEVEL_1, index, u64(frame) * software_machine.PAGE_SIZE | flags)
}

// fuzz_machine_build writes the page tables, the code of the input and the
// fill of each other frame. The three upper levels each hold one entry,
// so each page of the target is in the one table of the last level.
@(private = "file")
fuzz_machine_build :: proc(memory: []u8, code: []u8) {
	slice.fill(memory, FUZZ_MACHINE_FRAME_FILL)
	for frame in ([?]int{FUZZ_MACHINE_FRAME_LEVEL_4, FUZZ_MACHINE_FRAME_LEVEL_3, FUZZ_MACHINE_FRAME_LEVEL_2, FUZZ_MACHINE_FRAME_LEVEL_1}) {
		slice.zero(fuzz_machine_frame(memory, frame))
	}
	upper := software_machine.PAGE_PRESENT | software_machine.PAGE_WRITE | software_machine.PAGE_USER
	fuzz_machine_entry_write(memory, FUZZ_MACHINE_FRAME_LEVEL_4, (FUZZ_MACHINE_CODE_ADDRESS >> 39) & software_machine.PAGE_TABLE_INDEX_MASK, FUZZ_MACHINE_FRAME_LEVEL_3 * software_machine.PAGE_SIZE | upper)
	fuzz_machine_entry_write(memory, FUZZ_MACHINE_FRAME_LEVEL_3, (FUZZ_MACHINE_CODE_ADDRESS >> 30) & software_machine.PAGE_TABLE_INDEX_MASK, FUZZ_MACHINE_FRAME_LEVEL_2 * software_machine.PAGE_SIZE | upper)
	fuzz_machine_entry_write(memory, FUZZ_MACHINE_FRAME_LEVEL_2, (FUZZ_MACHINE_CODE_ADDRESS >> 21) & software_machine.PAGE_TABLE_INDEX_MASK, FUZZ_MACHINE_FRAME_LEVEL_1 * software_machine.PAGE_SIZE | upper)
	fuzz_machine_map(memory, FUZZ_MACHINE_CODE_ADDRESS, FUZZ_MACHINE_FRAME_CODE, software_machine.PAGE_PRESENT | software_machine.PAGE_USER)
	fuzz_machine_map(memory, FUZZ_MACHINE_CODE_ADDRESS + software_machine.PAGE_SIZE, FUZZ_MACHINE_FRAME_CODE + 1, software_machine.PAGE_PRESENT | software_machine.PAGE_USER)
	fuzz_machine_map(memory, FUZZ_MACHINE_DATA_ADDRESS, FUZZ_MACHINE_FRAME_DATA, software_machine.PAGE_PRESENT | software_machine.PAGE_WRITE | software_machine.PAGE_USER | software_machine.PAGE_NO_EXECUTE)
	fuzz_machine_map(memory, FUZZ_MACHINE_READ_ONLY_ADDRESS, FUZZ_MACHINE_FRAME_READ_ONLY, software_machine.PAGE_PRESENT | software_machine.PAGE_USER | software_machine.PAGE_NO_EXECUTE)
	fuzz_machine_map(memory, FUZZ_MACHINE_SUPERVISOR_ADDRESS, FUZZ_MACHINE_FRAME_SUPERVISOR, software_machine.PAGE_PRESENT | software_machine.PAGE_WRITE | software_machine.PAGE_NO_EXECUTE)
	fuzz_machine_map(memory, FUZZ_MACHINE_STACK_ADDRESS, FUZZ_MACHINE_FRAME_STACK, software_machine.PAGE_PRESENT | software_machine.PAGE_WRITE | software_machine.PAGE_USER | software_machine.PAGE_NO_EXECUTE)
	code_frames := memory[FUZZ_MACHINE_FRAME_CODE * int(software_machine.PAGE_SIZE):][:FUZZ_MACHINE_CODE_BYTES]
	slice.fill(code_frames, FUZZ_MACHINE_CODE_FILL)
	copy(code_frames, code)
}

@(private = "file")
fuzz_machine_is_page_table :: proc(frame: int) -> bool {
	return frame >= FUZZ_MACHINE_FRAME_LEVEL_4 && frame <= FUZZ_MACHINE_FRAME_LEVEL_1
}

// fuzz_machine_memory_problem compares a memory with an earlier one: a
// frame that the user cannot write keeps its bytes, and an entry of a page
// table gains at most its accessed and dirty bits. With no write allowed,
// the writable frames keep their bytes too.
@(private = "file")
fuzz_machine_memory_problem :: proc(now, earlier: []u8, writes_allowed: bool) -> string {
	for frame in 0 ..< FUZZ_MACHINE_FRAME_COUNT {
		now_frame := fuzz_machine_frame(now, frame)
		earlier_frame := fuzz_machine_frame(earlier, frame)
		if fuzz_machine_is_page_table(frame) {
			for index in 0 ..< int(software_machine.PAGE_TABLE_ENTRY_COUNT) {
				now_entry, earlier_entry: u64
				mem.copy(&now_entry, &now_frame[index * 8], 8)
				mem.copy(&earlier_entry, &earlier_frame[index * 8], 8)
				if now_entry & ~(software_machine.PAGE_ACCESSED | software_machine.PAGE_DIRTY) != earlier_entry & ~(software_machine.PAGE_ACCESSED | software_machine.PAGE_DIRTY) || earlier_entry & (software_machine.PAGE_ACCESSED | software_machine.PAGE_DIRTY) & ~now_entry != 0 {
					return fuzz_broken(.Contract, "the entry %d of the page table in the frame %d went from %x to %x", index, frame, earlier_entry, now_entry).text
				}
			}
			continue
		}
		if writes_allowed && (frame == FUZZ_MACHINE_FRAME_DATA || frame == FUZZ_MACHINE_FRAME_STACK) {
			continue
		}
		if !slice.equal(now_frame, earlier_frame) {
			return fuzz_broken(.Contract, "the frame %d changed (writes allowed: %v)", frame, writes_allowed).text
		}
	}
	return ""
}

@(private = "file")
fuzz_machine_is_fault :: proc(outcome: software_machine.Step_Outcome) -> bool {
	switch outcome {
	case .Page_Fault, .General_Protection, .Invalid_Opcode, .Divide_Error, .Simd_Floating_Point:
		return true
	case .Running, .Syscall, .Breakpoint, .Step_Budget_Exhausted, .Halted:
		return false
	}
	return false
}

@(private = "file")
fuzz_machine_same_architectural_state :: proc(a, b: ^software_machine.Processor_State) -> bool {
	return a.registers == b.registers && a.rip == b.rip && a.rflags == b.rflags && a.cr3 == b.cr3 && a.gs_base == b.gs_base && a.xmm == b.xmm && a.mxcsr == b.mxcsr
}

// fuzz_machine_same_state_after_fault: a fault changes no register; an
// unmasked exception of a vector instruction also sets its flags in MXCSR,
// and only them.
@(private = "file")
fuzz_machine_same_state_after_fault :: proc(after, before: ^software_machine.Processor_State, outcome: software_machine.Step_Outcome) -> bool {
	if outcome != .Simd_Floating_Point {
		return fuzz_machine_same_architectural_state(after, before)
	}
	flags := u32(0x3F)
	if after.mxcsr & ~flags != before.mxcsr & ~flags || before.mxcsr & flags & ~after.mxcsr != 0 {
		return false
	}
	same := after^
	same.mxcsr = before.mxcsr
	return fuzz_machine_same_architectural_state(&same, before)
}

// fuzz_software_machine_execute: each step ends with an outcome of its
// enumeration; a step that runs or traps counts one step, keeps the flags
// valid and leaves a canonical place; a fault counts none, changes no
// register and no byte but the accessed and dirty bits, and a page fault
// names an address and an error code that the walk of the page tables
// gives again. No step writes a frame that the user cannot write. The run
// of the budget in one call gives the state of the steps one by one.
fuzz_software_machine_execute :: proc(input: []u8) -> Fuzz_Verdict {
	state := &fuzz_machine_state
	registers: [16]u64
	mem.copy(&registers, raw_data(input), min(len(input), FUZZ_MACHINE_REGISTER_BYTES))
	code := input[min(len(input), FUZZ_MACHINE_REGISTER_BYTES):]
	if registers[int(software_machine.General_Register.Rsp)] == 0 {
		registers[int(software_machine.General_Register.Rsp)] = FUZZ_MACHINE_STACK_TOP
	}
	fuzz_machine_build(state.memory[:], code)
	state.initial = state.memory
	state.run_memory = state.memory

	root := u64(FUZZ_MACHINE_FRAME_LEVEL_4) * software_machine.PAGE_SIZE
	software_machine.processor_init(&state.processor, root, FUZZ_MACHINE_CODE_ADDRESS, registers[int(software_machine.General_Register.Rsp)])
	state.processor.registers = registers
	state.run_processor = state.processor
	// An empty cache for each input, so an input gives its verdict alone.
	state.run_blocks = {}
	state.run_processor.blocks = &state.run_blocks
	run_outcome := software_machine.processor_run(&state.run_processor, state.run_memory[:], FUZZ_MACHINE_STEP_LIMIT)
	if run_outcome > max(software_machine.Step_Outcome) || run_outcome == .Running || run_outcome == .Halted {
		return fuzz_broken(.Contract, "software_machine.processor_run gives the outcome %d", u8(run_outcome))
	}
	if state.run_processor.steps_executed > FUZZ_MACHINE_STEP_LIMIT {
		return fuzz_broken(.Contract, "software_machine.processor_run counts %d steps past its budget %d", state.run_processor.steps_executed, FUZZ_MACHINE_STEP_LIMIT)
	}

	outcome := software_machine.Step_Outcome.Running
	for _ in 0 ..< FUZZ_MACHINE_STEP_LIMIT {
		state.before_step = state.processor
		before := &state.before_step
		// The run in one call says which step faults: only that step needs
		// a copy of the memory before it.
		if fuzz_machine_is_fault(run_outcome) && before.steps_executed == state.run_processor.steps_executed {
			state.before_fault = state.memory
		}
		outcome = software_machine.processor_step(&state.processor, state.memory[:])
		after := &state.processor
		if outcome > max(software_machine.Step_Outcome) || outcome != after.outcome {
			return fuzz_broken(.Contract, "a step gives the outcome %d and records %d", u8(outcome), u8(after.outcome))
		}
		switch outcome {
		case .Running, .Syscall, .Breakpoint:
			if after.steps_executed != before.steps_executed + 1 {
				return fuzz_broken(.Contract, "a step with the outcome %v counts %d steps after %d", outcome, after.steps_executed, before.steps_executed)
			}
			if !software_machine.is_canonical_virtual_address(after.rip) {
				return fuzz_broken(.Contract, "a step with the outcome %v leaves the place %x, which is not canonical", outcome, after.rip)
			}
			if after.rflags & ~FUZZ_MACHINE_FLAGS_KNOWN != 0 || after.rflags & (software_machine.RFLAGS_RESERVED_ONE | software_machine.RFLAGS_IF) != software_machine.RFLAGS_RESERVED_ONE | software_machine.RFLAGS_IF {
				return fuzz_broken(.Contract, "a step at %x leaves the flags %x", before.rip, after.rflags)
			}
			if outcome != .Running && after.rip == before.rip {
				return fuzz_broken(.Contract, "the trap %v at %x does not move past its instruction", outcome, before.rip)
			}
			if outcome == .Syscall && (after.registers[int(software_machine.General_Register.Rcx)] != after.rip || after.registers[int(software_machine.General_Register.R11)] != before.rflags) {
				return fuzz_broken(.Contract, "the system call at %x saves the place %x and the flags %x", before.rip, after.registers[int(software_machine.General_Register.Rcx)], after.registers[int(software_machine.General_Register.R11)])
			}
		case .Page_Fault, .General_Protection, .Invalid_Opcode, .Divide_Error, .Simd_Floating_Point:
			if after.steps_executed != before.steps_executed {
				return fuzz_broken(.Contract, "the fault %v at %x counts a step", outcome, before.rip)
			}
			if !fuzz_machine_same_state_after_fault(after, before, outcome) {
				return fuzz_broken(.Contract, "the fault %v at %x changed a register, the place or the flags", outcome, before.rip)
			}
			if fuzz_machine_is_fault(run_outcome) && before.steps_executed == state.run_processor.steps_executed {
				if problem := fuzz_machine_memory_problem(state.memory[:], state.before_fault[:], false); problem != "" {
					return fuzz_broken(.Contract, "the fault %v at %x left a write: %s", outcome, before.rip, problem)
				}
			}
			if outcome == .Page_Fault {
				if problem := fuzz_machine_page_fault_problem(after, state.memory[:]); problem != "" {
					return fuzz_broken(.Two_Readers, "the page fault at %x: %s", before.rip, problem)
				}
			}
		case .Step_Budget_Exhausted, .Halted:
			return fuzz_broken(.Contract, "one step gives the outcome %v", outcome)
		}
		if problem := fuzz_machine_memory_problem(state.memory[:], state.initial[:], true); problem != "" {
			return fuzz_broken(.Contract, "after the step at %x: %s", before.rip, problem)
		}
		if outcome != .Running {
			break
		}
	}

	// The two machines agree: a run that used its budget is the steps that
	// all ran.
	expected := outcome if outcome != .Running else .Step_Budget_Exhausted
	if run_outcome != expected || !fuzz_machine_same_architectural_state(&state.processor, &state.run_processor) || state.processor.steps_executed != state.run_processor.steps_executed || state.processor.fault_address != state.run_processor.fault_address || state.processor.fault_error_code != state.run_processor.fault_error_code {
		return fuzz_broken(.Two_Readers, "the run gives %v after %d steps at %x; the steps give %v after %d at %x", run_outcome, state.run_processor.steps_executed, state.run_processor.rip, outcome, state.processor.steps_executed, state.processor.rip)
	}
	if state.memory != state.run_memory {
		return fuzz_broken(.Two_Readers, "the run and the steps leave two memories")
	}
	return FUZZ_PASSED
}

// fuzz_machine_page_fault_problem walks the page tables again for the
// address and the access that the error code of a fault names: the walk
// must fault with the same code. The step that faulted is the last one, so
// the accessed bits that this walk would set change nothing that follows.
@(private = "file")
fuzz_machine_page_fault_problem :: proc(processor: ^software_machine.Processor_State, memory: []u8) -> string {
	code := processor.fault_error_code
	if code & ~FUZZ_MACHINE_FAULT_BITS_KNOWN != 0 || code & software_machine.PAGE_FAULT_USER == 0 || code & software_machine.PAGE_FAULT_WRITE != 0 && code & software_machine.PAGE_FAULT_INSTRUCTION != 0 {
		return fuzz_broken(.Contract, "the error code %x", code).text
	}
	access := software_machine.Memory_Access_Kind.Read
	if code & software_machine.PAGE_FAULT_WRITE != 0 {
		access = .Write
	} else if code & software_machine.PAGE_FAULT_INSTRUCTION != 0 {
		access = .Execute
	}
	walk := software_machine.translate_virtual_address(nil, memory, processor.cr3, processor.fault_address, .User, access)
	if walk.status != .Page_Fault || walk.fault_error_code != code || walk.fault_address != processor.fault_address {
		return fuzz_broken(.Contract, "the walk of %x for %v gives %v with the code %x; the step gave %x", processor.fault_address, access, walk.status, walk.fault_error_code, code).text
	}
	return ""
}

// The seeds: each kind of instruction that the processor runs, and each
// kind of fault and trap, over the pages of the machine. The registers are
// zero, so the stack pointer is the top of the stack.
fuzz_software_machine_seeds :: proc(seeds: ^[dynamic][]u8) {
	add :: proc(seeds: ^[dynamic][]u8, code: []u8) {
		input := make([]u8, FUZZ_MACHINE_REGISTER_BYTES + len(code))
		copy(input[FUZZ_MACHINE_REGISTER_BYTES:], code)
		append(seeds, input)
	}
	// Loads, stores, the stack, an exchange, then a system call.
	add(seeds, []u8{0x48, 0xC7, 0xC0, 0x00, 0x20, 0x40, 0x00, 0x48, 0xC7, 0x00, 0x34, 0x12, 0x00, 0x00, 0x48, 0x8B, 0x18, 0x48, 0x01, 0xDB, 0x53, 0x59, 0x48, 0x87, 0x48, 0x08, 0xFE, 0x00, 0x0F, 0x05, 0xCC})
	// A loop of five calls.
	add(seeds, []u8{0xB9, 0x05, 0x00, 0x00, 0x00, 0xE8, 0x05, 0x00, 0x00, 0x00, 0xFF, 0xC9, 0x75, 0xF7, 0xCC, 0xC3})
	// rep stosb from the data page into the page that is read only.
	add(seeds, []u8{0x48, 0xC7, 0xC7, 0xFC, 0x2F, 0x40, 0x00, 0xB9, 0x10, 0x00, 0x00, 0x00, 0xB0, 0x5A, 0xF3, 0xAA, 0xCC})
	// A write into the code.
	add(seeds, []u8{0x48, 0xC7, 0xC0, 0x00, 0x00, 0x40, 0x00, 0xC6, 0x00, 0x90})
	// A jump into the data, which is not executable.
	add(seeds, []u8{0x48, 0xC7, 0xC0, 0x00, 0x20, 0x40, 0x00, 0xFF, 0xE0})
	// A read of the page of the supervisor.
	add(seeds, []u8{0x48, 0xC7, 0xC0, 0x00, 0x40, 0x40, 0x00, 0x48, 0x8B, 0x18})
	// A read of an address that is not canonical.
	add(seeds, []u8{0x48, 0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x48, 0x8B, 0x18})
	// A division by zero.
	add(seeds, []u8{0x31, 0xD2, 0x31, 0xC9, 0xB8, 0x07, 0x00, 0x00, 0x00, 0xF7, 0xF1})
	// The vector registers through the data page.
	add(seeds, []u8{0x48, 0xC7, 0xC0, 0x00, 0x20, 0x40, 0x00, 0xF3, 0x0F, 0x6F, 0x00, 0x66, 0x0F, 0xEF, 0xC9, 0xF3, 0x0F, 0x7F, 0x40, 0x10, 0xCC})
	// A push that straddles the hole below the stack.
	add(seeds, []u8{0x48, 0xC7, 0xC4, 0x04, 0x60, 0x40, 0x00, 0x50})
	// An undefined instruction, and an instruction of sixteen bytes.
	add(seeds, []u8{0x0F, 0x0B})
	add(seeds, []u8{0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x90})
	// A loop with no end: the budget ends it.
	add(seeds, []u8{0xEB, 0xFE})
	// A load relative to the place, from the data page.
	add(seeds, []u8{0x48, 0x8B, 0x05, 0xF9, 0x1F, 0x00, 0x00, 0xCC})
	// An instruction whose last bytes are in the data page: its fetch faults.
	long := make([]u8, FUZZ_MACHINE_CODE_BYTES, context.temp_allocator)
	slice.fill(long, FUZZ_MACHINE_CODE_FILL)
	copy(long, []u8{0xE9, 0xF8, 0x1F, 0x00, 0x00})
	copy(long[FUZZ_MACHINE_CODE_BYTES - 3:], []u8{0x48, 0xB8, 0x01})
	add(seeds, long)
}

// fuzz_software_machine_words gives the virtual places of the machine to
// the dictionary: an immediate or a register with one of them reaches a
// page instead of a fault on the first access.
fuzz_software_machine_words :: proc(words: ^[dynamic][]u8) {
	for place in ([?]u64{FUZZ_MACHINE_CODE_ADDRESS, FUZZ_MACHINE_DATA_ADDRESS, FUZZ_MACHINE_READ_ONLY_ADDRESS, FUZZ_MACHINE_SUPERVISOR_ADDRESS, FUZZ_MACHINE_STACK_ADDRESS, FUZZ_MACHINE_STACK_TOP - 8}) {
		word := place
		append(words, slice.clone(mem.ptr_to_bytes(&word)))
	}
}
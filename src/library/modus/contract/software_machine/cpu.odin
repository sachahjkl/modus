// Freestanding x86-64 user-mode software processor for the modus browser
// machine (src/md/features/browser_machine.md, "The software MMU").
//
// Executes unmodified x86-64 user-mode module code strictly through the
// Software MMU in `mmu.odin`, with zero host-memory bypass. Every instruction
// fetch, stack push/pop, data load/store, and SSE2 vector memory access walks
// the process page table rooted at `cr3` with `Privilege_Level.User`.
//
// Fault semantics match x86-64 hardware:
//   - Faults (Page_Fault, General_Protection, Invalid_Opcode, Divide_Error)
//     leave `rip` pointing at the start of the offending instruction and do
//     not leave partial writes or partial stack updates behind.
//   - Traps (Syscall, Breakpoint) advance `rip` past the instruction so the
//     kernel loop can resume execution directly after servicing the trap.
//   - Every `processor_run` enforces a strict `max_steps` execution budget
//     (including bounding `rep movsb`/`rep stosb` to one iteration per step).
//
// This package is freestanding (`"contextless"`), allocates no memory, and
// imports only `base:` and `modus:contract/` packages.
package software_machine

import "modus:contract/enum_word"

// Maximum architectural x86-64 instruction byte length.
MAX_INSTRUCTION_BYTES :: 15

// Architectural RFLAGS bit positions.
RFLAGS_CF :: u64(1) << 0
RFLAGS_RESERVED_ONE :: u64(1) << 1
RFLAGS_PF :: u64(1) << 2
RFLAGS_AF :: u64(1) << 4
RFLAGS_ZF :: u64(1) << 6
RFLAGS_SF :: u64(1) << 7
RFLAGS_IF :: u64(1) << 9
RFLAGS_DF :: u64(1) << 10
RFLAGS_OF :: u64(1) << 11

// Default user-mode RFLAGS matching `modulus` (`USER_FLAGS :: 0x202`).
USER_INITIAL_RFLAGS :: RFLAGS_RESERVED_ONE | RFLAGS_IF

// Architectural x86-64 general-purpose register indices.
General_Register :: enum u8 {
	Rax = 0,
	Rcx = 1,
	Rdx = 2,
	Rbx = 3,
	Rsp = 4,
	Rbp = 5,
	Rsi = 6,
	Rdi = 7,
	R8  = 8,
	R9  = 9,
	R10 = 10,
	R11 = 11,
	R12 = 12,
	R13 = 13,
	R14 = 14,
	R15 = 15,
}

// Execution outcome returned after stepping or running the software processor.
Step_Outcome :: enum u8 {
	Running               = 0,
	Syscall               = 1,
	Page_Fault            = 2,
	General_Protection    = 3,
	Invalid_Opcode        = 4,
	Breakpoint            = 5,
	Step_Budget_Exhausted = 6,
	Halted                = 7,
	Divide_Error          = 8,
	Simd_Floating_Point   = 9, // An exception that MXCSR does not mask: vector 19.
}

// Integer operand width in bytes.
Operand_Width :: enum u8 {
	Bits_8  = 1,
	Bits_16 = 2,
	Bits_32 = 4,
	Bits_64 = 8,
}

// Standard x86-64 4-bit condition codes shared by Jcc, SETcc, and CMOVcc.
Condition_Code :: enum u8 {
	Overflow         = 0x0,
	Not_Overflow     = 0x1,
	Below            = 0x2,
	Above_Or_Equal   = 0x3,
	Equal            = 0x4,
	Not_Equal        = 0x5,
	Below_Or_Equal   = 0x6,
	Above            = 0x7,
	Sign             = 0x8,
	Not_Sign         = 0x9,
	Parity           = 0xA,
	Not_Parity       = 0xB,
	Less             = 0xC,
	Greater_Or_Equal = 0xD,
	Less_Or_Equal    = 0xE,
	Greater          = 0xF,
}

// Standard 3-bit ALU operation selector shared by 0x00..0x3D and 0x80..0x83.
Alu_Operation :: enum u8 {
	Add = 0,
	Or  = 1,
	Adc = 2,
	Sbb = 3,
	And = 4,
	Sub = 5,
	Xor = 6,
	Cmp = 7,
}

// Shift and rotate operation selector for Group 2 opcodes (0xC0/C1/D0/D1/D2/D3).
Shift_Operation :: enum u8 {
	Rol = 0,
	Ror = 1,
	Shl = 4,
	Shr = 5,
	Sar = 7,
}

// Full architectural state of one x86-64 user-mode software processor.
Processor_State :: struct {
	registers:            [16]u64,
	rip:                  u64,
	rflags:               u64,
	cr3:                  u64,
	gs_base:              u64,
	xmm:                  [16][16]u8,
	mxcsr:                u32,
	// The source of rdtsc: the kernel gives its cycle counter. With none,
	// rdtsc reads the count of steps, which also only grows.
	cycle_counter_read:   proc "contextless" () -> u64,
	// The ports that in and out reach. With none, each in and each out is
	// a protection fault, as for a process with no port.
	ports:                Port_Bus,
	tlb:                  Software_Tlb,
	outcome:              Step_Outcome,
	fault_address:        u64,
	fault_error_code:     u64,
	steps_executed:       u64,
	syscall_return_rip:   u64,
	syscall_saved_rflags: u64,
}

// The ports of the machine, as the kernel gives them to the software
// processor. A process runs with IOPL 0, so the permission map of the task
// state alone decides each access, as on the processor.
Port_Bus :: struct {
	// One bit for each port; 1 refuses the port. An access whose bits pass
	// the end of the map is refused: the processor reads the map past its
	// end as refused bits.
	permission_map: []u8,
	// The device access, after the check. A width is 1, 2 or 4 bytes.
	read:           proc "contextless" (port: u16, width: Operand_Width) -> u32,
	write:          proc "contextless" (port: u16, width: Operand_Width, value: u32),
}

// port_access_permitted says whether each port of an access of width
// bytes from port is open in the map of the bus.
port_access_permitted :: proc "contextless" (bus: Port_Bus, port: u16, width: Operand_Width) -> bool {
	if bus.read == nil || bus.write == nil || width == .Bits_64 {
		return false
	}
	for offset in 0 ..< u32(width) {
		bit := u32(port) + offset
		index := bit / 8
		if index >= u32(len(bus.permission_map)) || bus.permission_map[index] & (u8(1) << (bit % 8)) != 0 {
			return false
		}
	}
	return true
}

// condition_code_from_word decodes a 4-bit opcode condition field at the
// instruction border and refuses any value naming no member.
@(private)
condition_code_from_word :: proc "contextless" (word: u8) -> (cc: Condition_Code, ok: bool) {
	return enum_word.member_of_word(Condition_Code, u64(word))
}

// alu_operation_from_word decodes a 3-bit ALU opcode/ModRM selector at the
// instruction border and refuses any value naming no member.
@(private)
alu_operation_from_word :: proc "contextless" (word: u8) -> (op: Alu_Operation, ok: bool) {
	return enum_word.member_of_word(Alu_Operation, u64(word))
}

// processor_init resets a processor state for user-mode execution at the given
// page-table root, instruction pointer, stack pointer, and optional GS base.
processor_init :: proc "contextless" (
	cpu: ^Processor_State,
	page_table_root: u64,
	instruction_pointer: u64,
	stack_pointer: u64,
	gs_base: u64 = 0,
) {
	cpu^ = {}
	cpu.cr3 = page_table_root
	cpu.rip = instruction_pointer
	cpu.registers[int(General_Register.Rsp)] = stack_pointer
	cpu.gs_base = gs_base
	cpu.rflags = USER_INITIAL_RFLAGS
	cpu.mxcsr = MXCSR_START
	cpu.outcome = .Running
}

// processor_set_cr3 updates the active page-table root and flushes the TLB.
processor_set_cr3 :: proc "contextless" (cpu: ^Processor_State, page_table_root: u64) {
	cpu.cr3 = page_table_root
	tlb_flush_all(&cpu.tlb)
}

// processor_invlpg invalidates cached translations for `virtual_address`.
processor_invlpg :: proc "contextless" (cpu: ^Processor_State, virtual_address: u64) {
	tlb_flush_page(&cpu.tlb, virtual_address)
}

// Instruction fetch cursor bounded to MAX_INSTRUCTION_BYTES so decoded length
// is checked incrementally and `next_rip` is exact before resolving RIP-relative
// addressing.
@(private)
Instruction_Cursor :: struct {
	start_rip:     u64,
	current_rip:   u64,
	bytes_fetched: int,
}

@(private)
Decoded_Prefixes :: struct {
	has_operand_size_override: bool, // 0x66
	has_address_size_override: bool, // 0x67
	has_lock:                  bool, // 0xF0
	has_repne:                 bool, // 0xF2
	has_rep:                   bool, // 0xF3
	// The last of F2 and F3 wins as the mandatory prefix of a vector form.
	last_repeat_is_not_equal:  bool,
	has_gs_override:           bool, // 0x65
	has_rex:                   bool,
	rex_w:                     bool,
	rex_r:                     bool,
	rex_x:                     bool,
	rex_b:                     bool,
}

// Decoded ModRM operand; memory operands defer RIP-relative finalization until
// all trailing immediate bytes of the instruction have been fetched.
@(private)
Decoded_Modrm :: struct {
	is_register:      bool,
	reg_index:        u8, // 0..15 (with REX.R)
	rm_register:      u8, // 0..15 (with REX.B) when is_register is true
	is_rip_relative:  bool,
	address_offset:   u64, // Computed offset (or disp32 when is_rip_relative)
	has_gs_override:  bool,
	address_32:       bool,
}

// record_translation_fault maps an MMU translation failure onto the processor
// outcome while preserving `instruction_start_rip`.
@(private)
record_translation_fault :: proc "contextless" (cpu: ^Processor_State, instruction_start_rip: u64, result: Translation_Result) -> Step_Outcome {
	cpu.rip = instruction_start_rip
	cpu.fault_address = result.fault_address
	cpu.fault_error_code = result.fault_error_code
	switch result.status {
	case .Ok:
		cpu.outcome = .Running
	case .Page_Fault:
		cpu.outcome = .Page_Fault
	case .Non_Canonical_Address, .Physical_Address_Out_Of_Bounds:
		cpu.outcome = .General_Protection
	}
	return cpu.outcome
}

@(private)
record_fault :: proc "contextless" (cpu: ^Processor_State, instruction_start_rip: u64, outcome: Step_Outcome, fault_address: u64 = 0) -> Step_Outcome {
	cpu.rip = instruction_start_rip
	cpu.fault_address = fault_address
	cpu.fault_error_code = 0
	cpu.outcome = outcome
	return outcome
}

@(private)
fetch_u8 :: proc "contextless" (cpu: ^Processor_State, physical_memory: []u8, cursor: ^Instruction_Cursor) -> (value: u8, outcome: Step_Outcome) {
	if cursor.bytes_fetched >= MAX_INSTRUCTION_BYTES {
		return 0, record_fault(cpu, cursor.start_rip, .General_Protection, cursor.current_rip)
	}
	byte, res := mmu_fetch_u8(&cpu.tlb, physical_memory, cpu.cr3, cursor.current_rip, .User)
	if res.status != .Ok {
		return 0, record_translation_fault(cpu, cursor.start_rip, res)
	}
	cursor.current_rip += 1
	cursor.bytes_fetched += 1
	return byte, .Running
}

@(private)
fetch_u16 :: proc "contextless" (cpu: ^Processor_State, physical_memory: []u8, cursor: ^Instruction_Cursor) -> (value: u16, outcome: Step_Outcome) {
	b0, o0 := fetch_u8(cpu, physical_memory, cursor)
	if o0 != .Running {
		return 0, o0
	}
	b1, o1 := fetch_u8(cpu, physical_memory, cursor)
	if o1 != .Running {
		return 0, o1
	}
	return u16(b0) | u16(b1) << 8, .Running
}

@(private)
fetch_u32 :: proc "contextless" (cpu: ^Processor_State, physical_memory: []u8, cursor: ^Instruction_Cursor) -> (value: u32, outcome: Step_Outcome) {
	b0, o0 := fetch_u8(cpu, physical_memory, cursor)
	if o0 != .Running {
		return 0, o0
	}
	b1, o1 := fetch_u8(cpu, physical_memory, cursor)
	if o1 != .Running {
		return 0, o1
	}
	b2, o2 := fetch_u8(cpu, physical_memory, cursor)
	if o2 != .Running {
		return 0, o2
	}
	b3, o3 := fetch_u8(cpu, physical_memory, cursor)
	if o3 != .Running {
		return 0, o3
	}
	return u32(b0) | u32(b1) << 8 | u32(b2) << 16 | u32(b3) << 24, .Running
}

@(private)
fetch_u64 :: proc "contextless" (cpu: ^Processor_State, physical_memory: []u8, cursor: ^Instruction_Cursor) -> (value: u64, outcome: Step_Outcome) {
	lo, o0 := fetch_u32(cpu, physical_memory, cursor)
	if o0 != .Running {
		return 0, o0
	}
	hi, o1 := fetch_u32(cpu, physical_memory, cursor)
	if o1 != .Running {
		return 0, o1
	}
	return u64(lo) | u64(hi) << 32, .Running
}

@(private)
operand_width_from_prefixes :: #force_inline proc "contextless" (prefixes: Decoded_Prefixes) -> Operand_Width {
	if prefixes.rex_w {
		return .Bits_64
	}
	if prefixes.has_operand_size_override {
		return .Bits_16
	}
	return .Bits_32
}

@(private)
width_mask :: #force_inline proc "contextless" (width: Operand_Width) -> u64 {
	switch width {
	case .Bits_8:
		return 0xFF
	case .Bits_16:
		return 0xFFFF
	case .Bits_32:
		return 0xFFFF_FFFF
	case .Bits_64:
		return max(u64)
	}
	return max(u64)
}

@(private)
width_sign_bit :: #force_inline proc "contextless" (width: Operand_Width) -> u64 {
	switch width {
	case .Bits_8:
		return u64(1) << 7
	case .Bits_16:
		return u64(1) << 15
	case .Bits_32:
		return u64(1) << 31
	case .Bits_64:
		return u64(1) << 63
	}
	return u64(1) << 63
}

@(private)
width_bit_count :: #force_inline proc "contextless" (width: Operand_Width) -> uint {
	switch width {
	case .Bits_8:
		return 8
	case .Bits_16:
		return 16
	case .Bits_32:
		return 32
	case .Bits_64:
		return 64
	}
	return 64
}

@(private)
sign_extend_to_i64 :: #force_inline proc "contextless" (value: u64, width: Operand_Width) -> i64 {
	switch width {
	case .Bits_8:
		return i64(i8(u8(value)))
	case .Bits_16:
		return i64(i16(u16(value)))
	case .Bits_32:
		return i64(i32(u32(value)))
	case .Bits_64:
		return i64(value)
	}
	return i64(value)
}

// read_register reads a register of `width` bits, applying the x86-64 rule
// that 8-bit indices 4..7 without a REX prefix access AH/CH/DH/BH.
@(private)
read_register :: proc "contextless" (cpu: ^Processor_State, index: u8, width: Operand_Width, has_rex: bool) -> u64 {
	switch width {
	case .Bits_8:
		if !has_rex && index >= 4 && index <= 7 {
			return (cpu.registers[index - 4] >> 8) & 0xFF
		}
		return cpu.registers[index & 15] & 0xFF
	case .Bits_16:
		return cpu.registers[index & 15] & 0xFFFF
	case .Bits_32:
		return cpu.registers[index & 15] & 0xFFFF_FFFF
	case .Bits_64:
		return cpu.registers[index & 15]
	}
	return 0
}

// write_register writes a register of `width` bits. Writing 32 bits zero-extends
// to 64 bits; writing 8 or 16 bits preserves all higher bits.
@(private)
write_register :: proc "contextless" (cpu: ^Processor_State, index: u8, width: Operand_Width, has_rex: bool, value: u64) {
	switch width {
	case .Bits_8:
		if !has_rex && index >= 4 && index <= 7 {
			target := index - 4
			cpu.registers[target] = (cpu.registers[target] & ~u64(0xFF00)) | ((value & 0xFF) << 8)
		} else {
			target := index & 15
			cpu.registers[target] = (cpu.registers[target] & ~u64(0xFF)) | (value & 0xFF)
		}
	case .Bits_16:
		target := index & 15
		cpu.registers[target] = (cpu.registers[target] & ~u64(0xFFFF)) | (value & 0xFFFF)
	case .Bits_32:
		cpu.registers[index & 15] = u64(u32(value))
	case .Bits_64:
		cpu.registers[index & 15] = value
	}
}

// decode_modrm parses ModRM, optional SIB, and optional disp8/disp32.
@(private)
decode_modrm :: proc "contextless" (
	cpu: ^Processor_State,
	physical_memory: []u8,
	cursor: ^Instruction_Cursor,
	prefixes: Decoded_Prefixes,
) -> (modrm: Decoded_Modrm, outcome: Step_Outcome) {
	byte, fetch_outcome := fetch_u8(cpu, physical_memory, cursor)
	if fetch_outcome != .Running {
		return {}, fetch_outcome
	}

	mod := (byte >> 6) & 3
	reg := ((byte >> 3) & 7) | (prefixes.rex_r ? u8(8) : 0)
	rm_low := byte & 7
	rm := rm_low | (prefixes.rex_b ? u8(8) : 0)

	modrm.reg_index = reg
	modrm.has_gs_override = prefixes.has_gs_override
	modrm.address_32 = prefixes.has_address_size_override

	if mod == 3 {
		modrm.is_register = true
		modrm.rm_register = rm
		return modrm, .Running
	}

	modrm.is_register = false

	// RIP-relative addressing: mod == 0 and low 3 bits of rm == 5 (ignores REX.B).
	if mod == 0 && rm_low == 5 {
		disp32, disp_outcome := fetch_u32(cpu, physical_memory, cursor)
		if disp_outcome != .Running {
			return {}, disp_outcome
		}
		modrm.is_rip_relative = true
		modrm.address_offset = u64(i64(i32(disp32)))
		return modrm, .Running
	}

	offset := u64(0)
	if rm_low == 4 {
		// SIB byte follows.
		sib, sib_outcome := fetch_u8(cpu, physical_memory, cursor)
		if sib_outcome != .Running {
			return {}, sib_outcome
		}
		scale_shift := (sib >> 6) & 3
		index_code := ((sib >> 3) & 7) | (prefixes.rex_x ? u8(8) : 0)
		base_low := sib & 7
		base_code := base_low | (prefixes.rex_b ? u8(8) : 0)

		index_value := u64(0)
		if index_code != 4 {
			index_value = cpu.registers[index_code] << scale_shift
		}

		if mod == 0 && base_low == 5 {
			disp32, disp_outcome := fetch_u32(cpu, physical_memory, cursor)
			if disp_outcome != .Running {
				return {}, disp_outcome
			}
			offset = index_value + u64(i64(i32(disp32)))
		} else {
			offset = cpu.registers[base_code] + index_value
		}
	} else {
		offset = cpu.registers[rm]
	}

	if mod == 1 {
		disp8, disp_outcome := fetch_u8(cpu, physical_memory, cursor)
		if disp_outcome != .Running {
			return {}, disp_outcome
		}
		offset += u64(i64(i8(disp8)))
	} else if mod == 2 {
		disp32, disp_outcome := fetch_u32(cpu, physical_memory, cursor)
		if disp_outcome != .Running {
			return {}, disp_outcome
		}
		offset += u64(i64(i32(disp32)))
	}

	modrm.address_offset = offset
	return modrm, .Running
}

// resolve_effective_address computes the linear address of a memory operand
// after all immediate bytes of the instruction are fetched (so `next_rip` is exact).
@(private)
resolve_effective_address :: proc "contextless" (cpu: ^Processor_State, modrm: Decoded_Modrm, next_rip: u64, apply_segment: bool) -> u64 {
	offset := modrm.address_offset
	if modrm.is_rip_relative {
		offset = next_rip + modrm.address_offset
	}
	if modrm.address_32 {
		offset = u64(u32(offset))
	}
	if apply_segment && modrm.has_gs_override {
		offset += cpu.gs_base
	}
	return offset
}

@(private)
read_memory_width :: proc "contextless" (
	cpu: ^Processor_State,
	physical_memory: []u8,
	instruction_start_rip: u64,
	address: u64,
	width: Operand_Width,
) -> (value: u64, outcome: Step_Outcome) {
	switch width {
	case .Bits_8:
		v, res := mmu_read_u8(&cpu.tlb, physical_memory, cpu.cr3, address, .User)
		if res.status != .Ok {
			return 0, record_translation_fault(cpu, instruction_start_rip, res)
		}
		return u64(v), .Running
	case .Bits_16:
		v, res := mmu_read_u16(&cpu.tlb, physical_memory, cpu.cr3, address, .User)
		if res.status != .Ok {
			return 0, record_translation_fault(cpu, instruction_start_rip, res)
		}
		return u64(v), .Running
	case .Bits_32:
		v, res := mmu_read_u32(&cpu.tlb, physical_memory, cpu.cr3, address, .User)
		if res.status != .Ok {
			return 0, record_translation_fault(cpu, instruction_start_rip, res)
		}
		return u64(v), .Running
	case .Bits_64:
		v, res := mmu_read_u64(&cpu.tlb, physical_memory, cpu.cr3, address, .User)
		if res.status != .Ok {
			return 0, record_translation_fault(cpu, instruction_start_rip, res)
		}
		return v, .Running
	}
	return 0, .Invalid_Opcode
}

@(private)
write_memory_width :: proc "contextless" (
	cpu: ^Processor_State,
	physical_memory: []u8,
	instruction_start_rip: u64,
	address: u64,
	width: Operand_Width,
	value: u64,
) -> Step_Outcome {
	res: Translation_Result
	switch width {
	case .Bits_8:
		res = mmu_write_u8(&cpu.tlb, physical_memory, cpu.cr3, address, .User, u8(value))
	case .Bits_16:
		res = mmu_write_u16(&cpu.tlb, physical_memory, cpu.cr3, address, .User, u16(value))
	case .Bits_32:
		res = mmu_write_u32(&cpu.tlb, physical_memory, cpu.cr3, address, .User, u32(value))
	case .Bits_64:
		res = mmu_write_u64(&cpu.tlb, physical_memory, cpu.cr3, address, .User, value)
	}
	if res.status != .Ok {
		return record_translation_fault(cpu, instruction_start_rip, res)
	}
	return .Running
}

@(private)
read_rm_operand :: proc "contextless" (
	cpu: ^Processor_State,
	physical_memory: []u8,
	instruction_start_rip: u64,
	next_rip: u64,
	modrm: Decoded_Modrm,
	width: Operand_Width,
	has_rex: bool,
) -> (value: u64, outcome: Step_Outcome) {
	if modrm.is_register {
		return read_register(cpu, modrm.rm_register, width, has_rex), .Running
	}
	address := resolve_effective_address(cpu, modrm, next_rip, true)
	return read_memory_width(cpu, physical_memory, instruction_start_rip, address, width)
}

@(private)
write_rm_operand :: proc "contextless" (
	cpu: ^Processor_State,
	physical_memory: []u8,
	instruction_start_rip: u64,
	next_rip: u64,
	modrm: Decoded_Modrm,
	width: Operand_Width,
	has_rex: bool,
	value: u64,
) -> Step_Outcome {
	if modrm.is_register {
		write_register(cpu, modrm.rm_register, width, has_rex, value)
		return .Running
	}
	address := resolve_effective_address(cpu, modrm, next_rip, true)
	return write_memory_width(cpu, physical_memory, instruction_start_rip, address, width, value)
}

@(private)
fetch_sign_extended_immediate :: proc "contextless" (
	cpu: ^Processor_State,
	physical_memory: []u8,
	cursor: ^Instruction_Cursor,
	width: Operand_Width,
) -> (value: u64, outcome: Step_Outcome) {
	switch width {
	case .Bits_8:
		v, o := fetch_u8(cpu, physical_memory, cursor)
		return u64(v), o
	case .Bits_16:
		v, o := fetch_u16(cpu, physical_memory, cursor)
		return u64(v), o
	case .Bits_32, .Bits_64:
		v, o := fetch_u32(cpu, physical_memory, cursor)
		return u64(i64(i32(v))), o
	}
	return 0, .Invalid_Opcode
}

// Parity flag is 1 when the least-significant byte has an even count of 1 bits.
@(private)
parity_even :: #force_inline proc "contextless" (value: u8) -> bool {
	folded := value
	folded ~= folded >> 4
	folded ~= folded >> 2
	folded ~= folded >> 1
	return (folded & 1) == 0
}

@(private)
set_flag :: #force_inline proc "contextless" (cpu: ^Processor_State, flag_bit: u64, enabled: bool) {
	if enabled {
		cpu.rflags |= flag_bit
	} else {
		cpu.rflags &~= flag_bit
	}
}

@(private)
update_szp_flags :: proc "contextless" (cpu: ^Processor_State, result: u64, width: Operand_Width) {
	masked := result & width_mask(width)
	set_flag(cpu, RFLAGS_ZF, masked == 0)
	set_flag(cpu, RFLAGS_SF, (masked & width_sign_bit(width)) != 0)
	set_flag(cpu, RFLAGS_PF, parity_even(u8(masked)))
}

@(private)
evaluate_condition :: proc "contextless" (cpu: ^Processor_State, condition: Condition_Code) -> bool {
	cf := (cpu.rflags & RFLAGS_CF) != 0
	pf := (cpu.rflags & RFLAGS_PF) != 0
	zf := (cpu.rflags & RFLAGS_ZF) != 0
	sf := (cpu.rflags & RFLAGS_SF) != 0
	of := (cpu.rflags & RFLAGS_OF) != 0
	switch condition {
	case .Overflow:
		return of
	case .Not_Overflow:
		return !of
	case .Below:
		return cf
	case .Above_Or_Equal:
		return !cf
	case .Equal:
		return zf
	case .Not_Equal:
		return !zf
	case .Below_Or_Equal:
		return cf || zf
	case .Above:
		return !cf && !zf
	case .Sign:
		return sf
	case .Not_Sign:
		return !sf
	case .Parity:
		return pf
	case .Not_Parity:
		return !pf
	case .Less:
		return sf != of
	case .Greater_Or_Equal:
		return sf == of
	case .Less_Or_Equal:
		return zf || (sf != of)
	case .Greater:
		return !zf && (sf == of)
	}
	return false
}

// execute_alu computes one of the 8 standard ALU operations and updates RFLAGS.
@(private)
execute_alu :: proc "contextless" (cpu: ^Processor_State, op: Alu_Operation, left, right: u64, width: Operand_Width) -> (result: u64, write_back: bool) {
	mask := width_mask(width)
	sign_bit := width_sign_bit(width)
	ua := left & mask
	ub := right & mask

	switch op {
	case .Add:
		res := (ua + ub) & mask
		cf := res < ua if width == .Bits_64 else (ua + ub) > mask
		of := ((~(ua ~ ub)) & (ua ~ res) & sign_bit) != 0
		af := ((ua ~ ub ~ res) & 0x10) != 0
		set_flag(cpu, RFLAGS_CF, cf)
		set_flag(cpu, RFLAGS_OF, of)
		set_flag(cpu, RFLAGS_AF, af)
		update_szp_flags(cpu, res, width)
		return res, true
	case .Adc:
		carry := u64(1) if (cpu.rflags & RFLAGS_CF) != 0 else u64(0)
		res := u64(0)
		cf := false
		if width == .Bits_64 {
			sum1 := ua + ub
			c1 := sum1 < ua
			res = sum1 + carry
			c2 := res < sum1
			cf = c1 || c2
		} else {
			full := ua + ub + carry
			res = full & mask
			cf = full > mask
		}
		of := ((~(ua ~ ub)) & (ua ~ res) & sign_bit) != 0
		af := ((ua ~ ub ~ res) & 0x10) != 0
		set_flag(cpu, RFLAGS_CF, cf)
		set_flag(cpu, RFLAGS_OF, of)
		set_flag(cpu, RFLAGS_AF, af)
		update_szp_flags(cpu, res, width)
		return res, true
	case .Sub, .Cmp:
		res := (ua - ub) & mask
		cf := ua < ub
		of := ((ua ~ ub) & (ua ~ res) & sign_bit) != 0
		af := ((ua ~ ub ~ res) & 0x10) != 0
		set_flag(cpu, RFLAGS_CF, cf)
		set_flag(cpu, RFLAGS_OF, of)
		set_flag(cpu, RFLAGS_AF, af)
		update_szp_flags(cpu, res, width)
		return res, op == .Sub
	case .Sbb:
		borrow := u64(1) if (cpu.rflags & RFLAGS_CF) != 0 else u64(0)
		d1 := (ua - ub) & mask
		b1 := ua < ub
		res := (d1 - borrow) & mask
		b2 := d1 < borrow
		cf := b1 || b2
		of := ((ua ~ ub) & (ua ~ res) & sign_bit) != 0
		af := ((ua ~ ub ~ res) & 0x10) != 0
		set_flag(cpu, RFLAGS_CF, cf)
		set_flag(cpu, RFLAGS_OF, of)
		set_flag(cpu, RFLAGS_AF, af)
		update_szp_flags(cpu, res, width)
		return res, true
	case .And:
		res := (ua & ub) & mask
		set_flag(cpu, RFLAGS_CF, false)
		set_flag(cpu, RFLAGS_OF, false)
		set_flag(cpu, RFLAGS_AF, false)
		update_szp_flags(cpu, res, width)
		return res, true
	case .Or:
		res := (ua | ub) & mask
		set_flag(cpu, RFLAGS_CF, false)
		set_flag(cpu, RFLAGS_OF, false)
		set_flag(cpu, RFLAGS_AF, false)
		update_szp_flags(cpu, res, width)
		return res, true
	case .Xor:
		res := (ua ~ ub) & mask
		set_flag(cpu, RFLAGS_CF, false)
		set_flag(cpu, RFLAGS_OF, false)
		set_flag(cpu, RFLAGS_AF, false)
		update_szp_flags(cpu, res, width)
		return res, true
	}
	return 0, false
}

@(private)
execute_test_flags :: proc "contextless" (cpu: ^Processor_State, left, right: u64, width: Operand_Width) {
	mask := width_mask(width)
	res := (left & right) & mask
	set_flag(cpu, RFLAGS_CF, false)
	set_flag(cpu, RFLAGS_OF, false)
	set_flag(cpu, RFLAGS_AF, false)
	update_szp_flags(cpu, res, width)
}

@(private)
execute_shift :: proc "contextless" (cpu: ^Processor_State, op: Shift_Operation, value: u64, raw_count: u8, width: Operand_Width) -> u64 {
	mask := width_mask(width)
	sign_bit := width_sign_bit(width)
	bits := width_bit_count(width)
	ua := value & mask

	count_mask := u8(63) if width == .Bits_64 else u8(31)
	count := uint(raw_count & count_mask)
	if count == 0 {
		return ua
	}

	switch op {
	case .Shl:
		res := (ua << count) & mask if count < bits else u64(0)
		cf := ((ua >> (bits - count)) & 1) != 0 if count <= bits else false
		set_flag(cpu, RFLAGS_CF, cf)
		if count == 1 {
			set_flag(cpu, RFLAGS_OF, ((res & sign_bit) != 0) != cf)
		}
		update_szp_flags(cpu, res, width)
		return res
	case .Shr:
		res := (ua >> count) & mask if count < bits else u64(0)
		cf := ((ua >> (count - 1)) & 1) != 0 if count <= bits else false
		set_flag(cpu, RFLAGS_CF, cf)
		if count == 1 {
			set_flag(cpu, RFLAGS_OF, (ua & sign_bit) != 0)
		}
		update_szp_flags(cpu, res, width)
		return res
	case .Sar:
		sa := sign_extend_to_i64(ua, width)
		clamped := min(count, uint(63))
		res := u64(sa >> clamped) & mask
		cf := ((ua >> (count - 1)) & 1) != 0 if count <= bits else ((ua & sign_bit) != 0)
		set_flag(cpu, RFLAGS_CF, cf)
		if count == 1 {
			set_flag(cpu, RFLAGS_OF, false)
		}
		update_szp_flags(cpu, res, width)
		return res
	case .Rol:
		eff := count % bits
		res := ua if eff == 0 else ((ua << eff) | (ua >> (bits - eff))) & mask
		cf := (res & 1) != 0
		set_flag(cpu, RFLAGS_CF, cf)
		if count == 1 {
			set_flag(cpu, RFLAGS_OF, ((res & sign_bit) != 0) != cf)
		}
		return res
	case .Ror:
		eff := count % bits
		res := ua if eff == 0 else ((ua >> eff) | (ua << (bits - eff))) & mask
		cf := (res & sign_bit) != 0
		set_flag(cpu, RFLAGS_CF, cf)
		if count == 1 {
			second_msb := (res & (sign_bit >> 1)) != 0
			set_flag(cpu, RFLAGS_OF, cf != second_msb)
		}
		return res
	}
	return ua
}

// Pure freestanding 64x64 -> 128-bit unsigned multiplication (avoids compiler-rt).
@(private)
multiply_u64_to_u128 :: proc "contextless" (a, b: u64) -> (low: u64, high: u64) {
	a_lo := a & 0xFFFF_FFFF
	a_hi := a >> 32
	b_lo := b & 0xFFFF_FFFF
	b_hi := b >> 32

	p0 := a_lo * b_lo
	p1 := a_lo * b_hi
	p2 := a_hi * b_lo
	p3 := a_hi * b_hi

	middle := (p0 >> 32) + (p1 & 0xFFFF_FFFF) + (p2 & 0xFFFF_FFFF)
	low = (p0 & 0xFFFF_FFFF) | (middle << 32)
	high = p3 + (p1 >> 32) + (p2 >> 32) + (middle >> 32)
	return low, high
}

// Pure freestanding 64x64 -> 128-bit signed multiplication.
@(private)
multiply_i64_to_i128 :: proc "contextless" (a, b: i64) -> (low: u64, high: i64) {
	u_lo, u_hi := multiply_u64_to_u128(u64(a), u64(b))
	s_hi := i64(u_hi)
	if a < 0 {
		s_hi -= b
	}
	if b < 0 {
		s_hi -= a
	}
	return u_lo, s_hi
}

// Pure freestanding 128/64 -> 64-bit unsigned division (avoids __udivti3).
@(private)
divide_u128_by_u64 :: proc "contextless" (low, high, divisor: u64) -> (quotient, remainder: u64, ok: bool) {
	if divisor == 0 || high >= divisor {
		return 0, 0, false
	}
	if high == 0 {
		return low / divisor, low % divisor, true
	}
	rem := high
	quot := u64(0)
	for bit := uint(63); ; bit -= 1 {
		carry := (rem >> 63) != 0
		rem = (rem << 1) | ((low >> bit) & 1)
		if carry || rem >= divisor {
			rem -= divisor
			quot |= u64(1) << bit
		}
		if bit == 0 {
			break
		}
	}
	return quot, rem, true
}

// Pure freestanding 128/64 -> 64-bit signed division (avoids __divti3).
@(private)
divide_i128_by_i64 :: proc "contextless" (low: u64, high: i64, divisor: i64) -> (quotient, remainder: i64, ok: bool) {
	if divisor == 0 {
		return 0, 0, false
	}
	neg_dividend := high < 0
	neg_divisor := divisor < 0

	abs_lo := low
	abs_hi := u64(high)
	if neg_dividend {
		abs_lo = 0 - low
		abs_hi = u64(~high) + (u64(1) if abs_lo == 0 else u64(0))
	}
	abs_div := (0 - u64(divisor)) if neg_divisor else u64(divisor)

	uq, ur, div_ok := divide_u128_by_u64(abs_lo, abs_hi, abs_div)
	if !div_ok {
		return 0, 0, false
	}

	neg_quot := neg_dividend != neg_divisor
	if neg_quot {
		if uq > (u64(1) << 63) {
			return 0, 0, false
		}
		quotient = i64(0 - uq)
	} else {
		if uq >= (u64(1) << 63) {
			return 0, 0, false
		}
		quotient = i64(uq)
	}
	remainder = i64(0 - ur) if neg_dividend else i64(ur)
	return quotient, remainder, true
}

@(private)
execute_imul_truncating :: proc "contextless" (cpu: ^Processor_State, left, right: u64, width: Operand_Width) -> u64 {
	sa := sign_extend_to_i64(left, width)
	sb := sign_extend_to_i64(right, width)
	lo, hi := multiply_i64_to_i128(sa, sb)
	truncated := lo & width_mask(width)
	sext_truncated := sign_extend_to_i64(truncated, width)
	expected_hi := i64(-1) if sext_truncated < 0 else i64(0)
	overflow := (i64(lo) != sext_truncated) || (hi != expected_hi)
	set_flag(cpu, RFLAGS_CF, overflow)
	set_flag(cpu, RFLAGS_OF, overflow)
	return truncated
}

@(private)
execute_stack_push :: proc "contextless" (
	cpu: ^Processor_State,
	physical_memory: []u8,
	instruction_start_rip: u64,
	width: Operand_Width,
	value: u64,
) -> Step_Outcome {
	step_bytes := u64(width)
	new_rsp := cpu.registers[int(General_Register.Rsp)] - step_bytes
	outcome := write_memory_width(cpu, physical_memory, instruction_start_rip, new_rsp, width, value)
	if outcome != .Running {
		return outcome
	}
	cpu.registers[int(General_Register.Rsp)] = new_rsp
	return .Running
}

@(private)
read_sse_operand :: proc "contextless" (
	cpu: ^Processor_State,
	physical_memory: []u8,
	instruction_start_rip: u64,
	next_rip: u64,
	modrm: Decoded_Modrm,
	require_16_byte_alignment: bool,
) -> (value: [16]u8, outcome: Step_Outcome) {
	if modrm.is_register {
		return cpu.xmm[modrm.rm_register & 15], .Running
	}
	address := resolve_effective_address(cpu, modrm, next_rip, true)
	if require_16_byte_alignment && (address & 15) != 0 {
		return {}, record_fault(cpu, instruction_start_rip, .General_Protection, address)
	}
	bytes, res := mmu_read_u128(&cpu.tlb, physical_memory, cpu.cr3, address, .User)
	if res.status != .Ok {
		return {}, record_translation_fault(cpu, instruction_start_rip, res)
	}
	return bytes, .Running
}

@(private)
write_sse_operand :: proc "contextless" (
	cpu: ^Processor_State,
	physical_memory: []u8,
	instruction_start_rip: u64,
	next_rip: u64,
	modrm: Decoded_Modrm,
	require_16_byte_alignment: bool,
	value: [16]u8,
) -> Step_Outcome {
	if modrm.is_register {
		cpu.xmm[modrm.rm_register & 15] = value
		return .Running
	}
	address := resolve_effective_address(cpu, modrm, next_rip, true)
	if require_16_byte_alignment && (address & 15) != 0 {
		return record_fault(cpu, instruction_start_rip, .General_Protection, address)
	}
	res := mmu_write_u128(&cpu.tlb, physical_memory, cpu.cr3, address, .User, value)
	if res.status != .Ok {
		return record_translation_fault(cpu, instruction_start_rip, res)
	}
	return .Running
}

@(private)
step_two_byte_opcode :: proc "contextless" (
	cpu: ^Processor_State,
	physical_memory: []u8,
	cursor: ^Instruction_Cursor,
	prefixes: Decoded_Prefixes,
) -> Step_Outcome {
	opcode2, o_op2 := fetch_u8(cpu, physical_memory, cursor)
	if o_op2 != .Running {
		return o_op2
	}
	width := operand_width_from_prefixes(prefixes)

	// SYSCALL (0F 05): save return RIP into RCX and RFLAGS into R11, advance
	// RIP past the instruction, and trap cleanly to the kernel loop.
	if opcode2 == 0x05 {
		next_rip := cursor.current_rip
		cpu.registers[int(General_Register.Rcx)] = next_rip
		cpu.registers[int(General_Register.R11)] = cpu.rflags
		cpu.syscall_return_rip = next_rip
		cpu.syscall_saved_rflags = cpu.rflags
		cpu.rip = next_rip
		cpu.steps_executed += 1
		cpu.outcome = .Syscall
		return .Syscall
	}

	// UD2 (0F 0B): architectural undefined instruction fault.
	if opcode2 == 0x0B {
		return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
	}

	// Multi-byte NOP r/m (0F 1F /0).
	if opcode2 == 0x1F {
		_, o_modrm := decode_modrm(cpu, physical_memory, cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running
	}

	// CMOVcc r, r/m (0F 40..4F). Memory operand is read unconditionally so a
	// faulting address still traps; 32-bit destination always zero-extends.
	if opcode2 >= 0x40 && opcode2 <= 0x4F {
		modrm, o_modrm := decode_modrm(cpu, physical_memory, cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		source, o_src := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, width, prefixes.has_rex)
		if o_src != .Running {
			return o_src
		}
		cc, cc_ok := condition_code_from_word(opcode2 & 0x0F)
		if !cc_ok {
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		}
		if evaluate_condition(cpu, cc) {
			write_register(cpu, modrm.reg_index, width, prefixes.has_rex, source)
		} else if width == .Bits_32 {
			existing := read_register(cpu, modrm.reg_index, .Bits_32, prefixes.has_rex)
			write_register(cpu, modrm.reg_index, .Bits_32, prefixes.has_rex, existing)
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running
	}

	// Jcc rel32 (0F 80..8F).
	if opcode2 >= 0x80 && opcode2 <= 0x8F {
		rel32, o_rel := fetch_u32(cpu, physical_memory, cursor)
		if o_rel != .Running {
			return o_rel
		}
		cc, cc_ok := condition_code_from_word(opcode2 & 0x0F)
		if !cc_ok {
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		}
		if evaluate_condition(cpu, cc) {
			target := cursor.current_rip + u64(i64(i32(rel32)))
			if !is_canonical_virtual_address(target) {
				return record_fault(cpu, cursor.start_rip, .General_Protection, target)
			}
			cpu.rip = target
		} else {
			cpu.rip = cursor.current_rip
		}
		cpu.steps_executed += 1
		return .Running
	}

	// SETcc r/m8 (0F 90..9F).
	if opcode2 >= 0x90 && opcode2 <= 0x9F {
		modrm, o_modrm := decode_modrm(cpu, physical_memory, cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		cc, cc_ok := condition_code_from_word(opcode2 & 0x0F)
		if !cc_ok {
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		}
		flag_byte := u64(1) if evaluate_condition(cpu, cc) else u64(0)
		o_write := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, .Bits_8, prefixes.has_rex, flag_byte)
		if o_write != .Running {
			return o_write
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running
	}

	// IMUL r, r/m (0F AF).
	if opcode2 == 0xAF {
		modrm, o_modrm := decode_modrm(cpu, physical_memory, cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		source, o_src := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, width, prefixes.has_rex)
		if o_src != .Running {
			return o_src
		}
		dest := read_register(cpu, modrm.reg_index, width, prefixes.has_rex)
		product := execute_imul_truncating(cpu, dest, source, width)
		write_register(cpu, modrm.reg_index, width, prefixes.has_rex, product)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running
	}

	// CMPXCHG r/m8, r8 (0F B0) and CMPXCHG r/m16/32/64, r (0F B1).
	if opcode2 == 0xB0 || opcode2 == 0xB1 {
		op_width := Operand_Width.Bits_8 if opcode2 == 0xB0 else width
		modrm, o_modrm := decode_modrm(cpu, physical_memory, cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		current_val, o_read := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex)
		if o_read != .Running {
			return o_read
		}
		accumulator := read_register(cpu, u8(General_Register.Rax), op_width, prefixes.has_rex)
		_, _ = execute_alu(cpu, .Cmp, accumulator, current_val, op_width)
		if accumulator == current_val {
			replacement := read_register(cpu, modrm.reg_index, op_width, prefixes.has_rex)
			o_write := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex, replacement)
			if o_write != .Running {
				return o_write
			}
		} else {
			// The processor writes the destination back with its own value
			// when the compare fails (Intel SDM, CMPXCHG), so a destination
			// that the user cannot write faults in both cases.
			if !modrm.is_register {
				o_write := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex, current_val)
				if o_write != .Running {
					return o_write
				}
			}
			write_register(cpu, u8(General_Register.Rax), op_width, prefixes.has_rex, current_val)
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running
	}

	// MOVZX r, r/m8 (0F B6) and MOVZX r, r/m16 (0F B7).
	if opcode2 == 0xB6 || opcode2 == 0xB7 {
		src_width := Operand_Width.Bits_8 if opcode2 == 0xB6 else Operand_Width.Bits_16
		modrm, o_modrm := decode_modrm(cpu, physical_memory, cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		source, o_src := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, src_width, prefixes.has_rex)
		if o_src != .Running {
			return o_src
		}
		write_register(cpu, modrm.reg_index, width, prefixes.has_rex, source)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running
	}

	// MOVSX r, r/m8 (0F BE) and MOVSX r, r/m16 (0F BF).
	if opcode2 == 0xBE || opcode2 == 0xBF {
		src_width := Operand_Width.Bits_8 if opcode2 == 0xBE else Operand_Width.Bits_16
		modrm, o_modrm := decode_modrm(cpu, physical_memory, cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		source, o_src := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, src_width, prefixes.has_rex)
		if o_src != .Running {
			return o_src
		}
		extended := u64(sign_extend_to_i64(source, src_width))
		write_register(cpu, modrm.reg_index, width, prefixes.has_rex, extended)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running
	}

	// XADD r/m8, r8 (0F C0) and XADD r/m, r (0F C1).
	if opcode2 == 0xC0 || opcode2 == 0xC1 {
		op_width := Operand_Width.Bits_8 if opcode2 == 0xC0 else width
		modrm, o_modrm := decode_modrm(cpu, physical_memory, cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		dest_val, o_read := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex)
		if o_read != .Running {
			return o_read
		}
		src_val := read_register(cpu, modrm.reg_index, op_width, prefixes.has_rex)
		sum, _ := execute_alu(cpu, .Add, dest_val, src_val, op_width)
		o_write := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex, sum)
		if o_write != .Running {
			return o_write
		}
		write_register(cpu, modrm.reg_index, op_width, prefixes.has_rex, dest_val)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running
	}

	if simd_outcome, simd_handled := simd_step(cpu, physical_memory, cursor, prefixes, opcode2); simd_handled {
		return simd_outcome
	}
	if integer_outcome, integer_handled := integer_two_byte_step(cpu, physical_memory, cursor, prefixes, opcode2); integer_handled {
		return integer_outcome
	}
	return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
}

// processor_step fetches and executes one x86-64 user-mode instruction (or one
// iteration of a `rep` string instruction) strictly through the Software MMU.
processor_step :: proc "contextless" (cpu: ^Processor_State, physical_memory: []u8) -> Step_Outcome {
	// A fault on x86-64 is precise, but a read-modify-write form computes its
	// flags, and some forms write a register, before the memory write that
	// can fault. The state before the instruction comes back here, in one
	// place for every form, so no new form can forget it.
	cpu.rflags |= RFLAGS_RESERVED_ONE
	registers_before := cpu.registers
	rflags_before := cpu.rflags
	outcome := instruction_execute(cpu, physical_memory)
	switch outcome {
	case .Page_Fault, .General_Protection, .Invalid_Opcode, .Divide_Error, .Simd_Floating_Point:
		cpu.registers = registers_before
		cpu.rflags = rflags_before
	case .Running, .Syscall, .Breakpoint, .Step_Budget_Exhausted, .Halted:
	}
	return outcome
}

// instruction_execute decodes and executes one instruction for processor_step.
@(private)
instruction_execute :: proc "contextless" (cpu: ^Processor_State, physical_memory: []u8) -> Step_Outcome {
	cpu.fault_address = 0
	cpu.fault_error_code = 0
	cpu.outcome = .Running

	cursor := Instruction_Cursor {
		start_rip   = cpu.rip,
		current_rip = cpu.rip,
	}

	prefixes: Decoded_Prefixes
	opcode := u8(0)

	// Decode legacy prefixes and REX prefix. A legacy prefix appearing after a
	// REX byte cancels the earlier REX per x86-64 rules.
	prefix_loop: for {
		byte, o_fetch := fetch_u8(cpu, physical_memory, &cursor)
		if o_fetch != .Running {
			return o_fetch
		}
		switch byte {
		case 0x66:
			prefixes.has_operand_size_override = true
			prefixes.has_rex = false
			prefixes.rex_w = false
			prefixes.rex_r = false
			prefixes.rex_x = false
			prefixes.rex_b = false
		case 0x67:
			prefixes.has_address_size_override = true
			prefixes.has_rex = false
			prefixes.rex_w = false
			prefixes.rex_r = false
			prefixes.rex_x = false
			prefixes.rex_b = false
		case 0xF0:
			prefixes.has_lock = true
			prefixes.has_rex = false
			prefixes.rex_w = false
			prefixes.rex_r = false
			prefixes.rex_x = false
			prefixes.rex_b = false
		case 0xF2:
			prefixes.has_repne = true
			prefixes.last_repeat_is_not_equal = true
			prefixes.has_rex = false
			prefixes.rex_w = false
			prefixes.rex_r = false
			prefixes.rex_x = false
			prefixes.rex_b = false
		case 0xF3:
			prefixes.has_rep = true
			prefixes.last_repeat_is_not_equal = false
			prefixes.has_rex = false
			prefixes.rex_w = false
			prefixes.rex_r = false
			prefixes.rex_x = false
			prefixes.rex_b = false
		case 0x65:
			prefixes.has_gs_override = true
			prefixes.has_rex = false
			prefixes.rex_w = false
			prefixes.rex_r = false
			prefixes.rex_x = false
			prefixes.rex_b = false
		case 0x26, 0x2E, 0x36, 0x3E:
			// ES, CS, SS, DS segment overrides have base 0 in 64-bit mode.
			prefixes.has_rex = false
			prefixes.rex_w = false
			prefixes.rex_r = false
			prefixes.rex_x = false
			prefixes.rex_b = false
		case 0x40 ..= 0x4F:
			prefixes.has_rex = true
			prefixes.rex_w = (byte & 0x08) != 0
			prefixes.rex_r = (byte & 0x04) != 0
			prefixes.rex_x = (byte & 0x02) != 0
			prefixes.rex_b = (byte & 0x01) != 0
		case:
			opcode = byte
			break prefix_loop
		}
	}

	// Two-byte opcode escape (0x0F).
	if opcode == 0x0F {
		return step_two_byte_opcode(cpu, physical_memory, &cursor, prefixes)
	}

	width := operand_width_from_prefixes(prefixes)

	// Standard 8-ALU-op matrix (0x00..0x3D): ADD, OR, ADC, SBB, AND, SUB, XOR, CMP.
	if opcode <= 0x3D && (opcode & 0x07) <= 5 {
		alu_op, op_ok := alu_operation_from_word(opcode >> 3)
		if !op_ok {
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		}
		form := opcode & 0x07
		switch form {
		case 0:
			// ALU r/m8, r8
			modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
			if o_modrm != .Running {
				return o_modrm
			}
			lhs, o_lhs := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, .Bits_8, prefixes.has_rex)
			if o_lhs != .Running {
				return o_lhs
			}
			rhs := read_register(cpu, modrm.reg_index, .Bits_8, prefixes.has_rex)
			res, wb := execute_alu(cpu, alu_op, lhs, rhs, .Bits_8)
			if wb {
				o_w := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, .Bits_8, prefixes.has_rex, res)
				if o_w != .Running {
					return o_w
				}
			}
		case 1:
			// ALU r/m, r
			modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
			if o_modrm != .Running {
				return o_modrm
			}
			lhs, o_lhs := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, width, prefixes.has_rex)
			if o_lhs != .Running {
				return o_lhs
			}
			rhs := read_register(cpu, modrm.reg_index, width, prefixes.has_rex)
			res, wb := execute_alu(cpu, alu_op, lhs, rhs, width)
			if wb {
				o_w := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, width, prefixes.has_rex, res)
				if o_w != .Running {
					return o_w
				}
			}
		case 2:
			// ALU r8, r/m8
			modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
			if o_modrm != .Running {
				return o_modrm
			}
			rhs, o_rhs := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, .Bits_8, prefixes.has_rex)
			if o_rhs != .Running {
				return o_rhs
			}
			lhs := read_register(cpu, modrm.reg_index, .Bits_8, prefixes.has_rex)
			res, wb := execute_alu(cpu, alu_op, lhs, rhs, .Bits_8)
			if wb {
				write_register(cpu, modrm.reg_index, .Bits_8, prefixes.has_rex, res)
			}
		case 3:
			// ALU r, r/m
			modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
			if o_modrm != .Running {
				return o_modrm
			}
			rhs, o_rhs := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, width, prefixes.has_rex)
			if o_rhs != .Running {
				return o_rhs
			}
			lhs := read_register(cpu, modrm.reg_index, width, prefixes.has_rex)
			res, wb := execute_alu(cpu, alu_op, lhs, rhs, width)
			if wb {
				write_register(cpu, modrm.reg_index, width, prefixes.has_rex, res)
			}
		case 4:
			// ALU AL, imm8
			imm, o_imm := fetch_u8(cpu, physical_memory, &cursor)
			if o_imm != .Running {
				return o_imm
			}
			lhs := read_register(cpu, u8(General_Register.Rax), .Bits_8, prefixes.has_rex)
			res, wb := execute_alu(cpu, alu_op, lhs, u64(imm), .Bits_8)
			if wb {
				write_register(cpu, u8(General_Register.Rax), .Bits_8, prefixes.has_rex, res)
			}
		case 5:
			// ALU rAX, imm16/32
			imm, o_imm := fetch_sign_extended_immediate(cpu, physical_memory, &cursor, width)
			if o_imm != .Running {
				return o_imm
			}
			lhs := read_register(cpu, u8(General_Register.Rax), width, prefixes.has_rex)
			res, wb := execute_alu(cpu, alu_op, lhs, imm, width)
			if wb {
				write_register(cpu, u8(General_Register.Rax), width, prefixes.has_rex, res)
			}
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running
	}

	// PUSH r64/r16 (0x50..0x57).
	if opcode >= 0x50 && opcode <= 0x57 {
		reg := (opcode - 0x50) | (prefixes.rex_b ? u8(8) : 0)
		push_width := Operand_Width.Bits_16 if (prefixes.has_operand_size_override && !prefixes.rex_w) else Operand_Width.Bits_64
		val := read_register(cpu, reg, push_width, prefixes.has_rex)
		o_push := execute_stack_push(cpu, physical_memory, cursor.start_rip, push_width, val)
		if o_push != .Running {
			return o_push
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running
	}

	// POP r64/r16 (0x58..0x5F).
	if opcode >= 0x58 && opcode <= 0x5F {
		reg := (opcode - 0x58) | (prefixes.rex_b ? u8(8) : 0)
		pop_width := Operand_Width.Bits_16 if (prefixes.has_operand_size_override && !prefixes.rex_w) else Operand_Width.Bits_64
		rsp := cpu.registers[int(General_Register.Rsp)]
		val, o_read := read_memory_width(cpu, physical_memory, cursor.start_rip, rsp, pop_width)
		if o_read != .Running {
			return o_read
		}
		cpu.registers[int(General_Register.Rsp)] = rsp + u64(pop_width)
		write_register(cpu, reg, pop_width, prefixes.has_rex, val)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running
	}

	// Jcc rel8 (0x70..0x7F).
	if opcode >= 0x70 && opcode <= 0x7F {
		rel8, o_rel := fetch_u8(cpu, physical_memory, &cursor)
		if o_rel != .Running {
			return o_rel
		}
		cc, cc_ok := condition_code_from_word(opcode & 0x0F)
		if !cc_ok {
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		}
		if evaluate_condition(cpu, cc) {
			target := cursor.current_rip + u64(i64(i8(rel8)))
			if !is_canonical_virtual_address(target) {
				return record_fault(cpu, cursor.start_rip, .General_Protection, target)
			}
			cpu.rip = target
		} else {
			cpu.rip = cursor.current_rip
		}
		cpu.steps_executed += 1
		return .Running
	}

	// MOV r8, imm8 (0xB0..0xB7).
	if opcode >= 0xB0 && opcode <= 0xB7 {
		reg := (opcode - 0xB0) | (prefixes.rex_b ? u8(8) : 0)
		imm, o_imm := fetch_u8(cpu, physical_memory, &cursor)
		if o_imm != .Running {
			return o_imm
		}
		write_register(cpu, reg, .Bits_8, prefixes.has_rex, u64(imm))
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running
	}

	// MOV r16/32/64, imm16/32/64 (0xB8..0xBF, including MOVABS with REX.W).
	if opcode >= 0xB8 && opcode <= 0xBF {
		reg := (opcode - 0xB8) | (prefixes.rex_b ? u8(8) : 0)
		imm := u64(0)
		o_imm := Step_Outcome.Running
		switch width {
		case .Bits_8:
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		case .Bits_16:
			v, o := fetch_u16(cpu, physical_memory, &cursor)
			imm, o_imm = u64(v), o
		case .Bits_32:
			v, o := fetch_u32(cpu, physical_memory, &cursor)
			imm, o_imm = u64(v), o
		case .Bits_64:
			imm, o_imm = fetch_u64(cpu, physical_memory, &cursor)
		}
		if o_imm != .Running {
			return o_imm
		}
		write_register(cpu, reg, width, prefixes.has_rex, imm)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running
	}

	switch opcode {
	case 0x63:
		// MOVSXD r64/32/16, r/m32.
		modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		src_w := Operand_Width.Bits_16 if width == .Bits_16 else Operand_Width.Bits_32
		source, o_src := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, src_w, prefixes.has_rex)
		if o_src != .Running {
			return o_src
		}
		extended := u64(sign_extend_to_i64(source, src_w))
		write_register(cpu, modrm.reg_index, width, prefixes.has_rex, extended)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0x68, 0x6A:
		// PUSH imm32/imm16 (0x68) or PUSH imm8 (0x6A).
		push_width := Operand_Width.Bits_16 if (prefixes.has_operand_size_override && !prefixes.rex_w) else Operand_Width.Bits_64
		imm := u64(0)
		o_imm := Step_Outcome.Running
		if opcode == 0x6A {
			v, o := fetch_u8(cpu, physical_memory, &cursor)
			imm, o_imm = u64(i64(i8(v))), o
		} else if push_width == .Bits_16 {
			v, o := fetch_u16(cpu, physical_memory, &cursor)
			imm, o_imm = u64(v), o
		} else {
			v, o := fetch_u32(cpu, physical_memory, &cursor)
			imm, o_imm = u64(i64(i32(v))), o
		}
		if o_imm != .Running {
			return o_imm
		}
		o_push := execute_stack_push(cpu, physical_memory, cursor.start_rip, push_width, imm)
		if o_push != .Running {
			return o_push
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0x69, 0x6B:
		// IMUL r, r/m, imm32/imm16 (0x69) or imm8 (0x6B).
		modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		imm := u64(0)
		o_imm := Step_Outcome.Running
		if opcode == 0x6B {
			v, o := fetch_u8(cpu, physical_memory, &cursor)
			imm, o_imm = u64(i64(i8(v))), o
		} else {
			imm, o_imm = fetch_sign_extended_immediate(cpu, physical_memory, &cursor, width)
		}
		if o_imm != .Running {
			return o_imm
		}
		source, o_src := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, width, prefixes.has_rex)
		if o_src != .Running {
			return o_src
		}
		product := execute_imul_truncating(cpu, source, imm, width)
		write_register(cpu, modrm.reg_index, width, prefixes.has_rex, product)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0x80, 0x81, 0x83:
		// Immediate Group 1: ALU r/m, imm.
		op_width := Operand_Width.Bits_8 if opcode == 0x80 else width
		modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		imm := u64(0)
		o_imm := Step_Outcome.Running
		if opcode == 0x80 {
			v, o := fetch_u8(cpu, physical_memory, &cursor)
			imm, o_imm = u64(v), o
		} else if opcode == 0x83 {
			v, o := fetch_u8(cpu, physical_memory, &cursor)
			imm, o_imm = u64(i64(i8(v))), o
		} else {
			imm, o_imm = fetch_sign_extended_immediate(cpu, physical_memory, &cursor, width)
		}
		if o_imm != .Running {
			return o_imm
		}
		lhs, o_lhs := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex)
		if o_lhs != .Running {
			return o_lhs
		}
		alu_op, op_ok := alu_operation_from_word(modrm.reg_index & 7)
		if !op_ok {
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		}
		res, wb := execute_alu(cpu, alu_op, lhs, imm, op_width)
		if wb {
			o_w := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex, res)
			if o_w != .Running {
				return o_w
			}
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0x84, 0x85:
		// TEST r/m, r.
		op_width := Operand_Width.Bits_8 if opcode == 0x84 else width
		modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		lhs, o_lhs := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex)
		if o_lhs != .Running {
			return o_lhs
		}
		rhs := read_register(cpu, modrm.reg_index, op_width, prefixes.has_rex)
		execute_test_flags(cpu, lhs, rhs, op_width)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0x86, 0x87:
		// XCHG r/m, r.
		op_width := Operand_Width.Bits_8 if opcode == 0x86 else width
		modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		rm_val, o_rm := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex)
		if o_rm != .Running {
			return o_rm
		}
		reg_val := read_register(cpu, modrm.reg_index, op_width, prefixes.has_rex)
		o_w := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex, reg_val)
		if o_w != .Running {
			return o_w
		}
		write_register(cpu, modrm.reg_index, op_width, prefixes.has_rex, rm_val)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0x88, 0x89:
		// MOV r/m, r.
		op_width := Operand_Width.Bits_8 if opcode == 0x88 else width
		modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		val := read_register(cpu, modrm.reg_index, op_width, prefixes.has_rex)
		o_w := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex, val)
		if o_w != .Running {
			return o_w
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0x8A, 0x8B:
		// MOV r, r/m.
		op_width := Operand_Width.Bits_8 if opcode == 0x8A else width
		modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		val, o_r := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex)
		if o_r != .Running {
			return o_r
		}
		write_register(cpu, modrm.reg_index, op_width, prefixes.has_rex, val)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0x8D:
		// LEA r, m (never reads memory; refuses register source mod == 3).
		modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		if modrm.is_register {
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		}
		ea := resolve_effective_address(cpu, modrm, cursor.current_rip, false)
		write_register(cpu, modrm.reg_index, width, prefixes.has_rex, ea)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0x8F:
		// POP r/m64/16 (0x8F /0). Memory addressing using RSP observes the
		// post-increment RSP, and faults roll RSP back cleanly.
		modrm_cursor := cursor
		modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		if (modrm.reg_index & 7) != 0 {
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		}
		pop_width := Operand_Width.Bits_16 if (prefixes.has_operand_size_override && !prefixes.rex_w) else Operand_Width.Bits_64
		old_rsp := cpu.registers[int(General_Register.Rsp)]
		val, o_read := read_memory_width(cpu, physical_memory, cursor.start_rip, old_rsp, pop_width)
		if o_read != .Running {
			return o_read
		}
		cpu.registers[int(General_Register.Rsp)] = old_rsp + u64(pop_width)
		if !modrm.is_register {
			redecode_cursor := modrm_cursor
			updated_modrm, o_redecode := decode_modrm(cpu, physical_memory, &redecode_cursor, prefixes)
			if o_redecode != .Running {
				cpu.registers[int(General_Register.Rsp)] = old_rsp
				return o_redecode
			}
			o_w := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, updated_modrm, pop_width, prefixes.has_rex, val)
			if o_w != .Running {
				cpu.registers[int(General_Register.Rsp)] = old_rsp
				return o_w
			}
		} else {
			write_register(cpu, modrm.rm_register, pop_width, prefixes.has_rex, val)
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0x90 ..= 0x97:
		// NOP (0x90 without REX.B) or XCHG r, rAX.
		if opcode == 0x90 && !prefixes.rex_b {
			cpu.rip = cursor.current_rip
			cpu.steps_executed += 1
			return .Running
		}
		reg := (opcode - 0x90) | (prefixes.rex_b ? u8(8) : 0)
		a := read_register(cpu, u8(General_Register.Rax), width, prefixes.has_rex)
		b := read_register(cpu, reg, width, prefixes.has_rex)
		write_register(cpu, u8(General_Register.Rax), width, prefixes.has_rex, b)
		write_register(cpu, reg, width, prefixes.has_rex, a)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0x9C:
		// PUSHF: the flags, 64 bits or 16 with 66.
		push_width := Operand_Width.Bits_16 if (prefixes.has_operand_size_override && !prefixes.rex_w) else Operand_Width.Bits_64
		o_push := execute_stack_push(cpu, physical_memory, cursor.start_rip, push_width, cpu.rflags & width_mask(push_width))
		if o_push != .Running {
			return o_push
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0x9D:
		// POPF: a process changes the arithmetic flags and the direction
		// only. The interrupt flag and the I/O level need privilege, and
		// the processor runs no trap flag, alignment check or identification
		// flag (browser_machine.md, "The vector instructions").
		pop_width := Operand_Width.Bits_16 if (prefixes.has_operand_size_override && !prefixes.rex_w) else Operand_Width.Bits_64
		rsp := cpu.registers[int(General_Register.Rsp)]
		popped, o_read := read_memory_width(cpu, physical_memory, cursor.start_rip, rsp, pop_width)
		if o_read != .Running {
			return o_read
		}
		changeable := RFLAGS_CF | RFLAGS_PF | RFLAGS_AF | RFLAGS_ZF | RFLAGS_SF | RFLAGS_DF | RFLAGS_OF
		cpu.rflags = (cpu.rflags & ~changeable) | (popped & changeable) | RFLAGS_RESERVED_ONE
		cpu.registers[int(General_Register.Rsp)] = rsp + u64(pop_width)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0x98:
		// CBW / CWDE / CDQE.
		switch width {
		case .Bits_8:
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		case .Bits_16:
			v := read_register(cpu, u8(General_Register.Rax), .Bits_8, false)
			write_register(cpu, u8(General_Register.Rax), .Bits_16, false, u64(i64(i8(u8(v)))))
		case .Bits_32:
			v := read_register(cpu, u8(General_Register.Rax), .Bits_16, false)
			write_register(cpu, u8(General_Register.Rax), .Bits_32, false, u64(i64(i16(u16(v)))))
		case .Bits_64:
			v := read_register(cpu, u8(General_Register.Rax), .Bits_32, true)
			write_register(cpu, u8(General_Register.Rax), .Bits_64, true, u64(i64(i32(u32(v)))))
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0x99:
		// CWD / CDQ / CQO.
		switch width {
		case .Bits_8:
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		case .Bits_16:
			v := i16(u16(read_register(cpu, u8(General_Register.Rax), .Bits_16, false)))
			write_register(cpu, u8(General_Register.Rdx), .Bits_16, false, 0xFFFF if v < 0 else 0)
		case .Bits_32:
			v := i32(u32(read_register(cpu, u8(General_Register.Rax), .Bits_32, false)))
			write_register(cpu, u8(General_Register.Rdx), .Bits_32, false, 0xFFFF_FFFF if v < 0 else 0)
		case .Bits_64:
			v := i64(read_register(cpu, u8(General_Register.Rax), .Bits_64, true))
			write_register(cpu, u8(General_Register.Rdx), .Bits_64, true, max(u64) if v < 0 else 0)
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0xA4:
		// MOVSB / REP MOVSB: executes one byte per step so `max_steps` strictly
		// bounds arbitrary RCX counts and faults preserve exact progress.
		if prefixes.has_rep {
			rcx := cpu.registers[int(General_Register.Rcx)]
			if rcx == 0 {
				cpu.rip = cursor.current_rip
				cpu.steps_executed += 1
				return .Running
			}
			rsi := cpu.registers[int(General_Register.Rsi)]
			rdi := cpu.registers[int(General_Register.Rdi)]
			src_addr := rsi + (cpu.gs_base if prefixes.has_gs_override else 0)
			byte_val, res_r := mmu_read_u8(&cpu.tlb, physical_memory, cpu.cr3, src_addr, .User)
			if res_r.status != .Ok {
				return record_translation_fault(cpu, cursor.start_rip, res_r)
			}
			res_w := mmu_write_u8(&cpu.tlb, physical_memory, cpu.cr3, rdi, .User, byte_val)
			if res_w.status != .Ok {
				return record_translation_fault(cpu, cursor.start_rip, res_w)
			}
			delta := max(u64) if (cpu.rflags & RFLAGS_DF) != 0 else u64(1)
			cpu.registers[int(General_Register.Rsi)] = rsi + delta
			cpu.registers[int(General_Register.Rdi)] = rdi + delta
			cpu.registers[int(General_Register.Rcx)] = rcx - 1
			if rcx - 1 == 0 {
				cpu.rip = cursor.current_rip
			} else {
				cpu.rip = cursor.start_rip
			}
			cpu.steps_executed += 1
			return .Running
		}
		rsi := cpu.registers[int(General_Register.Rsi)]
		rdi := cpu.registers[int(General_Register.Rdi)]
		src_addr := rsi + (cpu.gs_base if prefixes.has_gs_override else 0)
		byte_val, res_r := mmu_read_u8(&cpu.tlb, physical_memory, cpu.cr3, src_addr, .User)
		if res_r.status != .Ok {
			return record_translation_fault(cpu, cursor.start_rip, res_r)
		}
		res_w := mmu_write_u8(&cpu.tlb, physical_memory, cpu.cr3, rdi, .User, byte_val)
		if res_w.status != .Ok {
			return record_translation_fault(cpu, cursor.start_rip, res_w)
		}
		delta := max(u64) if (cpu.rflags & RFLAGS_DF) != 0 else u64(1)
		cpu.registers[int(General_Register.Rsi)] = rsi + delta
		cpu.registers[int(General_Register.Rdi)] = rdi + delta
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0xAA:
		// STOSB / REP STOSB: one byte per step so `max_steps` strictly bounds RCX.
		al := u8(cpu.registers[int(General_Register.Rax)] & 0xFF)
		if prefixes.has_rep {
			rcx := cpu.registers[int(General_Register.Rcx)]
			if rcx == 0 {
				cpu.rip = cursor.current_rip
				cpu.steps_executed += 1
				return .Running
			}
			rdi := cpu.registers[int(General_Register.Rdi)]
			res_w := mmu_write_u8(&cpu.tlb, physical_memory, cpu.cr3, rdi, .User, al)
			if res_w.status != .Ok {
				return record_translation_fault(cpu, cursor.start_rip, res_w)
			}
			delta := max(u64) if (cpu.rflags & RFLAGS_DF) != 0 else u64(1)
			cpu.registers[int(General_Register.Rdi)] = rdi + delta
			cpu.registers[int(General_Register.Rcx)] = rcx - 1
			if rcx - 1 == 0 {
				cpu.rip = cursor.current_rip
			} else {
				cpu.rip = cursor.start_rip
			}
			cpu.steps_executed += 1
			return .Running
		}
		rdi := cpu.registers[int(General_Register.Rdi)]
		res_w := mmu_write_u8(&cpu.tlb, physical_memory, cpu.cr3, rdi, .User, al)
		if res_w.status != .Ok {
			return record_translation_fault(cpu, cursor.start_rip, res_w)
		}
		delta := max(u64) if (cpu.rflags & RFLAGS_DF) != 0 else u64(1)
		cpu.registers[int(General_Register.Rdi)] = rdi + delta
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0xA8, 0xA9:
		// TEST AL, imm8 (0xA8) or TEST rAX, imm16/32 (0xA9).
		op_width := Operand_Width.Bits_8 if opcode == 0xA8 else width
		imm, o_imm := fetch_sign_extended_immediate(cpu, physical_memory, &cursor, op_width)
		if o_imm != .Running {
			return o_imm
		}
		lhs := read_register(cpu, u8(General_Register.Rax), op_width, prefixes.has_rex)
		execute_test_flags(cpu, lhs, imm, op_width)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0xC0, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3:
		// Shift/Rotate Group 2.
		op_width := Operand_Width.Bits_8 if (opcode == 0xC0 || opcode == 0xD0 || opcode == 0xD2) else width
		modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		shift_count := u8(1)
		if opcode == 0xC0 || opcode == 0xC1 {
			c, o_c := fetch_u8(cpu, physical_memory, &cursor)
			if o_c != .Running {
				return o_c
			}
			shift_count = c
		} else if opcode == 0xD2 || opcode == 0xD3 {
			shift_count = u8(cpu.registers[int(General_Register.Rcx)] & 0xFF)
		}

		sub := modrm.reg_index & 7
		shift_op: Shift_Operation
		switch sub {
		case 0:
			shift_op = .Rol
		case 1:
			shift_op = .Ror
		case 4, 6:
			shift_op = .Shl
		case 5:
			shift_op = .Shr
		case 7:
			shift_op = .Sar
		case:
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		}

		val, o_read := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex)
		if o_read != .Running {
			return o_read
		}
		shifted := execute_shift(cpu, shift_op, val, shift_count, op_width)
		o_w := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex, shifted)
		if o_w != .Running {
			return o_w
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0xC2, 0xC3:
		// RET imm16 (0xC2) or RET (0xC3).
		pop_extra := u64(0)
		if opcode == 0xC2 {
			imm16, o_imm := fetch_u16(cpu, physical_memory, &cursor)
			if o_imm != .Running {
				return o_imm
			}
			pop_extra = u64(imm16)
		}
		rsp := cpu.registers[int(General_Register.Rsp)]
		ret_rip, o_read := read_memory_width(cpu, physical_memory, cursor.start_rip, rsp, .Bits_64)
		if o_read != .Running {
			return o_read
		}
		if !is_canonical_virtual_address(ret_rip) {
			return record_fault(cpu, cursor.start_rip, .General_Protection, ret_rip)
		}
		cpu.registers[int(General_Register.Rsp)] = rsp + 8 + pop_extra
		cpu.rip = ret_rip
		cpu.steps_executed += 1
		return .Running

	case 0xC6, 0xC7:
		// MOV r/m, imm (only /0 is architectural).
		op_width := Operand_Width.Bits_8 if opcode == 0xC6 else width
		modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		if (modrm.reg_index & 7) != 0 {
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		}
		imm, o_imm := fetch_sign_extended_immediate(cpu, physical_memory, &cursor, op_width)
		if o_imm != .Running {
			return o_imm
		}
		o_w := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex, imm)
		if o_w != .Running {
			return o_w
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0xC9:
		// LEAVE: mov rsp, rbp; pop rbp (atomic if stack pop faults).
		frame_base := cpu.registers[int(General_Register.Rbp)]
		saved_rbp, o_read := read_memory_width(cpu, physical_memory, cursor.start_rip, frame_base, .Bits_64)
		if o_read != .Running {
			return o_read
		}
		cpu.registers[int(General_Register.Rbp)] = saved_rbp
		cpu.registers[int(General_Register.Rsp)] = frame_base + 8
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0xCC:
		// INT3: software breakpoint trap.
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		cpu.outcome = .Breakpoint
		return .Breakpoint

	case 0xE4, 0xE5, 0xE6, 0xE7, 0xEC, 0xED, 0xEE, 0xEF:
		// IN and OUT: the port is an 8-bit immediate (0xE4 to 0xE7) or dx;
		// the value is al, or ax with 0x66, else eax. REX.W changes
		// nothing. A refused port is a protection fault with error code 0,
		// before the device sees the access.
		port_width := Operand_Width.Bits_8
		if opcode & 1 != 0 {
			port_width = .Bits_16 if prefixes.has_operand_size_override && !prefixes.rex_w else .Bits_32
		}
		port: u16
		if opcode <= 0xE7 {
			immediate, o_immediate := fetch_u8(cpu, physical_memory, &cursor)
			if o_immediate != .Running {
				return o_immediate
			}
			port = u16(immediate)
		} else {
			port = u16(cpu.registers[int(General_Register.Rdx)])
		}
		if !port_access_permitted(cpu.ports, port, port_width) {
			return record_fault(cpu, cursor.start_rip, .General_Protection)
		}
		if opcode & 0x02 == 0 {
			value := cpu.ports.read(port, port_width)
			write_register(cpu, u8(General_Register.Rax), port_width, true, u64(value))
		} else {
			value := read_register(cpu, u8(General_Register.Rax), port_width, true)
			cpu.ports.write(port, port_width, u32(value))
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0xE8:
		// CALL rel32.
		rel32, o_rel := fetch_u32(cpu, physical_memory, &cursor)
		if o_rel != .Running {
			return o_rel
		}
		target := cursor.current_rip + u64(i64(i32(rel32)))
		if !is_canonical_virtual_address(target) {
			return record_fault(cpu, cursor.start_rip, .General_Protection, target)
		}
		o_push := execute_stack_push(cpu, physical_memory, cursor.start_rip, .Bits_64, cursor.current_rip)
		if o_push != .Running {
			return o_push
		}
		cpu.rip = target
		cpu.steps_executed += 1
		return .Running

	case 0xE9:
		// JMP rel32.
		rel32, o_rel := fetch_u32(cpu, physical_memory, &cursor)
		if o_rel != .Running {
			return o_rel
		}
		target := cursor.current_rip + u64(i64(i32(rel32)))
		if !is_canonical_virtual_address(target) {
			return record_fault(cpu, cursor.start_rip, .General_Protection, target)
		}
		cpu.rip = target
		cpu.steps_executed += 1
		return .Running

	case 0xEB:
		// JMP rel8.
		rel8, o_rel := fetch_u8(cpu, physical_memory, &cursor)
		if o_rel != .Running {
			return o_rel
		}
		target := cursor.current_rip + u64(i64(i8(rel8)))
		if !is_canonical_virtual_address(target) {
			return record_fault(cpu, cursor.start_rip, .General_Protection, target)
		}
		cpu.rip = target
		cpu.steps_executed += 1
		return .Running

	case 0xF6, 0xF7:
		// Unary Group 3: TEST, NOT, NEG, MUL, IMUL, DIV, IDIV.
		op_width := Operand_Width.Bits_8 if opcode == 0xF6 else width
		modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		sub := modrm.reg_index & 7
		switch sub {
		case 0, 1:
			// TEST r/m, imm.
			imm, o_imm := fetch_sign_extended_immediate(cpu, physical_memory, &cursor, op_width)
			if o_imm != .Running {
				return o_imm
			}
			lhs, o_lhs := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex)
			if o_lhs != .Running {
				return o_lhs
			}
			execute_test_flags(cpu, lhs, imm, op_width)
		case 2:
			// NOT r/m (does not modify flags).
			val, o_r := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex)
			if o_r != .Running {
				return o_r
			}
			o_w := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex, (~val) & width_mask(op_width))
			if o_w != .Running {
				return o_w
			}
		case 3:
			// NEG r/m.
			val, o_r := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex)
			if o_r != .Running {
				return o_r
			}
			mask := width_mask(op_width)
			ua := val & mask
			res := (0 - ua) & mask
			set_flag(cpu, RFLAGS_CF, ua != 0)
			set_flag(cpu, RFLAGS_OF, ua == width_sign_bit(op_width))
			set_flag(cpu, RFLAGS_AF, (ua & 0xF) != 0)
			update_szp_flags(cpu, res, op_width)
			o_w := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex, res)
			if o_w != .Running {
				return o_w
			}
		case 4:
			// MUL r/m (unsigned widening multiply).
			rhs, o_r := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex)
			if o_r != .Running {
				return o_r
			}
			switch op_width {
			case .Bits_8:
				al := cpu.registers[int(General_Register.Rax)] & 0xFF
				prod := al * (rhs & 0xFF)
				write_register(cpu, u8(General_Register.Rax), .Bits_16, false, prod)
				ov := (prod >> 8) != 0
				set_flag(cpu, RFLAGS_CF, ov)
				set_flag(cpu, RFLAGS_OF, ov)
			case .Bits_16:
				ax := cpu.registers[int(General_Register.Rax)] & 0xFFFF
				prod := ax * (rhs & 0xFFFF)
				write_register(cpu, u8(General_Register.Rax), .Bits_16, false, prod & 0xFFFF)
				write_register(cpu, u8(General_Register.Rdx), .Bits_16, false, prod >> 16)
				ov := (prod >> 16) != 0
				set_flag(cpu, RFLAGS_CF, ov)
				set_flag(cpu, RFLAGS_OF, ov)
			case .Bits_32:
				eax := cpu.registers[int(General_Register.Rax)] & 0xFFFF_FFFF
				prod := eax * (rhs & 0xFFFF_FFFF)
				write_register(cpu, u8(General_Register.Rax), .Bits_32, false, prod & 0xFFFF_FFFF)
				write_register(cpu, u8(General_Register.Rdx), .Bits_32, false, prod >> 32)
				ov := (prod >> 32) != 0
				set_flag(cpu, RFLAGS_CF, ov)
				set_flag(cpu, RFLAGS_OF, ov)
			case .Bits_64:
				lo, hi := multiply_u64_to_u128(cpu.registers[int(General_Register.Rax)], rhs)
				cpu.registers[int(General_Register.Rax)] = lo
				cpu.registers[int(General_Register.Rdx)] = hi
				ov := hi != 0
				set_flag(cpu, RFLAGS_CF, ov)
				set_flag(cpu, RFLAGS_OF, ov)
			}
		case 5:
			// IMUL r/m (1-operand signed widening multiply).
			rhs, o_r := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex)
			if o_r != .Running {
				return o_r
			}
			switch op_width {
			case .Bits_8:
				al := i64(i8(u8(cpu.registers[int(General_Register.Rax)])))
				prod := al * i64(i8(u8(rhs)))
				write_register(cpu, u8(General_Register.Rax), .Bits_16, false, u64(prod))
				ov := prod != i64(i8(u8(prod)))
				set_flag(cpu, RFLAGS_CF, ov)
				set_flag(cpu, RFLAGS_OF, ov)
			case .Bits_16:
				ax := i64(i16(u16(cpu.registers[int(General_Register.Rax)])))
				prod := ax * i64(i16(u16(rhs)))
				write_register(cpu, u8(General_Register.Rax), .Bits_16, false, u64(prod) & 0xFFFF)
				write_register(cpu, u8(General_Register.Rdx), .Bits_16, false, (u64(prod) >> 16) & 0xFFFF)
				ov := prod != i64(i16(u16(prod)))
				set_flag(cpu, RFLAGS_CF, ov)
				set_flag(cpu, RFLAGS_OF, ov)
			case .Bits_32:
				eax := i64(i32(u32(cpu.registers[int(General_Register.Rax)])))
				prod := eax * i64(i32(u32(rhs)))
				write_register(cpu, u8(General_Register.Rax), .Bits_32, false, u64(prod) & 0xFFFF_FFFF)
				write_register(cpu, u8(General_Register.Rdx), .Bits_32, false, (u64(prod) >> 32) & 0xFFFF_FFFF)
				ov := prod != i64(i32(u32(prod)))
				set_flag(cpu, RFLAGS_CF, ov)
				set_flag(cpu, RFLAGS_OF, ov)
			case .Bits_64:
				lo, hi := multiply_i64_to_i128(i64(cpu.registers[int(General_Register.Rax)]), i64(rhs))
				cpu.registers[int(General_Register.Rax)] = lo
				cpu.registers[int(General_Register.Rdx)] = u64(hi)
				expected_hi := i64(-1) if i64(lo) < 0 else i64(0)
				ov := hi != expected_hi
				set_flag(cpu, RFLAGS_CF, ov)
				set_flag(cpu, RFLAGS_OF, ov)
			}
		case 6:
			// DIV r/m (unsigned division).
			divisor, o_r := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex)
			if o_r != .Running {
				return o_r
			}
			if divisor == 0 {
				return record_fault(cpu, cursor.start_rip, .Divide_Error, cursor.start_rip)
			}
			switch op_width {
			case .Bits_8:
				dividend := cpu.registers[int(General_Register.Rax)] & 0xFFFF
				q := dividend / divisor
				r := dividend % divisor
				if q > 0xFF {
					return record_fault(cpu, cursor.start_rip, .Divide_Error, cursor.start_rip)
				}
				write_register(cpu, u8(General_Register.Rax), .Bits_16, false, (q & 0xFF) | ((r & 0xFF) << 8))
			case .Bits_16:
				dividend := (cpu.registers[int(General_Register.Rax)] & 0xFFFF) | ((cpu.registers[int(General_Register.Rdx)] & 0xFFFF) << 16)
				q := dividend / divisor
				r := dividend % divisor
				if q > 0xFFFF {
					return record_fault(cpu, cursor.start_rip, .Divide_Error, cursor.start_rip)
				}
				write_register(cpu, u8(General_Register.Rax), .Bits_16, false, q)
				write_register(cpu, u8(General_Register.Rdx), .Bits_16, false, r)
			case .Bits_32:
				dividend := (cpu.registers[int(General_Register.Rax)] & 0xFFFF_FFFF) | ((cpu.registers[int(General_Register.Rdx)] & 0xFFFF_FFFF) << 32)
				q := dividend / divisor
				r := dividend % divisor
				if q > 0xFFFF_FFFF {
					return record_fault(cpu, cursor.start_rip, .Divide_Error, cursor.start_rip)
				}
				write_register(cpu, u8(General_Register.Rax), .Bits_32, false, q)
				write_register(cpu, u8(General_Register.Rdx), .Bits_32, false, r)
			case .Bits_64:
				q, r, ok := divide_u128_by_u64(cpu.registers[int(General_Register.Rax)], cpu.registers[int(General_Register.Rdx)], divisor)
				if !ok {
					return record_fault(cpu, cursor.start_rip, .Divide_Error, cursor.start_rip)
				}
				cpu.registers[int(General_Register.Rax)] = q
				cpu.registers[int(General_Register.Rdx)] = r
			}
		case 7:
			// IDIV r/m (signed division).
			raw_divisor, o_r := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, op_width, prefixes.has_rex)
			if o_r != .Running {
				return o_r
			}
			divisor := sign_extend_to_i64(raw_divisor, op_width)
			if divisor == 0 {
				return record_fault(cpu, cursor.start_rip, .Divide_Error, cursor.start_rip)
			}
			switch op_width {
			case .Bits_8:
				dividend := i64(i16(u16(cpu.registers[int(General_Register.Rax)])))
				q := dividend / divisor
				r := dividend % divisor
				if q < -128 || q > 127 {
					return record_fault(cpu, cursor.start_rip, .Divide_Error, cursor.start_rip)
				}
				write_register(cpu, u8(General_Register.Rax), .Bits_16, false, (u64(q) & 0xFF) | ((u64(r) & 0xFF) << 8))
			case .Bits_16:
				dividend := i64(i32(u32((cpu.registers[int(General_Register.Rax)] & 0xFFFF) | ((cpu.registers[int(General_Register.Rdx)] & 0xFFFF) << 16))))
				q := dividend / divisor
				r := dividend % divisor
				if q < -32768 || q > 32767 {
					return record_fault(cpu, cursor.start_rip, .Divide_Error, cursor.start_rip)
				}
				write_register(cpu, u8(General_Register.Rax), .Bits_16, false, u64(q))
				write_register(cpu, u8(General_Register.Rdx), .Bits_16, false, u64(r))
			case .Bits_32:
				dividend := i64((cpu.registers[int(General_Register.Rax)] & 0xFFFF_FFFF) | ((cpu.registers[int(General_Register.Rdx)] & 0xFFFF_FFFF) << 32))
				if dividend == min(i64) && divisor == -1 {
					return record_fault(cpu, cursor.start_rip, .Divide_Error, cursor.start_rip)
				}
				q := dividend / divisor
				r := dividend % divisor
				if q < -2147483648 || q > 2147483647 {
					return record_fault(cpu, cursor.start_rip, .Divide_Error, cursor.start_rip)
				}
				write_register(cpu, u8(General_Register.Rax), .Bits_32, false, u64(q))
				write_register(cpu, u8(General_Register.Rdx), .Bits_32, false, u64(r))
			case .Bits_64:
				q, r, ok := divide_i128_by_i64(cpu.registers[int(General_Register.Rax)], i64(cpu.registers[int(General_Register.Rdx)]), divisor)
				if !ok {
					return record_fault(cpu, cursor.start_rip, .Divide_Error, cursor.start_rip)
				}
				cpu.registers[int(General_Register.Rax)] = u64(q)
				cpu.registers[int(General_Register.Rdx)] = u64(r)
			}
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0xFC:
		// CLD.
		set_flag(cpu, RFLAGS_DF, false)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0xFD:
		// STD.
		set_flag(cpu, RFLAGS_DF, true)
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0xFE:
		// INC r/m8 (/0) or DEC r/m8 (/1); preserves CF.
		modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		sub := modrm.reg_index & 7
		if sub != 0 && sub != 1 {
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		}
		val, o_r := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, .Bits_8, prefixes.has_rex)
		if o_r != .Running {
			return o_r
		}
		saved_cf := (cpu.rflags & RFLAGS_CF) != 0
		res, _ := execute_alu(cpu, .Add if sub == 0 else .Sub, val, 1, .Bits_8)
		set_flag(cpu, RFLAGS_CF, saved_cf)
		o_w := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, .Bits_8, prefixes.has_rex, res)
		if o_w != .Running {
			return o_w
		}
		cpu.rip = cursor.current_rip
		cpu.steps_executed += 1
		return .Running

	case 0xFF:
		// Group 5: INC (/0), DEC (/1), CALL r/m64 (/2), JMP r/m64 (/4), PUSH r/m64 (/6).
		modrm, o_modrm := decode_modrm(cpu, physical_memory, &cursor, prefixes)
		if o_modrm != .Running {
			return o_modrm
		}
		sub := modrm.reg_index & 7
		switch sub {
		case 0, 1:
			val, o_r := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, width, prefixes.has_rex)
			if o_r != .Running {
				return o_r
			}
			saved_cf := (cpu.rflags & RFLAGS_CF) != 0
			res, _ := execute_alu(cpu, .Add if sub == 0 else .Sub, val, 1, width)
			set_flag(cpu, RFLAGS_CF, saved_cf)
			o_w := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, width, prefixes.has_rex, res)
			if o_w != .Running {
				return o_w
			}
			cpu.rip = cursor.current_rip
			cpu.steps_executed += 1
			return .Running
		case 2:
			// CALL r/m64 (always 64-bit in 64-bit mode).
			target, o_r := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, .Bits_64, prefixes.has_rex)
			if o_r != .Running {
				return o_r
			}
			if !is_canonical_virtual_address(target) {
				return record_fault(cpu, cursor.start_rip, .General_Protection, target)
			}
			o_push := execute_stack_push(cpu, physical_memory, cursor.start_rip, .Bits_64, cursor.current_rip)
			if o_push != .Running {
				return o_push
			}
			cpu.rip = target
			cpu.steps_executed += 1
			return .Running
		case 4:
			// JMP r/m64 (always 64-bit in 64-bit mode).
			target, o_r := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, .Bits_64, prefixes.has_rex)
			if o_r != .Running {
				return o_r
			}
			if !is_canonical_virtual_address(target) {
				return record_fault(cpu, cursor.start_rip, .General_Protection, target)
			}
			cpu.rip = target
			cpu.steps_executed += 1
			return .Running
		case 6:
			// PUSH r/m64 (or r/m16 with 0x66 and no REX.W).
			push_width := Operand_Width.Bits_16 if (prefixes.has_operand_size_override && !prefixes.rex_w) else Operand_Width.Bits_64
			val, o_r := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, push_width, prefixes.has_rex)
			if o_r != .Running {
				return o_r
			}
			o_push := execute_stack_push(cpu, physical_memory, cursor.start_rip, push_width, val)
			if o_push != .Running {
				return o_push
			}
			cpu.rip = cursor.current_rip
			cpu.steps_executed += 1
			return .Running
		case:
			return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
		}
	}

	// Privileged opcodes (HLT, CLI, STI, IRET, the string forms of IN and
	// OUT, etc.) and any unsupported
	// opcode trap cleanly as `.Invalid_Opcode` in user mode.
	return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
}

// processor_run executes at most `max_steps` instructions, stopping immediately
// on any non-`.Running` outcome (syscall, fault, breakpoint, halt) or returning
// `.Step_Budget_Exhausted` when the slice budget runs out.
processor_run :: proc "contextless" (cpu: ^Processor_State, physical_memory: []u8, max_steps: u64) -> Step_Outcome {
	if max_steps == 0 {
		cpu.outcome = .Step_Budget_Exhausted
		return .Step_Budget_Exhausted
	}
	for _ in 0 ..< max_steps {
		outcome := processor_step(cpu, physical_memory)
		if outcome != .Running {
			return outcome
		}
	}
	cpu.outcome = .Step_Budget_Exhausted
	return .Step_Budget_Exhausted
}

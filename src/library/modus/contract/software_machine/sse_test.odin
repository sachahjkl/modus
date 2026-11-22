#+build !freestanding
package software_machine

import "core:testing"

// A machine for the tests of the vector and integer extensions: a code
// page, a data page, a page that is read only, and an address that no page
// maps. Each load resets the processor.
Sse_Machine :: struct {
	machine:         Test_Machine,
	code_frame:      u64,
	data_frame:      u64,
	read_only_frame: u64,
	cpu:             Processor_State,
}

SSE_CODE_ADDRESS :: u64(0x40_0000)
SSE_DATA_ADDRESS :: u64(0x80_0000)
SSE_READ_ONLY_ADDRESS :: u64(0x80_1000)
SSE_UNMAPPED_ADDRESS :: u64(0x90_0000)

sse_machine_create :: proc() -> Sse_Machine {
	result: Sse_Machine
	result.machine = test_machine_create(256 * 1024)
	result.code_frame = test_alloc_frame(&result.machine)
	result.data_frame = test_alloc_frame(&result.machine)
	result.read_only_frame = test_alloc_frame(&result.machine)
	test_map_4k_page(&result.machine, SSE_CODE_ADDRESS, result.code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&result.machine, SSE_DATA_ADDRESS, result.data_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(&result.machine, SSE_READ_ONLY_ADDRESS, result.read_only_frame, PAGE_PRESENT | PAGE_USER | PAGE_NO_EXECUTE)
	return result
}

sse_machine_destroy :: proc(machine: ^Sse_Machine) {
	test_machine_destroy(&machine.machine)
}

// sse_machine_load writes the code, followed by breakpoints, and resets the
// processor at its start with rdi at the data page.
sse_machine_load :: proc(machine: ^Sse_Machine, code: []u8) {
	for index in 0 ..< int(PAGE_SIZE) {
		machine.machine.ram[int(machine.code_frame) + index] = 0xCC
	}
	test_load_code(&machine.machine, machine.code_frame, code)
	processor_init(&machine.cpu, machine.machine.cr3, SSE_CODE_ADDRESS, 0)
	machine.cpu.registers[int(General_Register.Rdi)] = SSE_DATA_ADDRESS
}

sse_machine_step :: proc(machine: ^Sse_Machine) -> Step_Outcome {
	return processor_step(&machine.cpu, machine.machine.ram)
}

sse_machine_run :: proc(machine: ^Sse_Machine) -> Step_Outcome {
	return processor_run(&machine.cpu, machine.machine.ram, 100)
}

sse_data_u64 :: proc(machine: ^Sse_Machine, offset: int) -> u64 {
	value: u64
	for index in 0 ..< 8 {
		value |= u64(machine.machine.ram[int(machine.data_frame) + offset + index]) << (8 * uint(index))
	}
	return value
}

sse_data_set_u64 :: proc(machine: ^Sse_Machine, offset: int, value: u64) {
	for index in 0 ..< 8 {
		machine.machine.ram[int(machine.data_frame) + offset + index] = u8(value >> (8 * uint(index)))
	}
}

sse_low :: proc(cpu: ^Processor_State, register: int) -> u64 {
	return (transmute([2]u64)cpu.xmm[register])[0]
}

sse_set :: proc(cpu: ^Processor_State, register: int, low, high: u64) {
	cpu.xmm[register] = transmute([16]u8)[2]u64{low, high}
}

f64_bits :: proc(value: f64) -> u64 {
	return transmute(u64)value
}

// A fault keeps the place, the count of steps, every vector register and
// MXCSR.
sse_expect_fault_kept_state :: proc(t: ^testing.T, machine: ^Sse_Machine, before: Processor_State, expected: Step_Outcome, location := #caller_location) {
	outcome := sse_machine_step(machine)
	testing.expect_value(t, outcome, expected, loc = location)
	testing.expect_value(t, machine.cpu.rip, before.rip, loc = location)
	testing.expect_value(t, machine.cpu.steps_executed, before.steps_executed, loc = location)
	testing.expect(t, machine.cpu.xmm == before.xmm, "a fault changed a vector register", loc = location)
	testing.expect_value(t, machine.cpu.registers, before.registers, loc = location)
	if expected != .Simd_Floating_Point {
		testing.expect_value(t, machine.cpu.mxcsr, before.mxcsr, loc = location)
	}
}

@(test)
test_sse_refused_forms_are_invalid_opcodes :: proc(t: ^testing.T) {
	machine := sse_machine_create()
	defer sse_machine_destroy(&machine)
	forms := [?][]u8 {
		{0x0F, 0xEF, 0xC0}, // pxor without 66: the MMX form, which cpuid does not name.
		{0x66, 0x0F, 0xD7, 0x07}, // pmovmskb with memory.
		{0x66, 0x0F, 0xC5, 0x07, 0x00}, // pextrw with memory.
		{0x66, 0x0F, 0x12, 0xC1}, // movlpd between registers.
		{0x0F, 0x13, 0xC1}, // movlps store to a register.
		{0x0F, 0xAE, 0xE0}, // 0F AE with a register and selector 4.
		{0x0F, 0xAE, 0x27}, // xsave: cpuid names no xsave.
		{0x66, 0x0F, 0xAE, 0x17}, // ldmxcsr with 66.
		{0xF2, 0x0F, 0x5B, 0xC0}, // 0F 5B with F2.
		{0x66, 0x0F, 0x73, 0xE0, 0x04}, // 66 0F 73 /4: psraq does not exist.
		{0x66, 0x0F, 0x71, 0x07, 0x04}, // a shift by an immediate with memory.
		{0x0F, 0x2A, 0xC0}, // cvtpi2ps: MMX.
		{0x66, 0x0F, 0x52, 0xC0}, // rsqrtps has no 66 form.
		{0x0F, 0x2B, 0xC0}, // movntps to a register.
		{0x0F, 0xC3, 0xC0}, // movnti to a register.
		{0x0F, 0xBA, 0xC0, 0x01}, // The bit test group with selector 0.
		{0x66, 0x0F, 0x78, 0xC0}, // An opcode of the 66 map that SSE2 lacks.
		{0x66, 0x0F, 0xD0, 0xC0}, // addsubpd: SSE3.
		{0x0F, 0xC7, 0xC8}, // cmpxchg8b with a register.
	}
	for form, index in forms {
		sse_machine_load(&machine, form)
		before := machine.cpu
		outcome := sse_machine_step(&machine)
		testing.expectf(t, outcome == .Invalid_Opcode, "form %d gives %v", index, outcome)
		testing.expect_value(t, machine.cpu.rip, before.rip)
		testing.expect_value(t, machine.cpu.steps_executed, u64(0))
	}
}

@(test)
test_sse_moves_alignment_and_bitwise :: proc(t: ^testing.T) {
	machine := sse_machine_create()
	defer sse_machine_destroy(&machine)
	for index in 0 ..< 64 {
		machine.machine.ram[int(machine.data_frame) + index] = u8(index)
	}

	// movaps with an address that is not aligned: a protection fault before
	// any access, even to an unmapped address.
	sse_machine_load(&machine, {0x0F, 0x28, 0x0F}) // movaps xmm1, [rdi]
	machine.cpu.registers[int(General_Register.Rdi)] = SSE_DATA_ADDRESS + 8
	sse_set(&machine.cpu, 1, 0x5555, 0x6666)
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .General_Protection)
	sse_machine_load(&machine, {0x0F, 0x28, 0x0F})
	machine.cpu.registers[int(General_Register.Rdi)] = SSE_UNMAPPED_ADDRESS + 4
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .General_Protection)
	// The same aligned address that no page maps: a page fault.
	sse_machine_load(&machine, {0x0F, 0x28, 0x0F})
	machine.cpu.registers[int(General_Register.Rdi)] = SSE_UNMAPPED_ADDRESS
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .Page_Fault)
	testing.expect_value(t, machine.cpu.fault_address, SSE_UNMAPPED_ADDRESS)
	// pxor with memory that is not aligned faults too; movdqu does not.
	sse_machine_load(&machine, {0x66, 0x0F, 0xEF, 0x47, 0x01})
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .General_Protection)
	// An aligned store into the page that is read only: a write page fault
	// and no byte written.
	sse_machine_load(&machine, {0x0F, 0x29, 0x07}) // movaps [rdi], xmm0
	machine.cpu.registers[int(General_Register.Rdi)] = SSE_READ_ONLY_ADDRESS
	sse_set(&machine.cpu, 0, max(u64), max(u64))
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .Page_Fault)
	testing.expect_value(t, machine.cpu.fault_error_code & PAGE_FAULT_WRITE, PAGE_FAULT_WRITE)
	testing.expect_value(t, machine.machine.ram[int(machine.read_only_frame)], u8(0))

	// 00: 0F 57 C0        xorps xmm0, xmm0
	// 03: 0F 28 0F        movaps xmm1, [rdi]
	// 06: 0F 29 4F 10     movaps [rdi + 16], xmm1
	// 0A: 0F 10 57 01     movups xmm2, [rdi + 1]
	// 0E: 66 0F 57 DB     xorpd xmm3, xmm3
	// 12: 0F 56 E1        orps xmm4, xmm1
	// 15: 66 0F 54 E9     andpd xmm5, xmm1
	// 19: 0F 55 F1        andnps xmm6, xmm1
	// 1C: 0F 05           syscall
	sse_machine_load(&machine, {0x0F, 0x57, 0xC0, 0x0F, 0x28, 0x0F, 0x0F, 0x29, 0x4F, 0x10, 0x0F, 0x10, 0x57, 0x01, 0x66, 0x0F, 0x57, 0xDB, 0x0F, 0x56, 0xE1, 0x66, 0x0F, 0x54, 0xE9, 0x0F, 0x55, 0xF1, 0x0F, 0x05})
	for register in 0 ..< 8 {
		sse_set(&machine.cpu, register, 0xAAAA_AAAA_AAAA_AAAA, 0xAAAA_AAAA_AAAA_AAAA)
	}
	sse_set(&machine.cpu, 6, 0xFFFF_0000_FFFF_0000, 0)
	testing.expect_value(t, sse_machine_run(&machine), Step_Outcome.Syscall)
	testing.expect(t, machine.cpu.xmm[0] == [16]u8{}, "xorps keeps a bit")
	testing.expect(t, machine.cpu.xmm[3] == [16]u8{}, "xorpd keeps a bit")
	for index in 0 ..< 16 {
		testing.expect_value(t, machine.cpu.xmm[1][index], u8(index))
		testing.expect_value(t, machine.machine.ram[int(machine.data_frame) + 16 + index], u8(index))
	}
	// movups read bytes 1 to 16 after the store: byte 16 is now 0.
	testing.expect_value(t, machine.cpu.xmm[2][0], u8(1))
	testing.expect_value(t, machine.cpu.xmm[2][14], u8(15))
	testing.expect_value(t, machine.cpu.xmm[2][15], u8(0))
	low := u64(0x0706_0504_0302_0100)
	testing.expect_value(t, sse_low(&machine.cpu, 4), 0xAAAA_AAAA_AAAA_AAAA | low)
	testing.expect_value(t, sse_low(&machine.cpu, 5), 0xAAAA_AAAA_AAAA_AAAA & low)
	testing.expect_value(t, sse_low(&machine.cpu, 6), ~u64(0xFFFF_0000_FFFF_0000) & low)
	testing.expect_value(t, machine.cpu.mxcsr, MXCSR_START)
}

@(test)
test_sse_scalar_double_arithmetic_and_compare_flags :: proc(t: ^testing.T) {
	machine := sse_machine_create()
	defer sse_machine_destroy(&machine)
	quiet_nan := u64(0x7FF8_0000_0000_0001)
	sse_data_set_u64(&machine, 0, f64_bits(1.5))
	sse_data_set_u64(&machine, 8, f64_bits(2.0))
	sse_data_set_u64(&machine, 16, quiet_nan)

	// 00: F2 0F 10 07        movsd xmm0, [rdi]
	// 04: F2 0F 58 47 08     addsd xmm0, [rdi + 8]
	// 09: F2 0F 59 47 08     mulsd xmm0, [rdi + 8]
	// 0E: F2 0F 5E 47 08     divsd xmm0, [rdi + 8]
	// 13: F2 0F 11 47 20     movsd [rdi + 32], xmm0
	// 18: 66 0F 2E 47 10     ucomisd xmm0, [rdi + 16]
	// 1D: 0F 05              syscall
	sse_machine_load(&machine, {0xF2, 0x0F, 0x10, 0x07, 0xF2, 0x0F, 0x58, 0x47, 0x08, 0xF2, 0x0F, 0x59, 0x47, 0x08, 0xF2, 0x0F, 0x5E, 0x47, 0x08, 0xF2, 0x0F, 0x11, 0x47, 0x20, 0x66, 0x0F, 0x2E, 0x47, 0x10, 0x0F, 0x05})
	sse_set(&machine.cpu, 0, 0, 0x1234)
	machine.cpu.rflags |= RFLAGS_OF | RFLAGS_SF | RFLAGS_AF
	testing.expect_value(t, sse_machine_run(&machine), Step_Outcome.Syscall)
	testing.expect_value(t, sse_data_u64(&machine, 32), f64_bits(3.5))
	// The load of movsd clears the high lane.
	testing.expect_value(t, (transmute([2]u64)machine.cpu.xmm[0])[1], u64(0))
	unordered := RFLAGS_ZF | RFLAGS_PF | RFLAGS_CF
	arithmetic := unordered | RFLAGS_OF | RFLAGS_SF | RFLAGS_AF
	testing.expect_value(t, machine.cpu.rflags & arithmetic, unordered)
	// A quiet NaN raises nothing for ucomisd.
	testing.expect_value(t, machine.cpu.mxcsr, MXCSR_START)

	// comisd signals on a quiet NaN: the invalid flag, masked.
	sse_machine_load(&machine, {0x66, 0x0F, 0x2F, 0x47, 0x10})
	sse_set(&machine.cpu, 0, f64_bits(3.5), 0)
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, machine.cpu.mxcsr, MXCSR_START | u32(1))
	testing.expect_value(t, machine.cpu.rflags & arithmetic, unordered)

	// Greater, less and equal.
	relations := [?]struct {
		left, right: f64,
		flags:       u64,
	}{{3.5, 2.0, 0}, {1.0, 2.0, RFLAGS_CF}, {2.0, 2.0, RFLAGS_ZF}, {0.0, -0.0, RFLAGS_ZF}}
	for relation in relations {
		sse_machine_load(&machine, {0x66, 0x0F, 0x2E, 0xC1}) // ucomisd xmm0, xmm1
		sse_set(&machine.cpu, 0, f64_bits(relation.left), 0)
		sse_set(&machine.cpu, 1, f64_bits(relation.right), 0)
		machine.cpu.rflags |= arithmetic
		testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
		testing.expect_value(t, machine.cpu.rflags & arithmetic, relation.flags)
	}
}

@(test)
test_sse_floating_point_exceptions_and_nan_rules :: proc(t: ^testing.T) {
	machine := sse_machine_create()
	defer sse_machine_destroy(&machine)
	divide_by_zero_mask := u32(1) << (MXCSR_EXCEPTION_MASK_SHIFT + u32(Simd_Exception.Divide_By_Zero))
	divide_by_zero_flag := u32(1) << u32(Simd_Exception.Divide_By_Zero)

	// An unmasked division by zero: vector 19, the flag set, no destination
	// written, the place kept.
	sse_machine_load(&machine, {0xF2, 0x0F, 0x5E, 0xC1}) // divsd xmm0, xmm1
	machine.cpu.mxcsr = MXCSR_START & ~divide_by_zero_mask
	sse_set(&machine.cpu, 0, f64_bits(1.0), 77)
	sse_set(&machine.cpu, 1, f64_bits(0.0), 0)
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .Simd_Floating_Point)
	testing.expect_value(t, machine.cpu.mxcsr, (MXCSR_START & ~divide_by_zero_mask) | divide_by_zero_flag)
	// Masked: the infinity and the flag.
	sse_machine_load(&machine, {0xF2, 0x0F, 0x5E, 0xC1})
	sse_set(&machine.cpu, 0, f64_bits(-1.0), 77)
	sse_set(&machine.cpu, 1, f64_bits(0.0), 0)
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, sse_low(&machine.cpu, 0), u64(0xFFF0_0000_0000_0000))
	testing.expect_value(t, (transmute([2]u64)machine.cpu.xmm[0])[1], u64(77))
	testing.expect_value(t, machine.cpu.mxcsr, MXCSR_START | divide_by_zero_flag)
	// 0 / 0 is invalid, not a division by zero.
	sse_machine_load(&machine, {0xF2, 0x0F, 0x5E, 0xC1})
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, sse_low(&machine.cpu, 0), u64(0xFFF8_0000_0000_0000))
	testing.expect_value(t, machine.cpu.mxcsr, MXCSR_START | 1)

	// The NaN rules: the first NaN operand, made quiet; the invalid flag for
	// a signaling one; the indefinite for infinity minus infinity.
	Nan_Case :: struct {
		opcode:       u8,
		first, second: u64,
		result:       u64,
		flags:        u32,
	}
	positive_infinity := u64(0x7FF0_0000_0000_0000)
	cases := [?]Nan_Case {
		{0x58, 0x7FF0_0000_0000_0001, 0x7FF8_0000_0000_0002, 0x7FF8_0000_0000_0001, 1},
		{0x58, f64_bits(1.0), 0xFFF0_0000_0000_0003, 0xFFF8_0000_0000_0003, 1},
		{0x59, 0x7FF8_0000_0000_0004, f64_bits(2.0), 0x7FF8_0000_0000_0004, 0},
		{0x5C, positive_infinity, positive_infinity, 0xFFF8_0000_0000_0000, 1},
		{0x59, positive_infinity, f64_bits(0.0), 0xFFF8_0000_0000_0000, 1},
		// minsd and maxsd give the second operand, as it is, on any NaN.
		{0x5D, 0x7FF8_0000_0000_0005, f64_bits(2.0), f64_bits(2.0), 1},
		{0x5F, f64_bits(2.0), 0x7FF0_0000_0000_0006, 0x7FF0_0000_0000_0006, 1},
		{0x5D, f64_bits(0.0), f64_bits(-0.0), f64_bits(-0.0), 0},
		{0x5F, f64_bits(-0.0), f64_bits(0.0), f64_bits(0.0), 0},
		// An overflow to infinity raises overflow and precision.
		{0x59, f64_bits(1e300), f64_bits(1e300), positive_infinity, 0x28},
		// A denormal operand.
		{0x58, 1, f64_bits(0.0), 1, 2},
	}
	for nan_case, index in cases {
		sse_machine_load(&machine, {0xF2, 0x0F, nan_case.opcode, 0xC1})
		sse_set(&machine.cpu, 0, nan_case.first, 0)
		sse_set(&machine.cpu, 1, nan_case.second, 0)
		testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
		testing.expectf(t, sse_low(&machine.cpu, 0) == nan_case.result, "case %d gives %x, not %x", index, sse_low(&machine.cpu, 0), nan_case.result)
		testing.expectf(t, machine.cpu.mxcsr == MXCSR_START | nan_case.flags, "case %d gives MXCSR %x", index, machine.cpu.mxcsr)
	}

	// sqrtsd: -1 is invalid, -0 stays -0 with no flag.
	sse_machine_load(&machine, {0xF2, 0x0F, 0x51, 0xC1})
	sse_set(&machine.cpu, 1, f64_bits(-1.0), 0)
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, sse_low(&machine.cpu, 0), u64(0xFFF8_0000_0000_0000))
	testing.expect_value(t, machine.cpu.mxcsr, MXCSR_START | 1)
	sse_machine_load(&machine, {0xF2, 0x0F, 0x51, 0xC1})
	sse_set(&machine.cpu, 1, f64_bits(-0.0), 0)
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, sse_low(&machine.cpu, 0), u64(0x8000_0000_0000_0000))
	testing.expect_value(t, machine.cpu.mxcsr, MXCSR_START)
	sse_machine_load(&machine, {0xF2, 0x0F, 0x51, 0xC1})
	sse_set(&machine.cpu, 1, f64_bits(2.25), 0)
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, sse_low(&machine.cpu, 0), f64_bits(1.5))

	// cvtsd2ss of a signaling NaN keeps the sign and the high payload.
	sse_machine_load(&machine, {0xF2, 0x0F, 0x5A, 0xC1})
	sse_set(&machine.cpu, 0, 0xFFFF_FFFF_FFFF_FFFF, 0)
	sse_set(&machine.cpu, 1, 0xFFF4_0000_0000_0000, 0)
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, sse_low(&machine.cpu, 0), u64(0xFFFF_FFFF_FFE0_0000))
	testing.expect_value(t, machine.cpu.mxcsr, MXCSR_START | 1)
	// cvtsd2ss past the largest single: infinity, overflow and precision.
	sse_machine_load(&machine, {0xF2, 0x0F, 0x5A, 0xC1})
	sse_set(&machine.cpu, 1, f64_bits(1e300), 0)
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, sse_low(&machine.cpu, 0) & 0xFFFF_FFFF, u64(0x7F80_0000))
	testing.expect_value(t, machine.cpu.mxcsr, MXCSR_START | 0x28)

	// mulss to a denormal single: kept without flush-to-zero, a signed zero
	// with underflow and precision with it.
	tiny_first := u64(transmute(u32)f32(1e-30))
	tiny_second := u64(transmute(u32)f32(-1e-10))
	sse_machine_load(&machine, {0xF3, 0x0F, 0x59, 0xC1})
	sse_set(&machine.cpu, 0, tiny_first, 0)
	sse_set(&machine.cpu, 1, tiny_second, 0)
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect(t, float_is_denormal(sse_low(&machine.cpu, 0) & 0xFFFF_FFFF, .Single), "the product is not the denormal")
	sse_machine_load(&machine, {0xF3, 0x0F, 0x59, 0xC1})
	machine.cpu.mxcsr = MXCSR_START | MXCSR_FLUSH_TO_ZERO
	sse_set(&machine.cpu, 0, tiny_first, 0)
	sse_set(&machine.cpu, 1, tiny_second, 0)
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, sse_low(&machine.cpu, 0) & 0xFFFF_FFFF, u64(0x8000_0000))
	testing.expect_value(t, machine.cpu.mxcsr, MXCSR_START | MXCSR_FLUSH_TO_ZERO | 0x30)
}

@(test)
test_sse_mxcsr_load_store_and_fxsave :: proc(t: ^testing.T) {
	machine := sse_machine_create()
	defer sse_machine_destroy(&machine)

	// ldmxcsr refuses denormals-are-zero, which this processor lacks, and
	// every bit past 15.
	for refused in ([?]u64{0x1FC0, 0x1_1F80, 0x8000_1F80}) {
		sse_data_set_u64(&machine, 0, refused)
		sse_machine_load(&machine, {0x0F, 0xAE, 0x17}) // ldmxcsr [rdi]
		sse_expect_fault_kept_state(t, &machine, machine.cpu, .General_Protection)
	}
	// ldmxcsr from memory that no page maps.
	sse_machine_load(&machine, {0x0F, 0xAE, 0x17})
	machine.cpu.registers[int(General_Register.Rdi)] = SSE_UNMAPPED_ADDRESS
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .Page_Fault)
	// stmxcsr into the page that is read only.
	sse_machine_load(&machine, {0x0F, 0xAE, 0x1F})
	machine.cpu.registers[int(General_Register.Rdi)] = SSE_READ_ONLY_ADDRESS
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .Page_Fault)

	// 00: 0F AE 17        ldmxcsr [rdi]
	// 03: 0F AE 5F 08     stmxcsr [rdi + 8]
	// 07: 0F 05           syscall
	sse_data_set_u64(&machine, 0, 0xFFBF)
	sse_data_set_u64(&machine, 8, max(u64))
	sse_machine_load(&machine, {0x0F, 0xAE, 0x17, 0x0F, 0xAE, 0x5F, 0x08, 0x0F, 0x05})
	testing.expect_value(t, sse_machine_run(&machine), Step_Outcome.Syscall)
	testing.expect_value(t, machine.cpu.mxcsr, u32(0xFFBF))
	testing.expect_value(t, sse_data_u64(&machine, 8), u64(0xFFFF_FFFF_0000_FFBF))

	// fxsave: aligned only, and the whole 512 bytes must be writable.
	sse_machine_load(&machine, {0x0F, 0xAE, 0x07}) // fxsave [rdi]
	machine.cpu.registers[int(General_Register.Rdi)] = SSE_DATA_ADDRESS + 8
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .General_Protection)
	sse_machine_load(&machine, {0x0F, 0xAE, 0x07})
	machine.cpu.registers[int(General_Register.Rdi)] = SSE_DATA_ADDRESS + PAGE_SIZE - 256
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .Page_Fault)
	testing.expect_value(t, machine.machine.ram[int(machine.data_frame) + int(PAGE_SIZE) - 256], u8(0))

	for index in 0 ..< FXSAVE_AREA_BYTES {
		machine.machine.ram[int(machine.data_frame) + index] = 0xEE
	}
	// 00: 0F AE 07        fxsave [rdi]
	// 03: 0F 05           syscall
	sse_machine_load(&machine, {0x0F, 0xAE, 0x07, 0x0F, 0x05})
	machine.cpu.mxcsr = 0x1F81
	sse_set(&machine.cpu, 5, 0x1111_2222_3333_4444, 0x5555_6666_7777_8888)
	testing.expect_value(t, sse_machine_run(&machine), Step_Outcome.Syscall)
	testing.expect_value(t, sse_data_u64(&machine, 0) & 0xFFFF, u64(X87_CONTROL_WORD_START))
	testing.expect_value(t, sse_data_u64(&machine, FXSAVE_MXCSR_OFFSET), u64(MXCSR_MASK) << 32 | 0x1F81)
	testing.expect_value(t, sse_data_u64(&machine, FXSAVE_XMM_OFFSET + 5 * 16), u64(0x1111_2222_3333_4444))
	testing.expect_value(t, sse_data_u64(&machine, FXSAVE_XMM_OFFSET + 5 * 16 + 8), u64(0x5555_6666_7777_8888))
	testing.expect_value(t, machine.machine.ram[int(machine.data_frame) + FXSAVE_WRITTEN_BYTES], u8(0xEE))

	// fxrstor refuses an area whose MXCSR has a bit that the mask lacks.
	sse_data_set_u64(&machine, FXSAVE_MXCSR_OFFSET, u64(MXCSR_MASK) << 32 | 0x1FC0)
	sse_machine_load(&machine, {0x0F, 0xAE, 0x0F}) // fxrstor [rdi]
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .General_Protection)
	sse_data_set_u64(&machine, FXSAVE_MXCSR_OFFSET, u64(MXCSR_MASK) << 32 | 0x1F82)
	sse_machine_load(&machine, {0x0F, 0xAE, 0x0F})
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, machine.cpu.mxcsr, u32(0x1F82))
	testing.expect_value(t, (transmute([2]u64)machine.cpu.xmm[5])[1], u64(0x5555_6666_7777_8888))
}

@(test)
test_sse_conversions_and_their_edges :: proc(t: ^testing.T) {
	machine := sse_machine_create()
	defer sse_machine_destroy(&machine)
	indefinite_64 := u64(0x8000_0000_0000_0000)

	// cvttsd2si rbx, xmm0 (F2 48 0F 2C D8) and cvtsd2si rbx, xmm0 (2D).
	Conversion :: struct {
		opcode:  u8,
		rounding: Rounding_Control,
		value:   u64,
		result:  u64,
		invalid: bool,
	}
	nan := u64(0x7FF8_0000_0000_0000)
	conversions := [?]Conversion {
		{0x2C, .Nearest, nan, indefinite_64, true},
		{0x2C, .Nearest, 0xFFF0_0000_0000_0000, indefinite_64, true},
		{0x2C, .Nearest, f64_bits(9223372036854775808.0), indefinite_64, true},
		{0x2C, .Nearest, f64_bits(-9223372036854775808.0), indefinite_64, false},
		{0x2C, .Nearest, f64_bits(1e300), indefinite_64, true},
		{0x2C, .Nearest, f64_bits(-2.75), transmute(u64)i64(-2), false},
		{0x2C, .Nearest, f64_bits(-0.5), 0, false},
		{0x2D, .Nearest, f64_bits(2.5), 2, false},
		{0x2D, .Nearest, f64_bits(3.5), 4, false},
		{0x2D, .Nearest, f64_bits(-2.5), transmute(u64)i64(-2), false},
		{0x2D, .Down, f64_bits(-2.5), transmute(u64)i64(-3), false},
		{0x2D, .Up, f64_bits(2.25), 3, false},
		{0x2D, .Toward_Zero, f64_bits(-2.75), transmute(u64)i64(-2), false},
		{0x2D, .Nearest, f64_bits(4503599627370497.0), 4503599627370497, false},
	}
	for conversion, index in conversions {
		sse_machine_load(&machine, {0xF2, 0x48, 0x0F, conversion.opcode, 0xD8})
		machine.cpu.mxcsr = MXCSR_START | u32(conversion.rounding) << MXCSR_ROUNDING_SHIFT
		before := machine.cpu.mxcsr
		sse_set(&machine.cpu, 0, conversion.value, 0)
		testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
		testing.expectf(t, machine.cpu.registers[int(General_Register.Rbx)] == conversion.result, "conversion %d gives %x", index, machine.cpu.registers[int(General_Register.Rbx)])
		testing.expectf(t, machine.cpu.mxcsr == before | (1 if conversion.invalid else 0), "conversion %d gives MXCSR %x", index, machine.cpu.mxcsr)
	}

	// The 32-bit forms: the edges of i32, and the high half cleared.
	Narrow :: struct {
		value:  f64,
		result: u64,
	}
	narrows := [?]Narrow{{2147483647.0, 0x7FFF_FFFF}, {2147483648.0, 0x8000_0000}, {-2147483648.0, 0x8000_0000}, {-2147483649.0, 0x8000_0000}, {-1.0, 0xFFFF_FFFF}}
	for narrow in narrows {
		sse_machine_load(&machine, {0xF2, 0x0F, 0x2C, 0xD8}) // cvttsd2si ebx, xmm0
		machine.cpu.registers[int(General_Register.Rbx)] = max(u64)
		sse_set(&machine.cpu, 0, f64_bits(narrow.value), 0)
		testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
		testing.expect_value(t, machine.cpu.registers[int(General_Register.Rbx)], narrow.result)
	}

	// An unmasked invalid conversion writes no register.
	sse_machine_load(&machine, {0xF2, 0x48, 0x0F, 0x2C, 0xD8})
	machine.cpu.mxcsr = MXCSR_START & ~(u32(1) << MXCSR_EXCEPTION_MASK_SHIFT)
	machine.cpu.registers[int(General_Register.Rbx)] = 99
	sse_set(&machine.cpu, 0, nan, 0)
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .Simd_Floating_Point)
	// A source in memory that no page maps.
	sse_machine_load(&machine, {0xF2, 0x48, 0x0F, 0x2C, 0x07})
	machine.cpu.registers[int(General_Register.Rdi)] = SSE_UNMAPPED_ADDRESS
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .Page_Fault)

	// 00: 48 C7 C0 F9 FF FF FF   mov rax, -7
	// 07: F2 48 0F 2A C8         cvtsi2sd xmm1, rax
	// 0C: F3 0F 2A D0            cvtsi2ss xmm2, eax
	// 10: F3 0F 5A DA            cvtss2sd xmm3, xmm2
	// 14: 0F 05                  syscall
	sse_machine_load(&machine, {0x48, 0xC7, 0xC0, 0xF9, 0xFF, 0xFF, 0xFF, 0xF2, 0x48, 0x0F, 0x2A, 0xC8, 0xF3, 0x0F, 0x2A, 0xD0, 0xF3, 0x0F, 0x5A, 0xDA, 0x0F, 0x05})
	sse_set(&machine.cpu, 1, 0, 0xABCD)
	sse_set(&machine.cpu, 2, max(u64), 0)
	testing.expect_value(t, sse_machine_run(&machine), Step_Outcome.Syscall)
	testing.expect_value(t, sse_low(&machine.cpu, 1), f64_bits(-7.0))
	testing.expect_value(t, (transmute([2]u64)machine.cpu.xmm[1])[1], u64(0xABCD))
	testing.expect_value(t, sse_low(&machine.cpu, 2), u64(0xFFFF_FFFF_00000000) | u64(transmute(u32)f32(-7.0)))
	testing.expect_value(t, sse_low(&machine.cpu, 3), f64_bits(-7.0))

	// The packed conversions of 0F 5B and E6.
	sse_machine_load(&machine, {0x0F, 0x5B, 0xC1}) // cvtdq2ps xmm0, xmm1
	machine.cpu.xmm[1] = transmute([16]u8)[4]u32{1, transmute(u32)i32(-2), 3, 0x7FFF_FFFF}
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, transmute([4]f32)machine.cpu.xmm[0], [4]f32{1, -2, 3, 2147483648.0})
	sse_machine_load(&machine, {0xF3, 0x0F, 0x5B, 0xC1}) // cvttps2dq xmm0, xmm1
	machine.cpu.xmm[1] = transmute([16]u8)[4]f32{1.9, -2.9, 3e9, 0}
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, transmute([4]u32)machine.cpu.xmm[0], [4]u32{1, transmute(u32)i32(-2), 0x8000_0000, 0})
	testing.expect_value(t, machine.cpu.mxcsr, MXCSR_START | 1)
	sse_machine_load(&machine, {0x66, 0x0F, 0xE6, 0xC1}) // cvttpd2dq xmm0, xmm1
	sse_set(&machine.cpu, 0, max(u64), max(u64))
	sse_set(&machine.cpu, 1, f64_bits(-5.5), f64_bits(6.5))
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, transmute([4]u32)machine.cpu.xmm[0], [4]u32{transmute(u32)i32(-5), 6, 0, 0})
}

@(test)
test_sse_integer_vectors_shuffles_and_shifts :: proc(t: ^testing.T) {
	machine := sse_machine_create()
	defer sse_machine_destroy(&machine)

	// 00: 66 0F 70 C8 1B     pshufd xmm1, xmm0, 0x1B
	// 05: 66 0F FE C1        paddd xmm0, xmm1
	// 09: 66 0F 73 F8 04     pslldq xmm0, 4
	// 0E: 66 0F 6F D0        movdqa xmm2, xmm0
	// 12: 66 0F 73 DA 10     psrldq xmm2, 16
	// 17: 66 0F C4 D8 03     pinsrw xmm3, eax, 3
	// 1C: 66 0F C5 D3 03     pextrw edx, xmm3, 3
	// 21: 0F 05              syscall
	sse_machine_load(&machine, {0x66, 0x0F, 0x70, 0xC8, 0x1B, 0x66, 0x0F, 0xFE, 0xC1, 0x66, 0x0F, 0x73, 0xF8, 0x04, 0x66, 0x0F, 0x6F, 0xD0, 0x66, 0x0F, 0x73, 0xDA, 0x10, 0x66, 0x0F, 0xC4, 0xD8, 0x03, 0x66, 0x0F, 0xC5, 0xD3, 0x03, 0x0F, 0x05})
	machine.cpu.xmm[0] = transmute([16]u8)[4]u32{1, 2, 3, 0xFFFF_FFFF}
	machine.cpu.registers[int(General_Register.Rax)] = 0x1234_ABCD
	machine.cpu.registers[int(General_Register.Rdx)] = max(u64)
	testing.expect_value(t, sse_machine_run(&machine), Step_Outcome.Syscall)
	testing.expect_value(t, transmute([4]u32)machine.cpu.xmm[1], [4]u32{0xFFFF_FFFF, 3, 2, 1})
	// paddd wraps: {0, 5, 5, 0}, then shifted up by one dword.
	testing.expect_value(t, transmute([4]u32)machine.cpu.xmm[0], [4]u32{0, 0, 5, 5})
	testing.expect(t, machine.cpu.xmm[2] == [16]u8{}, "psrldq by 16 keeps a byte")
	testing.expect_value(t, (transmute([8]u16)machine.cpu.xmm[3])[3], u16(0xABCD))
	testing.expect_value(t, machine.cpu.registers[int(General_Register.Rdx)], u64(0xABCD))

	// The lanes of each width at their edges.
	a := transmute([16]u8)[8]u16{0x7FFF, 0x8000, 0xFFFF, 0, 1, 0x00FF, 0x0100, 0xFF00}
	b := transmute([16]u8)[8]u16{1, 0xFFFF, 1, 0xFFFF, 0x7FFF, 1, 0xFFFF, 0x0100}
	paddsw, _ := vector_integer_binary(0xED, a, b)
	testing.expect_value(t, transmute([8]u16)paddsw, [8]u16{0x7FFF, 0x8000, 0, 0xFFFF, 0x7FFF, 0x0100, 0x00FF, 0})
	paddusw, _ := vector_integer_binary(0xDD, a, b)
	testing.expect_value(t, transmute([8]u16)paddusw, [8]u16{0x8000, 0xFFFF, 0xFFFF, 0xFFFF, 0x8000, 0x0100, 0xFFFF, 0xFFFF})
	psubusw, _ := vector_integer_binary(0xD9, a, b)
	testing.expect_value(t, transmute([8]u16)psubusw, [8]u16{0x7FFE, 0, 0xFFFE, 0, 0, 0x00FE, 0, 0xFE00})
	pmulhuw, _ := vector_integer_binary(0xE4, a, b)
	testing.expect_value(t, (transmute([8]u16)pmulhuw)[2], u16(0))
	testing.expect_value(t, (transmute([8]u16)pmulhuw)[1], u16(0x7FFF))
	pmulhw, _ := vector_integer_binary(0xE5, a, b)
	testing.expect_value(t, (transmute([8]u16)pmulhw)[1], u16(0)) // -32768 * -1 = 32768: high word 0.
	packuswb, _ := vector_integer_binary(0x67, a, b)
	testing.expect_value(t, packuswb[0], u8(0xFF)) // 32767 saturates to 255.
	testing.expect_value(t, packuswb[1], u8(0)) // -32768 saturates to 0.
	testing.expect_value(t, packuswb[5], u8(0xFF))
	packsswb, _ := vector_integer_binary(0x63, a, b)
	testing.expect_value(t, packsswb[0], u8(0x7F))
	testing.expect_value(t, packsswb[1], u8(0x80))
	testing.expect_value(t, packsswb[2], u8(0xFF)) // -1.
	pmaddwd, _ := vector_integer_binary(0xF5, transmute([16]u8)[8]u16{0x8000, 0x8000, 2, 3, 0, 0, 0, 0}, transmute([16]u8)[8]u16{0x8000, 0x8000, 4, 5, 0, 0, 0, 0})
	testing.expect_value(t, (transmute([4]u32)pmaddwd)[0], u32(0x8000_0000)) // The one sum that wraps.
	testing.expect_value(t, (transmute([4]u32)pmaddwd)[1], u32(23))
	psadbw, _ := vector_integer_binary(0xF6, [16]u8{0, 255, 3, 0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0}, [16]u8{255, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7})
	testing.expect_value(t, transmute([2]u64)psadbw, [2]u64{512, 17})
	punpcklbw, _ := vector_integer_binary(0x60, [16]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 9, 9, 9, 9, 9, 9}, [16]u8{11, 12, 13, 14, 15, 16, 17, 18, 0, 0, 0, 0, 0, 0, 0, 0})
	testing.expect_value(t, punpcklbw, [16]u8{1, 11, 2, 12, 3, 13, 4, 14, 5, 15, 6, 16, 7, 17, 8, 18})
	pcmpgtb, _ := vector_integer_binary(0x64, [16]u8{0x7F, 0x80, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, [16]u8{0x80, 0x7F, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0})
	testing.expect_value(t, pcmpgtb[0], u8(0xFF))
	testing.expect_value(t, pcmpgtb[1], u8(0))
	testing.expect_value(t, pcmpgtb[2], u8(0))

	// The shifts past the lane: 0 for a logical shift, the sign for an
	// arithmetic one; a count in the high bits of the count register counts.
	value := transmute([16]u8)[8]u16{0x8001, 0x7FFF, 0, 0, 0, 0, 0, 0}
	testing.expect_value(t, transmute([8]u16)vector_shift(value, 16, 15, .Left), [8]u16{0x8000, 0x8000, 0, 0, 0, 0, 0, 0})
	testing.expect(t, vector_shift(value, 16, 16, .Left) == [16]u8{}, "psllw by 16 keeps a bit")
	testing.expect_value(t, transmute([8]u16)vector_shift(value, 16, 200, .Right_Arithmetic), [8]u16{0xFFFF, 0, 0, 0, 0, 0, 0, 0})
	testing.expect(t, vector_shift(value, 16, u64(1) << 32, .Right_Logical) == [16]u8{}, "psrlw by 2^32 keeps a bit")
	testing.expect_value(t, transmute([2]u64)vector_shift(transmute([16]u8)[2]u64{0x8000_0000_0000_0000, 1}, 64, 63, .Right_Logical), [2]u64{1, 0})
	testing.expect_value(t, vector_byte_shift([16]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}, 255, true), [16]u8{})
	testing.expect_value(t, vector_byte_shift([16]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}, 15, false), [16]u8{16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0})
}

@(test)
test_sse_packed_float_compare_and_moves :: proc(t: ^testing.T) {
	machine := sse_machine_create()
	defer sse_machine_destroy(&machine)
	nan := transmute(f32)u32(0x7FC0_0000)

	// cmpps with each predicate; bits 3 to 7 of the immediate are ignored.
	Predicate_Case :: struct {
		immediate: u8,
		mask:      [4]u32,
	}
	all := u32(0xFFFF_FFFF)
	predicates := [?]Predicate_Case {
		{0, {all, 0, 0, 0}},
		{1, {0, all, 0, 0}},
		{2, {all, all, 0, 0}},
		{3, {0, 0, 0, all}},
		{4, {0, all, all, all}},
		{5, {all, 0, all, all}},
		{6, {0, 0, all, all}},
		{0xF8 | 7, {all, all, all, 0}},
	}
	for predicate in predicates {
		sse_machine_load(&machine, {0x0F, 0xC2, 0xC1, predicate.immediate})
		machine.cpu.xmm[0] = transmute([16]u8)[4]f32{1, 1, 2, nan}
		machine.cpu.xmm[1] = transmute([16]u8)[4]f32{1, 2, 1, 1}
		testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
		testing.expect_value(t, transmute([4]u32)machine.cpu.xmm[0], predicate.mask)
	}

	// movmskps, shufps, unpcklps, movhlps and movlhps.
	sse_machine_load(&machine, {0x0F, 0x50, 0xC1}) // movmskps eax, xmm1
	machine.cpu.registers[int(General_Register.Rax)] = max(u64)
	machine.cpu.xmm[1] = transmute([16]u8)[4]f32{-1, 2, -0.0, 4}
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, machine.cpu.registers[int(General_Register.Rax)], u64(0b0101))
	sse_machine_load(&machine, {0x0F, 0xC6, 0xC1, 0b00_01_10_11}) // shufps xmm0, xmm1, 0x1B
	machine.cpu.xmm[0] = transmute([16]u8)[4]u32{10, 11, 12, 13}
	machine.cpu.xmm[1] = transmute([16]u8)[4]u32{20, 21, 22, 23}
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, transmute([4]u32)machine.cpu.xmm[0], [4]u32{13, 12, 21, 20})
	sse_machine_load(&machine, {0x0F, 0x14, 0xC1}) // unpcklps xmm0, xmm1
	machine.cpu.xmm[0] = transmute([16]u8)[4]u32{10, 11, 12, 13}
	machine.cpu.xmm[1] = transmute([16]u8)[4]u32{20, 21, 22, 23}
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, transmute([4]u32)machine.cpu.xmm[0], [4]u32{10, 20, 11, 21})
	sse_machine_load(&machine, {0x0F, 0x12, 0xC1, 0x0F, 0x16, 0xD1, 0x0F, 0x05}) // movhlps xmm0, xmm1; movlhps xmm2, xmm1
	sse_set(&machine.cpu, 0, 1, 2)
	sse_set(&machine.cpu, 1, 3, 4)
	sse_set(&machine.cpu, 2, 5, 6)
	testing.expect_value(t, sse_machine_run(&machine), Step_Outcome.Syscall)
	testing.expect_value(t, transmute([2]u64)machine.cpu.xmm[0], [2]u64{4, 2})
	testing.expect_value(t, transmute([2]u64)machine.cpu.xmm[2], [2]u64{5, 3})

	// movss between registers keeps the rest; a load clears it.
	sse_data_set_u64(&machine, 0, 0x4444_3333)
	sse_machine_load(&machine, {0xF3, 0x0F, 0x10, 0xC1, 0xF3, 0x0F, 0x10, 0x17, 0x0F, 0x05}) // movss xmm0, xmm1; movss xmm2, [rdi]
	sse_set(&machine.cpu, 0, max(u64), max(u64))
	sse_set(&machine.cpu, 1, 0x1111_2222, 0)
	sse_set(&machine.cpu, 2, max(u64), max(u64))
	testing.expect_value(t, sse_machine_run(&machine), Step_Outcome.Syscall)
	testing.expect_value(t, transmute([2]u64)machine.cpu.xmm[0], [2]u64{0xFFFF_FFFF_1111_2222, max(u64)})
	testing.expect_value(t, transmute([2]u64)machine.cpu.xmm[2], [2]u64{0x4444_3333, 0})

	// maskmovdqu writes the selected bytes only, and checks each before the
	// first: a selected byte in the page that is read only writes none.
	sse_machine_load(&machine, {0x66, 0x0F, 0xF7, 0xC1}) // maskmovdqu xmm0, xmm1
	machine.cpu.registers[int(General_Register.Rdi)] = SSE_READ_ONLY_ADDRESS - 8
	machine.cpu.xmm[0] = [16]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	machine.cpu.xmm[1] = [16]u8{0x80, 0, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80}
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .Page_Fault)
	testing.expect_value(t, machine.machine.ram[int(machine.data_frame) + int(PAGE_SIZE) - 8], u8(0))
	sse_machine_load(&machine, {0x66, 0x0F, 0xF7, 0xC1})
	machine.cpu.registers[int(General_Register.Rdi)] = SSE_DATA_ADDRESS + 64
	machine.cpu.xmm[0] = [16]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	machine.cpu.xmm[1] = [16]u8{0x80, 0, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80}
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, machine.machine.ram[int(machine.data_frame) + 64], u8(1))
	testing.expect_value(t, machine.machine.ram[int(machine.data_frame) + 65], u8(0))
	testing.expect_value(t, machine.machine.ram[int(machine.data_frame) + 66], u8(3))
	testing.expect_value(t, machine.machine.ram[int(machine.data_frame) + 79], u8(16))

	// rcpss and rsqrtss: zero gives infinity, a negative square root the
	// indefinite, and no flag.
	testing.expect_value(t, float_reciprocal(0x8000_0000, false), u32(0xFF80_0000))
	testing.expect_value(t, float_reciprocal(transmute(u32)f32(-4), true), u32(0xFFC0_0000))
	testing.expect_value(t, float_reciprocal(transmute(u32)f32(4), true), transmute(u32)f32(0.5))
	testing.expect_value(t, float_reciprocal(0x7F80_0000, false), u32(0))
}

@(test)
test_integer_bit_scans_tests_swaps_and_double_shifts :: proc(t: ^testing.T) {
	machine := sse_machine_create()
	defer sse_machine_destroy(&machine)
	rax := int(General_Register.Rax)
	rbx := int(General_Register.Rbx)

	// bsf with a zero source keeps the destination and sets ZF; tzcnt
	// (F3) runs as bsf, as cpuid names no BMI1.
	for code in ([?][]u8{{0x48, 0x0F, 0xBC, 0xC3}, {0xF3, 0x48, 0x0F, 0xBC, 0xC3}, {0x48, 0x0F, 0xBD, 0xC3}}) {
		sse_machine_load(&machine, code)
		machine.cpu.registers[rax] = 0x1234
		machine.cpu.registers[rbx] = 0
		testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
		testing.expect_value(t, machine.cpu.registers[rax], u64(0x1234))
		testing.expect(t, machine.cpu.rflags & RFLAGS_ZF != 0, "a zero source leaves ZF clear")
	}
	sse_machine_load(&machine, {0x48, 0x0F, 0xBC, 0xC3, 0x48, 0x0F, 0xBD, 0xD3, 0x0F, 0x05}) // bsf rax, rbx; bsr rdx, rbx
	machine.cpu.registers[rbx] = u64(1) << 40 | 0x80
	machine.cpu.rflags |= RFLAGS_ZF
	testing.expect_value(t, sse_machine_run(&machine), Step_Outcome.Syscall)
	testing.expect_value(t, machine.cpu.registers[rax], u64(7))
	testing.expect_value(t, machine.cpu.registers[int(General_Register.Rdx)], u64(40))
	testing.expect(t, machine.cpu.rflags & RFLAGS_ZF == 0, "a source with a bit leaves ZF set")

	// bt with a negative offset in a register reaches the operand before
	// the address; bts with offset 65 reaches the one after it.
	sse_data_set_u64(&machine, 8, u64(1) << 63)
	sse_machine_load(&machine, {0x48, 0x0F, 0xA3, 0x07, 0x0F, 0x05}) // bt [rdi], rax
	machine.cpu.registers[int(General_Register.Rdi)] = SSE_DATA_ADDRESS + 16
	machine.cpu.registers[rax] = max(u64)
	testing.expect_value(t, sse_machine_run(&machine), Step_Outcome.Syscall)
	testing.expect(t, machine.cpu.rflags & RFLAGS_CF != 0, "bt misses the bit before the operand")
	sse_machine_load(&machine, {0x48, 0x0F, 0xAB, 0x07}) // bts [rdi], rax
	machine.cpu.registers[rax] = 65
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, sse_data_u64(&machine, 8), u64(1) << 63 | 2)
	testing.expect(t, machine.cpu.rflags & RFLAGS_CF == 0, "bts reports a bit that was clear")
	// btr into the page that is read only faults and keeps CF.
	sse_machine_load(&machine, {0x48, 0x0F, 0xB3, 0x07})
	machine.cpu.registers[int(General_Register.Rdi)] = SSE_READ_ONLY_ADDRESS
	machine.cpu.rflags |= RFLAGS_CF
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .Page_Fault)
	testing.expect(t, machine.cpu.rflags & RFLAGS_CF != 0, "a faulted btr changed CF")
	// btc eax, 37 with an immediate: the offset wraps in the operand.
	sse_machine_load(&machine, {0x0F, 0xBA, 0xF8, 37})
	machine.cpu.registers[rax] = 0xFFFF_FFFF_0000_0000
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, machine.cpu.registers[rax], u64(0x20))

	// bswap of 32 bits clears the high half; of 64 bits swaps all.
	sse_machine_load(&machine, {0x0F, 0xC8, 0x48, 0x0F, 0xCB, 0x0F, 0x05})
	machine.cpu.registers[rax] = 0xDEAD_BEEF_1122_3344
	machine.cpu.registers[rbx] = 0x0102_0304_0506_0708
	testing.expect_value(t, sse_machine_run(&machine), Step_Outcome.Syscall)
	testing.expect_value(t, machine.cpu.registers[rax], u64(0x4433_2211))
	testing.expect_value(t, machine.cpu.registers[rbx], u64(0x0807_0605_0403_0201))

	// shld by 4 and shrd by cl; a count of 0 changes nothing.
	sse_machine_load(&machine, {0x48, 0x0F, 0xA4, 0xD8, 0x04, 0x0F, 0x05})
	machine.cpu.registers[rax] = 0x9000_0000_0000_0001
	machine.cpu.registers[rbx] = 0xF000_0000_0000_0000
	testing.expect_value(t, sse_machine_run(&machine), Step_Outcome.Syscall)
	testing.expect_value(t, machine.cpu.registers[rax], u64(0x1F))
	testing.expect(t, machine.cpu.rflags & RFLAGS_CF != 0, "shld lost the last bit out")
	sse_machine_load(&machine, {0x48, 0x0F, 0xAD, 0xD8, 0x0F, 0x05})
	machine.cpu.registers[rax] = 0x1234
	machine.cpu.registers[rbx] = 0xAB
	machine.cpu.registers[int(General_Register.Rcx)] = 0x108 // cl = 8.
	testing.expect_value(t, sse_machine_run(&machine), Step_Outcome.Syscall)
	testing.expect_value(t, machine.cpu.registers[rax], u64(0xAB00_0000_0000_0012))
	sse_machine_load(&machine, {0x48, 0x0F, 0xAD, 0xD8})
	machine.cpu.registers[rax] = 0x1234
	machine.cpu.registers[int(General_Register.Rcx)] = 0x40 // A count of 64 masks to 0.
	flags_before := machine.cpu.rflags
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, machine.cpu.registers[rax], u64(0x1234))
	testing.expect_value(t, machine.cpu.rflags, flags_before)
}

counter_for_test :: proc "contextless" () -> u64 {
	return 0xAABB_CCDD_1122_3344
}

@(test)
test_integer_counter_identification_and_flags_stack :: proc(t: ^testing.T) {
	machine := sse_machine_create()
	defer sse_machine_destroy(&machine)
	rax := int(General_Register.Rax)
	rdx := int(General_Register.Rdx)

	// rdtsc with no source counts the steps; with one, reads it.
	sse_machine_load(&machine, {0x0F, 0x31})
	machine.cpu.steps_executed = 0x1_0000_0005
	machine.cpu.registers[rax] = max(u64)
	machine.cpu.registers[rdx] = max(u64)
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, machine.cpu.registers[rax], u64(5))
	testing.expect_value(t, machine.cpu.registers[rdx], u64(1))
	sse_machine_load(&machine, {0x0F, 0x31})
	machine.cpu.cycle_counter_read = counter_for_test
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, machine.cpu.registers[rax], u64(0x1122_3344))
	testing.expect_value(t, machine.cpu.registers[rdx], u64(0xAABB_CCDD))

	// cpuid leaf 1 names SSE2 and no more; an unknown leaf gives zeros.
	sse_machine_load(&machine, {0x0F, 0xA2})
	machine.cpu.registers[rax] = 0xFFFF_FFFF_0000_0001
	machine.cpu.registers[int(General_Register.Rcx)] = max(u64)
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, machine.cpu.registers[rdx], u64(IDENTIFICATION_BASIC_FEATURES_EDX))
	testing.expect_value(t, machine.cpu.registers[int(General_Register.Rcx)], u64(0))
	sse_machine_load(&machine, {0x0F, 0xA2})
	machine.cpu.registers[rax] = 7
	testing.expect_value(t, sse_machine_step(&machine), Step_Outcome.Running)
	testing.expect_value(t, machine.cpu.registers[rax], u64(0))

	// popf of all ones changes the arithmetic flags and the direction only.
	stack := SSE_DATA_ADDRESS + 256
	sse_machine_load(&machine, {0x6A, 0xFF, 0x9D, 0x9C, 0x0F, 0x05}) // push -1; popf; pushf
	machine.cpu.registers[int(General_Register.Rsp)] = stack
	testing.expect_value(t, sse_machine_run(&machine), Step_Outcome.Syscall)
	expected := USER_INITIAL_RFLAGS | RFLAGS_CF | RFLAGS_PF | RFLAGS_AF | RFLAGS_ZF | RFLAGS_SF | RFLAGS_DF | RFLAGS_OF
	testing.expect_value(t, machine.cpu.rflags & ~u64(0), expected)
	testing.expect_value(t, sse_data_u64(&machine, 248), expected)
	testing.expect_value(t, machine.cpu.registers[int(General_Register.Rsp)], stack - 8)
	// popf from a stack that no page maps keeps the flags.
	sse_machine_load(&machine, {0x9D})
	machine.cpu.registers[int(General_Register.Rsp)] = SSE_UNMAPPED_ADDRESS
	flags := machine.cpu.rflags
	sse_expect_fault_kept_state(t, &machine, machine.cpu, .Page_Fault)
	testing.expect_value(t, machine.cpu.rflags, flags)
}

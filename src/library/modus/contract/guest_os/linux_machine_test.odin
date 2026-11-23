#+build !freestanding
package guest_os

import "core:testing"
import op "modus:contract/operation"

// Each decoded form of mov, with its size, its register and its length.
@(test)
device_access_decode_forms :: proc(t: ^testing.T) {
	cases := [?]struct {
		bytes: []u8,
		want:  Device_Access,
	} {
		{{0x8B, 0x07}, {direction = .Read, size = 4, register = .Rax, destination_size = 4, length = 2}},
		{{0x89, 0x47, 0x50}, {direction = .Write, size = 4, register = .Rax, length = 3}},
		{{0x48, 0x8B, 0x4F, 0x08}, {direction = .Read, size = 8, register = .Rcx, destination_size = 8, length = 4}},
		{{0x44, 0x89, 0x40, 0x70}, {direction = .Write, size = 4, register = .R8, length = 4}},
		{{0x88, 0x27}, {direction = .Write, size = 1, register = .Rax, high_byte = true, length = 2}},
		{{0x40, 0x88, 0x37}, {direction = .Write, size = 1, register = .Rsi, length = 3}},
		{{0x8A, 0x3F}, {direction = .Read, size = 1, register = .Rbx, high_byte = true, destination_size = 1, length = 2}},
		{{0x66, 0x89, 0x17}, {direction = .Write, size = 2, register = .Rdx, length = 3}},
		{{0xC7, 0x07, 0x01, 0x00, 0x00, 0x00}, {direction = .Write, size = 4, immediate = true, immediate_value = 1, length = 6}},
		{{0x48, 0xC7, 0x07, 0xFF, 0xFF, 0xFF, 0xFF}, {direction = .Write, size = 8, immediate = true, immediate_value = max(u64), length = 7}},
		{{0x66, 0xC7, 0x07, 0x34, 0x12}, {direction = .Write, size = 2, immediate = true, immediate_value = 0x1234, length = 5}},
		{{0xC6, 0x47, 0x10, 0xAB}, {direction = .Write, size = 1, immediate = true, immediate_value = 0xAB, length = 4}},
		{{0x0F, 0xB6, 0x07}, {direction = .Read, size = 1, register = .Rax, destination_size = 4, length = 3}},
		{{0x0F, 0xB7, 0x47, 0x04}, {direction = .Read, size = 2, register = .Rax, destination_size = 4, length = 4}},
		{{0x8B, 0x05, 0x10, 0x00, 0x00, 0x00}, {direction = .Read, size = 4, register = .Rax, destination_size = 4, length = 6}},
		{{0x8B, 0x04, 0x24}, {direction = .Read, size = 4, register = .Rax, destination_size = 4, length = 3}},
		{{0x8B, 0x04, 0x25, 0x00, 0x00, 0x00, 0xD0}, {direction = .Read, size = 4, register = .Rax, destination_size = 4, length = 7}},
		{{0x8B, 0x87, 0x00, 0x01, 0x00, 0x00}, {direction = .Read, size = 4, register = .Rax, destination_size = 4, length = 6}},
		{{0x65, 0x67, 0x45, 0x8B, 0x3F}, {direction = .Read, size = 4, register = .R15, destination_size = 4, length = 5}},
		// The forms that the accessors of Linux take in drivers/virtio/virtio_mmio.c,
		// with the bases and the indexes of REX.B and REX.X.
		{{0x8B, 0x43, 0x70}, {direction = .Read, size = 4, register = .Rax, destination_size = 4, length = 3}}, // readl(base + 0x70)
		{{0x89, 0x50, 0x70}, {direction = .Write, size = 4, register = .Rdx, length = 3}}, // writel(edx, base + 0x70)
		{{0x41, 0x8B, 0x84, 0x24, 0x00, 0x01, 0x00, 0x00}, {direction = .Read, size = 4, register = .Rax, destination_size = 4, length = 8}}, // mov eax, [r12 + 0x100]
		{{0x42, 0x8B, 0x04, 0x0B}, {direction = .Read, size = 4, register = .Rax, destination_size = 4, length = 4}}, // mov eax, [rbx + r9]
		{{0x47, 0x89, 0x54, 0x3D, 0x08}, {direction = .Write, size = 4, register = .R10, length = 5}}, // mov [r13 + r15 + 8], r10d
		{{0x45, 0x8B, 0x45, 0x00}, {direction = .Read, size = 4, register = .R8, destination_size = 4, length = 4}}, // mov r8d, [r13 + 0]: r13 needs a displacement.
		{{0x8B, 0x0D, 0xF8, 0xFF, 0xFF, 0xFF}, {direction = .Read, size = 4, register = .Rcx, destination_size = 4, length = 6}}, // mov ecx, [rip - 8]
		{{0x66, 0x89, 0x43, 0x0E}, {direction = .Write, size = 2, register = .Rax, length = 4}}, // writew
		{{0x66, 0x8B, 0x43, 0x0E}, {direction = .Read, size = 2, register = .Rax, destination_size = 2, length = 4}}, // readw
		{{0x88, 0x53, 0x01}, {direction = .Write, size = 1, register = .Rdx, length = 3}}, // writeb(dl)
		{{0x40, 0x8A, 0x73, 0x01}, {direction = .Read, size = 1, register = .Rsi, destination_size = 1, length = 4}}, // readb into sil
		{{0x44, 0x8A, 0x43, 0x02}, {direction = .Read, size = 1, register = .R8, destination_size = 1, length = 4}}, // readb into r8b
		{{0x0F, 0xB6, 0x43, 0x04}, {direction = .Read, size = 1, register = .Rax, destination_size = 4, length = 4}}, // movzx eax, byte [rbx + 4]
		{{0x44, 0x0F, 0xB7, 0x4B, 0x06}, {direction = .Read, size = 2, register = .R9, destination_size = 4, length = 5}}, // movzx r9d, word [rbx + 6]
		{{0x48, 0x0F, 0xBE, 0x43, 0x01}, {direction = .Read, size = 1, register = .Rax, destination_size = 8, sign_extend = true, length = 5}}, // movsx rax, byte [rbx + 1]
		{{0x0F, 0xBF, 0x03}, {direction = .Read, size = 2, register = .Rax, destination_size = 4, sign_extend = true, length = 3}}, // movsx eax, word [rbx]
		{{0x66, 0x0F, 0xBE, 0x03}, {direction = .Read, size = 1, register = .Rax, destination_size = 2, sign_extend = true, length = 4}}, // movsx ax, byte [rbx]
		{{0xC7, 0x43, 0x70, 0x00, 0x00, 0x00, 0x00}, {direction = .Write, size = 4, immediate = true, immediate_value = 0, length = 7}}, // mov dword [rbx + 0x70], 0
		{{0xC7, 0x04, 0x25, 0x70, 0x00, 0x00, 0xD0, 0x0F, 0x00, 0x00, 0x00}, {direction = .Write, size = 4, immediate = true, immediate_value = 0xF, length = 11}}, // mov dword [0xD0000070], 15
		{{0xC6, 0x84, 0x24, 0x00, 0x01, 0x00, 0x00, 0xFF}, {direction = .Write, size = 1, immediate = true, immediate_value = 0xFF, length = 8}}, // mov byte [rsp + 0x100], 0xFF
	}
	for entry in cases {
		access, refusal := device_access_decode(entry.bytes, true)
		// The operand has its own test (memory_operand_of_each_form).
		access.operand = {}
		testing.expectf(t, refusal == .None && access == entry.want, "% x gives %v %v", entry.bytes, access, refusal)
		// Each cut of the instruction is refused.
		for length in 0 ..< len(entry.bytes) {
			_, cut := device_access_decode(entry.bytes[:length], true)
			testing.expectf(t, cut == .Truncated, "% x cut at %v gives %v", entry.bytes, length, cut)
		}
	}
}

@(test)
device_access_decode_refusals :: proc(t: ^testing.T) {
	refusals := [?]struct {
		bytes:     []u8,
		long_mode: bool,
		want:      Instruction_Refusal,
	} {
		{{0x89, 0xC0}, true, .Register_Operand},
		{{0x8B, 0xC8}, true, .Register_Operand},
		{{0xFF, 0x07}, true, .Unknown_Opcode},
		{{0xA1, 0, 0, 0, 0}, true, .Unknown_Opcode},
		{{0x0F, 0xB8, 0x07}, true, .Unknown_Opcode},
		{{0xC7, 0x0F, 0, 0, 0, 0}, true, .Unknown_Opcode}, // C7 /1 is not mov.
		{{0x48, 0x8B, 0x07}, false, .Unknown_Opcode}, // dec eax in 32-bit code.
		{{0x67, 0x8B, 0x07}, false, .Unknown_Opcode},
		{{0xF3, 0xA5}, true, .Unknown_Opcode}, // rep movsd.
		{{0x0F, 0xBC, 0x03}, true, .Unknown_Opcode}, // bsf: next to movsx, not a move.
		{{0x0F, 0xBE, 0xC0}, true, .Register_Operand}, // movsx eax, al.
		{{0xF0, 0x89, 0x03}, true, .Unknown_Opcode}, // A lock prefix: no mov takes it.
	}
	for entry in refusals {
		_, refusal := device_access_decode(entry.bytes, entry.long_mode)
		testing.expectf(t, refusal == entry.want, "% x gives %v", entry.bytes, refusal)
	}
	prefixes: [20]u8
	for &value in prefixes {
		value = 0x66
	}
	_, refusal := device_access_decode(prefixes[:], true)
	testing.expect_value(t, refusal, Instruction_Refusal.Too_Long)
	long: [16]u8 = {0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x48, 0xC7, 0x87, 0, 0, 0, 0}
	_, refusal = device_access_decode(long[:], true)
	testing.expect(t, refusal == .Too_Long || refusal == .Truncated)
}

// A read writes its register with the rules of the processor.
@(test)
device_access_register_rules :: proc(t: ^testing.T) {
	registers := op.Guest_Registers{rax = 0x1111_2222_3333_4444, rbx = 0x5555_6666_7777_8888, rip = 0x1000}
	device_access_complete(&registers, {direction = .Read, size = 1, register = .Rax, destination_size = 1, length = 2}, 0xAB)
	testing.expect_value(t, registers.rax, u64(0x1111_2222_3333_44AB))
	device_access_complete(&registers, {direction = .Read, size = 1, register = .Rbx, high_byte = true, destination_size = 1, length = 2}, 0xCD)
	testing.expect_value(t, registers.rbx, u64(0x5555_6666_7777_CD88))
	device_access_complete(&registers, {direction = .Read, size = 2, register = .Rax, destination_size = 2, length = 3}, 0xBEEF)
	testing.expect_value(t, registers.rax, u64(0x1111_2222_3333_BEEF))
	device_access_complete(&registers, {direction = .Read, size = 4, register = .Rax, destination_size = 4, length = 2}, 0xFFFF_FFFF_DEAD_BEEF)
	testing.expect_value(t, registers.rax, u64(0xDEAD_BEEF))
	device_access_complete(&registers, {direction = .Read, size = 1, register = .Rbx, destination_size = 4, length = 3}, 0x1FF)
	testing.expect_value(t, registers.rbx, u64(0xFF))
	testing.expect_value(t, registers.rip, u64(0x1000 + 2 + 2 + 3 + 2 + 3))
	value := device_access_value({rax = 0xAABB_CCDD}, {direction = .Write, size = 1, register = .Rax, high_byte = true})
	testing.expect_value(t, value, u64(0xCC))
	value = device_access_value({r8 = max(u64)}, {direction = .Write, size = 2, register = .R8})
	testing.expect_value(t, value, u64(0xFFFF))
	// movsx: the sign fills the register to its size; a write of 4 bytes
	// clears the high half, a write of 2 bytes keeps it.
	signed := op.Guest_Registers{rax = 0x1111_2222_3333_4444}
	device_access_complete(&signed, {direction = .Read, size = 1, register = .Rax, destination_size = 8, sign_extend = true, length = 5}, 0x80)
	testing.expect_value(t, signed.rax, u64(0xFFFF_FFFF_FFFF_FF80))
	device_access_complete(&signed, {direction = .Read, size = 1, register = .Rax, destination_size = 4, sign_extend = true, length = 3}, 0xFFFF_FF7F)
	testing.expect_value(t, signed.rax, u64(0x7F))
	signed.rax = 0x1111_2222_3333_4444
	device_access_complete(&signed, {direction = .Read, size = 2, register = .Rax, destination_size = 4, sign_extend = true, length = 3}, 0x8001)
	testing.expect_value(t, signed.rax, u64(0xFFFF_8001))
	signed.rax = 0x1111_2222_3333_4444
	device_access_complete(&signed, {direction = .Read, size = 1, register = .Rax, destination_size = 2, sign_extend = true, length = 4}, 0xFE)
	testing.expect_value(t, signed.rax, u64(0x1111_2222_3333_FFFE))
	testing.expect_value(t, sign_extended(0x8000_0000, 4), u64(0xFFFF_FFFF_8000_0000))
	testing.expect_value(t, sign_extended(max(u64), 8), max(u64))
	testing.expect_value(t, sign_extended(0x17F, 1), u64(0x7F))
}

// The model-specific registers: each value that the processor refuses
// gives a general protection fault and changes nothing; each accepted
// value lands in its field, and the record still passes the checks.
@(test)
machine_model_specific_registers :: proc(t: ^testing.T) {
	machine := new(Linux_Machine)
	defer free(machine)
	linux_machine_start(machine, {}, nil, nil)
	long := op.Guest_Registers {
		rip  = 0x10_0000,
		cr0  = op.GUEST_CONTROL_0_PROTECTION | op.GUEST_CONTROL_0_PAGING,
		cr4  = op.GUEST_CONTROL_4_PHYSICAL_ADDRESS_EXTENSION,
		efer = op.GUEST_EFER_LONG_MODE_ENABLE | op.GUEST_EFER_LONG_MODE_ACTIVE | op.GUEST_EFER_SECURE_VIRTUAL_MACHINE,
	}
	msr_exit :: proc(machine: ^Linux_Machine, registers: ^op.Guest_Registers, register: u32, write: bool, value: u64) -> Machine_Step {
		registers.rcx = u64(register)
		registers.rax = value & 0xFFFF_FFFF
		registers.rdx = value >> 32
		return linux_machine_handle_exit(machine, registers, {kind = .Other, code = u64(Other_Exit_Code.Model_Specific_Register), information = write ? 1 : 0})
	}
	refused := [?]struct {
		register: u32,
		value:    u64,
	} {
		{0xC000_0082, 0x0000_8000_0000_0000},
		{0xC000_0082, 0xFFFF_7FFF_FFFF_FFFF},
		{0xC000_0083, 0x8000_0000_0000_0000},
		{0xC000_0084, 0x1_0000_0000},
		{0xC000_0100, 0x0001_0000_0000_0000},
		{0xC000_0101, 0x0000_8000_0000_0000},
		{0xC000_0102, max(u64) >> 1},
		{0xC000_0080, u64(op.GUEST_EFER_SECURE_VIRTUAL_MACHINE)},
		{0xC000_0080, 1 << 2},
		{0x0000_001B, 0xFEE0_0900},
		{0x0000_0010, 0}, // The counter of the virtual clock never moves back.
		{0x0000_0277, 0x0007_0406_0007_0402}, // A reserved memory type: 2.
		{0x0000_0277, 0x0307_0406_0007_0406}, // A reserved memory type: 3.
		{0x0000_0277, 0x0807_0406_0007_0406}, // A bit past the type.
		{0x0000_00FE, 0}, // MTRRCAP: read only.
		{0x0000_01A0, 1},
		{0x0000_02FF, 0x800}, // The ranges stay off.
		{0x0000_0048, 0}, // SPEC_CTRL: cpuid does not offer it.
		{0x0000_010A, 0}, // ARCH_CAPABILITIES: cpuid does not offer it.
		{0xFFFF_FFFF, 0},
	}
	for entry in refused {
		registers := long
		step := msr_exit(machine, &registers, entry.register, true, entry.value)
		testing.expect_value(t, step, Machine_Step.Continue)
		testing.expectf(t, registers.inject_kind == u8(op.Guest_Inject_Kind.Exception) && registers.inject_vector == VECTOR_GENERAL_PROTECTION && registers.inject_error_code_valid == 1, "msr %x value %x gives a fault", entry.register, entry.value)
		testing.expectf(t, registers.rip == long.rip, "msr %x: the instruction does not complete", entry.register)
		testing.expect(t, registers.lstar == 0 && registers.fs_base == 0 && registers.gs_base == 0 && registers.kernel_gs_base == 0 && registers.sfmask == 0 && registers.efer == long.efer)
	}
	testing.expect_value(t, machine.faults_injected, u64(len(refused)))
	// A change of LME while paging is on: the processor refuses it, in both
	// directions, and with LMA kept.
	lme_changes := [?]struct {
		registers: op.Guest_Registers,
		value:     u64,
	} {
		{long, u64(op.GUEST_EFER_LONG_MODE_ACTIVE)},
		{long, u64(op.GUEST_EFER_SYSTEM_CALL | op.GUEST_EFER_NO_EXECUTE)},
		{{rip = 0x1000, cr0 = op.GUEST_CONTROL_0_PROTECTION | op.GUEST_CONTROL_0_PAGING}, u64(op.GUEST_EFER_LONG_MODE_ENABLE)},
	}
	for entry in lme_changes {
		registers := entry.registers
		msr_exit(machine, &registers, 0xC000_0080, true, entry.value)
		testing.expectf(t, registers.inject_vector == VECTOR_GENERAL_PROTECTION && registers.rip == entry.registers.rip, "EFER %x with paging on is refused", entry.value)
		testing.expect_value(t, registers.efer, entry.registers.efer)
	}
	testing.expect_value(t, machine.faults_injected, u64(len(refused) + len(lme_changes)))
	// With paging off, LME turns on; with paging on, a write that keeps LME
	// is accepted.
	unpaged := op.Guest_Registers{rip = 0x1000, cr0 = op.GUEST_CONTROL_0_PROTECTION}
	msr_exit(machine, &unpaged, 0xC000_0080, true, u64(op.GUEST_EFER_LONG_MODE_ENABLE))
	testing.expect(t, unpaged.inject_kind == 0 && unpaged.efer == op.GUEST_EFER_LONG_MODE_ENABLE && unpaged.rip == 0x1002)
	// The next instruction that the kernel gives wins: a prefix makes the
	// instruction longer than 2 bytes.
	prefixed := long
	prefixed.rcx = 0xC000_0081
	prefixed.rax, prefixed.rdx = 1, 0
	linux_machine_handle_exit(machine, &prefixed, {kind = .Other, code = u64(Other_Exit_Code.Model_Specific_Register), information = 1, next = long.rip + 3})
	testing.expect(t, prefixed.inject_kind == 0 && prefixed.star == 1 && prefixed.rip == long.rip + 3)
	// An exit of a model-specific register with an information that names
	// neither a read nor a write stops the guest.
	odd := long
	testing.expect_value(t, linux_machine_handle_exit(machine, &odd, {kind = .Other, code = u64(Other_Exit_Code.Model_Specific_Register), information = 2}), Machine_Step.Failed)
	testing.expect_value(t, machine.failure, Machine_Failure.Unknown_Exit)
	// A read of the local APIC faults too: cpuid does not offer it. So do
	// the reads of the registers of speculation that cpuid does not offer:
	// Linux reads them only with the check of a fault.
	for register in ([?]u32{0x1B, 0x48, 0x10A, 0xC000_0103, 0x8B}) {
		registers := long
		msr_exit(machine, &registers, register, false, 0)
		testing.expectf(t, registers.inject_vector == VECTOR_GENERAL_PROTECTION && registers.rip == long.rip, "a read of msr %x faults", register)
	}
	registers := long
	// The successful cases last.
	registers = long
	accepted := [?]struct {
		register: u32,
		value:    u64,
	} {
		{0xC000_0081, 0x0023_0010_0000_0000},
		{0xC000_0082, 0xFFFF_FFFF_8100_0000},
		{0xC000_0083, 0xFFFF_FFFF_8100_1000},
		{0xC000_0084, 0x0004_7700},
		{0xC000_0100, 0x0000_7FFF_FFFF_F000},
		{0xC000_0101, 0xFFFF_8880_0000_0000},
		{0xC000_0102, 0x1000},
		{0x0000_0174, 0x10},
		{0xC000_0080, u64(op.GUEST_EFER_SYSTEM_CALL | op.GUEST_EFER_LONG_MODE_ENABLE | op.GUEST_EFER_NO_EXECUTE | op.GUEST_EFER_LONG_MODE_ACTIVE)},
	}
	for entry, index in accepted {
		msr_exit(machine, &registers, entry.register, true, entry.value)
		testing.expectf(t, registers.inject_kind == 0, "msr %x is accepted", entry.register)
		testing.expect_value(t, registers.rip, long.rip + u64(index + 1) * 2)
	}
	testing.expect_value(t, registers.star, u64(0x0023_0010_0000_0000))
	testing.expect_value(t, registers.lstar, u64(0xFFFF_FFFF_8100_0000))
	testing.expect_value(t, machine.compatibility_system_call_target, u64(0xFFFF_FFFF_8100_1000))
	testing.expect_value(t, registers.sfmask, u64(0x0004_7700))
	testing.expect_value(t, registers.fs_base, u64(0x0000_7FFF_FFFF_F000))
	testing.expect_value(t, registers.gs_base, u64(0xFFFF_8880_0000_0000))
	testing.expect_value(t, registers.kernel_gs_base, u64(0x1000))
	testing.expect_value(t, registers.efer, op.GUEST_EFER_SYSTEM_CALL | op.GUEST_EFER_LONG_MODE_ENABLE | op.GUEST_EFER_NO_EXECUTE | op.GUEST_EFER_LONG_MODE_ACTIVE | op.GUEST_EFER_SECURE_VIRTUAL_MACHINE)
	_, check := op.guest_registers_check(registers)
	testing.expect_value(t, check, op.Guest_Registers_Refusal.None)
	// A read splits the value in edx:eax; EFER hides SVME.
	msr_exit(machine, &registers, 0xC000_0082, false, max(u64))
	testing.expect(t, registers.rax == 0x8100_0000 && registers.rdx == 0xFFFF_FFFF)
	msr_exit(machine, &registers, 0xC000_0080, false, 0)
	testing.expect_value(t, registers.rax & u64(op.GUEST_EFER_SECURE_VIRTUAL_MACHINE), u64(0))
}

// The registers that an early boot of Linux can read on a processor of 64
// bits answer with no fault and no stop: the page attribute table at its
// reset value, the ranges of memory types off, no feature to turn off, and
// the time stamp counter of the virtual clock.
@(test)
machine_early_boot_model_specific_registers :: proc(t: ^testing.T) {
	machine := new(Linux_Machine)
	defer free(machine)
	linux_machine_start(machine, {}, nil, nil)
	read :: proc(machine: ^Linux_Machine, register: u32) -> (value: u64, registers: op.Guest_Registers, step: Machine_Step) {
		registers = {rip = 0x10_0000, rcx = u64(register), rax = max(u64), rdx = max(u64)}
		step = linux_machine_handle_exit(machine, &registers, {kind = .Other, code = u64(Other_Exit_Code.Model_Specific_Register), information = 0})
		return registers.rdx << 32 | registers.rax, registers, step
	}
	write :: proc(machine: ^Linux_Machine, register: u32, value: u64) -> op.Guest_Registers {
		registers := op.Guest_Registers{rip = 0x10_0000, rcx = u64(register), rax = value & 0xFFFF_FFFF, rdx = value >> 32}
		linux_machine_handle_exit(machine, &registers, {kind = .Other, code = u64(Other_Exit_Code.Model_Specific_Register), information = 1})
		return registers
	}
	expected := [?]struct {
		register: u32,
		value:    u64,
	} {
		{0x0000_0277, PAGE_ATTRIBUTE_TABLE_RESET},
		{0x0000_00FE, 0},
		{0x0000_01A0, 0},
		{0x0000_02FF, 0},
	}
	for entry in expected {
		value, registers, step := read(machine, entry.register)
		testing.expect_value(t, step, Machine_Step.Continue)
		testing.expectf(t, registers.inject_kind == 0 && value == entry.value && registers.rip == 0x10_0002, "msr %x reads %x", entry.register, value)
	}
	testing.expect_value(t, machine.failure, Machine_Failure.None)
	// The counter of the virtual clock, as rdtsc gives it: each exit moves
	// the clock, so two reads never give one value.
	first, _, _ := read(machine, 0x10)
	second, _, _ := read(machine, 0x10)
	testing.expect_value(t, first, machine.clock * LINUX_TIME_STAMP_COUNTS_PER_TICK - LINUX_TICKS_PER_EXIT * LINUX_TIME_STAMP_COUNTS_PER_TICK)
	testing.expect(t, second > first)
	// The writes that change nothing are accepted; the table of Linux (write
	// back, write combining, uncached-minus, uncached, write back, write
	// protected, uncached-minus, write through) lands and reads back.
	LINUX_PAGE_ATTRIBUTE_TABLE :: u64(0x0407_0506_0007_0106)
	for entry in ([?]struct {
			register: u32,
			value:    u64,
		}{{0x01A0, 0}, {0x02FF, 0}, {0x0277, LINUX_PAGE_ATTRIBUTE_TABLE}}) {
		registers := write(machine, entry.register, entry.value)
		testing.expectf(t, registers.inject_kind == 0 && registers.rip == 0x10_0002, "a write of %x to msr %x is accepted", entry.value, entry.register)
	}
	value, _, _ := read(machine, 0x277)
	testing.expect_value(t, value, LINUX_PAGE_ATTRIBUTE_TABLE)
	testing.expect_value(t, machine.faults_injected, u64(0))
	// Each byte of the table names a type: the edges of the check.
	testing.expect(t, page_attribute_table_valid(0) && page_attribute_table_valid(0x0707_0707_0707_0707))
	testing.expect(t, !page_attribute_table_valid(0x02) && !page_attribute_table_valid(0x0300) && !page_attribute_table_valid(0x08 << 56) && !page_attribute_table_valid(max(u64)))
}

// wbinvd and wbnoinvd complete with no work; an exit of that code on
// another instruction stops the guest.
@(test)
machine_cache_write_back :: proc(t: ^testing.T) {
	machine := new(Linux_Machine)
	defer free(machine)
	bytes := make([]u8, 0x2000)
	defer delete(bytes)
	linux_machine_start(machine, {bytes}, nil, nil)
	// Paging off: the linear address is the physical address.
	unpaged := op.Guest_Registers{cr0 = op.GUEST_CONTROL_0_PROTECTION}
	exit := Machine_Exit{kind = .Other, code = u64(Other_Exit_Code.Write_Back_Invalidate)}
	cases := [?]struct {
		bytes: []u8,
		step:  Machine_Step,
		next:  u64,
	} {
		{{0x0F, 0x08}, .Failed, 0}, // invd: not answered.
		{{0x66, 0x0F, 0x09}, .Failed, 0}, // A prefix that the machine does not know.
		{{0x0F}, .Failed, 0}, // Cut at the end of the memory.
		{{0x0F, 0x09}, .Continue, 2},
		{{0xF3, 0x0F, 0x09}, .Continue, 3},
	}
	for entry in cases {
		machine.failure = .None
		registers := unpaged
		registers.rip = u64(len(bytes) - len(entry.bytes))
		copy(bytes[registers.rip:], entry.bytes)
		step := linux_machine_handle_exit(machine, &registers, exit)
		testing.expectf(t, step == entry.step, "% x gives %v", entry.bytes, step)
		if entry.step == .Continue {
			testing.expect_value(t, registers.rip, u64(len(bytes)))
			testing.expect_value(t, machine.failure, Machine_Failure.None)
		} else {
			testing.expect_value(t, registers.rip, u64(len(bytes) - len(entry.bytes)))
			testing.expect_value(t, machine.failure, Machine_Failure.Undecoded_Instruction)
		}
	}
}

// cpuid offers long mode, SYSCALL and NX, and no local APIC and no XSAVE.
@(test)
machine_cpuid :: proc(t: ^testing.T) {
	_, _, _, d := linux_cpuid(0x8000_0001, 0)
	testing.expect(t, d & (1 << 29) != 0 && d & (1 << 11) != 0 && d & (1 << 20) != 0)
	_, _, c, d1 := linux_cpuid(1, 0)
	testing.expect(t, d1 & (1 << 9) == 0) // No APIC.
	testing.expect(t, c & (1 << 26) == 0) // No XSAVE.
	testing.expect(t, c & (1 << 31) != 0) // A hypervisor.
	// The features that Linux needs of a processor of 64 bits.
	for bit in ([?]u32{0, 3, 5, 6, 8, 13, 15, 24, 25, 26}) {
		testing.expectf(t, d1 & (1 << bit) != 0, "leaf 1 edx bit %v", bit)
	}
	a, b, c2, d2 := linux_cpuid(0x4000_0000, 0)
	testing.expect(t, a == 0 && b == 0 && c2 == 0 && d2 == 0)
	a, _, _, _ = linux_cpuid(0x8000_0009, 0)
	testing.expect_value(t, a, u32(0))
}

// The ports: the serial port captures what the guest writes and passes the
// loop test of Linux; a port of no device goes back to the process; a size
// that no port instruction has fails.
@(test)
machine_ports :: proc(t: ^testing.T) {
	machine := new(Linux_Machine)
	defer free(machine)
	linux_machine_start(machine, {}, nil, nil)
	registers := op.Guest_Registers{rip = 0x100}
	for value in "ok\n" {
		step := linux_machine_handle_exit(machine, &registers, {kind = .Port_Write, a = 0x3F8, b = 1, c = u64(value), next = registers.rip + 1})
		testing.expect_value(t, step, Machine_Step.Continue)
	}
	testing.expect_value(t, string(machine.serial.capture[:machine.serial.captured]), "ok\n")
	testing.expect_value(t, registers.rip, u64(0x103))
	linux_machine_handle_exit(machine, &registers, {kind = .Port_Write, a = 0x3FC, b = 1, c = 0x1A, next = 0})
	registers.rax = 0xFFFF_FFFF_FFFF_FF00
	linux_machine_handle_exit(machine, &registers, {kind = .Port_Read, a = 0x3FE, b = 1, next = 0})
	testing.expect_value(t, registers.rax, u64(0xFFFF_FFFF_FFFF_FF90))
	linux_machine_handle_exit(machine, &registers, {kind = .Port_Read, a = 0x3FD, b = 1, next = 0})
	testing.expect_value(t, registers.rax & 0xFF, u64(0x60))
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Port_Write, a = 0x508, b = 4, c = 0}), Machine_Step.Not_Handled)
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Port_Read, a = 0x70, b = 1}), Machine_Step.Not_Handled)
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Port_Read, a = 0x3FF, b = 2}), Machine_Step.Not_Handled)
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Port_Read, a = 0x3F8, b = 3}), Machine_Step.Failed)
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Shutdown}), Machine_Step.Failed)
	testing.expect_value(t, machine.failure, Machine_Failure.Shutdown)
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Other, code = 0x88}), Machine_Step.Failed)
}

// The tick: the guest sets the controllers and the timer as Linux does;
// hlt with interrupts on jumps to the next tick and delivers it at the
// vector of the line 0; with interrupts off, or the line masked, the guest
// stopped; no tick waits in service before its end of interrupt.
@(test)
machine_timer_interrupts :: proc(t: ^testing.T) {
	machine := new(Linux_Machine)
	defer free(machine)
	linux_machine_start(machine, {}, nil, nil)
	registers := op.Guest_Registers{rflags = 0x2}
	out :: proc(machine: ^Linux_Machine, registers: ^op.Guest_Registers, port: u16, value: u8) {
		linux_machine_handle_exit(machine, registers, {kind = .Port_Write, a = u64(port), b = 1, c = u64(value), next = registers.rip})
	}
	for pair in ([?][2]u16{{0x20, 0x11}, {0x21, 0x30}, {0x21, 0x04}, {0x21, 0x01}, {0xA0, 0x11}, {0xA1, 0x38}, {0xA1, 0x02}, {0xA1, 0x01}, {0x21, 0xFF}, {0xA1, 0xFF}}) {
		out(machine, &registers, pair[0], u8(pair[1]))
	}
	out(machine, &registers, 0x43, 0x34) // Channel 0, both bytes, mode 2.
	out(machine, &registers, 0x40, 0x00)
	out(machine, &registers, 0x40, 0x10) // 4096 ticks.
	// All lines masked: hlt with interrupts on stops the guest.
	registers.rflags = 0x202
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Halt, next = 1}), Machine_Step.Halted)
	out(machine, &registers, 0x21, 0xFE)
	registers.rflags = 0x2
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Halt, next = 1}), Machine_Step.Halted)
	registers.rflags = 0x202
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Halt, next = 1}), Machine_Step.Continue)
	testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.External_Interrupt))
	testing.expect_value(t, registers.inject_vector, u8(0x30))
	testing.expect(t, machine.clock >= 4096)
	// The kernel delivered it; the line stays in service until the end.
	registers.inject_kind, registers.inject_vector = 0, 0
	machine.clock += 3 * 4096
	linux_machine_handle_exit(machine, &registers, {kind = .Interrupted})
	testing.expect_value(t, registers.inject_kind, u8(0))
	out(machine, &registers, 0x20, 0x20)
	testing.expect_value(t, registers.inject_vector, u8(0x30))
	// The count reads down from the reload, latched in two bytes.
	out(machine, &registers, 0x43, 0x00)
	registers.rax = 0
	linux_machine_handle_exit(machine, &registers, {kind = .Port_Read, a = 0x40, b = 1})
	low := registers.rax & 0xFF
	linux_machine_handle_exit(machine, &registers, {kind = .Port_Read, a = 0x40, b = 1})
	count := (registers.rax & 0xFF) << 8 | low
	testing.expect(t, count >= 1 && count <= 4096)
	// A virtio line on the secondary controller comes through the cascade.
	registers.inject_kind, registers.inject_vector = 0, 0
	out(machine, &registers, 0x20, 0x20)
	out(machine, &registers, 0x21, 0xFB)
	out(machine, &registers, 0xA1, 0xF7) // Line 11: the disk of outputs.
	machine.devices[.Output_Disk].interrupt_status = VIRTIO_INTERRUPT_USED_BUFFER
	linux_machine_handle_exit(machine, &registers, {kind = .Interrupted})
	testing.expect_value(t, registers.inject_vector, u8(0x38 + 3))
}

// A device access by the decode of the instruction at rip, through the
// page table of the guest; a mismatch of the access or an instruction that
// the decode refuses stops the guest; an access inside the memory asks the
// process to switch its region.
@(test)
machine_device_access :: proc(t: ^testing.T) {
	bytes := make([]u8, TEST_MEMORY_BYTES)
	defer delete(bytes)
	memory := Guest_Memory{bytes}
	top, _ := linux_page_tables_write(memory, LINUX_PAGE_TABLES_ADDRESS)
	machine := new(Linux_Machine)
	defer free(machine)
	disk: [4096]u8
	linux_machine_start(machine, memory, disk[:], disk[:])
	registers := op.Guest_Registers {
		rip  = LINUX_HIGHER_HALF + 0x20_0000 - 1, // An instruction across two pages.
		cr0  = op.GUEST_CONTROL_0_PROTECTION | op.GUEST_CONTROL_0_PAGING,
		cr3  = top,
		cr4  = op.GUEST_CONTROL_4_PHYSICAL_ADDRESS_EXTENSION,
		efer = op.GUEST_EFER_LONG_MODE_ENABLE | op.GUEST_EFER_LONG_MODE_ACTIVE,
	}
	copy(bytes[0x20_0000 - 1:], []u8{0x8B, 0x07}) // mov eax, [rdi]
	step := linux_machine_handle_exit(machine, &registers, {kind = .Memory, a = LINUX_VIRTIO_BASE + 0x1000, b = 0})
	testing.expect_value(t, step, Machine_Step.Continue)
	testing.expect_value(t, registers.rax, u64(VIRTIO_MAGIC))
	testing.expect_value(t, registers.rip, LINUX_HIGHER_HALF + 0x20_0001)
	// A write: mov [rdi+0x70], esi with esi 1 (ACKNOWLEDGE) to Status.
	copy(bytes[0x20_0001:], []u8{0x89, 0x77, 0x70})
	registers.rsi = 0xFFFF_FFFF_0000_0001
	step = linux_machine_handle_exit(machine, &registers, {kind = .Memory, a = LINUX_VIRTIO_BASE + 0x1070, b = FAULT_ACCESS_WRITE | 1})
	testing.expect_value(t, step, Machine_Step.Continue)
	testing.expect_value(t, machine.devices[.Input_Disk].status, VIRTIO_STATUS_ACKNOWLEDGE)
	// An address where no device answers: the read gives all ones.
	copy(bytes[0x20_0004:], []u8{0x8B, 0x0F})
	step = linux_machine_handle_exit(machine, &registers, {kind = .Memory, a = 0xFEE0_0030, b = 0})
	testing.expect(t, step == .Continue && registers.rcx == 0xFFFF_FFFF)
	testing.expect_value(t, machine.unclaimed_accesses, u64(1))
	// Refusals: the instruction reads where the exit says write, an
	// instruction that is not decoded, an instruction on no page.
	at := registers.rip
	copy(bytes[0x20_0006:], []u8{0x8B, 0x07})
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Memory, a = LINUX_VIRTIO_BASE, b = FAULT_ACCESS_WRITE}), Machine_Step.Failed)
	testing.expect_value(t, machine.failure, Machine_Failure.Access_Mismatch)
	copy(bytes[0x20_0006:], []u8{0xF3, 0xA5})
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Memory, a = LINUX_VIRTIO_BASE, b = FAULT_ACCESS_WRITE}), Machine_Step.Failed)
	testing.expect_value(t, machine.failure, Machine_Failure.Undecoded_Instruction)
	registers.rip = 0x0000_7000_0000_0000
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Memory, a = LINUX_VIRTIO_BASE, b = 0}), Machine_Step.Failed)
	testing.expect_value(t, machine.devices[.Input_Disk].status, VIRTIO_STATUS_ACKNOWLEDGE)
	registers.rip = at
	// Inside the memory: the kernel switches each page itself, so a fault
	// that reaches the machine is one that the kernel refused.
	for access in ([?]u64{FAULT_ACCESS_WRITE | 1, FAULT_ACCESS_EXECUTE | 1, 1}) {
		machine.failure = .None
		testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Memory, a = 0x30_0000, b = access}), Machine_Step.Failed)
		testing.expect_value(t, machine.failure, Machine_Failure.Memory_Refused)
	}
}

// rdtsc and rdtscp: the count comes from the virtual clock, never goes
// back, is the same in two machines that see the same exits, and the
// instruction completes at the address that the kernel gave, or after its
// bytes.
@(test)
machine_time_stamp_counter :: proc(t: ^testing.T) {
	machine := new(Linux_Machine)
	defer free(machine)
	linux_machine_start(machine, {}, nil, nil)
	// An exit code that the machine does not answer stops the guest.
	for code in ([?]u64{0x6D, 0x6F, 0x86, 0x88, max(u64)}) {
		registers := op.Guest_Registers{rip = 0x1000}
		testing.expectf(t, linux_machine_handle_exit(machine, &registers, {kind = .Other, code = code}) == .Failed, "exit code %x", code)
		testing.expect_value(t, registers.rip, u64(0x1000))
	}
	machine^ = {}
	linux_machine_start(machine, {}, nil, nil)
	registers := op.Guest_Registers{rip = 0x1000, rax = max(u64), rcx = 0x55, rdx = max(u64)}
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Other, code = 0x6E}), Machine_Step.Continue)
	testing.expect_value(t, registers.rax, LINUX_TICKS_PER_EXIT * LINUX_TIME_STAMP_COUNTS_PER_TICK)
	testing.expect_value(t, registers.rdx, u64(0))
	testing.expect_value(t, registers.rcx, u64(0x55)) // rdtsc leaves rcx.
	testing.expect_value(t, registers.rip, u64(0x1002))
	linux_machine_handle_exit(machine, &registers, {kind = .Other, code = 0x87})
	testing.expect_value(t, registers.rax, 2 * LINUX_TICKS_PER_EXIT * LINUX_TIME_STAMP_COUNTS_PER_TICK)
	testing.expect_value(t, registers.rcx, u64(0))
	testing.expect_value(t, registers.rip, u64(0x1005))
	linux_machine_handle_exit(machine, &registers, {kind = .Other, code = 0x6E, next = 0x2000})
	testing.expect_value(t, registers.rip, u64(0x2000))
	// The high half goes to rdx.
	machine.clock = u64(1) << 40
	linux_machine_handle_exit(machine, &registers, {kind = .Other, code = 0x87, next = 0x2003})
	count := (u64(1) << 40 + LINUX_TICKS_PER_EXIT) * LINUX_TIME_STAMP_COUNTS_PER_TICK
	testing.expect(t, registers.rax == count & 0xFFFF_FFFF && registers.rdx == count >> 32)
	testing.expect(t, registers.rax <= 0xFFFF_FFFF && registers.rdx != 0)
	// Two reads never give one value, the count never goes back, and two
	// machines that see the same exits read the same counts.
	other := new(Linux_Machine)
	defer free(other)
	linux_machine_start(machine, {}, nil, nil)
	linux_machine_start(other, {}, nil, nil)
	first := op.Guest_Registers{rip = 0x1000}
	second := first
	last := u64(0)
	for index in 0 ..< 100 {
		linux_machine_handle_exit(machine, &first, {kind = .Other, code = 0x6E, next = first.rip + 2})
		linux_machine_handle_exit(other, &second, {kind = .Other, code = 0x6E, next = second.rip + 2})
		read := first.rdx << 32 | first.rax
		testing.expectf(t, read > last, "read %v: %v after %v", index, read, last)
		testing.expect_value(t, second.rdx << 32 | second.rax, read)
		last = read
	}
	testing.expect_value(t, first, second)
	_, refusal := op.guest_registers_check(first)
	testing.expect_value(t, refusal, op.Guest_Registers_Refusal.None)
}

// The interrupt shadow: after an exit inside the shadow of sti or mov ss
// with the guest still at its instruction, the tick waits, and the record
// passes the checks of the kernel; it comes at the first exit out of the
// shadow. An exit whose instruction the machine completes (sti; hlt) ends
// the shadow, and the tick comes at once.
@(test)
machine_interrupt_shadow_defers_the_tick :: proc(t: ^testing.T) {
	machine := new(Linux_Machine)
	defer free(machine)
	linux_machine_start(machine, {}, nil, nil)
	registers := op.Guest_Registers{rflags = 0x2, rip = 0x100}
	out :: proc(machine: ^Linux_Machine, registers: ^op.Guest_Registers, port: u16, value: u8) {
		linux_machine_handle_exit(machine, registers, {kind = .Port_Write, a = u64(port), b = 1, c = u64(value), next = registers.rip + 1})
	}
	for pair in ([?][2]u16{{0x20, 0x11}, {0x21, 0x30}, {0x21, 0x04}, {0x21, 0x01}, {0xA0, 0x11}, {0xA1, 0x38}, {0xA1, 0x02}, {0xA1, 0x01}, {0x21, 0xFE}, {0xA1, 0xFF}}) {
		out(machine, &registers, pair[0], u8(pair[1]))
	}
	out(machine, &registers, 0x43, 0x34)
	out(machine, &registers, 0x40, 0x00)
	out(machine, &registers, 0x40, 0x10) // 4096 ticks.
	machine.clock += 2 * 4096
	// In the shadow, with interrupts on: the record asks for the tick only
	// to open the interrupt window, and no line goes into service, at each
	// exit that leaves the guest at its instruction.
	registers.rflags = 0x202
	registers.interrupt_shadow = 1
	at := registers.rip
	for _ in 0 ..< 3 {
		testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Interrupted}), Machine_Step.Continue)
		testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.External_Interrupt))
		testing.expect(t, machine.window_requested)
		testing.expect_value(t, machine.interrupts.primary.service, u8(0))
		testing.expect_value(t, registers.interrupt_shadow, u8(1))
		testing.expect_value(t, registers.rip, at)
		_, refusal := op.guest_registers_check(registers)
		testing.expect_value(t, refusal, op.Guest_Registers_Refusal.None)
	}
	// An exception of the machine in the shadow is still given: a refused
	// model-specific register does not complete, and the shadow stays.
	registers.rcx = 0x1B
	linux_machine_handle_exit(machine, &registers, {kind = .Other, code = u64(Other_Exit_Code.Model_Specific_Register), information = 0})
	testing.expect(t, registers.inject_kind == u8(op.Guest_Inject_Kind.Exception) && registers.inject_vector == VECTOR_GENERAL_PROTECTION)
	testing.expect_value(t, registers.interrupt_shadow, u8(1))
	_, exception_refusal := op.guest_registers_check(registers)
	testing.expect_value(t, exception_refusal, op.Guest_Registers_Refusal.None)
	registers.inject_kind, registers.inject_vector, registers.inject_error_code_valid = 0, 0, 0
	// The shadow ended in the guest: the kernel gives the record with 0, and
	// the tick comes.
	registers.interrupt_shadow = 0
	linux_machine_handle_exit(machine, &registers, {kind = .Interrupted})
	testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.External_Interrupt))
	testing.expect_value(t, registers.inject_vector, u8(0x30))
	// sti; hlt: the end of interrupt with interrupts off, then hlt in the
	// shadow of sti. The machine completes hlt, so the shadow ends, and the
	// next tick comes with no exit more.
	registers.inject_kind, registers.inject_vector = 0, 0
	registers.rflags = 0x2
	out(machine, &registers, 0x20, 0x20)
	// No tick waits yet: no request, and no window.
	testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.None))
	testing.expect(t, !machine.window_requested)
	registers.rflags = 0x202
	registers.interrupt_shadow = 1
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Halt, next = registers.rip + 1}), Machine_Step.Continue)
	testing.expect_value(t, registers.interrupt_shadow, u8(0))
	testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.External_Interrupt))
	testing.expect_value(t, registers.inject_vector, u8(0x30))
	_, refusal := op.guest_registers_check(registers)
	testing.expect_value(t, refusal, op.Guest_Registers_Refusal.None)
}

@(test)
host_interruptions_do_not_advance_guest_tsc_and_rdpru_faults :: proc(t: ^testing.T) {
	machine := new(Linux_Machine)
	defer free(machine)
	linux_machine_start(machine, {}, nil, nil)
	registers := op.Guest_Registers{rip = 0x1000, rflags = 0x2}

	// First rdtsc exit.
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Other, code = u64(Other_Exit_Code.Time_Stamp_Counter), next = 0x1002}), Machine_Step.Continue)
	tsc1 := (registers.rdx << 32) | (registers.rax & 0xFFFF_FFFF)
	// Several host-caused .Interrupted exits must not move the guest clock.
	for _ in 0 ..< 10 {
		testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Interrupted}), Machine_Step.Continue)
	}
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Other, code = u64(Other_Exit_Code.Time_Stamp_Counter), next = 0x1004}), Machine_Step.Continue)
	tsc2 := (registers.rdx << 32) | (registers.rax & 0xFFFF_FFFF)
	testing.expect_value(t, tsc2 - tsc1, LINUX_TICKS_PER_EXIT * LINUX_TIME_STAMP_COUNTS_PER_TICK)

	// rdpru (0x8E) must inject #UD (vector 6) without advancing rip.
	registers.inject_kind, registers.inject_vector = 0, 0
	before_rip := registers.rip
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Other, code = u64(Other_Exit_Code.Read_Processor_Register), next = before_rip + 3}), Machine_Step.Continue)
	testing.expect_value(t, registers.rip, before_rip)
	testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.Exception))
	testing.expect_value(t, registers.inject_vector, u8(6))
}

// The interrupt window from the side of the machine: a line that waits
// while the guest takes no interrupt opens the window with no acknowledge;
// the exit Interrupt_Window acknowledges it and asks for its vector; a
// controller that the guest did not program (base 0) never gives a vector
// below 32 to the kernel.
@(test)
machine_interrupt_window_and_unprogrammed_controller :: proc(t: ^testing.T) {
	machine := new(Linux_Machine)
	defer free(machine)
	linux_machine_start(machine, {}, nil, nil)
	registers := op.Guest_Registers{rflags = 0x202, rip = 0x100}
	out :: proc(machine: ^Linux_Machine, registers: ^op.Guest_Registers, port: u16, value: u8) {
		linux_machine_handle_exit(machine, registers, {kind = .Port_Write, a = u64(port), b = 1, c = u64(value), next = registers.rip + 1})
	}
	// The controller at reset: base 0, nothing masked. The timer line
	// rises, the guest takes interrupts, and still nothing is asked.
	out(machine, &registers, 0x43, 0x34)
	out(machine, &registers, 0x40, 0x00)
	out(machine, &registers, 0x40, 0x10) // 4096 ticks.
	machine.clock += 2 * 4096
	for _ in 0 ..< 3 {
		testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Interrupted}), Machine_Step.Continue)
		testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.None))
		testing.expect_value(t, machine.interrupts.primary.service, u8(0))
		_, refusal := op.guest_registers_check(registers)
		testing.expect_value(t, refusal, op.Guest_Registers_Refusal.None)
	}
	// The guest programs the controllers at 0x30 and 0x38, the timer line
	// alone unmasked, with interrupts off.
	registers.rflags = 0x2
	for pair in ([?][2]u16{{0x20, 0x11}, {0x21, 0x30}, {0x21, 0x04}, {0x21, 0x01}, {0xA0, 0x11}, {0xA1, 0x38}, {0xA1, 0x02}, {0xA1, 0x01}, {0x21, 0xFE}, {0xA1, 0xFF}}) {
		out(machine, &registers, pair[0], u8(pair[1]))
	}
	machine.clock += 2 * 4096
	linux_machine_handle_exit(machine, &registers, {kind = .Interrupted})
	// Interrupts off: the record asks for 0x30 to open the window, and the
	// line is not in service.
	testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.External_Interrupt))
	testing.expect_value(t, registers.inject_vector, u8(0x30))
	testing.expect(t, machine.window_requested)
	testing.expect_value(t, machine.interrupts.primary.service, u8(0))
	_, window_refusal := op.guest_registers_check(registers)
	testing.expect_value(t, window_refusal, op.Guest_Registers_Refusal.None)
	// The same in the shadow of sti, with the flag set.
	registers.rflags = 0x202
	registers.interrupt_shadow = 1
	linux_machine_handle_exit(machine, &registers, {kind = .Interrupted})
	testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.External_Interrupt))
	testing.expect(t, machine.window_requested)
	testing.expect_value(t, machine.interrupts.primary.service, u8(0))
	// An exception of the machine at that exit replaces the request: the
	// line still waits, and no line went into service.
	registers.rcx = 0x1B
	linux_machine_handle_exit(machine, &registers, {kind = .Other, code = u64(Other_Exit_Code.Model_Specific_Register), information = 0})
	testing.expect(t, registers.inject_kind == u8(op.Guest_Inject_Kind.Exception) && registers.inject_vector == VECTOR_GENERAL_PROTECTION)
	testing.expect(t, !machine.window_requested)
	testing.expect_value(t, machine.interrupts.primary.service, u8(0))
	registers.inject_kind, registers.inject_vector, registers.inject_error_code_valid = 0, 0, 0
	registers.rflags = 0x2
	registers.interrupt_shadow = 0
	linux_machine_handle_exit(machine, &registers, {kind = .Interrupted})
	testing.expect(t, machine.window_requested)
	// The successful case last: the guest opened its window (sti, then one
	// instruction). The exit acknowledges the line and asks for its vector.
	registers.rflags = 0x202
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Interrupt_Window}), Machine_Step.Continue)
	testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.External_Interrupt))
	testing.expect_value(t, registers.inject_vector, u8(0x30))
	testing.expect(t, !machine.window_requested)
	testing.expect_value(t, machine.interrupts.primary.service, u8(1))
	_, refusal := op.guest_registers_check(registers)
	testing.expect_value(t, refusal, op.Guest_Registers_Refusal.None)
}

// The exit Writes_Own_Page: the machine does the one store of a mov to
// memory of 64-bit code for the guest, through the memory of the process,
// only at the address of the exit, and moves rip past it. The refusals
// first; each leaves the memory and rip as they were.
@(test)
machine_own_page_write_edges :: proc(t: ^testing.T) {
	MEMORY :: 3 * 4096
	CODE :: 0x1010
	ram := make([]u8, MEMORY)
	defer delete(ram)
	machine := new(Linux_Machine)
	defer free(machine)
	// Protected mode with no paging: a linear address is the physical one.
	start :: proc(machine: ^Linux_Machine, ram: []u8, code: []u8, target: u64) -> op.Guest_Registers {
		for &value in ram {
			value = 0
		}
		copy(ram[CODE:], code)
		linux_machine_start(machine, {ram}, nil, nil)
		return op.Guest_Registers{rip = CODE, cr0 = 1, rax = 0x1122_3344_5566_7788, rdi = target}
	}
	unchanged :: proc(t: ^testing.T, ram: []u8) -> bool {
		for value, place in ram {
			if (place < CODE || place >= CODE + 16) && value != 0 {
				return false
			}
		}
		return true
	}
	refused := [?]struct {
		code:    []u8,
		target:  u64, // rdi: the address of the operand.
		address: u64, // a of the exit.
		bits:    u64, // b of the exit: 1 for 64-bit code.
		about:   string,
	}{
		{{0x89, 0x07}, 0x1100, 0x1100, 0, "code that is not 64-bit"},
		{{0x0F, 0x0B}, 0x1100, 0x1100, 1, "ud2"},
		{{0x8B, 0x07}, 0x1100, 0x1100, 1, "a read"},
		{{0xF3, 0xA4}, 0x1100, 0x1100, 1, "rep movsb"},
		{{0xF0, 0x89, 0x07}, 0x1100, 0x1100, 1, "a lock"},
		{{0x67, 0x89, 0x07}, 0x1100, 0x1100, 1, "an address of 32 bits"},
		{{0x89, 0x07}, 0x1104, 0x1100, 1, "an operand that is not the address of the exit"},
		{{0x89, 0x07}, 0x1FFD, 0x1FFD, 1, "4 bytes across a page"},
		{{0x48, 0x89, 0x07}, 0x1FF9, 0x1FF9, 1, "8 bytes across a page"},
		{{0x89, 0x07}, MEMORY - 2, MEMORY - 2, 1, "past the memory"},
		{{0x89, 0x07}, max(u64), max(u64), 1, "the largest address"},
	}
	for case_of in refused {
		registers := start(machine, ram, case_of.code, case_of.target)
		step := linux_machine_handle_exit(machine, &registers, {kind = .Writes_Own_Page, a = case_of.address, b = case_of.bits})
		testing.expectf(t, step == .Failed && machine.failure == .Writes_Own_Page, "%s is refused", case_of.about)
		testing.expectf(t, registers.rip == CODE && machine.own_page_writes == 0 && unchanged(t, ram), "%s changes nothing", case_of.about)
	}
	// The successful cases last.
	accepted := [?]struct {
		code:   []u8,
		target: u64,
		wanted: []u8,
		about:  string,
	}{
		{{0x89, 0x07}, 0x1FFC, {0x88, 0x77, 0x66, 0x55}, "4 bytes at the end of a page"},
		{{0x48, 0x89, 0x07}, 0x1100, {0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11}, "8 bytes with REX.W"},
		{{0x66, 0x89, 0x07}, 0x1100, {0x88, 0x77}, "2 bytes with 66"},
		{{0xC7, 0x07, 0x01, 0x02, 0x03, 0x04}, 0x1100, {0x01, 0x02, 0x03, 0x04}, "an immediate"},
		{{0x88, 0x27}, 0x2000, {0x77}, "ah at the first byte of a page"},
		{{0x89, 0x47, 0x08}, 0x10F8, {0x88, 0x77, 0x66, 0x55}, "rdi plus 8"},
	}
	for case_of in accepted {
		registers := start(machine, ram, case_of.code, case_of.target)
		address := case_of.target
		if case_of.about == "rdi plus 8" {
			address += 8
		}
		step := linux_machine_handle_exit(machine, &registers, {kind = .Writes_Own_Page, a = address, b = 1})
		testing.expectf(t, step == .Continue, "%s is done", case_of.about)
		testing.expectf(t, registers.rip == CODE + u64(len(case_of.code)), "%s moves rip past it", case_of.about)
		testing.expectf(t, string(ram[address:][:len(case_of.wanted)]) == string(case_of.wanted), "%s writes its bytes", case_of.about)
		testing.expectf(t, ram[address + u64(len(case_of.wanted))] == 0 || address + u64(len(case_of.wanted)) == MEMORY, "%s writes no byte more", case_of.about)
		testing.expect_value(t, machine.own_page_writes, u64(1))
	}
}

// The memory operand of each form of address, and its linear address with
// the registers before the instruction: a base, a SIB with an index and a
// scale, a SIB with no base, REX.B and REX.X, rip-relative, fs and gs. The
// refusal first: an address of 32 bits is not computed.
@(test)
memory_operand_of_each_form :: proc(t: ^testing.T) {
	registers := op.Guest_Registers{rax = 0x10, rbx = 0x1000, rsp = 0x7000, r9 = 0x3, r13 = 0x5000, r15 = 0x20, rip = 0x40_0000, fs_base = 0x9_0000, gs_base = 0xA_0000}
	address_32, _ := device_access_decode({0x67, 0x89, 0x03}, true)
	_, computed := memory_operand_linear(registers, address_32)
	testing.expect(t, !computed)
	cases := [?]struct {
		bytes:  []u8,
		linear: u64,
		about:  string,
	}{
		{{0x89, 0x03}, 0x1000, "[rbx]"},
		{{0x89, 0x43, 0x70}, 0x1070, "[rbx + 0x70]"},
		{{0x89, 0x43, 0xF8}, 0x0FF8, "[rbx - 8]"},
		{{0x89, 0x04, 0x24}, 0x7000, "[rsp] with a SIB"},
		{{0x42, 0x89, 0x04, 0x8B}, 0x1000 + 3 * 4, "[rbx + r9 * 4]"},
		{{0x47, 0x89, 0x54, 0x3D, 0x08}, 0x5000 + 0x20 + 8, "[r13 + r15 + 8]"},
		{{0x89, 0x04, 0x25, 0x00, 0x10, 0x00, 0x00}, 0x1000, "[0x1000] with no base"},
		{{0x89, 0x04, 0xC5, 0x00, 0x10, 0x00, 0x00}, 0x1000 + 0x10 * 8, "[rax * 8 + 0x1000]"},
		{{0x89, 0x05, 0x10, 0x00, 0x00, 0x00}, 0x40_0000 + 6 + 0x10, "[rip + 0x10]"},
		{{0x64, 0x89, 0x03}, 0x9_1000, "fs:[rbx]"},
		{{0x65, 0x48, 0x89, 0x43, 0x08}, 0xA_1008, "gs:[rbx + 8]"},
		{{0x2E, 0x89, 0x03}, 0x1000, "cs:[rbx], a base of 0"},
		{{0x64, 0x2E, 0x89, 0x03}, 0x9_1000, "fs then cs: cs does nothing in 64-bit code, fs stays"},
		{{0x2E, 0x65, 0x89, 0x03}, 0xA_1000, "cs then gs"},
		{{0x64, 0x3E, 0x26, 0x36, 0x89, 0x03}, 0x9_1000, "fs then ds, es and ss"},
		{{0x64, 0x65, 0x89, 0x03}, 0xA_1000, "fs then gs: the last one"},
	}
	for case_of in cases {
		access, refusal := device_access_decode(case_of.bytes, true)
		linear, ok := memory_operand_linear(registers, access)
		testing.expectf(t, refusal == .None && ok && linear == case_of.linear, "%s gives %x, not %x", case_of.about, linear, case_of.linear)
	}
}

// The store of Writes_Own_Page through the page table of the guest in long
// mode: four levels, five levels and a page of 1 GiB give the address of
// the exit; an entry not present, a table past the memory, and a
// translation to another page than the exit are refused, with nothing
// changed.
@(test)
machine_own_page_write_through_the_page_table :: proc(t: ^testing.T) {
	MEMORY :: 16 * 4096
	PML5 :: 0x8000
	PML4 :: 0x1000
	PDPT :: 0x2000
	PD :: 0x3000
	PT :: 0x4000
	CODE :: 0x5000
	DATA :: 0x6000
	CODE_LINEAR :: u64(0x40_0000) // PML4 0, PDPT 0, PD 2, PT 0.
	DATA_LINEAR :: u64(0x40_1000) // PT 1.
	ABSENT_LINEAR :: u64(0x40_2000) // PT 2: not present.
	FAR_LINEAR :: u64(0x60_0000) // PD 3: a table past the memory.
	GIANT_LINEAR :: u64(0x4000_0000) // PDPT 1: a page of 1 GiB at the physical 0.
	ENTRY :: u64(0x3) // Present and writable.
	ram := make([]u8, MEMORY)
	defer delete(ram)
	machine := new(Linux_Machine)
	defer free(machine)
	put :: proc(ram: []u8, address: u64, value: u64) {
		for index in 0 ..< u64(8) {
			ram[address + index] = u8(value >> (index * 8))
		}
	}
	start :: proc(machine: ^Linux_Machine, ram: []u8, target: u64, five_level: bool) -> op.Guest_Registers {
		for &value in ram {
			value = 0
		}
		put(ram, PML5, PML4 | ENTRY)
		put(ram, PML4, PDPT | ENTRY)
		put(ram, PDPT, PD | ENTRY)
		put(ram, PDPT + 8, 0 | ENTRY | 0x80) // 1 GiB at the physical 0.
		put(ram, PD + 2 * 8, PT | ENTRY)
		put(ram, PD + 3 * 8, 0x10_0000 | ENTRY) // A table past the memory.
		put(ram, PT, CODE | ENTRY)
		put(ram, PT + 8, DATA | ENTRY)
		copy(ram[CODE:], []u8{0x89, 0x07}) // mov [rdi], eax
		linux_machine_start(machine, {ram}, nil, nil)
		registers := op.Guest_Registers{rip = CODE_LINEAR, rax = 0x5566_7788, rdi = target}
		registers.cr0 = op.GUEST_CONTROL_0_PROTECTION | op.GUEST_CONTROL_0_PAGING
		registers.cr4 = op.GUEST_CONTROL_4_PHYSICAL_ADDRESS_EXTENSION
		registers.efer = op.GUEST_EFER_LONG_MODE_ENABLE | op.GUEST_EFER_LONG_MODE_ACTIVE
		registers.cr3 = PML4
		if five_level {
			registers.cr4 |= op.GUEST_CONTROL_4_FIVE_LEVEL_PAGING
			registers.cr3 = PML5
		}
		return registers
	}
	data_unchanged :: proc(ram: []u8) -> bool {
		for value in ram[DATA:][:4096] {
			if value != 0 {
				return false
			}
		}
		return true
	}
	refused := [?]struct {
		target:  u64,
		address: u64,
		about:   string,
	}{
		{ABSENT_LINEAR + 0x10, DATA + 0x10, "an entry not present"},
		{FAR_LINEAR + 0x10, DATA + 0x10, "a table past the memory"},
		{DATA_LINEAR + 0x10, DATA + 0x20, "another address than the exit"},
		{DATA_LINEAR + 0x10, CODE + 0x10, "another page than the exit"},
	}
	for case_of in refused {
		registers := start(machine, ram, case_of.target, false)
		step := linux_machine_handle_exit(machine, &registers, {kind = .Writes_Own_Page, a = case_of.address, b = 1})
		testing.expectf(t, step == .Failed && machine.failure == .Writes_Own_Page, "%s is refused", case_of.about)
		testing.expectf(t, registers.rip == CODE_LINEAR && data_unchanged(ram), "%s changes nothing", case_of.about)
	}
	// The successful cases last: four levels, five levels, a page of 1 GiB.
	accepted := [?]struct {
		target:     u64,
		five_level: bool,
		about:      string,
	}{
		{DATA_LINEAR + 0x10, false, "four levels"},
		{DATA_LINEAR + 0x10, true, "five levels"},
		{GIANT_LINEAR + DATA + 0x10, false, "a page of 1 GiB"},
	}
	for case_of in accepted {
		registers := start(machine, ram, case_of.target, case_of.five_level)
		step := linux_machine_handle_exit(machine, &registers, {kind = .Writes_Own_Page, a = DATA + 0x10, b = 1})
		testing.expectf(t, step == .Continue, "%s is done", case_of.about)
		testing.expectf(t, registers.rip == CODE_LINEAR + 2, "%s moves rip past it", case_of.about)
		testing.expectf(t, ram[DATA + 0x10] == 0x88 && ram[DATA + 0x11] == 0x77 && ram[DATA + 0x12] == 0x66 && ram[DATA + 0x13] == 0x55 && ram[DATA + 0x14] == 0, "%s writes its 4 bytes", case_of.about)
	}
}

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
	}
	for entry in cases {
		access, refusal := device_access_decode(entry.bytes, true)
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
		{0x0000_0010, 0},
		{0x0000_0277, 0},
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
	// A read of the local APIC faults too: cpuid does not offer it.
	registers := long
	msr_exit(machine, &registers, 0x1B, false, 0)
	testing.expect_value(t, registers.inject_vector, VECTOR_GENERAL_PROTECTION)
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
	// Inside the memory: a switch of the region, or a fault that cannot be.
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Memory, a = 0x30_0000, b = FAULT_ACCESS_WRITE | 1}), Machine_Step.Switch_Write)
	testing.expect_value(t, machine.switch_address, u64(0x30_0000))
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Memory, a = 0x40_0000, b = FAULT_ACCESS_EXECUTE | 1}), Machine_Step.Switch_Execute)
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Memory, a = 0x40_0000, b = 1}), Machine_Step.Failed)
	testing.expect_value(t, machine.failure, Machine_Failure.Memory_Read_Fault)
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
	// In the shadow, with interrupts on: nothing is injected, at each exit
	// that leaves the guest at its instruction.
	registers.rflags = 0x202
	registers.interrupt_shadow = 1
	at := registers.rip
	for _ in 0 ..< 3 {
		testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Interrupted}), Machine_Step.Continue)
		testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.None))
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
	testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.None))
	registers.rflags = 0x202
	registers.interrupt_shadow = 1
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Halt, next = registers.rip + 1}), Machine_Step.Continue)
	testing.expect_value(t, registers.interrupt_shadow, u8(0))
	testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.External_Interrupt))
	testing.expect_value(t, registers.inject_vector, u8(0x30))
	_, refusal := op.guest_registers_check(registers)
	testing.expect_value(t, refusal, op.Guest_Registers_Refusal.None)
}

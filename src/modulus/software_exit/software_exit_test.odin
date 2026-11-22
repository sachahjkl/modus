#+build !freestanding
package software_exit

import "core:testing"
import software "modus:contract/software_machine"

// Running is not an exit: it is refused, and the exit stays empty.
@(test)
running_is_refused :: proc(t: ^testing.T) {
	cpu: software.Processor_State
	cpu.fault_error_code = 0x7
	cpu.fault_address = 0x1234
	exit, ok := exit_of(&cpu, .Running)
	testing.expect(t, !ok, "Running gives an exit")
	testing.expect_value(t, exit, Exit{})
}

// An error code or an address that a former fault left in the state never
// reaches an exit that has none.
@(test)
a_stale_fault_reaches_no_other_exit :: proc(t: ^testing.T) {
	cpu: software.Processor_State
	cpu.fault_error_code = 0x1F
	cpu.fault_address = 0xFFFF_FFFF_FFFF_FFFF
	cases := [?]struct {
		outcome: software.Step_Outcome,
		want:    Exit,
	} {
		{.Syscall, {kind = .Kernel_Enter}},
		{.Step_Budget_Exhausted, {kind = .Slice_End}},
		{.Halted, {kind = .Exception, vector = .General_Protection}},
		{.Invalid_Opcode, {kind = .Exception, vector = .Invalid_Opcode}},
		{.Breakpoint, {kind = .Exception, vector = .Breakpoint}},
		{.Divide_Error, {kind = .Exception, vector = .Divide_Error}},
	}
	for c in cases {
		exit, ok := exit_of(&cpu, c.outcome)
		testing.expectf(t, ok, "%v is refused", c.outcome)
		testing.expectf(t, exit == c.want, "%v gives %v, not %v", c.outcome, exit, c.want)
	}
}

// Each outcome of the software processor is either refused or an exit:
// none is lost.
@(test)
each_outcome_is_named :: proc(t: ^testing.T) {
	cpu: software.Processor_State
	for outcome in software.Step_Outcome {
		_, ok := exit_of(&cpu, outcome)
		testing.expectf(t, ok == (outcome != .Running), "%v: ok is %v", outcome, ok)
	}
}

// The page fault and the protection fault keep their error code; the page
// fault keeps its address, at the edges of the address space.
@(test)
faults_keep_their_error_code_and_address :: proc(t: ^testing.T) {
	cpu: software.Processor_State
	for address in ([]u64{0, 1, software.CANONICAL_LOWER_MAX, software.CANONICAL_UPPER_MIN, max(u64)}) {
		cpu.fault_error_code = software.PAGE_FAULT_USER | software.PAGE_FAULT_WRITE
		cpu.fault_address = address
		exit, ok := exit_of(&cpu, .Page_Fault)
		testing.expect(t, ok)
		testing.expect_value(t, exit, Exit{kind = .Exception, vector = .Page_Fault, error_code = cpu.fault_error_code, fault_address = address})
	}
	cpu.fault_error_code = 0
	cpu.fault_address = 0x5000
	exit, ok := exit_of(&cpu, .General_Protection)
	testing.expect(t, ok)
	testing.expect_value(t, exit, Exit{kind = .Exception, vector = .General_Protection})
}

// A small machine: four levels of table at 0x1000 to 0x4000, and one user
// page of code at 0x5000, at its own address.
MEMORY_BYTES :: 0x8000
CODE_ADDRESS :: u64(0x5000)
TABLE_FLAGS :: software.PAGE_PRESENT | software.PAGE_WRITE | software.PAGE_USER

@(private = "file")
entry_write :: proc(memory: []u8, address: u64, value: u64) {
	for index in 0 ..< u64(8) {
		memory[address + index] = u8(value >> (index * 8))
	}
}

@(private = "file")
machine_with_code :: proc(memory: []u8, code: []u8, cpu: ^software.Processor_State) {
	entry_write(memory, 0x1000, 0x2000 | TABLE_FLAGS)
	entry_write(memory, 0x2000, 0x3000 | TABLE_FLAGS)
	entry_write(memory, 0x3000, 0x4000 | TABLE_FLAGS)
	entry_write(memory, 0x4000 + 5 * 8, CODE_ADDRESS | software.PAGE_PRESENT | software.PAGE_USER)
	copy(memory[CODE_ADDRESS:], code)
	software.processor_init(cpu, 0x1000, CODE_ADDRESS, 0)
}

// A real run: syscall exits as the kernel entry, with rcx and r11 as the
// instruction sets them.
@(test)
syscall_is_the_kernel_entry :: proc(t: ^testing.T) {
	memory: [MEMORY_BYTES]u8
	cpu: software.Processor_State
	machine_with_code(memory[:], {0x0F, 0x05}, &cpu)
	outcome := software.processor_run(&cpu, memory[:], 16)
	exit, ok := exit_of(&cpu, outcome)
	testing.expect(t, ok)
	testing.expect_value(t, exit.kind, Exit_Kind.Kernel_Enter)
	testing.expect_value(t, cpu.registers[software.General_Register.Rcx], CODE_ADDRESS + 2)
	testing.expect_value(t, cpu.registers[software.General_Register.R11], software.USER_INITIAL_RFLAGS)
}

// A run that uses its whole budget ends its slice, with the next
// instruction not run.
@(test)
a_spent_budget_ends_the_slice :: proc(t: ^testing.T) {
	memory: [MEMORY_BYTES]u8
	cpu: software.Processor_State
	machine_with_code(memory[:], {0x90, 0x90, 0x0F, 0x05}, &cpu)
	outcome := software.processor_run(&cpu, memory[:], 1)
	exit, ok := exit_of(&cpu, outcome)
	testing.expect(t, ok)
	testing.expect_value(t, exit.kind, Exit_Kind.Slice_End)
	testing.expect_value(t, cpu.rip, CODE_ADDRESS + 1)
}

// A jump to a page that the table does not map is a page fault of an
// instruction fetch by the user, at the address of the jump target.
@(test)
a_fetch_from_an_unmapped_page_is_a_page_fault :: proc(t: ^testing.T) {
	memory: [MEMORY_BYTES]u8
	cpu: software.Processor_State
	// jmp rel32 to the next page, 0x6000.
	machine_with_code(memory[:], {0xE9, 0xFB, 0x0F, 0x00, 0x00}, &cpu)
	outcome := software.processor_run(&cpu, memory[:], 16)
	exit, ok := exit_of(&cpu, outcome)
	testing.expect(t, ok)
	testing.expect_value(t, exit.kind, Exit_Kind.Exception)
	testing.expect_value(t, exit.vector, Exception_Vector.Page_Fault)
	testing.expect_value(t, exit.fault_address, u64(0x6000))
	testing.expect_value(t, exit.error_code, software.PAGE_FAULT_USER | software.PAGE_FAULT_INSTRUCTION)
}

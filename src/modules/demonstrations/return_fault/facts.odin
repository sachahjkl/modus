package return_fault

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of return_fault (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero. A status of the kernel is a field of the contract
// enum, which a reader writes by its name, as the line did.
//
// The stop of a child writes its address in 16 hexadecimal digits, as
// system.Hex wrote it, and its cause and its outcome by their words.

// A child stopped itself.
@(log_fact = "return_fault: {case_name}: the child stopped: {cause}, {outcome}, the address {address}: {verdict}")
Child_Stopped_Itself :: struct {
	address:   value_kinds.Hexadecimal_Sixteen_Digits,
	cause:     op.Stop_Cause,
	outcome:   op.Stop_Outcome,
	case_name: [56]u8,
	verdict:   [16]u8,
}

// A child stopped on its own fault: its vector.
@(log_fact = "return_fault: {case_name}: the child stopped: {cause}, vector {vector}, the address {address}: {verdict}")
Child_Stopped_On_Fault :: struct {
	address:   value_kinds.Hexadecimal_Sixteen_Digits,
	vector:    u64,
	cause:     op.Stop_Cause,
	case_name: [56]u8,
	verdict:   [20]u8,
}

// A child stopped for another cause: the kernel cannot return to it, a
// holder, its last thread.
@(log_fact = "return_fault: {case_name}: the child stopped: {cause}, the address {address}: {verdict}")
Child_Stopped :: struct {
	address:   value_kinds.Hexadecimal_Sixteen_Digits,
	cause:     op.Stop_Cause,
	case_name: [56]u8,
	verdict:   [20]u8,
}

// The child of the nested task could not set the flag: the case did not
// run.
@(log_fact = "return_fault: the child of the nested task: popfq did not set the flag, so the case did not run")
Nested_Task_Not_Set :: struct {}

// The flag of the nested task came back after the entry.
@(log_fact = "return_fault: the child of the nested task: the flag came back after the entry")
Nested_Task_Came_Back :: struct {}

// The child of the trap flag came past its instruction with no trap.
@(log_fact = "return_fault: the child of the trap flag: no trap came")
No_Trap :: struct {}

// The context of the process holds no random seed.
@(log_fact = "return_fault: no random seed in the context")
No_Random_Seed :: struct {}

// The process has no boot image.
@(log_fact = "return_fault: no boot image")
No_Boot_Image :: struct {}

// The bytes of the Text field of the name of a case: the longest, "a stack
// address that is not canonical at a syscall", has 50 bytes.
CASE_FIELD_BYTES :: 56

// The child of the instruction address cannot make its page.
@(log_fact = "return_fault: the child of the instruction address could not make its page: {status}")
Instruction_Page_Not_Made :: struct {
	status: op.Status,
}

// The child of the instruction address cannot map its page to write it.
@(log_fact = "return_fault: the child of the instruction address could not map its page to write it: {status}")
Instruction_Page_Not_Mapped_To_Write :: struct {
	status: op.Status,
}

// The child of the instruction address cannot map its page at the last
// page below the half of a process.
@(log_fact = "return_fault: the child of the instruction address could not map its page at the last page: {status}")
Instruction_Page_Not_Mapped_At_End :: struct {
	status: op.Status,
}

// The child of a case did not start.
@(log_fact = "return_fault: {case_name}: the child did not start")
Child_Not_Started :: struct {
	case_name: [56]u8,
}

// The context names no role of this module.
@(log_fact = "return_fault: the context names the role {role}, which names no role")
Role_Word_Unknown :: struct {
	role: u64,
}

// Each case passed.
@(log_fact = "return_fault: ok, {cases} cases: each child stopped as its own fault or returned with the flags of a process, and the machine goes on")
Cases_Passed :: struct {
	cases: u64,
}

// Some cases failed.
@(log_fact = "return_fault: failed: {failed} cases of {cases}")
Cases_Failed :: struct {
	failed: u64,
	cases:  u64,
}

#assert(size_of(Child_Not_Started) == CASE_FIELD_BYTES)

// case_field gives the Text field of the name of a case.
case_field :: proc "contextless" (name: string) -> [CASE_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, CASE_FIELD_BYTES)
}

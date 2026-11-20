package extended_state

import "modus:contract/value_kinds"

// The log facts of the demonstration extended_state
// (src/md/features/log_facts.md, "The facts of the demonstrations"): what
// the kernel saves, the measures and the end, as records of fields. Each
// fact template is the sentence that the line wrote before it was a fact,
// so a wait of a machine test on that sentence reads it as before. A Text
// field comes last, and holds its longest text and a zero byte.
//
// A line that a loop wrote, the parts of a save, is one fact for each
// part. The times of a part are in hundredths: the line wrote tenths.

// The state components that the kernel saves, and the most bytes of one
// save.
@(log_fact = "extended_state: the kernel saves {components}; one save writes at most {saved_area_bytes} bytes")
Saved_Components :: struct {
	saved_area_bytes: u64,
	components:       [24]u8,
}

// The machine has more processors than the threads of a process.
@(log_fact = "extended_state: {processors} processors: {threads} threads, the most that a process can have, fewer than the processors plus two")
Threads_Fewer_Than_Processors :: struct {
	processors: u64,
	threads:    u64,
}

// A thread of the test did not start.
@(log_fact = "extended_state: cannot start thread {thread_number}")
Thread_Not_Started :: struct {
	thread_number: u64,
}

// The measure of an empty kernel entry with each level of the registers in
// use.
@(log_fact = "extended_state: an empty kernel entry, {kernel_entries} times: {xmm_time} ns with xmm in use, {ymm_time} ns with ymm in use, {zmm_time} ns with zmm in use (0: not usable)")
Kernel_Entry_Measured :: struct {
	kernel_entries: u64,
	xmm_time:       u64,
	ymm_time:       u64,
	zmm_time:       u64,
}

// Each thread kept its registers through each pass.
@(log_fact = "extended_state: ok, {threads} threads on {processors} processors, {passes} passes, {kernel_entries} kernel entries in the passes: each thread kept {kept_registers}, the x87 stack, the x87 control word and MXCSR, and started with the start state")
Registers_Kept :: struct {
	threads:        u64,
	processors:     u64,
	passes:         u64,
	kernel_entries: u64,
	kept_registers: [40]u8,
}

// A pass found wrong registers, or a start state was wrong.
@(log_fact = "extended_state: failed: {wrong_registers} wrong registers after a pass, {wrong_start_parts} parts of a start state wrong")
Registers_Wrong :: struct {
	wrong_registers:   u64,
	wrong_start_parts: u64,
}

// The usable instruction sets of the xmm registers. The sets of AVX and of
// the general registers are facts of their own: the three lists are longer
// together than the values of one fact hold.
@(log_fact = "extended_state: the usable instruction sets: {xmm_sets}")
Usable_Sets :: struct {
	xmm_sets: [56]u8,
}

@(log_fact = "extended_state: the usable instruction sets of AVX: {avx_sets}")
Usable_Sets_Of_Avx :: struct {
	avx_sets: [80]u8,
}

@(log_fact = "extended_state: the usable instruction sets of the general registers: {general_register_sets}")
Usable_Sets_Of_General_Registers :: struct {
	general_register_sets: [24]u8,
}

@(log_fact = "extended_state: AVX is not usable: the processor does not have it or the kernel does not save it; the test holds xmm0 to xmm15")
Avx_Not_Usable :: struct {}

// A register that a pass found wrong: the value expected and the value
// found, as system.Hex writes them.
@(log_fact = "extended_state: WRONG: thread {thread_number}, {register}, {moment} {pass}: expected {expected}, found {found}")
Register_Wrong :: struct {
	thread_number: u64,
	pass:          u64,
	expected:      value_kinds.Hexadecimal_Sixteen_Digits,
	found:         value_kinds.Hexadecimal_Sixteen_Digits,
	register:      [24]u8,
	moment:        [24]u8,
}

// The measure of one part of a save and a restore, alone in this process:
// the cycles of one loop and their time, in hundredths.
@(log_fact = "extended_state: a part of a save and a restore, alone in this process: {part_name} {cycles} cycles of the cycle counter for one loop ({part_time} ns)")
Save_Part_Measured :: struct {
	cycles:    value_kinds.Hundredths,
	part_time: value_kinds.Hundredths,
	part_name: [40]u8,
}

// A part of a save and a restore that this processor cannot run.
@(log_fact = "extended_state: a part of a save and a restore, alone in this process: {part_name} none")
Save_Part_Not_Measured :: struct {
	part_name: [40]u8,
}

// The measure of one instruction alone, the loop included.
@(log_fact = "extended_state: an instruction alone, the loop included: {part_name} {cycles} cycles of the cycle counter for one loop ({part_time} ns)")
Instruction_Measured :: struct {
	cycles:    value_kinds.Hundredths,
	part_time: value_kinds.Hundredths,
	part_name: [40]u8,
}

// An instruction that this processor cannot run.
@(log_fact = "extended_state: an instruction alone, the loop included: {part_name} none")
Instruction_Not_Measured :: struct {
	part_name: [40]u8,
}

// The measure of a hand-over between two threads by the word wait.
@(log_fact = "extended_state: a hand-over between two threads by the word wait (a wake, a wait, and the save and restore of the thread that waits and of the thread that runs): {x87_and_sse_time} ns with x87 and SSE in use, {ymm_time} ns with the ymm high halves in use (0: not usable); {x87_and_sse_hand_overs} and {ymm_hand_overs} hand-overs in {period} ms each")
Hand_Over_Measured :: struct {
	x87_and_sse_time:       u64,
	ymm_time:               u64,
	x87_and_sse_hand_overs: u64,
	ymm_hand_overs:         u64,
	period:                 u64,
}

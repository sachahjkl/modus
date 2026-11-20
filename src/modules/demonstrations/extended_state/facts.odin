package extended_state

// The log facts of the demonstration extended_state
// (src/md/features/log_facts.md, "The facts of the demonstrations"): what
// the kernel saves, the measures and the end, as records of fields. Each
// fact template is the sentence that the line wrote before it was a fact,
// so a wait of a machine test on that sentence reads it as before. A Text
// field comes last, and holds its longest text and a zero byte.
//
// Some lines stay text: a register that a pass found wrong, which
// system.Hex writes in 16 digits with no "0x"; the times of the parts of a
// save with one decimal, which no field kind writes; and the instruction
// sets, three lists whose names are longer together than a fact holds.

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

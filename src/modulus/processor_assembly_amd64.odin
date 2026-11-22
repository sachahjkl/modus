package kernel

// The procedures and the labels of processor.asm, which only the build for
// x86-64 assembles and links. A kernel for WebAssembly defines each name in
// processor_loop_wasm64p32.odin (src/md/features/browser_machine.md, "What
// the arch layer becomes").

// Used by processor.odin.
foreign _ {
	// sti, hlt, cli: wait for one interrupt. It stays in processor.asm: the
	// compiler takes hlt as the end of the flow of a template.
	idle_wait :: proc "c" () ---
	// sti, nop, cli: take the interrupts that wait, with no wait. The
	// drain of the serial port in the idle loop opens it after each byte,
	// so an interrupt waits one port write at most
	// (src/md/features/log_side_channels.md).
	interrupt_window :: proc "c" () ---
	// The load of the segment table also loads cs with a far return: it
	// uses its own return address.
	gdt_load :: proc "c" (descriptor: rawptr) ---
	kernel_enter :: proc "c" () ---
	resume :: proc "c" (frame: ^Frame) -> ! ---
	interrupt_stubs: [STUB_COUNT]u64
}

// Used by paging.odin.
foreign _ {
	// 1: the processors refuse the memory of processes to the kernel (SMAP).
	// interrupt_common reads it too. user_copy is in instructions_amd64.odin.
	user_access_guard: u8
	stack_switch :: proc "c" (top: u64, entry: rawptr) -> ! ---
}

// Used by extended_state.odin.
foreign _ {
	// The save of a thread that a processor leaves, and the restore of a
	// thread that a processor takes; also the proofs at boot.
	extended_state_save :: proc "c" (area: ^Extended_State_Area, form: Extended_State_Form) ---
	extended_state_restore :: proc "c" (area: ^Extended_State_Area, form: Extended_State_Form) ---
	// The restore, then a read of the x87 control word, MXCSR, the low 8
	// bytes of xmm0 and, with with_avx, bytes 16 to 23 of ymm0, in that
	// order, at read: one routine, so no compiled code runs between.
	extended_state_restore_and_read :: proc "c" (area: ^Extended_State_Area, read: ^[4]u64, with_avx: bool, form: Extended_State_Form) ---
}

// Used by guest.odin.
foreign _ {
	// The entry of a guest processor, with interrupts on and held by clgi,
	// until its exit. It saves and loads the state that the exit does not
	// restore (processor.asm).
	guest_enter :: proc "c" (control_block: u64, general: ^Guest_General_Registers, host_area: u64) ---
}

// Used by register_trial.odin.
foreign _ {
	model_specific_register_trial_read :: proc "c" (index: u32, value: ^u64) -> bool ---
	model_specific_register_trial_write :: proc "c" (index: u32, value: u64) -> bool ---
	// The one instruction of each trial, and the label where a refusal goes
	// on.
	model_specific_register_trial_read_instruction: u8
	model_specific_register_trial_write_instruction: u8
	model_specific_register_trial_refused: u8
}

// Used by return_to_process.odin.
foreign _ {
	// The iretq of resume (processor.asm), where a refusal of the processor
	// faults.
	resume_return: u8
}

// Used by serial.odin.
foreign _ {
	// cli, then hlt in a loop. It stays in processor.asm: the compiler
	// takes hlt as the end of the flow of a template, and a hlt continues
	// after an NMI.
	processor_stop :: proc "c" () -> ! ---
}

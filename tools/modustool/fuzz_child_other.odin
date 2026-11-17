#+build !linux
package modustool

// The child of the fuzzing maps its mailbox and its input arena, and
// catches its faults, with the system calls of Linux. On another host the
// commands of the fuzzing refuse to start.

fuzz_mailbox_map :: proc(path: string, create: bool) -> (mailbox: ^Fuzz_Mailbox, ok: bool) {
	return nil, false
}

fuzz_input_arena_make :: proc(limit: int) -> (arena: Fuzz_Input_Arena, ok: bool) {
	return {}, false
}

fuzz_fault_handlers_install :: proc(mailbox: ^Fuzz_Mailbox) -> bool {
	return false
}

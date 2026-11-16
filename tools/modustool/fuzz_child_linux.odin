package modustool

import "base:intrinsics"
import "core:strings"
import "core:sys/linux"

// The parts of the child of the fuzzing that need the system calls of
// Linux: the mailbox mapped from a file, the input arena with its pages
// with no access, and the handler of the faults.

// fuzz_mailbox_map maps the mailbox file into this process: the parent
// creates it with its size, and the child maps the same file. The two
// mappings share their pages, so the parent reads the count of executions
// while the child runs, and the input of a fault after the child ended.
fuzz_mailbox_map :: proc(path: string, create: bool) -> (mailbox: ^Fuzz_Mailbox, ok: bool) {
	name := strings.clone_to_cstring(path, context.temp_allocator)
	flags := linux.Open_Flags{.RDWR}
	if create {
		flags += {.CREAT, .TRUNC}
	}
	descriptor, open_error := linux.open(name, flags, {.IRUSR, .IWUSR})
	if open_error != .NONE {
		return nil, false
	}
	defer linux.close(descriptor)
	if create && linux.ftruncate(descriptor, FUZZ_MAILBOX_SIZE) != .NONE {
		return nil, false
	}
	address, map_error := linux.mmap(0, FUZZ_MAILBOX_SIZE, {.READ, .WRITE}, {.SHARED}, descriptor, 0)
	if map_error != .NONE {
		return nil, false
	}
	return (^Fuzz_Mailbox)(address), true
}

// fuzz_input_arena_make maps room for one input of `limit` bytes between
// two pages with no access. The child places an input against one of the
// two pages, so a read one byte past its end, or one byte before its
// start, faults even through a raw pointer, which no bounds check of Odin
// sees.
fuzz_input_arena_make :: proc(limit: int) -> (arena: Fuzz_Input_Arena, ok: bool) {
	data_size := (max(limit, 1) + FUZZ_PAGE_SIZE - 1) / FUZZ_PAGE_SIZE * FUZZ_PAGE_SIZE
	total := data_size + 2 * FUZZ_PAGE_SIZE
	address, map_error := linux.mmap(0, uint(total), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	if map_error != .NONE {
		return {}, false
	}
	base := ([^]u8)(address)
	if linux.mprotect(address, FUZZ_PAGE_SIZE, {}) != .NONE || linux.mprotect(&base[FUZZ_PAGE_SIZE + data_size], FUZZ_PAGE_SIZE, {}) != .NONE {
		return {}, false
	}
	return {data = base[FUZZ_PAGE_SIZE:][:data_size]}, true
}

// The mailbox of the child, for the handler of the faults: a handler gets
// no argument of the program.
fuzz_fault_mailbox: ^Fuzz_Mailbox

// The stack of the handler: a fault of a stack that overflowed still runs
// the handler.
FUZZ_FAULT_STACK_SIZE :: 64 * 1024
fuzz_fault_stack: [FUZZ_FAULT_STACK_SIZE]u8

// The offset of the instruction address in the context of a signal on
// x86-64: uc_flags (8 bytes), uc_link (8), uc_stack (24), then the general
// registers of uc_mcontext, of which RIP is the 17th.
FUZZ_CONTEXT_INSTRUCTION_OFFSET :: 8 + 8 + 24 + 16 * 8

// fuzz_fault_handler records a fault in the mailbox and ends the child with
// FUZZ_EXIT_FAULT: the parent then reads the input, the signal, the address
// that faulted and the place of the instruction. It calls no procedure of
// Odin that can allocate, print or fault again.
fuzz_fault_handler :: proc "c" (signal: linux.Signal, information: ^linux.Sig_Info, signal_context: rawptr) {
	mailbox := fuzz_fault_mailbox
	if mailbox != nil {
		mailbox.signal = i32(signal)
		mailbox.fault_address = u64(uintptr(information.addr))
		if signal_context != nil {
			instruction := intrinsics.unaligned_load((^u64)(uintptr(signal_context) + FUZZ_CONTEXT_INSTRUCTION_OFFSET))
			mailbox.instruction_offset = instruction - u64(uintptr(rawptr(fuzz_fault_handler)))
		}
		intrinsics.atomic_store_explicit(&mailbox.state, u32(Fuzz_Child_State.Fault), .Release)
	}
	linux.exit_group(FUZZ_EXIT_FAULT)
}

// fuzz_fault_handlers_install sends each signal of a fault to
// fuzz_fault_handler, on its own stack.
fuzz_fault_handlers_install :: proc(mailbox: ^Fuzz_Mailbox) -> bool {
	fuzz_fault_mailbox = mailbox
	stack := linux.Sig_Stack{sp = &fuzz_fault_stack[0], size = FUZZ_FAULT_STACK_SIZE}
	if linux.sigaltstack(&stack, nil) != .NONE {
		return false
	}
	for signal in ([?]linux.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGTRAP, .SIGABRT}) {
		action := linux.Sig_Action {
			sigaction = fuzz_fault_handler,
			flags     = {.SIGINFO, .ONSTACK, .RESETHAND},
		}
		if linux.rt_sigaction(signal, &action, nil) != .NONE {
			return false
		}
	}
	return true
}

// The first guest: a process that runs a few instructions of another system
// on the processor, in a guest, and receives what the guest does as records
// (docs/ARCHITECTURE.md, "A guest").
//
// **What it is for.** It is the proof of the guest support of the kernel,
// and the smallest process that uses it. The guest is a process that this
// process made and never started: its addresses are the memory of the guest.
// One page holds 16-bit code at the guest address 0x1000:
//
//     mov dx, 0x80
//     mov al, 42
//     out dx, al
//     hlt
//
// The process runs the guest processor with `Guest_Run`. The `out` arrives
// as an exit record `Port_Write` with the port and the value; the process
// moves the guest to the next instruction and runs it again; the `hlt`
// arrives as an exit `Halt`. Then the process moves the guest to an `int1`
// after the `hlt`: the instruction arrives as an exit `Other` with the
// exit code 0x88 (icebp), because the kernel lets no guest deliver its debug
// exception to itself.
// Then it checks that a guest takes no thread: `Process_Start` of the guest
// gives `Bad_State`.
//
// On a machine whose processors have no virtualization support that the
// kernel uses, the first run gives `Bad_Operation` with the error kind
// `Unsupported`, and the process says so: no guest runs there.
//
// **Start**: `start("guest_demo")` in the console. It needs no grant: its
// own budget pays the guest process, its memory and its page tables.
//
// **What a reader sees**: no window. The log has "guest_demo: the guest
// wrote 42 to the port 0x80, then halted after it: as it must", or the line
// of a machine with no support, then "guest_demo: ok". A fault gives
// "guest_demo: failed: " and what came.
//
// The design: src/md/features/guest.md.
package guest_demo

import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:system"

// The process itself and its guest. The working memory holds what the
// counted parts do not: the load of the process (its page tables, its
// stack guard, the copy of its writable data), one page of guest memory,
// the page tables of the guest and the two pages that the first run takes.
// 180 pages, as the other small processes that hold no window.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 180, processes = 2, threads = 1}

// The name of the guest process in the reports and on the log.
GUEST_NAME :: "guest_demo guest"
// The guest physical address of the code: Memory_Map takes no page 0.
CODE_ADDRESS :: 0x1000
// The port and the value that the guest writes.
PORT :: 0x80
VALUE :: 42
// mov dx, 0x80 (ba 80 00); mov al, 42 (b0 2a); out dx, al (ee); hlt (f4);
// then int1 (f1), which the process runs on its own after the hlt.
GUEST_CODE :: [?]u8{0xBA, 0x80, 0x00, 0xB0, 0x2A, 0xEE, 0xF4, 0xF1}
HALT_ADDRESS :: CODE_ADDRESS + 6 // The address of hlt in the guest.
DEBUG_ADDRESS :: CODE_ADDRESS + 7 // The address of int1 in the guest.
// The exit code of the processor for the debug exception (0x40 plus the
// vector 1): the kernel does not let a guest deliver it to itself.
DEBUG_EXCEPTION_EXIT_CODE :: 0x88 // The exit of the instruction int1 (icebp).

// The runs of the guest that an interrupt of the machine ends with nothing
// to answer, before the process gives up: a count, not a time. A tick ends
// at most one run, and the guest runs seven instructions.
INTERRUPTED_RUNS_LIMIT :: 1000

// step_failed writes the fact of a step that gave a status that stops the
// demonstration, and stops the process with `Failed`.
step_failed :: proc "contextless" (step: string, status: system.Status) -> ! {
	system.log_fact(.Info, Step_Failed{status_word = op.Status_Word(status), step = value_kinds.text_field(step, 40)})
	system.stop(.Failed)
}

@(export, link_name = "entry")
entry :: proc "c" (_: ^system.Context) -> ! {
	name := GUEST_NAME
	created, create_status := system.call(.Process_Create, u64(system.own_budget()), u64(uintptr(raw_data(name))), u64(len(name)))
	if create_status != .Ok {
		step_failed("Process_Create of the guest", create_status)
	}
	guest := system.Handle(created[0])

	// The code goes in one memory object, written here, then mapped in the
	// guest with Execute only: no page is writable and executable.
	memory, memory_status := system.memory_create(1)
	if memory_status != .Ok {
		step_failed("Memory_Create", memory_status)
	}
	page, map_status := system.memory_map(memory, {.Write})
	if map_status != .Ok {
		step_failed("Memory_Map of the code", map_status)
	}
	code := GUEST_CODE
	bytes := ([^]u8)(page)
	for code_byte, index in code {
		bytes[index] = code_byte
	}
	system.memory_unmap(page)
	if _, guest_map_status := system.memory_map(memory, {.Execute}, guest, CODE_ADDRESS); guest_map_status != .Ok {
		step_failed("Memory_Map of the code in the guest", guest_map_status)
	}

	registers := op.Guest_Registers{rip = CODE_ADDRESS}
	written_port, written_value, writes: u64
	halted := false
	interrupted := 0
	for !halted {
		error: errors.Error_Record
		exit, run_status := system.guest_run(guest, &registers, &error)
		if run_status == .Bad_Operation && error.kind == i64(errors.Kind.Unsupported) {
			system.log_fact(.Info, Guests_Unsupported{})
			system.log_fact(.Info, Guest_Demo_Held{})
			system.stop(.Done)
		}
		if run_status != .Ok {
			step_failed("Guest_Run", run_status)
		}
		switch exit.kind {
		case .Port_Write:
			written_port, written_value = exit.a, exit.c
			writes += 1
			if exit.b != 1 {
				system.log_fact(.Info, Port_Write_Size_Wrong{port_write_bytes = u64(exit.b)})
				system.stop(.Failed)
			}
			registers.rip = exit.next
		case .Halt:
			if registers.rip != HALT_ADDRESS {
				system.log_fact(.Info, Halted_Elsewhere{halt_address = value_kinds.Hexadecimal_Sixteen_Digits(registers.rip), expected_address = value_kinds.Hexadecimal_Sixteen_Digits(HALT_ADDRESS)})
				system.stop(.Failed)
			}
			halted = true
		case .Interrupted:
			interrupted += 1
			if interrupted > INTERRUPTED_RUNS_LIMIT {
				system.log_fact(.Info, Instruction_Not_Reached{runs = u64(INTERRUPTED_RUNS_LIMIT), instruction = value_kinds.text_field("hlt", 8)})
				system.stop(.Failed)
			}
		case .None, .Port_Read, .Cpuid, .Memory, .Shutdown, .Refused_State, .Other, .Interrupt_Window:
			system.log_fact(.Info, Exit_Unexpected{exit_kind = u64(exit.kind), exit_code = value_kinds.Hexadecimal_Sixteen_Digits(exit.code), information = value_kinds.Hexadecimal_Sixteen_Digits(exit.information), instruction_address = value_kinds.Hexadecimal_Sixteen_Digits(registers.rip)})
			system.stop(.Failed)
		}
	}
	if writes != 1 || written_port != PORT || written_value != VALUE {
		system.log_fact(.Info, Port_Writes_Wrong{writes = writes, written_value = written_value, written_port = written_port})
		system.stop(.Failed)
	}
	system.log_fact(.Info, Port_Written_Then_Halted{})

	// A debug exception of the guest exits: a guest whose delivery of it
	// raised it again would hold the processor for ever.
	registers.rip = DEBUG_ADDRESS
	interrupted = 0
	for {
		exit, run_status := system.guest_run(guest, &registers)
		if run_status != .Ok {
			step_failed("Guest_Run at int1", run_status)
		}
		if exit.kind == .Interrupted {
			interrupted += 1
			if interrupted > INTERRUPTED_RUNS_LIMIT {
				system.log_fact(.Info, Instruction_Not_Reached{runs = u64(INTERRUPTED_RUNS_LIMIT), instruction = value_kinds.text_field("int1", 8)})
				system.stop(.Failed)
			}
			continue
		}
		if exit.kind != .Other || exit.code != DEBUG_EXCEPTION_EXIT_CODE {
			system.log_fact(.Info, Debug_Exit_Wrong{exit_kind = u64(exit.kind), exit_code = value_kinds.Hexadecimal_Sixteen_Digits(exit.code), expected_code = value_kinds.Hexadecimal_Sixteen_Digits(DEBUG_EXCEPTION_EXIT_CODE)})
			system.stop(.Failed)
		}
		break
	}
	system.log_fact(.Info, Debug_Exit_Arrived{})

	// A guest has no kernel half in its page table: no thread runs on it.
	if _, start_status := system.call(.Process_Start, u64(guest), CODE_ADDRESS, op.STACK_TOP, op.CONTEXT_ADDRESS); start_status != .Bad_State {
		system.log_fact(.Info, Step_Not_Refused{status_word = op.Status_Word(start_status), expected = .Bad_State, step = value_kinds.text_field("Process_Start of the guest", 36)})
		system.stop(.Failed)
	}
	system.log_fact(.Info, Guest_Start_Refused{})
	system.log_fact(.Info, Guest_Demo_Held{})
	system.stop(.Done)
}

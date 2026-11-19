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
import "modus:support/system"

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

// fail writes the line of a failure, which starts with "guest_demo:
// failed: ", and stops the process with `Failed`.
fail :: proc "contextless" (parts: ..system.Part) -> ! {
	system.log(..parts)
	system.stop(.Failed)
}

@(export, link_name = "entry")
entry :: proc "c" (_: ^system.Context) -> ! {
	name := GUEST_NAME
	created, create_status := system.call(.Process_Create, u64(system.own_budget()), u64(uintptr(raw_data(name))), u64(len(name)))
	if create_status != .Ok {
		fail("guest_demo: failed: Process_Create of the guest gave ", create_status)
	}
	guest := system.Handle(created[0])

	// The code goes in one memory object, written here, then mapped in the
	// guest with Execute only: no page is writable and executable.
	memory, memory_status := system.memory_create(1)
	if memory_status != .Ok {
		fail("guest_demo: failed: Memory_Create gave ", memory_status)
	}
	page, map_status := system.memory_map(memory, {.Write})
	if map_status != .Ok {
		fail("guest_demo: failed: Memory_Map of the code gave ", map_status)
	}
	code := GUEST_CODE
	bytes := ([^]u8)(page)
	for code_byte, index in code {
		bytes[index] = code_byte
	}
	system.memory_unmap(page)
	if _, guest_map_status := system.memory_map(memory, {.Execute}, guest, CODE_ADDRESS); guest_map_status != .Ok {
		fail("guest_demo: failed: Memory_Map of the code in the guest gave ", guest_map_status)
	}

	registers := op.Guest_Registers{rip = CODE_ADDRESS}
	written_port, written_value, writes: u64
	halted := false
	interrupted := 0
	for !halted {
		error: errors.Error_Record
		exit, run_status := system.guest_run(guest, &registers, &error)
		if run_status == .Bad_Operation && error.kind == i64(errors.Kind.Unsupported) {
			system.log("guest_demo: Guest_Run gave Bad_Operation with the error kind Unsupported: the processors of this machine have no virtualization support that the kernel uses, and no guest runs: as it must")
			system.log("guest_demo: ok")
			system.stop(.Done)
		}
		if run_status != .Ok {
			fail("guest_demo: failed: Guest_Run gave ", run_status)
		}
		switch exit.kind {
		case .Port_Write:
			written_port, written_value = exit.a, exit.c
			writes += 1
			if exit.b != 1 {
				fail("guest_demo: failed: the port write has ", exit.b, " bytes, not 1")
			}
			registers.rip = exit.next
		case .Halt:
			if registers.rip != HALT_ADDRESS {
				fail("guest_demo: failed: the guest halted at ", system.Hex(registers.rip), ", not at ", system.Hex(HALT_ADDRESS))
			}
			halted = true
		case .Interrupted:
			interrupted += 1
			if interrupted > INTERRUPTED_RUNS_LIMIT {
				fail("guest_demo: failed: the guest did not reach its hlt in ", u64(INTERRUPTED_RUNS_LIMIT), " runs")
			}
		case .None, .Port_Read, .Cpuid, .Memory, .Shutdown, .Refused_State, .Other:
			fail("guest_demo: failed: an exit of kind ", u64(exit.kind), ", exit code ", system.Hex(exit.code), ", information ", system.Hex(exit.information), ", at ", system.Hex(registers.rip))
		}
	}
	if writes != 1 || written_port != PORT || written_value != VALUE {
		fail("guest_demo: failed: the guest wrote ", writes, " times, the last ", written_value, " to the port ", written_port)
	}
	system.log("guest_demo: the guest wrote 42 to the port 0x80, then halted after it: as it must")

	// A debug exception of the guest exits: a guest whose delivery of it
	// raised it again would hold the processor for ever.
	registers.rip = DEBUG_ADDRESS
	interrupted = 0
	for {
		exit, run_status := system.guest_run(guest, &registers)
		if run_status != .Ok {
			fail("guest_demo: failed: Guest_Run at int1 gave ", run_status)
		}
		if exit.kind == .Interrupted {
			interrupted += 1
			if interrupted > INTERRUPTED_RUNS_LIMIT {
				fail("guest_demo: failed: the guest did not reach its int1 in ", u64(INTERRUPTED_RUNS_LIMIT), " runs")
			}
			continue
		}
		if exit.kind != .Other || exit.code != DEBUG_EXCEPTION_EXIT_CODE {
			fail("guest_demo: failed: int1 gave an exit of kind ", u64(exit.kind), ", exit code ", system.Hex(exit.code), ", not Other with ", system.Hex(DEBUG_EXCEPTION_EXIT_CODE))
		}
		break
	}
	system.log("guest_demo: the int1 of the guest arrived as an exit Other with the exit code 0x88: as it must")

	// A guest has no kernel half in its page table: no thread runs on it.
	if _, start_status := system.call(.Process_Start, u64(guest), CODE_ADDRESS, op.STACK_TOP, op.CONTEXT_ADDRESS); start_status != .Bad_State {
		fail("guest_demo: failed: Process_Start of the guest gave ", start_status, ", not Bad_State")
	}
	system.log("guest_demo: Process_Start of the guest gave Bad_State: as it must")
	system.log("guest_demo: ok")
	system.stop(.Done)
}

package system

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"

// The wiring of a process before its first instruction
// (src/md/features/module_outputs.md, "The wiring list of a start"). A
// starter that wires gives process_start a Start_Wiring: the ends that the
// child takes from its wiring ring before it runs. process_start makes the
// wiring ring from the budget of the child, gives it at the handle
// op.CONTEXT_WIRING_RING, gives each end through the memory of that ring,
// writes each command, and only then starts the first thread. It is a
// list of ends, not a callback: the starter checked the list, made the
// output rings and gave the other ends before the call.
Start_Wiring :: struct {
	// In: each end of the child. ring and terms are handles of the starter;
	// process_start gives them through the wiring ring, and the command
	// names the handles of the child.
	ends:          []output.Given_End,
	// Out: the memory of the wiring ring, with Read and Write, in the
	// starter; 0 when the child declares no record stream and has no end.
	wiring_memory: Handle,
	// Out: a handle of the budget of the child with Read and Spend: the
	// starter pays the wirings that the child asks for from it, and closes
	// it at the stop of the child.
	budget:        Handle,
}

// module_declares_record_streams says if a module file declares a record
// output or a record input: such a process gets a wiring ring at its start.
module_declares_record_streams :: proc "contextless" (file: []u8) -> bool {
	return module.count(file, .Record_Outputs) > 1 || module.count(file, .Record_Inputs) > 1
}

// start_wiring_give makes the wiring ring of a process, gives it in the
// context record, and writes the ends. It runs after the other handles of
// the context are in the process, so the process holds the memory of the
// ring when each end is given through it. A failure closes what it made;
// the caller then stops the process.
@(private)
start_wiring_give :: proc "contextless" (process: Handle, budget: Handle, record: ^op.Context, file: []u8, wiring: ^Start_Wiring) -> Status {
	if len(wiring.ends) == 0 && !module_declares_record_streams(file) {
		return .Ok
	}
	capacity, capacity_ok := output.wiring_ring_capacity(u64(len(wiring.ends)))
	if !capacity_ok {
		return .Bad_Operation
	}
	memory := memory_create(ring.pages(capacity), budget) or_return
	status: Status
	record.handles[op.CONTEXT_WIRING_RING], status = give(process, memory, {.Read, .Write})
	if status != .Ok {
		close(memory)
		return status
	}
	mapped: ring.Ring
	mapped, status = ring_open(memory)
	if status != .Ok {
		close(memory)
		return status
	}
	defer ring_close(&mapped)
	for end in wiring.ends {
		given := end
		// The handles go through the memory of the wiring ring: the child
		// proves with Handle_State that each one came through it.
		given.ring, status = give(memory, end.ring, {.Read, .Write})
		if status == .Ok && end.terms != 0 {
			given.terms, status = give(memory, end.terms, {.Read})
		}
		if status != .Ok {
			close(memory)
			return status
		}
		// The capacity holds each end, and no one reads the ring yet.
		if !ring.push(&mapped.commands, output.given_end_record(given)) {
			close(memory)
			return .Bad_Operation
		}
	}
	wiring.wiring_memory = memory
	return .Ok
}

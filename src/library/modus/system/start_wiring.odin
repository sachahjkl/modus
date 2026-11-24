package system

import "modus:contract/call_outcome"
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
// writes each command, and only then starts the first thread. The
// starter checked the list before the call. It makes the objects of the
// ends in ends_make, which process_start calls after the load of the
// modules of the child: the loader then prepares each module with no
// handle of the list in the handle table of the starter, whose margin is
// the bound of a start (src/md/features/module_outputs.md, "The budget").
Start_Wiring :: struct {
	// In: each end of the child. ring and terms are handles of the starter;
	// process_start gives them through the wiring ring, and the command
	// names the handles of the child. ends_make, when it is set, gives them.
	ends:          []output.Given_End,
	// In: makes the objects of the ends and gives the ends, after the load
	// of the modules. A refusal stops the start; the starter ends what it
	// made. nil: ends is the list.
	ends_make:     proc "contextless" (data: rawptr) -> (ends: []output.Given_End, status: call_outcome.Call_Outcome),
	ends_data:     rawptr,
	// In: the starter keeps a handle of the budget of the child, because
	// the child can ask for wirings, which its budget pays.
	keep_budget:   bool,
	// Out: the memory of the wiring ring, with Read and Write, in the
	// starter; 0 when the child declares no record stream and has no end.
	wiring_memory: Handle,
	// Out, with keep_budget: a handle of the budget of the child with Read
	// and Spend. The starter closes it at the stop of the child.
	budget:        Handle,
	// In: the output ring and the end page of the record output `log` of
	// the child, handles of the starter; 0 when the list does not wire
	// `log`. ends_make may set them, as it makes the objects of the list.
	// process_start gives them at op.CONTEXT_LOG_OUTPUT, with Read and
	// Write, and op.CONTEXT_LOG_OUTPUT_END, with Read only: never through
	// the wiring ring, so a child whose only wiring is `log` has none.
	log_ring:      Handle,
	log_end_words: Handle,
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
start_wiring_give :: proc "contextless" (process: Handle, budget: Handle, record: ^op.Context, file: []u8, wiring: ^Start_Wiring) -> call_outcome.Call_Outcome {
	// The end of log, in its two places of the context. Both or neither: a
	// ring with no end page would hold a writer that never learns the end
	// of its reader.
	if (wiring.log_ring == 0) != (wiring.log_end_words == 0) {
		return .Argument_Refused
	}
	if wiring.log_ring != 0 {
		status: call_outcome.Call_Outcome
		record.handles[op.CONTEXT_LOG_OUTPUT], status = give(process, wiring.log_ring, {.Read, .Write})
		if status == .Succeeded {
			record.handles[op.CONTEXT_LOG_OUTPUT_END], status = give(process, wiring.log_end_words, {.Read})
		}
		if status != .Succeeded {
			return status
		}
	}
	if len(wiring.ends) == 0 && !module_declares_record_streams(file) {
		return .Succeeded
	}
	capacity, capacity_ok := output.wiring_ring_capacity(u64(len(wiring.ends)))
	if !capacity_ok {
		return .Argument_Refused
	}
	memory := memory_create(ring.pages(capacity), budget) or_return
	status: call_outcome.Call_Outcome
	record.handles[op.CONTEXT_WIRING_RING], status = give(process, memory, {.Read, .Write})
	if status != .Succeeded {
		close(memory)
		return status
	}
	mapped: ring.Ring
	mapped, status = ring_open(memory)
	if status != .Succeeded {
		close(memory)
		return status
	}
	defer ring_close(&mapped)
	if len(wiring.ends) > 0 {
		// Temporarily map the wiring ring in the Created child with
		// Receive_Handles so Handle_Give delivers each initial end handle
		// through it before Process_Start, then unmap before the child runs.
		child_ring_address: rawptr
		child_ring_address, status = memory_map(memory, {.Receive_Handles}, process)
		if status != .Succeeded {
			close(memory)
			return status
		}
		defer memory_unmap(child_ring_address, process)
		for end in wiring.ends {
			given := end
			// The handles go through the memory of the wiring ring: the child
			// proves with Handle_State that each one came through it.
			given.ring, status = give(memory, end.ring, {.Read, .Write})
			if status == .Succeeded && end.terms != 0 {
				given.terms, status = give(memory, end.terms, {.Read})
			}
			if status == .Succeeded && end.description != 0 {
				given.description, status = give(memory, end.description, {.Read})
			}
			// The condition of a writer end, with Read only: only the root
			// service writes it.
			if status == .Succeeded && end.condition != 0 {
				given.condition, status = give(memory, end.condition, {.Read})
			}
			// The end page with Read only: only the root service writes the end.
			if status == .Succeeded {
				given.end_words, status = give(memory, end.end_words, {.Read})
			}
			if status != .Succeeded {
				close(memory)
				return status
			}
			// The capacity holds each end, and no one reads the ring yet.
			if !ring.push(&mapped.commands, output.given_end_record(given)) {
				close(memory)
				return .Argument_Refused
			}
		}
	}
	wiring.wiring_memory = memory
	return .Succeeded
}

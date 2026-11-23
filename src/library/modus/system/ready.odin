package system

import "base:intrinsics"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/root_ring"

// The first state of work of a process (src/md/features/module_budget_request.md,
// "The first state of work"): the moment when its start is done and it waits
// for its work. The process says it once, on its ready ring (the handle
// op.CONTEXT_READY_RING), and its starter then reads the peak of its budget
// against the floor of its start. The library says it for each process at
// the first present of a window (display) and at the first wait of a
// service for its calls (service_wait); a process with neither calls ready
// itself.

// The side of a starter of the ready ring of a process that it starts: the
// memory, which the budget of the process pays, and the ring mapped in the
// starter. process_start makes it when the starter asks for it.
Ready_Ring :: struct {
	memory: Handle,
	mapped: ring.Ring,
}

// The ready ring has the smallest capacity: it carries one record.
READY_RING_CAPACITY :: ring.CAPACITY

// ready says to the starter of this process that it reached its first state
// of work. The first call takes the handle of the ready ring out of the
// context with one atomic exchange, sends the record Ready on the ring,
// then closes the view and the handle: the ring carries nothing else, and
// no completion comes. The context is the one claim of the process: a
// process that carries two copies of this package (its own, and the one of
// the drawing module) says it once, and a later call never opens a handle
// number that was closed and given again. sent is false when the starter
// gave no ready ring, when the ring cannot be mapped, or when an earlier
// call took the handle.
ready :: proc "contextless" () -> (sent: bool) {
	start_context := (^op.Context)(uintptr(op.CONTEXT_ADDRESS))
	memory := intrinsics.atomic_exchange(&start_context.handles[op.CONTEXT_READY_RING], 0)
	if memory == 0 {
		return false
	}
	mapped, status := ring_open(memory)
	if status != .Ok {
		return false
	}
	sent = send(&mapped.commands, ring.Record{kind = u32(root_ring.Root_Command.Ready)})
	ring_close(&mapped)
	close(memory)
	return sent
}

// ready_ring_close ends the side of a starter of a ready ring: its view and
// its handle. A ring that was never made, or that is closed, is left as it
// is.
ready_ring_close :: proc "contextless" (ready: ^Ready_Ring) {
	if ready.mapped.head != nil {
		ring_close(&ready.mapped)
	}
	if ready.memory != 0 {
		close(ready.memory)
	}
	ready^ = {}
}

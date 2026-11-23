// The queue of the guest builds of the recipes service
// (src/md/features/recipes.md, "The queue of the guest builds"): one build
// runs on the build thread, and a bounded number waits. Each principal
// holds at most GUEST_QUEUE_PER_PRINCIPAL_MOST of them, running or
// waiting, and the next build is the oldest of a principal other than the
// one whose build just ran, when one waits: a principal that queues many
// builds does not keep the builder from the others. The principal that
// queued a build may cancel it: a waiting build leaves the queue, a running
// build ends at the next exit of its guest. This file is the state
// machine; the service holds its lock around each call.
package recipes_core

import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"

// The guest builds that the service holds: the running one and the ones
// that wait.
GUEST_QUEUE_MOST :: 8
// The builds of one principal in the queue, running or waiting.
GUEST_QUEUE_PER_PRINCIPAL_MOST :: 2
// The principal of a build of the delegated ring: no caller cancels it.
GUEST_QUEUE_RING_PRINCIPAL :: max(u64)

Guest_Job_State :: enum u8 {
	Free    = 0,
	Waiting = 1,
	Running = 2,
}

// One guest build of the queue.
Guest_Queue_Job :: struct {
	state:            Guest_Job_State,
	principal:        u64,
	recipe_hash:      blake3.Hash,
	mode:             pr.Build_Mode,
	order:            u64, // The order of its arrival.
	cancel_requested: bool, // A running build ends at the next exit of its guest.
	from_ring:        bool, // A command of the delegated ring: its spec, its tag and its result place.
	spec:             pr.Recipe_Spec,
	ring_tag:         u32,
	result_offset:    u64,
}

Guest_Queue :: struct {
	jobs:           [GUEST_QUEUE_MOST]Guest_Queue_Job,
	arrivals:       u64,
	last_principal: u64, // The principal of the build that ran last.
	ran_once:       bool,
}

// What a cancel did.
Guest_Cancel :: enum u8 {
	Removed   = 1, // The build waited: it left the queue.
	Requested = 2, // The build runs: it ends at the next exit of its guest.
	Absent    = 3, // The queue holds no build of this recipe of this principal: a build of another principal is not told apart.
}

// guest_queue_push adds a build at the end of the queue. Builder_Busy when
// the queue is full, or when its principal holds its share already; the
// queue does not change then.
guest_queue_push :: proc "contextless" (queue: ^Guest_Queue, job: Guest_Queue_Job) -> pr.Recipe_Refusal {
	held := 0
	free: ^Guest_Queue_Job
	for &place in queue.jobs {
		switch place.state {
		case .Free:
			if free == nil {
				free = &place
			}
		case .Waiting, .Running:
			if place.principal == job.principal {
				held += 1
			}
		}
	}
	if free == nil || (job.principal != GUEST_QUEUE_RING_PRINCIPAL && held >= GUEST_QUEUE_PER_PRINCIPAL_MOST) {
		return .Builder_Busy
	}
	free^ = job
	free.state = .Waiting
	free.cancel_requested = false
	free.order = queue.arrivals
	queue.arrivals += 1
	return .None
}

// guest_queue_running gives the running build, or nil.
guest_queue_running :: proc "contextless" (queue: ^Guest_Queue) -> ^Guest_Queue_Job {
	for &place in queue.jobs {
		if place.state == .Running {
			return &place
		}
	}
	return nil
}

// guest_queue_start makes the next build run and gives it, or nil when a
// build runs or none waits. The next is the oldest build of a principal
// other than the one whose build ran last, else the oldest.
guest_queue_start :: proc "contextless" (queue: ^Guest_Queue) -> ^Guest_Queue_Job {
	if guest_queue_running(queue) != nil {
		return nil
	}
	oldest, oldest_other: ^Guest_Queue_Job
	for &place in queue.jobs {
		if place.state != .Waiting {
			continue
		}
		if oldest == nil || place.order < oldest.order {
			oldest = &place
		}
		if (!queue.ran_once || place.principal != queue.last_principal) && (oldest_other == nil || place.order < oldest_other.order) {
			oldest_other = &place
		}
	}
	next := oldest_other != nil ? oldest_other : oldest
	if next != nil {
		next.state = .Running
		queue.last_principal = next.principal
		queue.ran_once = true
	}
	return next
}

// guest_queue_end frees the running build.
guest_queue_end :: proc "contextless" (queue: ^Guest_Queue) {
	if running := guest_queue_running(queue); running != nil {
		running^ = {}
	}
}

// guest_queue_cancel cancels the build of recipe_hash of principal: the
// waiting one first, else the running one. The principal of the ring is
// no caller: it cancels nothing. A build of another principal is Absent,
// as no build: a caller learns nothing of the builds of others.
guest_queue_cancel :: proc "contextless" (queue: ^Guest_Queue, principal: u64, recipe_hash: blake3.Hash) -> Guest_Cancel {
	if principal == GUEST_QUEUE_RING_PRINCIPAL {
		return .Absent
	}
	for state in ([2]Guest_Job_State{.Waiting, .Running}) {
		for &place in queue.jobs {
			if place.state != state || place.recipe_hash != recipe_hash {
				continue
			}
			if place.principal != principal {
				continue
			}
			if state == .Waiting {
				place = {}
				return .Removed
			}
			place.cancel_requested = true
			return .Requested
		}
	}
	return .Absent
}

// guest_queue_count gives the builds that wait and that run.
guest_queue_count :: proc "contextless" (queue: ^Guest_Queue) -> (waiting: int, running: int) {
	for place in queue.jobs {
		switch place.state {
		case .Free:
		case .Waiting:
			waiting += 1
		case .Running:
			running += 1
		}
	}
	return
}

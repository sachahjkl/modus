package kernel

import "base:intrinsics"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modulus:slot_set"

// The origin tree: what came from which handle. Kernel state is flat tables
// with no pointer tree, so the tree is one table of links below
// (docs/PROPERTIES.md, "Data-oriented kernel internals").
//
// A holding is a handle or a mapping of a process. The origin of a holding
// is the handle that it came from:
//   a handle that Handle_Give made: the handle that was given;
//   a mapping that Memory_Map made: the memory handle that was mapped.
// A holding that the kernel made, or the handle of a new object, has no
// origin. When a handle closes, what came from it now comes from its own
// origin: a process that closes a handle does not hide what it passed on.
// Handle_Revoke ends each holding that came from a handle.
//
// The tree is one flat table of links. Holding number = process slot *
// HOLDINGS_PER_PROCESS + n. n < HANDLE_CAPACITY: handle slot n. n >=
// HANDLE_CAPACITY: mapping slot n - HANDLE_CAPACITY. 0: none, because the
// process slot 0 holds no process. Each change is a constant number of
// writes: a holding is in the list of the holdings of its origin, with a
// link in each direction.
HOLDINGS_PER_PROCESS :: HANDLE_CAPACITY + MAPPING_CAPACITY
#assert(u64(PROCESS_CAPACITY) * HOLDINGS_PER_PROCESS <= u64(max(u32)))

Holding :: u32

// holding_process gives the process slot of a holding.
holding_process :: #force_inline proc "contextless" (holding: Holding) -> u32 {
	return holding / HOLDINGS_PER_PROCESS
}

// holding_place gives the place of a holding in its process: a handle slot
// below HANDLE_CAPACITY, else HANDLE_CAPACITY + a mapping slot.
holding_place :: #force_inline proc "contextless" (holding: Holding) -> u32 {
	return holding % HOLDINGS_PER_PROCESS
}

Origin_Link :: struct {
	origin:   Holding,
	first:    Holding, // The first holding that came from this one.
	next:     Holding, // In the list of the holdings of `origin`.
	previous: Holding,
}

// The origin lock protects `origins`, `origin_changes` and `revoking`. The
// link of a holding changes under the origin lock; a path that ends a
// holding also holds the process lock of the holder.
origin_lock: Lock
origins: [PROCESS_CAPACITY * HOLDINGS_PER_PROCESS]Origin_Link
origin_changes: u64 // Detaches since boot: a revocation sees that another processor changed the tree.
revoking: bool // A revocation lists and ends holdings: a path with no control lock adds none.
revoke_lost: Process_Set // The processes of which Handle_Revoke ended a holding. Control lock.

holding_of_handle :: proc "contextless" (process: ^Process, slot: ^Handle_Slot) -> Holding {
	return Holding(intrinsics.ptr_sub(process, &processes[0])) * HOLDINGS_PER_PROCESS + Holding(intrinsics.ptr_sub(slot, &process.handles[0]))
}

holding_of_mapping :: proc "contextless" (process: ^Process, mapping: ^Mapping) -> Holding {
	return Holding(intrinsics.ptr_sub(process, &processes[0])) * HOLDINGS_PER_PROCESS + Holding(HANDLE_CAPACITY + intrinsics.ptr_sub(mapping, &process.mappings[0]))
}

// origin_attach says that a holding came from a handle. The holding is in
// no list. false: a revocation runs and the caller has no control lock;
// nothing changed, and the caller runs again with the control lock.
origin_attach :: proc "contextless" (holding: Holding, origin: Holding) -> bool {
	if origin == 0 {
		return true // The link of a holding that ends is zero: it stays so.
	}
	lock_take(&origin_lock, .Origin)
	defer lock_free(&origin_lock, .Origin)
	if revoking && !processor_self().operation.control {
		return false
	}
	link := &origins[holding]
	link.origin, link.previous = origin, 0
	link.next = origins[origin].first
	if link.next != 0 {
		origins[link.next].previous = holding
	}
	origins[origin].first = holding
	return true
}

// origin_detach takes a holding that ends out of the tree. What came from
// it now comes from its origin. The caller holds the process lock of the
// holder: then a link that is zero stays zero (only that process adds a
// holding below this one, and a holding with no origin gets none), and the
// origin lock is not needed.
origin_detach :: proc "contextless" (holding: Holding) {
	link := &origins[holding]
	if intrinsics.atomic_load(&link.first) == 0 && intrinsics.atomic_load(&link.origin) == 0 {
		return
	}
	lock_take(&origin_lock, .Origin)
	defer lock_free(&origin_lock, .Origin)
	origin_changes += 1
	for child := link.first; child != 0; {
		next := origins[child].next
		reattach(child, link.origin)
		child = next
	}
	if link.previous != 0 {
		origins[link.previous].next = link.next
	} else if link.origin != 0 {
		origins[link.origin].first = link.next
	}
	if link.next != 0 {
		origins[link.next].previous = link.previous
	}
	link^ = {}
}

// reattach moves a holding to the list of another origin. The caller holds
// the origin lock.
@(private = "file")
reattach :: proc "contextless" (holding: Holding, origin: Holding) {
	link := &origins[holding]
	link.origin, link.previous, link.next = origin, 0, 0
	if origin == 0 {
		return
	}
	link.next = origins[origin].first
	if link.next != 0 {
		origins[link.next].previous = holding
	}
	origins[origin].first = holding
}

// origin_next gives the holding after `holding` in the holdings that came
// from `top`, each one after its origin. 0: no more.
origin_next :: proc "contextless" (top: Holding, holding: Holding) -> Holding {
	if origins[holding].first != 0 {
		return origins[holding].first
	}
	for at := holding; at != top && at != 0; at = origins[at].origin {
		if origins[at].next != 0 {
			return origins[at].next
		}
	}
	return 0
}

// origin_count gives the count of the holdings that came from a handle.
origin_count :: proc "contextless" (top: Holding) -> (count: u64) {
	lock_take(&origin_lock, .Origin)
	for at := origin_next(top, top); at != 0; at = origin_next(top, at) {
		count += 1
	}
	lock_free(&origin_lock, .Origin)
	return count
}

// A mapping in the process that revokes stays: a process does not remove
// its own memory when it takes back what it gave.
@(private = "file")
stays :: proc "contextless" (holding: Holding, caller: u32) -> bool {
	return holding_process(holding) == caller && holding_place(holding) >= HANDLE_CAPACITY
}

// holding_end closes a handle or removes a mapping, for Handle_Revoke. The
// caller holds the control lock. `changes` is origin_changes when the caller
// read the tree: if another processor changed the tree since, the holding
// can be another one now, and nothing ends (false, restart).
End :: enum {
	Ended, // The holding ended.
	Gone, // The holding was not there any more.
	Changed, // Another processor changed the tree: nothing ended.
}

@(private = "file")
holding_end :: proc "contextless" (holding: Holding, changes: u64) -> End {
	index := holding_process(holding)
	process := &processes[index]
	taken := process_lock(index)
	defer process_unlock(index, taken)
	lock_take(&origin_lock, .Origin)
	same := origin_changes == changes
	lock_free(&origin_lock, .Origin)
	if !same {
		return .Changed
	}
	// A revocation never waits for a recording: end the input history at once.
	record_replay_on_revocation(index)
	n := holding_place(holding)
	if n < HANDLE_CAPACITY {
		slot := &process.handles[n]
		if slot.kind == .None {
			return .Gone
		}
		handle_close(process, slot)
		slot.ended = u8(errors.End.Revoked)
	} else {
		mapping := &process.mappings[n - HANDLE_CAPACITY]
		if mapping.page_count == 0 {
			return .Gone
		}
		// Before the unmap: the unmap can end the memory object and free its
		// frames. A thread that waits on a word of it wakes; it runs again
		// after the unmap, under this process lock.
		// A thread that registered its words and does not wait yet counts
		// too: its wait_end must not wait on a frame that leaves. One sorted
		// search over the frames of the object, not one walk of the object
		// for each word. Each frame of the object counts: the unmap can end
		// the object, and then each of its frames leaves.
		region := &regions[mapping.region]
		whole := [1]op.Page_Range{{first = 0, page_count = region.page_count}}
		waiters_on_frames_wake(process, region, whole[:])
		unmap(process, mapping)
	}
	slot_set.add(&revoke_lost, index)
	return .Ended
}

// revoke_under ends a holding and each holding that came from it, the last
// ones first. `changes` is origin_changes when the caller chose `top`: if
// another processor changed the tree since (a process closed a holding, and
// its slot can hold a new handle now), nothing more ends here, and the
// caller looks again from its own handle (restart). It does not loop for
// ever: during the revocation no holding is added to the tree, so each
// change removes one holding.
@(private = "file")
revoke_under :: proc "contextless" (top: Holding, caller: u32, changes: u64) -> (count: u64) {
	changes := changes
	cursor := top
	for {
		lock_take(&origin_lock, .Origin)
		if origin_changes != changes {
			lock_free(&origin_lock, .Origin)
			return count
		}
		for {
			child := origins[cursor].first
			for child != 0 && stays(child, caller) {
				child = origins[child].next
			}
			if child == 0 {
				break
			}
			cursor = child
		}
		origin := origins[cursor].origin
		last := cursor == top
		lock_free(&origin_lock, .Origin)
		if holding_end(cursor, changes) != .Ended {
			return count
		}
		count += 1
		changes += 1 // The end of this holding is one change: its detach.
		if last {
			return count
		}
		cursor = origin
	}
}

// revoke ends each holding that came from a handle: in one process
// (only != 0), or in each process. A holding that ends takes with it what
// came from it, in any process. The handle stays. The caller holds the
// control lock.
revoke :: proc "contextless" (top: Holding, caller: u32, only: u32) -> (count: u64) {
	revoke_lost = {}
	lock_take(&origin_lock, .Origin)
	revoking = true
	lock_free(&origin_lock, .Origin)
	for {
		found: Holding
		lock_take(&origin_lock, .Origin)
		for at := origin_next(top, top); at != 0; at = origin_next(top, at) {
			if !stays(at, caller) && (only == 0 || holding_process(at) == only) {
				found = at
				break
			}
		}
		changes := origin_changes
		lock_free(&origin_lock, .Origin)
		if found == 0 {
			break
		}
		count += revoke_under(found, caller, changes)
	}
	lock_take(&origin_lock, .Origin)
	revoking = false
	lock_free(&origin_lock, .Origin)
	// Each process that lost a holding gets an event.
	for index in slot_set.take(&revoke_lost) {
		if index != caller {
			process_event(index)
		}
	}
	return count
}

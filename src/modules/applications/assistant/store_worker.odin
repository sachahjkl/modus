// Dedicated off-thread storage worker for assistant conversation persistence
// (src/md/features/assistant.md, "The conversation kept in the private store").
//
// The window thread never calls storage.* directly: it owns `talk`, encodes
// dirty snapshots into `write_arena` when no write is in flight, and wakes the
// worker via `work_event`. The worker opens `storage.Client`, loads the stored
// `"conversation"` object once at start into `read_arena`, and commits dirty
// snapshots asynchronously.
package assistant_window

import "modus:contract/call_outcome"
import "internal:assistant/conversation"
import "modus:contract/errors"
import "modus:storage"
import "modus:system"

// Format property: object name inside assistant's private store.
CONVERSATION_OBJECT_NAME :: "conversation"

// Computed: stack pages for the store worker thread (calls of storage service
// and their records, matching notes).
STORE_THREAD_STACK_PAGES :: 16

// Computed: virtual address reservation covering PERSIST_MAX_BYTES; physical
// pages are committed on demand via system.arena_extend_to.
STORE_RESERVE_PAGES :: (conversation.PERSIST_MAX_BYTES + system.PAGE_SIZE - 1) / system.PAGE_SIZE

// Computed: working memory pages budgeted for the live snapshot arena (read_arena
// is released via system.arena_end right after startup load completes, so one
// full PERSIST_MAX_BYTES snapshot fits cleanly without truncation).
STORE_WORKING_PAGES :: STORE_RESERVE_PAGES

Store_State :: struct {
	lock:            system.Lock,
	work_event:      system.Event,
	done_event:      system.Event,
	client:          storage.Client,
	read_arena:      system.Arena,
	write_arena:     system.Arena,
	opened:          bool,
	load_done:       bool,
	load_applied:    bool,
	load_has_bytes:  bool,
	load_bytes:      int,
	load_damaged:    bool,
	dirty:           bool,
	write_pending:   bool,
	write_in_flight: bool,
	write_bytes:     int,
}

store_state: Store_State

// store_read_room grows read_arena to hold the persisted conversation object.
// Called by the store worker thread alone during initial load.
@(private = "file")
store_read_room :: proc "contextless" (data: rawptr, minimum: int) -> (room: []u8, ok: bool) {
	_ = data
	if minimum < 0 || minimum > conversation.PERSIST_MAX_BYTES {
		return nil, false
	}
	if minimum == 0 {
		return store_state.read_arena.base[:0], true
	}
	bytes, status := system.arena_extend_to(&store_state.read_arena, u64(minimum))
	if status != .Succeeded {
		return nil, false
	}
	return bytes[:minimum], true
}

// store_worker_entry runs on the store thread: loads any saved conversation
// once, then commits dirty conversation snapshots on demand.
@(private = "file")
store_worker_entry :: proc "c" (parameter: rawptr) -> ! {
	ctx := (^system.Context)(parameter)
	client, opened := storage.open(ctx)
	load_has_bytes := false
	load_bytes := 0
	load_damaged := false
	if opened {
		store_state.client = client
		error: errors.Error_Record
		bytes, outcome, status := storage.read_whole(&store_state.client, storage.ROOT, CONVERSATION_OBJECT_NAME, store_read_room, nil, &error)
		switch {
		case status == .Damaged:
			load_damaged = true
		case status == .Ok && outcome == .Read:
			load_has_bytes = true
			load_bytes = len(bytes)
		case status == .Ok && outcome == .Too_Long:
			load_damaged = true
		}
	}
	system.lock(&store_state.lock)
	store_state.opened = opened
	store_state.load_has_bytes = load_has_bytes
	store_state.load_bytes = load_bytes
	store_state.load_damaged = load_damaged
	store_state.load_done = true
	system.unlock(&store_state.lock)
	system.event_wake(&store_state.done_event)

	for {
		seen := system.event_count(&store_state.work_event)
		system.lock(&store_state.lock)
		has_work := store_state.write_pending
		count := store_state.write_bytes
		if has_work {
			store_state.write_pending = false
		}
		system.unlock(&store_state.lock)
		if !has_work {
			system.event_wait(&store_state.work_event, seen)
			continue
		}
		if opened && count > 0 && u64(count) <= store_state.write_arena.used_bytes {
			error: errors.Error_Record
			generation, status := storage.write_whole(&store_state.client, storage.ROOT, CONVERSATION_OBJECT_NAME, store_state.write_arena.base[:count], &error)
			if status == .Ok && generation >= 0 {
				system.log_fact(.Info, Store_Saved{generation = generation, bytes = u64(count)})
			} else {
				system.log_fact(.Info, Store_Write_Failed{status = u64(status)})
			}
		}
		system.lock(&store_state.lock)
		store_state.write_in_flight = false
		system.unlock(&store_state.lock)
		system.event_wake(&store_state.done_event)
	}
}

// store_start reserves the snapshot arenas and launches the store worker thread.
store_start :: proc "contextless" (ctx: ^system.Context) {
	read_status, write_status: call_outcome.Call_Outcome
	store_state.read_arena, read_status = system.arena_create(STORE_RESERVE_PAGES)
	store_state.write_arena, write_status = system.arena_create(STORE_RESERVE_PAGES)
	if read_status != .Succeeded || write_status != .Succeeded {
		if read_status == .Succeeded {
			_ = system.arena_end(&store_state.read_arena)
		}
		if write_status == .Succeeded {
			_ = system.arena_end(&store_state.write_arena)
		}
		store_state.load_done = true
		store_state.load_applied = true
		store_state.opened = false
		system.log_fact(.Info, Store_Unavailable{})
		return
	}
	if _, status := system.thread_start(store_worker_entry, ctx, STORE_THREAD_STACK_PAGES); status != .Succeeded {
		_ = system.arena_end(&store_state.read_arena)
		_ = system.arena_end(&store_state.write_arena)
		store_state.load_done = true
		store_state.load_applied = true
		store_state.opened = false
		system.log_fact(.Info, Store_Unavailable{})
	}
}

// store_mark_dirty marks the conversation for asynchronous persistence on the
// next turn of the main loop.
store_mark_dirty :: proc "contextless" () {
	store_state.dirty = true
}

// store_poll applies a completed initial load into talk and dispatches a dirty
// snapshot write when the worker is idle. Runs on the main thread; never blocks.
store_poll :: proc "contextless" () {
	if !store_state.load_applied {
		system.lock(&store_state.lock)
		done := store_state.load_done
		opened := store_state.opened
		has_bytes := store_state.load_has_bytes
		byte_count := store_state.load_bytes
		damaged := store_state.load_damaged
		system.unlock(&store_state.lock)
		if !done {
			return
		}
		store_state.load_applied = true
		if !opened {
			_ = system.arena_end(&store_state.read_arena)
			_ = system.arena_end(&store_state.write_arena)
			system.log_fact(.Info, Store_Unavailable{})
			return
		}
		if damaged {
			system.log_fact(.Info, Store_Corrupt_Recovered{refusal = u64(conversation.Persist_Refusal.Hash_Mismatch)})
		} else if has_bytes && talk.entry_count == 0 && byte_count > 0 && u64(byte_count) <= store_state.read_arena.used_bytes {
			refusal := conversation.persist_decode(&talk, store_state.read_arena.base[:byte_count])
			if refusal == .None {
				system.log_fact(.Info, Store_Restored{entries = u64(talk.entry_count)})
			} else {
				system.log_fact(.Info, Store_Corrupt_Recovered{refusal = u64(refusal)})
			}
		}
		// Release read_arena immediately after startup restore so only
		// write_arena consumes physical pages during the session.
		_ = system.arena_end(&store_state.read_arena)
	}
	if !store_state.opened || !store_state.dirty {
		return
	}
	system.lock(&store_state.lock)
	busy := store_state.write_in_flight
	system.unlock(&store_state.lock)
	if busy {
		return
	}
	needed := conversation.persist_encoded_size(&talk)
	if needed <= 0 || needed > conversation.PERSIST_MAX_BYTES {
		store_state.dirty = false
		system.log_fact(.Info, Store_Write_Failed{status = u64(conversation.Persist_Refusal.Bad_Length)})
		return
	}
	buf, status := system.arena_extend_to(&store_state.write_arena, u64(needed))
	if status != .Succeeded {
		store_state.dirty = false
		system.log_fact(.Info, Store_Write_Failed{status = u64(status)})
		return
	}
	written, refusal := conversation.persist_encode(&talk, buf[:needed])
	if refusal != .None {
		store_state.dirty = false
		system.log_fact(.Info, Store_Write_Failed{status = u64(refusal)})
		return
	}
	store_state.dirty = false
	system.lock(&store_state.lock)
	store_state.write_bytes = written
	store_state.write_pending = true
	store_state.write_in_flight = true
	system.unlock(&store_state.lock)
	system.event_wake(&store_state.work_event)
}

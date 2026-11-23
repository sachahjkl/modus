package kept_choices

// The keeper of the chosen values of one owner (src/md/features/
// module_settings.md, "Module settings"): the kept record of the owner, the
// changes that come before its read ends, and the next job of the store.
// This file is pure: it decides each job and takes each end, and never
// calls the store. worker.odin runs the jobs on a worker thread, so the
// loop of an owner with a window never waits for the store.

import "modus:contract/chosen_values"

// The room of the kept record: one page holds about a hundred names. A
// record past it is read as one that this release cannot read, and stays
// as it is.
KEPT_RECORD_BYTES :: 4096

// The resets that wait for the end of the read: one for each name. An
// owner has fewer settings than this.
PENDING_CAPACITY :: 32

// The job of the store that the keeper asks for now.
Job :: enum u8 {
	None  = 0,
	Read  = 1, // Read the kept record, once.
	Write = 2, // Write the kept record of this run.
}

// What went wrong at the end of a job: the owner writes its own line of
// the log for it.
Fault :: enum u8 {
	None       = 0,
	Not_Read   = 1, // The store did not give the record: the changes of this run hold for this run only, and the record stays as it is.
	Unreadable = 2, // The record is not one that this release reads: the defaults hold, and the record stays until the principal changes a value.
	Not_Kept   = 3, // The store did not keep a write: the change holds for this run only.
}

// The result of a change.
Change_Result :: enum u8 {
	Taken    = 0, // The change holds, and the keeper keeps it.
	No_Room  = 1, // The record or the changes before the read have no room for it: nothing changed.
	No_Store = 2, // The owner has no store: nothing changed.
}

Keeper :: struct {
	store_open:      bool,
	read_wanted:     bool, // The owner asked for the read: after its first frame.
	read:            bool, // The read ended.
	dirty:           bool, // The kept record holds a change that the store does not hold yet.
	job:             Job, // The job that runs, or None.
	// The bytes of the job: the record that the store gave, or the one that
	// it writes. The owner touches them only while no job runs.
	job_bytes:       [KEPT_RECORD_BYTES]u8,
	job_length:      int,
	// The record in force: what the store gave, with the changes of this
	// run. Always a record of chosen values.
	kept_bytes:      [KEPT_RECORD_BYTES]u8,
	kept_length:     int,
	scratch_bytes:   [KEPT_RECORD_BYTES]u8,
	// The changes that came before the read ended: the values chosen, as a
	// record in the memory of the keeper (a text of a call does not live
	// past the call), and the names reset, copied too. A name is in one of
	// the two at most: its last change.
	pending_bytes:   [KEPT_RECORD_BYTES]u8,
	pending_scratch: [KEPT_RECORD_BYTES]u8, // Not scratch_bytes: a change holds the next kept record there meanwhile.
	pending_length:  int,
	resets:          [PENDING_CAPACITY][chosen_values.NAME_SIZE]u8,
	reset_lengths:   [PENDING_CAPACITY]u8,
	reset_count:     int,
	problem:         chosen_values.Record_Problem, // With Unreadable.
}

// keeper_start makes the record empty, and says if the owner has a store.
keeper_start :: proc "contextless" (keeper: ^Keeper, store_open: bool) {
	keeper^ = {}
	keeper.store_open = store_open
	keeper.kept_length, _ = chosen_values.write_record({}, {}, keeper.kept_bytes[:])
	keeper.pending_length, _ = chosen_values.write_record({}, {}, keeper.pending_bytes[:])
}

// pending_count gives the changes that wait for the end of the read.
pending_count :: proc "contextless" (keeper: ^Keeper) -> int {
	record, _ := chosen_values.read_record(keeper.pending_bytes[:keeper.pending_length])
	return record.count + keeper.reset_count
}

// pending_changes writes the changes of before the read into changes: the
// values chosen, with their texts in the bytes of the keeper, then the
// resets. It gives their count.
@(private = "file")
pending_changes :: proc "contextless" (keeper: ^Keeper, changes: ^[2 * PENDING_CAPACITY]chosen_values.Change) -> int {
	record, _ := chosen_values.read_record(keeper.pending_bytes[:keeper.pending_length])
	count := 0
	for index in 0 ..< min(record.count, PENDING_CAPACITY) {
		name := chosen_values.entry_name(record, index)
		switch chosen_values.entry_kind(record, index) {
		case .Word:
			changes[count] = {name = name, kind = .Choose, value = chosen_values.entry_value(record, index)}
		case .Text:
			changes[count] = {name = name, kind = .Choose_Text, text = chosen_values.entry_text(record, index)}
		}
		count += 1
	}
	for index in 0 ..< keeper.reset_count {
		changes[count] = {name = string(keeper.resets[index][:keeper.reset_lengths[index]]), kind = .Reset}
		count += 1
	}
	return count
}

// keeper_record gives the record in force. It holds bytes of the keeper:
// read it before the next change.
keeper_record :: proc "contextless" (keeper: ^Keeper) -> chosen_values.Record {
	record, _ := chosen_values.read_record(keeper.kept_bytes[:keeper.kept_length])
	return record
}

// keeper_next_job gives the job to ask for when none runs: the read once
// the owner wants it, then a write of each record that the store does not
// hold. None: nothing to ask.
keeper_next_job :: proc "contextless" (keeper: ^Keeper) -> Job {
	if !keeper.store_open || keeper.job != .None {
		return .None
	}
	if !keeper.read {
		if !keeper.read_wanted {
			return .None
		}
		keeper.job = .Read
		return .Read
	}
	if !keeper.dirty {
		return .None
	}
	keeper.dirty = false
	copy(keeper.job_bytes[:], keeper.kept_bytes[:keeper.kept_length])
	keeper.job_length = keeper.kept_length
	keeper.job = .Write
	return .Write
}

// keeper_job_refused takes back a job that the worker did not take: it is
// asked again at the next step.
keeper_job_refused :: proc "contextless" (keeper: ^Keeper) {
	if keeper.job == .Write {
		keeper.dirty = true
	}
	keeper.job = .None
}

// keeper_read_ended takes the end of the read: length bytes of job_bytes,
// found when the store holds the object, stored when the store answered.
// The changes that came before go on the record that the store gave.
keeper_read_ended :: proc "contextless" (keeper: ^Keeper, length: int, found: bool, stored: bool) -> (fault: Fault) {
	keeper.job = .None
	keeper.read = true
	pending: [2 * PENDING_CAPACITY]chosen_values.Change
	count := pending_changes(keeper, &pending)
	defer {
		keeper.pending_length, _ = chosen_values.write_record({}, {}, keeper.pending_bytes[:])
		keeper.reset_count = 0
	}
	if !stored {
		// A record that the store did not give is never written over in this
		// run: the next start reads it again.
		keeper.store_open = false
		return .Not_Read
	}
	base: chosen_values.Record
	if found {
		if length < 0 || length > KEPT_RECORD_BYTES {
			keeper.problem = .No_Room
			fault = .Unreadable
		} else if record, problem := chosen_values.read_record(keeper.job_bytes[:length]); problem != .None {
			keeper.problem = problem
			fault = .Unreadable
		} else {
			base = record
		}
	}
	if fault == .Unreadable && count == 0 {
		// Nothing of this run goes over a record that this release cannot
		// read: the defaults hold, and no write is asked.
		keeper.kept_length, _ = chosen_values.write_record({}, {}, keeper.kept_bytes[:])
		return fault
	}
	// A change of the principal starts a new record over one that this
	// release cannot read: the principal acted.
	written, problem := chosen_values.write_record(base, pending[:count], keeper.scratch_bytes[:])
	if problem != .None {
		// The record of the store has no room for the changes of before: it
		// holds, and those changes are lost.
		written, _ = chosen_values.write_record(base, {}, keeper.scratch_bytes[:])
	}
	copy(keeper.kept_bytes[:], keeper.scratch_bytes[:written])
	keeper.kept_length = written
	keeper.dirty = count > 0 && problem == .None
	return fault
}

// keeper_write_ended takes the end of a write.
keeper_write_ended :: proc "contextless" (keeper: ^Keeper, stored: bool) -> Fault {
	keeper.job = .None
	return stored ? .None : .Not_Kept
}

// keeper_change makes changes hold at once, and has the keeper keep them.
// The owner checked each word at its border. Before the read ends, the
// changes wait to go on the record that the store gives.
keeper_change :: proc "contextless" (keeper: ^Keeper, changes: []chosen_values.Change) -> Change_Result {
	if !keeper.store_open {
		return .No_Store
	}
	return keeper_change_for_this_run(keeper, changes)
}

// keeper_change_for_this_run makes changes hold, with a store or not: a
// press of the principal on the desktop holds for this run even when
// nothing keeps it.
keeper_change_for_this_run :: proc "contextless" (keeper: ^Keeper, changes: []chosen_values.Change) -> Change_Result {
	written, problem := chosen_values.write_record(keeper_record(keeper), changes, keeper.scratch_bytes[:])
	if problem != .None {
		return .No_Room
	}
	if keeper.store_open && !keeper.read && !pending_take(keeper, changes) {
		return .No_Room
	}
	copy(keeper.kept_bytes[:], keeper.scratch_bytes[:written])
	keeper.kept_length = written
	keeper.dirty = keeper.store_open && keeper.read
	return .Taken
}

// pending_take keeps changes of before the read in the memory of the
// keeper: a choice goes on the pending record and leaves the resets, a
// reset leaves the record and joins the resets. false: no room, and nothing
// changed.
@(private = "file")
pending_take :: proc "contextless" (keeper: ^Keeper, changes: []chosen_values.Change) -> bool {
	resets, reset_lengths, reset_count := keeper.resets, keeper.reset_lengths, keeper.reset_count
	record_changes: [PENDING_CAPACITY]chosen_values.Change
	if len(changes) > PENDING_CAPACITY {
		return false
	}
	for change, index in changes {
		// A reset is a removal from the pending record; a choice is itself.
		record_changes[index] = change
		place := -1
		for reset in 0 ..< reset_count {
			if string(resets[reset][:reset_lengths[reset]]) == change.name {
				place = reset
			}
		}
		switch change.kind {
		case .Reset:
			if place < 0 {
				if reset_count == PENDING_CAPACITY || len(change.name) >= chosen_values.NAME_SIZE {
					return false
				}
				copy(resets[reset_count][:], change.name)
				reset_lengths[reset_count] = u8(len(change.name))
				reset_count += 1
			}
		case .Choose, .Choose_Text:
			if place >= 0 {
				resets[place], reset_lengths[place] = resets[reset_count - 1], reset_lengths[reset_count - 1]
				reset_count -= 1
			}
		}
	}
	pending, _ := chosen_values.read_record(keeper.pending_bytes[:keeper.pending_length])
	written, problem := chosen_values.write_record(pending, record_changes[:len(changes)], keeper.pending_scratch[:])
	if problem != .None {
		return false
	}
	after, _ := chosen_values.read_record(keeper.pending_scratch[:written])
	if after.count > PENDING_CAPACITY {
		return false
	}
	copy(keeper.pending_bytes[:], keeper.pending_scratch[:written])
	keeper.pending_length = written
	keeper.resets, keeper.reset_lengths, keeper.reset_count = resets, reset_lengths, reset_count
	return true
}

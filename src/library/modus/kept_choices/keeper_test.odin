#+build !freestanding
#+build !modus
package kept_choices

import "core:fmt"
import "core:testing"
import "modus:contract/chosen_values"

// stored_record writes a record of chosen values into the bytes of the job,
// as the store gives it, and gives its length.
@(private = "file")
stored_record :: proc(keeper: ^Keeper, changes: []chosen_values.Change) -> int {
	written, _ := chosen_values.write_record({}, changes, keeper.job_bytes[:])
	return written
}

@(private = "file")
value_of :: proc(keeper: ^Keeper, name: string) -> (u64, bool) {
	return chosen_values.find(keeper_record(keeper), name)
}

// A read that the store refused, a length past the bytes of the job or
// below zero, and bytes that are no record: each keeps the record of the
// store as it is, and asks for no write until the principal acts.
@(test)
a_read_that_cannot_be_taken_writes_nothing :: proc(t: ^testing.T) {
	keeper: Keeper
	keeper_start(&keeper, true)
	testing.expect_value(t, keeper_next_job(&keeper), Job.None)
	keeper.read_wanted = true
	testing.expect_value(t, keeper_next_job(&keeper), Job.Read)
	testing.expect_value(t, keeper_next_job(&keeper), Job.None)
	testing.expect_value(t, keeper_read_ended(&keeper, 0, false, false), Fault.Not_Read)
	testing.expect(t, !keeper.store_open && !keeper.dirty)
	testing.expect_value(t, keeper_change(&keeper, {{name = "font", kind = .Choose, value = 1}}), Change_Result.No_Store)
	testing.expect_value(t, keeper_next_job(&keeper), Job.None)
	for length in ([?]int{-1, KEPT_RECORD_BYTES + 1, max(int)}) {
		keeper_start(&keeper, true)
		keeper.read_wanted = true
		_ = keeper_next_job(&keeper)
		testing.expectf(t, keeper_read_ended(&keeper, length, true, true) == .Unreadable, "a length of %d is read", length)
		testing.expect_value(t, keeper_next_job(&keeper), Job.None)
		testing.expect_value(t, keeper_record(&keeper).count, 0)
	}
	keeper_start(&keeper, true)
	keeper.read_wanted = true
	_ = keeper_next_job(&keeper)
	keeper.job_bytes[0] = 'x'
	testing.expect_value(t, keeper_read_ended(&keeper, chosen_values.HEADER_SIZE, true, true), Fault.Unreadable)
	testing.expect_value(t, keeper.problem, chosen_values.Record_Problem.Bad_Magic)
	testing.expect_value(t, keeper_next_job(&keeper), Job.None)
	// A change of the principal then starts a new record.
	testing.expect_value(t, keeper_change(&keeper, {{name = "font", kind = .Choose, value = 2}}), Change_Result.Taken)
	testing.expect_value(t, keeper_next_job(&keeper), Job.Write)
	record, problem := chosen_values.read_record(keeper.job_bytes[:keeper.job_length])
	value, found := chosen_values.find(record, "font")
	testing.expect(t, problem == .None && found && value == 2 && record.count == 1)
}

// The changes before the read: the last change of a name holds, a reset
// removes the value that the store gave, a name that the keeper does not
// know stays as the store gave it, and one name past the room of the
// changes is refused with nothing changed.
@(test)
the_changes_before_the_read_go_on_the_record_of_the_store :: proc(t: ^testing.T) {
	keeper: Keeper
	keeper_start(&keeper, true)
	testing.expect_value(t, keeper_change(&keeper, {{name = "font", kind = .Choose, value = 1}}), Change_Result.Taken)
	testing.expect_value(t, keeper_change(&keeper, {{name = "font", kind = .Choose, value = 3}, {name = "scale", kind = .Reset}}), Change_Result.Taken)
	value, found := value_of(&keeper, "font")
	testing.expect(t, found && value == 3)
	testing.expect_value(t, pending_count(&keeper), 2)
	testing.expect_value(t, keeper_next_job(&keeper), Job.None)
	keeper.read_wanted = true
	testing.expect_value(t, keeper_next_job(&keeper), Job.Read)
	length := stored_record(&keeper, {{name = "scale", kind = .Choose, value = 16}, {name = "later_field", kind = .Choose, value = 9}, {name = "font", kind = .Choose, value = 0}})
	testing.expect_value(t, keeper_read_ended(&keeper, length, true, true), Fault.None)
	value, found = value_of(&keeper, "font")
	testing.expect(t, found && value == 3)
	_, found = value_of(&keeper, "scale")
	testing.expect(t, !found)
	value, found = value_of(&keeper, "later_field")
	testing.expect(t, found && value == 9)
	testing.expect_value(t, keeper_next_job(&keeper), Job.Write)
	testing.expect_value(t, keeper_write_ended(&keeper, false), Fault.Not_Kept)
	testing.expect_value(t, keeper_next_job(&keeper), Job.None)

	keeper_start(&keeper, true)
	names: [PENDING_CAPACITY + 1]string
	for index in 0 ..< PENDING_CAPACITY + 1 {
		names[index] = fmt.tprintf("name_%d", index)
	}
	for index in 0 ..< PENDING_CAPACITY {
		testing.expect_value(t, keeper_change(&keeper, {{name = names[index], kind = .Choose, value = u64(index)}}), Change_Result.Taken)
	}
	before := keeper.kept_length
	testing.expect_value(t, keeper_change(&keeper, {{name = names[PENDING_CAPACITY], kind = .Choose, value = 1}}), Change_Result.No_Room)
	testing.expect(t, keeper.kept_length == before && pending_count(&keeper) == PENDING_CAPACITY)
	_, found = value_of(&keeper, names[PENDING_CAPACITY])
	testing.expect(t, !found)
	// A name already waiting takes its place again.
	testing.expect_value(t, keeper_change(&keeper, {{name = names[0], kind = .Choose, value = 7}}), Change_Result.Taken)
}

// A change that the record refuses (a name not valid, a name twice, a
// record with no room) changes nothing; a change for this run holds with no
// store and asks for no write; a write that the worker did not take is
// asked again.
@(test)
a_refused_change_changes_nothing :: proc(t: ^testing.T) {
	keeper: Keeper
	keeper_start(&keeper, true)
	keeper.read_wanted = true
	_ = keeper_next_job(&keeper)
	testing.expect_value(t, keeper_read_ended(&keeper, 0, false, true), Fault.None)
	testing.expect_value(t, keeper_next_job(&keeper), Job.None)
	for changes in ([?][]chosen_values.Change{{{name = "", kind = .Choose}}, {{name = "Font", kind = .Choose}}, {{name = "font", kind = .Choose}, {name = "font", kind = .Reset}}, {{name = "font", kind = Change_Kind_None}}}) {
		testing.expect_value(t, keeper_change(&keeper, changes), Change_Result.No_Room)
		testing.expect(t, keeper_record(&keeper).count == 0 && !keeper.dirty)
	}
	count := 0
	for {
		name := fmt.tprintf("n%d", count)
		if keeper_change(&keeper, {{name = name, kind = .Choose, value = 1}}) != .Taken {
			break
		}
		count += 1
		testing.expect(t, count <= KEPT_RECORD_BYTES / chosen_values.ENTRY_SIZE)
	}
	testing.expect_value(t, count, (KEPT_RECORD_BYTES - chosen_values.HEADER_SIZE) / chosen_values.ENTRY_SIZE)
	testing.expect_value(t, keeper_next_job(&keeper), Job.Write)
	keeper_job_refused(&keeper)
	testing.expect_value(t, keeper_next_job(&keeper), Job.Write)
	testing.expect_value(t, keeper_write_ended(&keeper, true), Fault.None)
	testing.expect_value(t, keeper_next_job(&keeper), Job.None)

	keeper_start(&keeper, false)
	testing.expect_value(t, keeper_change(&keeper, {{name = "font", kind = .Choose, value = 1}}), Change_Result.No_Store)
	testing.expect_value(t, keeper_change_for_this_run(&keeper, {{name = "font", kind = .Choose, value = 1}}), Change_Result.Taken)
	value, found := value_of(&keeper, "font")
	testing.expect(t, found && value == 1 && !keeper.dirty)
	keeper.read_wanted = true
	testing.expect_value(t, keeper_next_job(&keeper), Job.None)
}

// A text of a change before the read lives in the keeper: the bytes of the
// call change after it, and the record of the read holds the text of the
// call. A reset and then a choice of one name hold as the choice; a choice
// and then a reset hold as the reset, which removes the value of the store.
@(test)
a_text_before_the_read_is_copied_and_the_last_change_of_a_name_holds :: proc(t: ^testing.T) {
	keeper := new(Keeper, context.temp_allocator)
	keeper_start(keeper, true)
	call_bytes := [?]u8{'m', 'o', 'd', 'u', 's', ':', '/', '/', 'g', 'u', 'i', 'd', 'e'}
	testing.expect_value(t, keeper_change(keeper, {{name = "home", kind = .Choose_Text, text = string(call_bytes[:])}}), Change_Result.Taken)
	testing.expect_value(t, keeper_change(keeper, {{name = "font", kind = .Reset}}), Change_Result.Taken)
	testing.expect_value(t, keeper_change(keeper, {{name = "font", kind = .Choose, value = 2}}), Change_Result.Taken)
	testing.expect_value(t, keeper_change(keeper, {{name = "scale", kind = .Choose, value = 9}}), Change_Result.Taken)
	testing.expect_value(t, keeper_change(keeper, {{name = "scale", kind = .Reset}}), Change_Result.Taken)
	for &byte in call_bytes {
		byte = 'x'
	}
	testing.expect_value(t, pending_count(keeper), 3)
	keeper.read_wanted = true
	_ = keeper_next_job(keeper)
	length := stored_record(keeper, {{name = "scale", kind = .Choose, value = 16}, {name = "font", kind = .Choose, value = 1}, {name = "home", kind = .Choose_Text, text = "modus://forms"}})
	testing.expect_value(t, keeper_read_ended(keeper, length, true, true), Fault.None)
	home, home_found := chosen_values.find_text(keeper_record(keeper), "home")
	testing.expect(t, home_found && home == "modus://guide")
	font, font_found := value_of(keeper, "font")
	testing.expect(t, font_found && font == 2)
	testing.expect(t, !chosen_values.contains(keeper_record(keeper), "scale"))
	testing.expect_value(t, pending_count(keeper), 0)
	// A text past the bound of the record, or not UTF-8, changes nothing.
	long := make([]u8, chosen_values.TEXT_BYTES_MOST + 1, context.temp_allocator)
	for &byte in long {
		byte = 'a'
	}
	before := keeper.kept_length
	testing.expect_value(t, keeper_change(keeper, {{name = "home", kind = .Choose_Text, text = string(long)}}), Change_Result.No_Room)
	testing.expect_value(t, keeper_change(keeper, {{name = "home", kind = .Choose_Text, text = "\xff"}}), Change_Result.No_Room)
	testing.expect_value(t, keeper.kept_length, before)
}

@(private = "file")
Change_Kind_None :: chosen_values.Change_Kind(0)

// A job that the worker refused waits to be asked again: a refused read
// and a refused write are each wanted, and asked again whole; with no
// store, with a job that runs, or with nothing to do, no job is wanted.
@(test)
a_refused_job_is_asked_again :: proc(t: ^testing.T) {
	keeper: Keeper
	keeper_start(&keeper, false)
	keeper.read_wanted = true
	testing.expect(t, !keeper_job_wanted(&keeper))
	keeper_start(&keeper, true)
	testing.expect(t, !keeper_job_wanted(&keeper))
	keeper.read_wanted = true
	testing.expect(t, keeper_job_wanted(&keeper))
	testing.expect_value(t, keeper_next_job(&keeper), Job.Read)
	testing.expect(t, !keeper_job_wanted(&keeper))
	keeper_job_refused(&keeper)
	testing.expect(t, keeper_job_wanted(&keeper))
	testing.expect_value(t, keeper_next_job(&keeper), Job.Read)
	testing.expect_value(t, keeper_read_ended(&keeper, 0, false, true), Fault.None)
	testing.expect(t, !keeper_job_wanted(&keeper))
	testing.expect_value(t, keeper_change(&keeper, {{name = "font", kind = .Choose, value = 1}}), Change_Result.Taken)
	testing.expect(t, keeper_job_wanted(&keeper))
	testing.expect_value(t, keeper_next_job(&keeper), Job.Write)
	length := keeper.job_length
	keeper_job_refused(&keeper)
	testing.expect(t, keeper_job_wanted(&keeper) && keeper.dirty)
	testing.expect_value(t, keeper_next_job(&keeper), Job.Write)
	testing.expect_value(t, keeper.job_length, length)
}

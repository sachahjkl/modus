#+build !freestanding
#+build !modus
package system

import "core:slice"
import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/ring"

// The kernel ring of these cases: the smallest ring, in memory of the test.
@(private = "file")
kernel_ring_memory :: proc() -> []u64 {
	return make([]u64, ring.PAGE_COUNT * ring.PAGE_SIZE / size_of(u64))
}

@(private = "file")
kernel_ring_of :: proc(t: ^testing.T, memory: []u64) -> ring.Ring {
	kernel, opened := ring.open(raw_data(memory), ring.PAGE_COUNT)
	testing.expect(t, opened)
	return kernel
}

// A command whose every field is set, so a field that the push lost or
// changed shows.
@(private = "file")
TEST_COMMAND :: ring.Record {
	kind   = u32(op.Operation.Memory_Size),
	tag    = max(u32),
	values = {1, 2, 3, 4, 5, 6, 7},
}

// A batch that commands_call must refuse writes nothing: no command, one
// past the capacity of the ring, the largest count, completions with one
// place less than the batch, and none. Each refusal has its record.
@(test)
kernel_commands_push_refuses_a_batch_that_does_not_fit :: proc(t: ^testing.T) {
	commands: [ring.CAPACITY + 1]ring.Record
	for &command in commands {
		command = TEST_COMMAND
	}
	Batch :: struct {
		count, places: int,
		kind:          errors.Kind,
		argument:      i64,
		value, limit:  i64,
	}
	refused_batches := [?]Batch {
		{count = 0, places = 1, kind = .Too_Small, argument = 1, value = 0, limit = 1},
		{count = ring.CAPACITY + 1, places = ring.CAPACITY + 1, kind = .Too_Long, argument = 1, value = ring.CAPACITY + 1, limit = ring.CAPACITY},
		{count = 2, places = 1, kind = .Too_Small, argument = 2, value = 1, limit = 2},
		{count = 1, places = 0, kind = .Too_Small, argument = 2, value = 0, limit = 1},
	}
	for batch in refused_batches {
		memory := kernel_ring_memory()
		defer delete(memory)
		kernel := kernel_ring_of(t, memory)
		error: errors.Error_Record
		first_tag, push_outcome := kernel_commands_push(&kernel, commands[:batch.count], batch.places, &error)
		testing.expectf(t, push_outcome == .Argument_Refused, "a batch of %v commands with %v places gives %v", batch.count, batch.places, push_outcome)
		testing.expect_value(t, first_tag, 0)
		testing.expect(t, ring.empty(&kernel.commands), "a refused batch writes a command")
		testing.expect_value(t, error.kind, i64(batch.kind))
		testing.expect_value(t, error.unit, i64(errors.Unit.Records))
		testing.expect_value(t, error.argument, batch.argument)
		testing.expect_value(t, error.value, batch.value)
		testing.expect_value(t, error.limit, batch.limit)
	}
}

// A kernel ring that holds a record refuses the push of commands_call, and
// nothing is written: a command that waits (it would run first and its
// answer would come first), a completion that waits (one), a completion
// queue at its capacity (a held command would follow), and counters that
// another thread of the process wrote false. The refusal is the record
// Busy with the records that wait, counted at most at the capacity.
@(test)
kernel_commands_push_refuses_a_ring_that_holds_a_record :: proc(t: ^testing.T) {
	Held :: struct {
		command_write, command_read, completion_write, completion_read: u32,
		waiting:                                                           i64,
	}
	held_cases := [?]Held {
		{command_write = 1, waiting = 1}, // One command that waits.
		{completion_write = 1, waiting = 1}, // One completion that waits.
		{completion_write = ring.CAPACITY, waiting = ring.CAPACITY}, // A full completion queue.
		{command_write = 1, completion_write = ring.CAPACITY, waiting = ring.CAPACITY + 1}, // A held command behind a full queue.
		{completion_read = 1, waiting = ring.CAPACITY}, // The read one past the write: a false count.
		{command_write = max(u32), waiting = ring.CAPACITY}, // The largest distance: a false count.
	}
	commands := [1]ring.Record{TEST_COMMAND}
	for held in held_cases {
		memory := kernel_ring_memory()
		defer delete(memory)
		kernel := kernel_ring_of(t, memory)
		kernel.head.commands.write = held.command_write
		kernel.head.commands.read = held.command_read
		kernel.head.completions.write = held.completion_write
		kernel.head.completions.read = held.completion_read
		before := slice.clone(memory)
		defer delete(before)
		error: errors.Error_Record
		first_tag, push_outcome := kernel_commands_push(&kernel, commands[:], len(commands), &error)
		testing.expectf(t, push_outcome == .Callee_Busy, "a ring with %v records that wait gives %v", held.waiting, push_outcome)
		testing.expect_value(t, first_tag, 0)
		testing.expect(t, slice.equal(before, memory), "a refused push writes no byte of the ring")
		testing.expect_value(t, error.kind, i64(errors.Kind.Busy))
		testing.expect_value(t, error.unit, i64(errors.Unit.Requests))
		testing.expect_value(t, error.operation, i64(op.Operation.Memory_Size))
		testing.expect_value(t, error.value, held.waiting)
		testing.expect_value(t, error.limit, 0)
	}
	// With no error record, the refusal is the same and writes nothing.
	memory := kernel_ring_memory()
	defer delete(memory)
	kernel := kernel_ring_of(t, memory)
	kernel.head.completions.write = 1
	before := slice.clone(memory)
	defer delete(before)
	_, push_outcome := kernel_commands_push(&kernel, commands[:], len(commands), nil)
	testing.expect_value(t, push_outcome, call_outcome.Call_Outcome.Callee_Busy)
	testing.expect(t, slice.equal(before, memory), "a refused push with no error record writes no byte")
}

// The answers of a batch are the completions with the tags of its
// commands, in their order: no completion, a completion of another tag
// (one less, one more, 0, the largest tag), the tag in another field, and
// the two answers of a batch in the wrong order are refused, with the
// record Refused that names the operation with no bit of the table of error
// details.
@(test)
kernel_completions_take_refuses_an_answer_that_is_not_its_own :: proc(t: ^testing.T) {
	FIRST_TAG :: u32(7)
	command := TEST_COMMAND
	command.kind |= op.COMMAND_NAMES_ERROR_DETAILS
	one := [1]ring.Record{command}
	{
		memory := kernel_ring_memory()
		defer delete(memory)
		kernel := kernel_ring_of(t, memory)
		error: errors.Error_Record
		completions: [1]ring.Record
		taken := kernel_completions_take(&kernel, FIRST_TAG, one[:], completions[:], &error)
		testing.expect(t, !taken, "an empty completion queue gives an answer")
		testing.expect_value(t, completions[0], ring.Record{})
		testing.expect_value(t, error.kind, i64(errors.Kind.Refused))
		testing.expect_value(t, error.operation, i64(op.Operation.Memory_Size))
		testing.expect_value(t, error.found, i64(call_outcome.Call_Outcome.Answer_Unreadable))
	}
	other_tags := [?]u32{FIRST_TAG - 1, FIRST_TAG + 1, 0, max(u32)}
	for other in other_tags {
		memory := kernel_ring_memory()
		defer delete(memory)
		kernel := kernel_ring_of(t, memory)
		// The tag of the command in a value, not in the tag: still not its answer.
		testing.expect(t, ring.push(&kernel.completions, ring.Record{tag = other, values = {0 = u64(FIRST_TAG)}}))
		error: errors.Error_Record
		completions: [1]ring.Record
		taken := kernel_completions_take(&kernel, FIRST_TAG, one[:], completions[:], &error)
		testing.expectf(t, !taken, "the tag %v is taken as the tag %v", other, FIRST_TAG)
		testing.expect_value(t, completions[0], ring.Record{})
		testing.expect_value(t, error.kind, i64(errors.Kind.Refused))
	}
	{
		memory := kernel_ring_memory()
		defer delete(memory)
		kernel := kernel_ring_of(t, memory)
		testing.expect(t, ring.push(&kernel.completions, ring.Record{tag = FIRST_TAG + 1}))
		testing.expect(t, ring.push(&kernel.completions, ring.Record{tag = FIRST_TAG}))
		two := [2]ring.Record{command, command}
		error: errors.Error_Record
		completions: [2]ring.Record
		taken := kernel_completions_take(&kernel, FIRST_TAG, two[:], completions[:], &error)
		testing.expect(t, !taken, "two answers in the wrong order are taken")
		testing.expect_value(t, error.kind, i64(errors.Kind.Refused))
	}
}

// stop_step on a ring that does not empty: completion counters that the
// process wrote false (the read one past the write, one past the capacity)
// stop by a fault at once, with the counters as they were; held commands
// past the bound of the rounds (the capacity, the largest round) stop by a
// fault, also with command counters that the kernel refuses to read, which
// no entry empties.
@(test)
stop_step_stops_by_a_fault_when_the_ring_does_not_empty :: proc(t: ^testing.T) {
	Counts :: struct {
		command_write, command_read, completion_write, completion_read: u32,
		round:                                                             int,
	}
	fault_cases := [?]Counts {
		{completion_write = 0, completion_read = 1}, // The read one past the write.
		{completion_write = ring.CAPACITY + 1}, // One past the capacity.
		{command_write = 1, completion_write = ring.CAPACITY + 1}, // A held command behind false completion counters.
		{command_write = 1, round = ring.CAPACITY}, // The bound of the rounds.
		{command_write = 1, round = max(int)},
		{command_write = max(u32), round = ring.CAPACITY}, // Command counters that the kernel refuses: no entry empties them.
	}
	for counts in fault_cases {
		memory := kernel_ring_memory()
		defer delete(memory)
		kernel := kernel_ring_of(t, memory)
		kernel.head.commands.write = counts.command_write
		kernel.head.commands.read = counts.command_read
		kernel.head.completions.write = counts.completion_write
		kernel.head.completions.read = counts.completion_read
		step := stop_step(&kernel, counts.round)
		testing.expectf(t, step == .Stop_By_Fault, "%v at round %v gives %v", counts, counts.round, step)
		testing.expect_value(t, kernel.head.commands.write, counts.command_write)
		testing.expect_value(t, kernel.head.commands.read, counts.command_read)
	}
	// Below the bound, the same false command counters ask for an entry:
	// the bound, not the counters, ends the rounds.
	memory := kernel_ring_memory()
	defer delete(memory)
	kernel := kernel_ring_of(t, memory)
	kernel.head.commands.write = max(u32)
	testing.expect_value(t, stop_step(&kernel, ring.CAPACITY - 1), Stop_Step.Enter_For_Held_Commands)
}

// The successful cases last. stop_step drops each completion that waits
// (one, the capacity) and, with no command, sends the stop; with held
// commands, it asks for an entry from round 0 to the last round below the
// bound, and leaves the commands as they were for the kernel.
@(test)
stop_step_drops_the_completions_then_runs_the_held_commands :: proc(t: ^testing.T) {
	for completions in ([?]u32{0, 1, ring.CAPACITY}) {
		memory := kernel_ring_memory()
		defer delete(memory)
		kernel := kernel_ring_of(t, memory)
		kernel.head.completions.write = completions
		step := stop_step(&kernel, 0)
		testing.expectf(t, step == .Send_Stop, "%v completions give %v", completions, step)
		testing.expect_value(t, kernel.head.completions.read, completions)
		testing.expect(t, ring.empty(&kernel.commands), "a step wrote a command")
	}
	for round in ([?]int{0, ring.CAPACITY - 1}) {
		memory := kernel_ring_memory()
		defer delete(memory)
		kernel := kernel_ring_of(t, memory)
		testing.expect(t, ring.push(&kernel.commands, TEST_COMMAND))
		kernel.head.completions.write = ring.CAPACITY
		step := stop_step(&kernel, round)
		testing.expectf(t, step == .Enter_For_Held_Commands, "a held command at round %v gives %v", round, step)
		testing.expect(t, ring.empty(&kernel.completions), "the completions are not dropped")
		testing.expect_value(t, ring.count(&kernel.commands), 1)
		testing.expect_value(t, kernel.commands.records[0], TEST_COMMAND)
	}
}

// What wait_end pushes: the command Word_Wait with the address of its list
// and the count of its words, at the edges 0, 1 and the capacity.
@(test)
wait_command_names_the_list_and_its_count :: proc(t: ^testing.T) {
	words := make([]op.Word, op.WORD_WAIT_MOST)
	defer delete(words)
	for count in ([?]int{0, 1, op.WORD_WAIT_INLINE, op.WORD_WAIT_MOST}) {
		command := wait_command(words[:count])
		testing.expect_value(t, command.kind, u32(op.Operation.Word_Wait))
		testing.expect_value(t, command.tag, 0)
		testing.expect_value(t, command.values[0], u64(uintptr(raw_data(words))))
		testing.expect_value(t, command.values[1], u64(count))
		for value in command.values[2:] {
			testing.expect_value(t, value, 0)
		}
	}
}

// The successful case last: a batch of one, then a batch of the capacity,
// into an empty ring writes each command with consecutive new tags and each
// other field as it was; the kernel answers each with its tag; the take
// gives the answers in order and leaves the ring empty. Two batches do not
// share a tag, so an old answer never matches a new command.
@(test)
kernel_commands_push_and_take_give_the_answer_of_each_command :: proc(t: ^testing.T) {
	memory := kernel_ring_memory()
	defer delete(memory)
	kernel := kernel_ring_of(t, memory)
	error: errors.Error_Record
	commands: [ring.CAPACITY]ring.Record
	for &command in commands {
		command = TEST_COMMAND
	}
	completions: [ring.CAPACITY]ring.Record
	last_tag_before: u32
	for count, round in ([?]int{1, ring.CAPACITY}) {
		first_tag, push_outcome := kernel_commands_push(&kernel, commands[:count], count, &error)
		testing.expectf(t, push_outcome == .Succeeded, "an empty ring refuses a batch of %v with %v", count, push_outcome)
		if round > 0 {
			testing.expect(t, first_tag > last_tag_before, "two batches share a tag")
		}
		last_tag_before = first_tag + u32(count) - 1
		for index in 0 ..< count {
			command, popped := ring.pop(&kernel.commands)
			testing.expect(t, popped)
			written := TEST_COMMAND
			written.tag = first_tag + u32(index)
			testing.expect_value(t, command, written)
			testing.expect(t, ring.push(&kernel.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = written.tag, values = {0 = u64(index)}}))
		}
		taken := kernel_completions_take(&kernel, first_tag, commands[:count], completions[:count], &error)
		testing.expect(t, taken, "the answers of the batch are refused")
		for index in 0 ..< count {
			testing.expect_value(t, completions[index].tag, first_tag + u32(index))
			testing.expect_value(t, completions[index].values[0], u64(index))
		}
		testing.expect(t, ring.empty(&kernel.commands) && ring.empty(&kernel.completions), "the ring is empty after the answers")
	}
	testing.expect_value(t, error, errors.Error_Record{})
}

#+build !freestanding
package system

import "core:slice"
import "core:testing"
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

// A kernel ring that holds a record refuses the push of command_call, and
// nothing is written: a command that waits (it would run first and its
// answer would come first), a completion that waits (one), a completion
// queue at its capacity (a held command would follow), and counters that
// another thread of the program wrote false. The refusal is the record
// Busy with the records that wait, counted at most at the capacity.
@(test)
kernel_command_push_refuses_a_ring_that_holds_a_record :: proc(t: ^testing.T) {
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
		tag, pushed := kernel_command_push(&kernel, TEST_COMMAND, &error)
		testing.expectf(t, !pushed, "a ring with %v records that wait takes a command", held.waiting)
		testing.expect_value(t, tag, 0)
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
	_, pushed := kernel_command_push(&kernel, TEST_COMMAND, nil)
	testing.expect(t, !pushed, "a ring with a completion takes a command with no error record")
	testing.expect(t, slice.equal(before, memory), "a refused push with no error record writes no byte")
}

// The answer of command_call is the completion with the tag of its
// command: no completion, a completion of another tag (one less, one more,
// 0, the largest tag), and the tag in another field are refused, with the
// record Refused that names the operation with no bit of the table of error
// details.
@(test)
kernel_completion_take_refuses_an_answer_that_is_not_its_own :: proc(t: ^testing.T) {
	TAG :: u32(7)
	kind := u32(op.Operation.Memory_Size) | op.COMMAND_NAMES_ERROR_DETAILS
	{
		memory := kernel_ring_memory()
		defer delete(memory)
		kernel := kernel_ring_of(t, memory)
		error: errors.Error_Record
		completion, taken := kernel_completion_take(&kernel, TAG, kind, &error)
		testing.expect(t, !taken, "an empty completion queue gives an answer")
		testing.expect_value(t, completion, ring.Record{})
		testing.expect_value(t, error.kind, i64(errors.Kind.Refused))
		testing.expect_value(t, error.operation, i64(op.Operation.Memory_Size))
		testing.expect_value(t, error.found, i64(Status.Bad_Operation))
	}
	other_tags := [?]u32{TAG - 1, TAG + 1, 0, max(u32)}
	for other in other_tags {
		memory := kernel_ring_memory()
		defer delete(memory)
		kernel := kernel_ring_of(t, memory)
		// The tag of the command in a value, not in the tag: still not its answer.
		testing.expect(t, ring.push(&kernel.completions, ring.Record{tag = other, values = {0 = u64(TAG)}}))
		error: errors.Error_Record
		completion, taken := kernel_completion_take(&kernel, TAG, kind, &error)
		testing.expectf(t, !taken, "the tag %v is taken as the tag %v", other, TAG)
		testing.expect_value(t, completion, ring.Record{})
		testing.expect_value(t, error.kind, i64(errors.Kind.Refused))
	}
}

// The successful case last: a push into an empty ring writes the command
// with a new tag and each other field as it was; the kernel answers it with
// that tag; the take gives the answer and leaves the ring empty. Two pushes
// give two tags, so an old answer never matches a new command.
@(test)
kernel_command_push_and_take_give_the_answer_of_the_command :: proc(t: ^testing.T) {
	memory := kernel_ring_memory()
	defer delete(memory)
	kernel := kernel_ring_of(t, memory)
	error: errors.Error_Record
	first_tag: u32
	for round in 0 ..< 2 {
		tag, pushed := kernel_command_push(&kernel, TEST_COMMAND, &error)
		testing.expect(t, pushed, "an empty ring refuses a command")
		if round == 0 {
			first_tag = tag
		} else {
			testing.expect(t, tag != first_tag, "two commands have one tag")
		}
		command, popped := ring.pop(&kernel.commands)
		testing.expect(t, popped)
		written := TEST_COMMAND
		written.tag = tag
		testing.expect_value(t, command, written)
		answer := ring.Record{kind = u32(Status.Ok), tag = tag, values = {0 = 9}}
		testing.expect(t, ring.push(&kernel.completions, answer))
		completion, taken := kernel_completion_take(&kernel, tag, TEST_COMMAND.kind, &error)
		testing.expect(t, taken, "the answer of the command is refused")
		testing.expect_value(t, completion, answer)
		testing.expect(t, ring.empty(&kernel.commands) && ring.empty(&kernel.completions), "the ring is empty after the answer")
	}
	testing.expect_value(t, error, errors.Error_Record{})
}

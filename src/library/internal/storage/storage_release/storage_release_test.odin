#+build !freestanding
package storage_release

import "base:runtime"
import "core:testing"
import format "modus:contract/store"

// An object in memory: its nodes, the counts of names that the last commit
// left, and the changes of the step in progress.
@(private = "file")
Test_Object :: struct {
	using releaser: Releaser,
	nodes_of: map[u64]Object_Node,
	counts:   map[u64]i64,
	changes:  map[u64]i64,
	broken:   map[u64]bool, // A read of these fails on the device.
	next:     u64, // The next block of a node.
}

@(private = "file")
test_count_after :: proc "contextless" (releaser: ^Releaser, number: u64) -> i64 {
	object := (^Test_Object)(releaser)
	context = runtime.default_context()
	return (object.counts[number] or_else 0) + (object.changes[number] or_else 0)
}

@(private = "file")
test_drop :: proc "contextless" (releaser: ^Releaser, number: u64) {
	object := (^Test_Object)(releaser)
	context = runtime.default_context()
	object.changes[number] = (object.changes[number] or_else 0) - 1
}

@(private = "file")
test_drop_whole :: proc "contextless" (releaser: ^Releaser, child: Object_Child, level: int) {
	object := (^Test_Object)(releaser)
	test_drop(releaser, child.block)
	context = runtime.default_context()
	if level == 0 || test_count_after(releaser, child.block) != 0 {
		return
	}
	if object.broken[child.block] {
		object.device = true
		return
	}
	node := object.nodes_of[child.block]
	for item in node.children {
		if item.block != 0 {
			test_drop_whole(releaser, item, level - 1)
		}
	}
}

@(private = "file")
test_read_node :: proc "contextless" (releaser: ^Releaser, child: Object_Child, level: int, into: ^Object_Node) -> Read {
	object := (^Test_Object)(releaser)
	context = runtime.default_context()
	if object.broken[child.block] {
		return .Device
	}
	node, found := object.nodes_of[child.block]
	if !found || int(node.header.level) != level {
		return .Wrong
	}
	into^ = node
	return .Good
}

@(private = "file")
object_make :: proc() -> ^Test_Object {
	object := new(Test_Object)
	object.releaser = {count_after = test_count_after, drop = test_drop, drop_whole = test_drop_whole, read_node = test_read_node}
	object.next = 100
	return object
}

@(private = "file")
object_free :: proc(object: ^Test_Object) {
	delete(object.nodes_of)
	delete(object.counts)
	delete(object.changes)
	delete(object.broken)
	free(object)
}

// node_make makes a node of a level over \`count\` blocks of data from the
// data block \`first\`, the data block n at the block data_block(n), and
// gives its child; each block has one name.
@(private = "file")
node_make :: proc(object: ^Test_Object, level: int, first: u64, count: u64, data_block: proc(n: u64) -> u64) -> Object_Child {
	node: Object_Node
	node.header = {level = u32(level), magic = format.OBJECT_NODE_MAGIC}
	span := format.object_span(level - 1)
	blocks: u64 = 1
	for place in u64(0) ..< format.OBJECT_FANOUT {
		start := first + place * span
		if start >= first + count {
			break
		}
		if level == 1 {
			number := data_block(start)
			object.counts[number] = 1
			node.children[place] = {block = number, blocks = 1}
			blocks += 1
		} else {
			node.children[place] = node_make(object, level - 1, start, min(span, first + count - start), data_block)
			blocks += node.children[place].blocks
		}
	}
	number := object.next
	object.next += 1
	object.nodes_of[number] = node
	object.counts[number] = 1
	return {block = number, blocks = blocks}
}

// commit puts the changes of a step in the counts, and gives the leaves
// that they changed.
@(private = "file")
commit :: proc(t: ^testing.T, object: ^Test_Object) -> (leaves: int) {
	seen := make(map[u64]bool, context.temp_allocator)
	for number, change in object.changes {
		object.counts[number] = (object.counts[number] or_else 0) + change
		testing.expectf(t, object.counts[number] >= 0, "the block %d has a count below 0", number)
		seen[number / format.COUNTS_OF_A_PAGE] = true
	}
	clear(&object.changes)
	return len(seen)
}

// release_all runs steps until the state is free, each one committed, and
// checks the leaves of each step. crash_every: a step out of that many is
// lost, as a loss of power before its root, and runs again.
@(private = "file")
release_all :: proc(t: ^testing.T, object: ^Test_Object, root: Object_Child, size: u64, leaves: int, crash_every: int = 0) -> (steps: int) {
	cursor: u64
	for attempt := 1; ; attempt += 1 {
		saved := cursor
		done := step(object, {block = root.block}, size, &cursor, leaves)
		testing.expect(t, !object.device)
		if crash_every != 0 && attempt % crash_every == 0 {
			clear(&object.changes)
			cursor = saved
			continue
		}
		changed := commit(t, object)
		testing.expectf(t, changed <= leaves, "a step changed %d leaves, past its %d", changed, leaves)
		steps += 1
		if done {
			return steps
		}
		testing.expect(t, cursor > saved || changed > 0, "each step frees something")
		if steps > 100_000 {
			testing.fail_now(t, "the release does not end")
		}
	}
}

@(private = "file")
all_free :: proc(t: ^testing.T, object: ^Test_Object, label: string) {
	for number, count in object.counts {
		testing.expectf(t, count == 0, "%s: the block %d keeps %d names", label, number, count)
	}
}

// An object of 1000 blocks of data, each in a leaf of the count tree of its
// own: no step changes more leaves than its room, and the object is free.
@(test)
a_fragmented_object_is_freed_in_steps_of_its_leaves :: proc(t: ^testing.T) {
	object := object_make()
	defer object_free(object)
	spread :: proc(n: u64) -> u64 {return 1_000_000 + n * format.COUNTS_OF_A_PAGE}
	root := node_make(object, 2, 0, 1000, spread)
	steps := release_all(t, object, root, 1000 * format.BLOCK_SIZE, 256)
	testing.expect(t, steps >= 4, "1000 leaves in steps of 256")
	all_free(t, object, "fragmented")
}

// A loss of power before the root of some steps: the step runs again from
// the cursor of the last commit, and the end is the same.
@(test)
a_lost_step_runs_again :: proc(t: ^testing.T) {
	object := object_make()
	defer object_free(object)
	spread :: proc(n: u64) -> u64 {return 1_000_000 + n * format.COUNTS_OF_A_PAGE}
	root := node_make(object, 2, 0, 1000, spread)
	release_all(t, object, root, 1000 * format.BLOCK_SIZE, 100, crash_every = 3)
	all_free(t, object, "lost steps")
}

// A child of level 2 holds 4161 blocks: with a room of 64 leaves it does
// not go whole, and the step walks into it.
@(test)
a_child_of_level_two_is_walked_into :: proc(t: ^testing.T) {
	object := object_make()
	defer object_free(object)
	dense :: proc(n: u64) -> u64 {return 10_000_000 + n}
	whole := u64(format.OBJECT_FANOUT * format.OBJECT_FANOUT)
	root := node_make(object, 3, 0, whole + 10, dense)
	level_two := object.nodes_of[root.block].children[0]
	testing.expect_value(t, level_two.blocks, u64(whole + format.OBJECT_FANOUT + 1))
	release_all(t, object, root, (whole + 10) * format.BLOCK_SIZE, 64)
	all_free(t, object, "level two")
}

// A node that another state names too loses one name, and its children
// keep theirs; the root of a state of one block, and a shared root before
// any step, are one name.
@(test)
a_shared_node_and_the_edges_lose_one_name :: proc(t: ^testing.T) {
	object := object_make()
	defer object_free(object)
	dense :: proc(n: u64) -> u64 {return 20_000 + n}
	root := node_make(object, 2, 0, 200, dense)
	shared := object.nodes_of[root.block].children[1]
	object.counts[shared.block] = 2
	release_all(t, object, root, 200 * format.BLOCK_SIZE, 1024)
	testing.expect_value(t, object.counts[shared.block], i64(1))
	shared_node := object.nodes_of[shared.block]
	for item in shared_node.children {
		testing.expectf(t, object.counts[item.block] == 1, "a child of the shared node keeps its name")
	}

	one := object_make()
	defer object_free(one)
	one.counts[7] = 1
	cursor: u64
	testing.expect(t, step(one, {block = 7}, 10, &cursor, 4))
	testing.expect_value(t, test_count_after(one, 7), i64(0))

	shared_root := object_make()
	defer object_free(shared_root)
	top := node_make(shared_root, 1, 0, 10, dense)
	shared_root.counts[top.block] = 2
	cursor = 0
	testing.expect(t, step(shared_root, {block = top.block}, 10 * format.BLOCK_SIZE, &cursor, 4))
	testing.expect_value(t, test_count_after(shared_root, top.block), i64(1))
	testing.expect_value(t, test_count_after(shared_root, 20_000), i64(1))
}

// A read that fails on the device stops the step: it says so, and its
// commit is refused by its caller.
@(test)
a_failed_read_stops_the_step :: proc(t: ^testing.T) {
	object := object_make()
	defer object_free(object)
	dense :: proc(n: u64) -> u64 {return 30_000 + n}
	root := node_make(object, 2, 0, 200, dense)
	object.broken[object.nodes_of[root.block].children[2].block] = true
	cursor: u64
	testing.expect(t, !step(object, {block = root.block}, 200 * format.BLOCK_SIZE, &cursor, 1024))
	testing.expect(t, object.device)
	// A room of no leaf frees nothing.
	cursor = 0
	clear(&object.changes)
	delete_key(&object.broken, object.nodes_of[root.block].children[2].block)
	testing.expect(t, !step(object, {block = root.block}, 200 * format.BLOCK_SIZE, &cursor, 0))
	testing.expect_value(t, len(object.changes), 0)
	testing.expect_value(t, cursor, u64(0))
}

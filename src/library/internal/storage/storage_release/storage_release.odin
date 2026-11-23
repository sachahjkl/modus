package storage_release

// The release of a large state in steps (src/md/data/storage_capacity.md,
// "A large state is released in steps"): the walk of one step, from the
// block of data at the cursor, in the order of the blocks of data. The
// caller counts the names: this package reads nodes and says which name
// goes. A step stops at its bound of blocks and at its bound of leaves of
// the count tree, so that the pages of its commit fit the staging.

import format "modus:contract/store"

Object_Child :: format.Object_Child
Object_Node :: format.Object_Node
Pointer :: format.Pointer

// The outcome of a read of a node.
Read :: enum u8 {
	Good   = 0,
	Wrong  = 1, // A wrong check, a node of another kind or level, or a block that the service knows wrong.
	Device = 2,
}

// The names of the plan of the caller.
Releaser :: struct {
	// count_after gives the count of names of a block after the plan so far.
	count_after: proc "contextless" (releaser: ^Releaser, number: u64) -> i64,
	// drop counts one name less of a block.
	drop:        proc "contextless" (releaser: ^Releaser, number: u64),
	// drop_whole counts one name less of a node of a level, and walks under
	// each one that loses its last name, as a release of one commit. A read
	// that fails on the device sets device.
	drop_whole:  proc "contextless" (releaser: ^Releaser, child: Object_Child, level: int),
	// read_node reads a node of a level into \`into\`, with its checks.
	read_node:   proc "contextless" (releaser: ^Releaser, child: Object_Child, level: int, into: ^Object_Node) -> Read,
	data:        rawptr,
	// The bounds of a step and what it took.
	blocks_left: int, // The names that the step can still drop.
	leaves_left: int, // The leaves of the count tree that the step can still change.
	last_leaf:   u64,
	device:      bool, // A read failed on the device: the step stops, and its commit is refused.
	damaged:     u64, // Nodes that were wrong: their blocks stay in use until the next open.
	nodes:       [format.OBJECT_LEVEL_LIMIT + 1]Object_Node, // One node for each level of the walk.
}

// The blocks whose names one step frees, at most.
STEP_BLOCKS :: 65536

// step frees the next part of a state that the queue holds, from the block
// of data at the cursor, with at most \`leaves\` leaves of the count tree
// changed. It gives true when the state is free whole. A state of one
// block, and a state that another name holds too when no step started, is
// one name to drop.
step :: proc "contextless" (releaser: ^Releaser, root: Pointer, size: u64, cursor: ^u64, leaves: int) -> bool {
	releaser.blocks_left = STEP_BLOCKS
	releaser.leaves_left = leaves
	releaser.last_leaf = max(u64)
	releaser.device = false
	levels := format.object_levels(min(size, format.OBJECT_SIZE_LIMIT))
	if levels == 0 || cursor^ == 0 && releaser.count_after(releaser, root.block) > 1 {
		if !leaf_take(releaser, root.block, 1) {
			return false
		}
		releaser.drop(releaser, root.block)
		return true
	}
	return part(releaser, {block = root.block, check = root.check}, levels, 0, cursor)
}

// leaf_take takes the room of the leaves that a change of \`blocks\` names
// from a block can need: one leaf for one block in the leaf of the change
// before it, else one leaf for each block, at most.
@(private)
leaf_take :: proc "contextless" (releaser: ^Releaser, number: u64, blocks: u64) -> bool {
	leaf := number / format.COUNTS_OF_A_PAGE
	names := int(min(blocks, u64(max(int) / 2)))
	need := names
	if blocks == 1 && leaf == releaser.last_leaf {
		need = 0
	}
	if need > releaser.leaves_left || names > releaser.blocks_left {
		return false
	}
	releaser.leaves_left -= need
	releaser.blocks_left -= names
	releaser.last_leaf = leaf
	return true
}

// part frees the part of a node of a level from the cursor: the node has
// one name left, from its parent or from the queue, so each child under it
// that no other state names goes too. It gives true when the node is free
// whole.
@(private)
part :: proc "contextless" (releaser: ^Releaser, node_child: Object_Child, level: int, base: u64, cursor: ^u64) -> bool {
	span := format.object_span(level - 1)
	end := base + format.OBJECT_FANOUT * span
	// The room of the name of the node itself, taken first: when its last
	// child goes, its name goes in the same step.
	if !leaf_take(releaser, node_child.block, 1) {
		return false
	}
	node := &releaser.nodes[level]
	switch releaser.read_node(releaser, node_child, level, node) {
	case .Device:
		releaser.device = true
		return false
	case .Wrong:
		// The open did not count under a wrong block: its node loses its
		// name, and the blocks under it stay in use until the next open.
		releaser.damaged += 1
		releaser.drop(releaser, node_child.block)
		cursor^ = end
		return true
	case .Good:
	}
	// A deeper call reads into the node of its own level: the children of
	// this node stay in releaser.nodes[level].
	for place in 0 ..< format.OBJECT_FANOUT {
		item := node.children[place]
		child_base := base + u64(place) * span
		child_end := child_base + span
		if item.block == 0 || child_end <= cursor^ {
			continue
		}
		whole := child_base >= cursor^
		if level == 1 || whole && releaser.count_after(releaser, item.block) > 1 {
			// A block of data, or a node that another state names too: one
			// name, whatever its size.
			if !leaf_take(releaser, item.block, 1) {
				return false
			}
			releaser.drop(releaser, item.block)
			cursor^ = child_end
			continue
		}
		if whole && leaf_take(releaser, item.block, max(item.blocks, 1)) {
			// A node whose blocks fit the room of the step goes whole; its walk
			// can fail on the device too (releaser.device).
			releaser.drop_whole(releaser, item, level - 1)
			if releaser.device {
				return false
			}
			cursor^ = child_end
			continue
		}
		if !part(releaser, item, level - 1, child_base, cursor) {
			return false
		}
	}
	releaser.drop(releaser, node_child.block)
	cursor^ = end
	return true
}

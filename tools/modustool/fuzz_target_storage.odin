package modustool

import "base:runtime"
import "core:slice"
import "modus:support/disk_program"
import format "modus:contract/store"
import "modus:private/storage/storage_mount"
import tree "modus:private/storage/storage_tree"

// The fuzz targets of the storage format on the disk
// (src/md/infrastructure/fuzzing.md, "The targets, in order of value"): a
// principal or an attacker with the disk writes any block. A damaged block
// must give a refusal or a damaged store, never a fault and never a wrong
// object.

// ---------------------------------------------------------------------
// The B-tree against a model.

// The keys of the target: "k" and three digits, few enough that the
// operations meet the same keys again.
FUZZ_TREE_KEY_COUNT :: 400
FUZZ_TREE_OPERATION_LIMIT :: 300 // The operations of one execution.

// The disk of the target, in memory: a block is written one time and
// never again, as copy on write needs. While `ignore_checks`, a read gives
// the bytes of a damaged block as Good, so that the checks of the format
// itself see them, as when an attacker wrote a whole consistent disk.
Fuzz_Tree_Disk :: struct {
	using source:  tree.Source,
	writer:        tree.Writer,
	blocks:        [dynamic]tree.Block,
	ignore_checks: bool,
}

// One key of the model, and the number that its entry holds.
Fuzz_Tree_Record :: struct {
	key:    format.Entry_Name,
	number: u64,
}

// The state that each execution resets: about 2 MiB of the pool, made once.
fuzz_tree_disk: ^Fuzz_Tree_Disk
fuzz_tree_pool: ^tree.Pool

fuzz_tree_read :: proc "contextless" (source: ^tree.Source, pointer: tree.Pointer, into: ^tree.Block) -> tree.Read {
	disk := (^Fuzz_Tree_Disk)(source)
	if pointer.block < 2 || pointer.block >= u64(len(disk.blocks)) {
		return .Wrong
	}
	into^ = disk.blocks[pointer.block]
	if disk.ignore_checks {
		return .Good
	}
	return format.check(into[:]) == pointer.check ? .Good : .Wrong
}

fuzz_tree_write :: proc "contextless" (writer: ^tree.Writer, bytes: ^tree.Block) -> tree.Pointer {
	disk := (^Fuzz_Tree_Disk)(writer.data)
	context = runtime.default_context()
	number := len(disk.blocks)
	append(&disk.blocks, bytes^)
	return {block = u64(number), check = format.check(bytes[:])}
}

fuzz_storage_tree_start :: proc() -> bool {
	fuzz_tree_disk = new(Fuzz_Tree_Disk)
	fuzz_tree_disk.source = {read = fuzz_tree_read}
	fuzz_tree_disk.writer = {write = fuzz_tree_write, data = fuzz_tree_disk}
	fuzz_tree_disk.blocks = make([dynamic]tree.Block)
	fuzz_tree_pool = new(tree.Pool)
	return fuzz_tree_disk != nil && fuzz_tree_pool != nil
}

fuzz_tree_key :: proc(number: int) -> (key: format.Entry_Name) {
	key[0] = 'k'
	key[1] = u8('0' + number / 100 % 10)
	key[2] = u8('0' + number / 10 % 10)
	key[3] = u8('0' + number % 10)
	return key
}

fuzz_tree_entry :: proc(number: u64) -> (entry: format.Entry) {
	entry.kind = u64(format.Entry_Kind.Object)
	entry.size = number
	entry.generation = number
	return entry
}

// fuzz_model_find gives the place of a key in the sorted model, and if it
// is there.
fuzz_model_find :: proc(model: []Fuzz_Tree_Record, key: format.Entry_Name) -> (place: int, found: bool) {
	key_copy := key
	for item, index in model {
		item_key := item.key
		order := tree.compare(item_key[:], key_copy[:])
		if order == 0 {
			return index, true
		}
		if order > 0 {
			return index, false
		}
	}
	return len(model), false
}

// fuzz_tree_walk_compare walks the whole tree of a root and compares its
// records with the model, in order.
fuzz_tree_walk_compare :: proc(root: tree.Pointer, model: []Fuzz_Tree_Record) -> Fuzz_Verdict {
	Walked :: struct {
		model:    []Fuzz_Tree_Record,
		next:     int,
		mismatch: bool,
	}
	walked := Walked{model = model}
	walk := new(tree.Walk, context.temp_allocator)
	walk.source = &fuzz_tree_disk.source
	walk.shape = tree.TREE_SHAPE
	walk.data = &walked
	walk.visit_record = proc "contextless" (visited: ^tree.Walk, key: []u8, value: []u8) {
		state := (^Walked)(visited.data)
		if state.next >= len(state.model) {
			state.mismatch = true
			return
		}
		expected := state.model[state.next]
		entry := (^format.Entry)(raw_data(value))
		if tree.compare(key, expected.key[:]) != 0 || entry.size != expected.number {
			state.mismatch = true
		}
		state.next += 1
	}
	failure := tree.walk_tree(walk, root)
	if failure != .None {
		return fuzz_broken(.Model, "the walk of a tree with no damage fails: %v at the block %d", failure, walk.failed_block)
	}
	if walked.mismatch || walked.next != len(model) {
		return fuzz_broken(.Model, "the walk gives other records than the model: %d records walked, %d in the model", walked.next, len(model))
	}
	return FUZZ_PASSED
}

// fuzz_storage_tree_execute runs operations from the choices on a tree and
// on a sorted model, and compares each answer. A commit writes the dirty
// nodes; the walk of the new root must give the model. At the end, some
// written blocks are damaged, and each reader runs on them with no check of
// the checks: no fault.
fuzz_storage_tree_execute :: proc(input: []u8) -> Fuzz_Verdict {
	choices := fuzz_choices_of(input)
	disk := fuzz_tree_disk
	clear(&disk.blocks)
	append(&disk.blocks, tree.Block{}, tree.Block{}) // The two places of the root.
	disk.ignore_checks = false
	tree.pool_reset(fuzz_tree_pool)
	work := tree.Work{pool = fuzz_tree_pool, source = &disk.source, shape = tree.TREE_SHAPE}
	model := make([dynamic]Fuzz_Tree_Record, context.temp_allocator)
	value: format.Entry
	value_bytes := ([^]u8)(&value)[:size_of(format.Entry)]
	key_out: format.Entry_Name
	operations := fuzz_choice_below(&choices, FUZZ_TREE_OPERATION_LIMIT)
	for _ in 0 ..< operations {
		if fuzz_choices_ran_out(&choices) {
			break
		}
		number := fuzz_choice_below(&choices, FUZZ_TREE_KEY_COUNT)
		key := fuzz_tree_key(number)
		place, found := fuzz_model_find(model[:], key)
		switch fuzz_choice_below(&choices, 6) {
		case 0, 1:
			replace := fuzz_choice_flag(&choices)
			stored := u64(fuzz_choice_word(&choices, 2))
			entry := fuzz_tree_entry(stored)
			existed := tree.put(&work, key[:], ([^]u8)(&entry)[:size_of(format.Entry)], replace)
			if tree.failed(&work) {
				if fuzz_tree_pool.failure == .Full {
					return FUZZ_PASSED // The pool of one commit has a stated capacity: no answer to compare.
				}
				return fuzz_broken(.Model, "put fails on a tree with no damage: %v", fuzz_tree_pool.failure)
			}
			if existed != found {
				return fuzz_broken(.Model, "put says that the key existed: %v, the model: %v", existed, found)
			}
			if !found {
				inject_at(&model, place, Fuzz_Tree_Record{key = key, number = stored})
			} else if replace {
				model[place].number = stored
			}
		case 2:
			existed := tree.remove(&work, key[:])
			if tree.failed(&work) {
				return fuzz_broken(.Model, "remove fails on a tree with no damage: %v", fuzz_tree_pool.failure)
			}
			if existed != found {
				return fuzz_broken(.Model, "remove says that the key existed: %v, the model: %v", existed, found)
			}
			if found {
				ordered_remove(&model, place)
			}
		case 3:
			got := tree.get(&work, key[:], value_bytes)
			if got != found || (found && value.size != model[place].number) {
				return fuzz_broken(.Model, "get gives another answer than the model: found %v, the model %v", got, found)
			}
		case 4:
			after := fuzz_choice_flag(&choices)
			got := tree.first_from(&work, key[:], after, key_out[:], value_bytes)
			expected := place
			if found && after {
				expected += 1
			}
			has_expected := expected < len(model)
			if got != has_expected || (got && (tree.compare(key_out[:], model[expected].key[:]) != 0 || value.size != model[expected].number)) {
				return fuzz_broken(.Model, "first_from gives another record than the model: found %v, the model %v", got, has_expected)
			}
		case 5:
			root := tree.finish(&work, &disk.writer)
			if tree.failed(&work) {
				return fuzz_broken(.Model, "the commit fails on a tree with no damage: %v", fuzz_tree_pool.failure)
			}
			tree.pool_reset(fuzz_tree_pool)
			work.root = root
			if verdict := fuzz_tree_walk_compare(root, model[:]); verdict.oracle != .None {
				return verdict
			}
		}
	}
	root := tree.finish(&work, &disk.writer)
	if tree.failed(&work) {
		return FUZZ_PASSED
	}
	tree.pool_reset(fuzz_tree_pool)
	if verdict := fuzz_tree_walk_compare(root, model[:]); verdict.oracle != .None {
		return verdict
	}
	// The damage: bytes of written blocks, read with no check of the
	// checks. Each reader must end with no fault.
	if len(disk.blocks) <= 2 {
		return FUZZ_PASSED
	}
	for _ in 0 ..< fuzz_choice_range(&choices, 1, 8) {
		block := 2 + fuzz_choice_below(&choices, len(disk.blocks) - 2)
		at := fuzz_choice_below(&choices, format.BLOCK_SIZE - 8)
		fuzz_word_write(disk.blocks[block][:], at, 8, fuzz_boundary_value_of_choice(fuzz_choice_word(&choices, 8)), false)
	}
	disk.ignore_checks = true
	walk := new(tree.Walk, context.temp_allocator)
	walk.source = &disk.source
	walk.shape = tree.TREE_SHAPE
	_ = tree.walk_tree(walk, root)
	damaged := tree.Work{pool = fuzz_tree_pool, source = &disk.source, shape = tree.TREE_SHAPE, root = root}
	for _ in 0 ..< 4 {
		key := fuzz_tree_key(fuzz_choice_below(&choices, FUZZ_TREE_KEY_COUNT))
		_ = tree.get(&damaged, key[:], value_bytes)
		_ = tree.first_from(&damaged, key[:], true, key_out[:], value_bytes)
		entry := fuzz_tree_entry(1)
		_ = tree.put(&damaged, key[:], ([^]u8)(&entry)[:size_of(format.Entry)], true)
		_ = tree.remove(&damaged, key[:])
		if tree.failed(&damaged) {
			break
		}
	}
	_ = tree.finish(&damaged, &disk.writer)
	return FUZZ_PASSED
}

// ---------------------------------------------------------------------
// The open of a whole disk.

FUZZ_MOUNT_FILE_LIMIT :: 6 // The files of the store of one execution.
FUZZ_MOUNT_DISK_SIZE :: 128 * format.BLOCK_SIZE // A disk of 128 blocks: room for each file and its nodes.

// The state of the open: several MiB, made once.
fuzz_mount_state: ^storage_mount.State

fuzz_storage_mount_start :: proc() -> bool {
	fuzz_mount_state = new(storage_mount.State)
	return fuzz_mount_state != nil
}

// fuzz_mount_contents opens an image with a state at zero.
fuzz_mount_contents :: proc(image: []u8) -> Disk_Contents {
	fuzz_mount_state^ = {}
	return disk_contents(image, fuzz_mount_state, context.temp_allocator)
}

// fuzz_storage_mount_execute writes a disk of files from the choices with
// the writer of the tool, opens it with the open of the storage service,
// and compares each object with its file. Then it damages bytes of the
// disk, opens it again, and checks that each object that the open gives as
// whole has the bytes of its file.
fuzz_storage_mount_execute :: proc(input: []u8) -> Fuzz_Verdict {
	choices := fuzz_choices_of(input)
	file_count := 1 + fuzz_choice_below(&choices, FUZZ_MOUNT_FILE_LIMIT)
	files := make([]Module_File, file_count, context.temp_allocator)
	names := [FUZZ_MOUNT_FILE_LIMIT]string{"alpha", "beta", "gamma", "delta", "epsilon", "zeta"}
	for &file, index in files {
		size := 1 + fuzz_choice_below(&choices, 3 * format.BLOCK_SIZE)
		bytes := make([]u8, size, context.temp_allocator)
		// A pattern from two choices: the bytes differ from block to block,
		// and the input stays small.
		first, step := fuzz_choice_byte(&choices), fuzz_choice_byte(&choices) | 1
		for &item, place in bytes {
			item = first + u8(place) * step + u8(place >> 12)
		}
		file = {name = names[index], bytes = bytes}
	}
	image, encoded := module_disk_encode(files, FUZZ_MOUNT_DISK_SIZE, nil, context.temp_allocator)
	if !encoded {
		return fuzz_broken(.Contract, "the writer of the tool refuses files of the rules")
	}
	contents := fuzz_mount_contents(image)
	if contents.mount.failed || contents.mount.needs_format || contents.mount.wrong != 0 {
		return fuzz_broken(.Round_Trip, "the open refuses a disk that the writer wrote: failed %v, wrong %d", contents.mount.failed, contents.mount.wrong)
	}
	if len(contents.objects) != file_count {
		return fuzz_broken(.Round_Trip, "the open gives another count of objects: %d, not %d", len(contents.objects), file_count)
	}
	for object in contents.objects {
		file, found := fuzz_mount_file_of(files, object)
		if !found || object.damaged || object.hash_wrong || !slice.equal(object.bytes, file.bytes) {
			return fuzz_broken(.Round_Trip, "the open gives an object that is not the file that the writer wrote: %s", object.name)
		}
	}
	// The damage: words over bytes of the blocks in use.
	blocks_in_use := 2
	for block in 2 ..< FUZZ_MOUNT_DISK_SIZE / format.BLOCK_SIZE {
		if !slice.all_of(image[block * format.BLOCK_SIZE:][:format.BLOCK_SIZE], 0) {
			blocks_in_use = block + 1
		}
	}
	for _ in 0 ..< fuzz_choice_range(&choices, 1, 8) {
		block := fuzz_choice_below(&choices, blocks_in_use)
		at := block * format.BLOCK_SIZE + fuzz_choice_below(&choices, format.BLOCK_SIZE - 8)
		fuzz_word_write(image, at, 8, fuzz_boundary_value_of_choice(fuzz_choice_word(&choices, 8)), false)
	}
	damaged := fuzz_mount_contents(image)
	for object in damaged.objects {
		if object.damaged || object.hash_wrong || object.tree || object.bytes == nil {
			continue
		}
		file, found := fuzz_mount_file_of(files, object)
		if found && !slice.equal(object.bytes, file.bytes) {
			return fuzz_broken(.Contract, "the open of a damaged disk gives a wrong object as whole: %s", object.name)
		}
	}
	return FUZZ_PASSED
}

fuzz_mount_file_of :: proc(files: []Module_File, object: Stored_Object) -> (file: Module_File, found: bool) {
	if object.store != disk_program.STORE_NAME {
		return {}, false
	}
	for item in files {
		if item.name == object.name {
			return item, true
		}
	}
	return {}, false
}

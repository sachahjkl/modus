package machine

import "modus:contract/store"
import tree "internal:storage/storage_tree"
import "core:fmt"
import "core:os"
import "modustool:build"

// Persistence: three machines with one data disk. The first one starts
// from a new disk: the scenario types a note in `notes` and counts 1000 (1000
// commits), then stops the machine. The second one finds the note and the
// count; the scenario counts again, and the tool ends QEMU in the middle of
// the commits, with no stop of the machine. The third one finds a store
// that the checks accept, and a count of one commit: its three blocks agree.
scenario_persist_first := [?]Step {
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	// The storage service starts at boot, for the boot pass of settings.
	{kind = .Wait, text = "root: started storage", any_order = true},
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	{kind = .Wait, text = "settings: the boot pass: no settings kept: the defaults", any_order = true},
	{kind = .Wait, text = "root: settings stopped: itself, done"},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "root: started notes"},
	{kind = .Wait, text = "notes: a new store: no note, the count 0", any_order = true},
	{kind = .Wait, text = "display: notes" + WINDOW_TAKEN, any_order = true},
	{kind = .Type, text = "kept across a restart"},
	{kind = .Wait, text = "notes: the note is \"kept across a restart\", generation 22"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "notes: count 1000, stopped: 1000 commits in "},
	{kind = .Wait, text = "notes: the versions of the count: 1000 rows in "},
	// A setting that the next machine finds (the boot pass of settings).
	{kind = .Launch, text = "settings"},
	{kind = .Wait, text = "display: settings" + WINDOW_TAKEN, any_order = true},
	{kind = .Wait, text = "settings: ok, "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"settings\")"},
	{kind = .Wait, text = "[console]   module     settings"},
	{kind = .Wait, text = "[console]   commands   13"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "settings.set(font = .spleen)"},
	{kind = .Wait, text = "settings: font spleen, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; kept in the store"},
	// A line for the next machine: the console keeps its line history in
	// its store, after each line and before shutdown().
	{kind = .Type, text = "length(\"kept across a stop\")"},
	{kind = .Wait, text = "[console] 18"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_persist_second := [?]Step {
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	// 1 + 21 commits of the note, 1000 of the count, 1 of the settings, and
	// 4 of the line history of the console: after connect, after set,
	// after length, and before shutdown(). The stores of notes, settings
	// and the history of the console; the history is one object.
	{kind = .Wait, text = "storage: ok, generation 1027: 3 stores, 4 objects, ", any_order = true},
	{kind = .Wait, text = "console: the line history: 4 lines kept from before the stop", any_order = true},
	// The setting of the machine before: the desktop draws in Spleen 8x16.
	{kind = .Wait, text = "settings: the boot pass: the settings kept in the store: font spleen, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; in ", any_order = true},
	{kind = .Wait, text = " blocks checked, 0 wrong, in ", any_order = true},
	{kind = .Wait, text = "compositor: the settings changed: font spleen, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; "},
	// The console read the page before the boot pass, and may have made its
	// surface after the compositor told the windows: it reads the setting
	// itself, and draws its interface text in Spleen cells.
	{kind = .Wait, text = "terminal: console draws its interface text in the font of the cells", any_order = true},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "notes: restored the note \"kept across a restart\" and the count 1000, its 3 blocks agree", any_order = true},
	{kind = .Wait, text = "display: notes" + WINDOW_TAKEN, any_order = true},
	{kind = .Wait, text = "notes: ok, the first picture is presented"},
	{kind = .Shot, text = "notes"},
	// The vector font again, for the machines after this one.
	{kind = .Launch, text = "settings"},
	{kind = .Wait, text = "display: settings" + WINDOW_TAKEN, any_order = true},
	{kind = .Wait, text = "settings: ok, font spleen, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us"},
	{kind = .Shot, text = "settings_kept"},
	{kind = .Front, text = "console"},
	// The line history of the machine before: Up gives shutdown(), a second
	// Up the line before it; Enter runs it.
	{kind = .Key, text = "up"},
	{kind = .Key, text = "up"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "> length(\"kept across a stop\")"},
	{kind = .Wait, text = "[console] 18"},
	// The search finds it too: Enter puts it in the input, a second Enter
	// runs it.
	{kind = .Key, text = "ctrl-r"},
	{kind = .Keys, text = "kept"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: the history search gave the line length(\"kept across a stop\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] 18"},
	{kind = .Type, text = "connect(\"settings\")"},
	{kind = .Wait, text = "[console]   module     settings"},
	{kind = .Wait, text = "[console]   commands   13"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "settings.set(font = .vector)"},
	{kind = .Wait, text = "settings: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; kept in the store"},
	{kind = .Front, text = "notes"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "notes: count 1100"},
	{kind = .Quit}, // In the middle of the commits: the machine does not stop.
}

scenario_persist_crash := [?]Step {
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "storage: ok, generation ", any_order = true},
	{kind = .Wait, text = " blocks checked, 0 wrong, in ", any_order = true},
	{kind = .Wait, text = "notes: restored the note \"kept across a restart\" and the count ", any_order = true},
	{kind = .Wait, text = ", its 3 blocks agree, the last run stopped before its end", any_order = true},
	{kind = .Wait, text = "display: notes" + WINDOW_TAKEN, any_order = true},
	{kind = .Wait, text = "notes: ok, the first picture is presented"},
	{kind = .Shot, text = "notes_crash"},
	{kind = .Quit},
}

// A block of data that changed on the disk outside the service: the tool
// changes one byte of the note. Each valid root names the block, so no
// root is better: the storage service serves, with one damaged object. The
// count is whole. `notes` says that the note is damaged, and does not take
// it for an empty note. A key writes a new note in place of it.
scenario_persist_damaged := [?]Step {
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "storage: 1 blocks have a wrong check: 1 objects and 0 stores are damaged; the service serves the others", any_order = true},
	{kind = .Wait, text = " blocks checked, 1 wrong, in ", any_order = true},
	{kind = .Wait, text = "notes: WRONG: the storage service cannot give the note: the object is damaged; restored the count ", any_order = true},
	{kind = .Wait, text = "display: notes" + WINDOW_TAKEN, any_order = true},
	{kind = .Wait, text = "notes: ok, the first picture is presented"},
	{kind = .Shot, text = "notes_damaged"},
	{kind = .Type, text = "again"},
	{kind = .Wait, text = "notes: the note is \"again\", generation "},
	{kind = .Quit},
}

// After the new note: no wrong block, and the note and the count.
scenario_persist_replaced := [?]Step {
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = " blocks checked, 0 wrong, in ", any_order = true},
	{kind = .Wait, text = "notes: restored the note \"again\" and the count ", any_order = true},
	{kind = .Wait, text = "display: notes" + WINDOW_TAKEN, any_order = true},
	{kind = .Quit},
}

// A wrong block that only the newest root names: the last commit is not
// whole on the disk. The root before it names no wrong block, so the
// storage service uses it: the note is the note before its last letter.
scenario_persist_older := [?]Step {
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "storage: the newest root names a block with a wrong check, and the root before it names none: the root before it is used", any_order = true},
	{kind = .Wait, text = " blocks checked, 0 wrong, in ", any_order = true},
	{kind = .Wait, text = "notes: restored the note \"agai\" and the count ", any_order = true},
	{kind = .Quit},
}

// A format that a stop cut: a first root with a wrong check, and no commit
// after it. The disk holds no object: the storage service formats again.
scenario_persist_first_cut := [?]Step {
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "storage: the first root of the disk has a wrong check and no commit followed it", any_order = true},
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	{kind = .Wait, text = "notes: a new store: no note, the count 0", any_order = true},
	{kind = .Quit},
}

// A root block that a stop cut: the tool writes zero bytes over the second
// half of the root with the highest generation, as a write that the machine
// did not finish. The storage service finds the wrong check and uses the
// root before it: the count of the commit before.
scenario_persist_cut := [?]Step {
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = " has a wrong check: a write that a stop cut; the service uses the root before it", any_order = true},
	{kind = .Wait, text = " blocks checked, 0 wrong, in ", any_order = true},
	{kind = .Wait, text = "notes: restored the note \"kept across a restart\" and the count ", any_order = true},
	{kind = .Wait, text = ", its 3 blocks agree, the last run stopped before its end", any_order = true},
	{kind = .Wait, text = "display: notes" + WINDOW_TAKEN, any_order = true},
	{kind = .Quit},
}

// The data disk of the test of persistence, read with the format of the
// storage service (src/library/modus/contract/store).
disk_open :: proc(path: string) -> (file: ^os.File, ok: bool) {
	err: os.Error
	if file, err = os.open(path, {.Read, .Write}); err != nil {
		fmt.eprintfln("modustool: cannot open %s: %v", path, err)
		return nil, false
	}
	return file, true
}

disk_block :: proc(file: ^os.File, number: u64, value: ^$T) -> bool where size_of(T) == store.BLOCK_SIZE {
	count, err := os.read_at(file, ([^]u8)(value)[:store.BLOCK_SIZE], i64(number * store.BLOCK_SIZE))
	if err != nil || count != store.BLOCK_SIZE {
		fmt.eprintfln("modustool: cannot read the block %d of the disk", number)
		return false
	}
	return true
}

// disk_root gives the valid root with the highest generation, and its place.
disk_root :: proc(file: ^os.File, root: ^store.Root) -> (place: u64, ok: bool) {
	roots: [2]store.Root
	disk_block(file, 0, &roots[0]) or_return
	disk_block(file, 1, &roots[1]) or_return
	found := false
	for &candidate, index in roots {
		if store.root_valid(&candidate, store.DISK_BLOCKS_LIMIT) && (!found || candidate.generation > root.generation) {
			root^, place, found = candidate, u64(index), true
		}
	}
	if !found {
		fmt.eprintln("modustool: the disk has no valid root")
	}
	return place, found
}

// root_cut writes zero bytes over the second half of the valid root block
// with the highest generation, as a write that the machine did not finish.
root_cut :: proc(path: string) -> bool {
	file := disk_open(path) or_return
	defer os.close(file)
	root: store.Root
	place := disk_root(file, &root) or_return
	zero: [store.BLOCK_SIZE / 2]u8
	if _, err := os.write_at(file, zero[:], i64(place * store.BLOCK_SIZE + store.BLOCK_SIZE / 2)); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, err)
		return false
	}
	fmt.printfln("modustool: the root block %d of %s is cut, generation %d", place, path, root.generation)
	return true
}

// object_damage changes one byte of the first block of data of an object:
// a change on the disk that the storage service did not make.
object_damage :: proc(path: string, store_name: string, object_name: string) -> bool {
	file := disk_open(path) or_return
	defer os.close(file)
	root: store.Root
	disk_root(file, &root) or_return
	name_of :: proc(bytes: []u8) -> string {
		count := 0
		for count < len(bytes) && bytes[count] != 0 {
			count += 1
		}
		return string(bytes[:count])
	}
	for &entry in root.stores {
		if name_of(entry.name[:]) != store_name {
			continue
		}
		block: store.Store_Block
		disk_block(file, entry.store.block, &block) or_return
		object, found := tree_entry_find(file, block.tree, object_name) or_return
		if found && object.kind == u64(store.Entry_Kind.Object) && object.pointer.block != 0 {
			// The first block of data: down the first child of each object
			// node, or the root of an object of one block.
			number := object.pointer.block
			for level := store.object_levels(object.size); level >= 1 && number != 0; level -= 1 {
				node: store.Object_Node
				disk_block(file, number, &node) or_return
				next: u64
				for child in node.children {
					if child.block != 0 {
						next = child.block
						break
					}
				}
				number = next
			}
			if number == 0 {
				break
			}
			at := i64(number * store.BLOCK_SIZE)
			one: [1]u8
			if count, err := os.read_at(file, one[:], at); err != nil || count != 1 {
				return false
			}
			one[0] ~= 0x40
			if _, err := os.write_at(file, one[:], at); err != nil {
				fmt.eprintfln("modustool: cannot write %s: %v", path, err)
				return false
			}
			fmt.printfln("modustool: one byte of the block %d is changed: the first block of data of the object %s of the store %s, under the root of generation %d", number, object_name, store_name, root.generation)
			return true
		}
	}
	fmt.eprintfln("modustool: the disk has no object %s in a store %s", object_name, store_name)
	return false
}

// tree_entry_find finds an entry of a tree on a disk file: the walk down
// the B+ tree of the tree, as src/library/internal/storage/storage_tree does.
tree_entry_find :: proc(file: ^os.File, root: store.Pointer, name: string) -> (found_entry: store.Entry, found: bool, ok: bool) {
	key := store.entry_name(name)
	pointer := root
	for _ in 0 ..< store.TREE_DEPTH_LIMIT {
		if pointer.block == 0 {
			return {}, false, true
		}
		node: [store.BLOCK_SIZE]u8
		disk_block(file, pointer.block, &node) or_return
		header := (^store.Tree_Header)(&node)
		if header.level == 0 {
			size := size_of(store.Entry_Name) + size_of(store.Entry)
			for index in 0 ..< int(min(header.count, store.LEAF_CAPACITY)) {
				record := node[store.TREE_HEADER_SIZE + index * size:][:size]
				if tree.compare(record[:size_of(store.Entry_Name)], key[:]) == 0 {
					return (^store.Entry)(raw_data(record[size_of(store.Entry_Name):]))^, true, true
				}
			}
			return {}, false, true
		}
		size := size_of(store.Entry_Name) + size_of(store.Pointer)
		next := 0
		for index in 1 ..< int(min(header.count, store.BRANCH_CAPACITY)) {
			if tree.compare(node[store.TREE_HEADER_SIZE + index * size:][:size_of(store.Entry_Name)], key[:]) <= 0 {
				next = index
			}
		}
		pointer = (^store.Pointer)(raw_data(node[store.TREE_HEADER_SIZE + next * size + size_of(store.Entry_Name):]))^
	}
	return {}, false, true
}

// first_root_cut makes a new disk with a first root that a stop cut: the
// first half of a first root in block 1, and zero bytes after it.
first_root_cut :: proc(path: string) -> bool {
	disk_prepare(path, build.DATA_DISK_SIZE, true) or_return
	file := disk_open(path) or_return
	defer os.close(file)
	root := store.Root{magic = store.ROOT_MAGIC, generation = 1, disk_blocks = build.DATA_DISK_SIZE / store.BLOCK_SIZE}
	if _, err := os.write_at(file, ([^]u8)(&root)[:store.BLOCK_SIZE / 2], store.BLOCK_SIZE); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, err)
		return false
	}
	fmt.printfln("modustool: %s has a first root with no check: a format that a stop cut", path)
	return true
}

persistence_run :: proc(part: ^Test_Part_Run) -> bool {
	disk_prepare(TEST_PERSIST_DISK, build.DATA_DISK_SIZE, true) or_return
	machine_test(part, scenario_persist_first[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_PERSIST, 1), exit_status = build.MACHINE_STOP_OK, data_disk = TEST_PERSIST_DISK}) or_return
	machine_test(part, scenario_persist_second[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_PERSIST, 2), exit_status = 0, data_disk = TEST_PERSIST_DISK}) or_return
	machine_test(part, scenario_persist_crash[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_PERSIST, 3), exit_status = 0, data_disk = TEST_PERSIST_DISK}) or_return
	root_cut(TEST_PERSIST_DISK) or_return
	machine_test(part, scenario_persist_cut[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_PERSIST, 4), exit_status = 0, data_disk = TEST_PERSIST_DISK}) or_return
	object_damage(TEST_PERSIST_DISK, "notes", "note") or_return
	machine_test(part, scenario_persist_damaged[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_PERSIST, 5), exit_status = 0, data_disk = TEST_PERSIST_DISK}) or_return
	machine_test(part, scenario_persist_replaced[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_PERSIST, 6), exit_status = 0, data_disk = TEST_PERSIST_DISK}) or_return
	// The last commit wrote the last letter of the note: only the newest
	// root names the block of data that the tool changes now.
	object_damage(TEST_PERSIST_DISK, "notes", "note") or_return
	machine_test(part, scenario_persist_older[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_PERSIST, 7), exit_status = 0, data_disk = TEST_PERSIST_DISK}) or_return
	first_root_cut(TEST_PERSIST_DISK) or_return
	return machine_test(part, scenario_persist_first_cut[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_PERSIST, 8), exit_status = 0, data_disk = TEST_PERSIST_DISK})
}

// A binary of the tool runs the test part persist only when it holds this file
// (test_parts.odin, test_part_scenario_register).
@(init)
persist_test_part_register :: proc "contextless" () {
	test_part_scenario_register("persist", persistence_run)
}

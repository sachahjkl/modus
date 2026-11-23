package machine

import "core:fmt"
import "core:os"
import format "modus:contract/store"
import "modustool:foundation"
import "modustool:build"

// A data disk larger than the tables of the storage service
// (src/md/data/storage_capacity.md, "The open has two forms"): 32 GiB,
// where the budget of the service holds the tables of 16 GiB. The first
// machine formats the whole disk with its count tree, commits an object,
// and commits and removes another; the second opens the disk from its
// count tree, with no walk of its blocks, reads the first object back and
// finds no second one. Then the host changes a byte of leaf 0 of the count
// tree in the image: the third machine opens it, and its first write meets
// the wrong leaf. The service enters the repair state and answers Busy;
// the client of the console makes the write again until the repair has
// written the leaf, and the write passes (src/md/data/storage_capacity.md,
// "The repair state").

TEST_LARGE_DISK :: foundation.BUILD_FOLDER + "/test_large_disk.img"
TEST_OUTPUT_LARGE_DISK :: foundation.BUILD_FOLDER + "/test_output_large_disk_%d.txt"

// The size of the disk: twice the disk whose tables the budget of the
// service holds, so the open takes the form Count_Tree.
LARGE_DISK_SIZE :: i64(32) << 30

scenario_large_disk_first := [?]Step {
	{kind = .Wait, text = "the service reads the counts of the blocks from the count tree of the disk", any_order = true},
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, "},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"storage\")"},
	{kind = .Record, process = "root", level = "Info", text = "root: connected console to the service storage"},
	{kind = .Type, text = "storage.write(0, \"large\", \"kept on a large disk\")"},
	{kind = .Wait, text = "> storage.write(0, \"large\", \"kept on a large disk\")"},
	{kind = .Type, text = "storage.read(0, \"large\")"},
	{kind = .Wait, text = "[console] kept on a large disk"},
	// A remove: its commit releases the state of the object through the
	// count tree.
	{kind = .Type, text = "storage.write(0, \"gone\", \"removed on a large disk\")"},
	{kind = .Wait, text = "> storage.write(0, \"gone\", \"removed on a large disk\")"},
	{kind = .Type, text = "storage.remove(0, \"gone\")"},
	{kind = .Wait, text = "> storage.remove(0, \"gone\")"},
	{kind = .Type, text = "storage.read(0, \"gone\")"},
	{kind = .Wait, text = "[console] error: storage.read: the argument name: the store has no object with this name"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_large_disk_second := [?]Step {
	{kind = .Wait, text = "the service reads the counts of the blocks from the count tree of the disk", any_order = true},
	{kind = .Wait, text = "storage: ok, generation "},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"storage\")"},
	{kind = .Record, process = "root", level = "Info", text = "root: connected console to the service storage"},
	{kind = .Type, text = "storage.read(0, \"large\")"},
	{kind = .Wait, text = "[console] kept on a large disk"},
	{kind = .Type, text = "storage.read(0, \"gone\")"},
	{kind = .Wait, text = "[console] error: storage.read: the argument name: the store has no object with this name"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_large_disk_third := [?]Step {
	{kind = .Wait, text = "the service reads the counts of the blocks from the count tree of the disk", any_order = true},
	{kind = .Wait, text = "storage: ok, generation "},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"storage\")"},
	{kind = .Record, process = "root", level = "Info", text = "root: connected console to the service storage"},
	{kind = .Type, text = "storage.write(0, \"after\", \"written after the repair\")"},
	{kind = .Wait, text = "storage: the count tree has a wrong check in 1 of its leaves"},
	{kind = .Wait, text = "storage: the leaves of the count tree that had a wrong check are counted again and written"},
	{kind = .Type, text = "storage.read(0, \"after\")"},
	{kind = .Wait, text = "[console] written after the repair"},
	{kind = .Type, text = "storage.read(0, \"large\")"},
	{kind = .Wait, text = "[console] kept on a large disk"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// large_disk_leaf_break changes a byte of leaf 0 of the count tree of the
// newest valid root of an image, so that its check is wrong.
large_disk_leaf_break :: proc(path: string, size: i64) -> bool {
	file, open_error := os.open(path, {.Read, .Write})
	if open_error != nil {
		fmt.eprintfln("modustool: cannot open %s: %v", path, open_error)
		return false
	}
	defer os.close(file)
	block_read :: proc(file: ^os.File, number: u64, into: rawptr) -> bool {
		count, error := os.read_at(file, ([^]u8)(into)[:format.BLOCK_SIZE], i64(number * format.BLOCK_SIZE))
		return error == nil && count == format.BLOCK_SIZE
	}
	disk_blocks := u64(size) / format.BLOCK_SIZE
	roots: [2]format.Root
	newest := -1
	for &root, place in roots {
		if block_read(file, u64(place), &root) && format.root_valid(&root, disk_blocks) && (newest < 0 || root.generation > roots[newest].generation) {
			newest = place
		}
	}
	if newest < 0 || roots[newest].counts.block == 0 {
		fmt.eprintfln("modustool: %s has no root with a count tree", path)
		return false
	}
	// From the top directory down to leaf 0, by the first child of each.
	page := roots[newest].counts.block
	directory: format.Count_Directory
	for {
		if !block_read(file, page, &directory) || directory.magic != format.COUNT_DIRECTORY_MAGIC {
			fmt.eprintfln("modustool: %s: block %d is no directory of the count tree", path, page)
			return false
		}
		page = directory.children[0].block
		if directory.level == 1 {
			break
		}
	}
	byte: [1]u8
	at := i64(page * format.BLOCK_SIZE + 100)
	if count, error := os.read_at(file, byte[:], at); error != nil || count != 1 {
		return false
	}
	byte[0] ~= 1
	if count, error := os.write_at(file, byte[:], at); error != nil || count != 1 {
		fmt.eprintfln("modustool: cannot change block %d of %s", page, path)
		return false
	}
	return true
}

// large_disk_prepare makes a new sparse disk: the host holds no block of
// it until a machine writes one.
large_disk_prepare :: proc(path: string, size: i64) -> bool {
	file, open_error := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if open_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, open_error)
		return false
	}
	size_error := os.truncate(file, size)
	close_error := os.close(file)
	if size_error != nil || close_error != nil {
		fmt.eprintfln("modustool: cannot make the sparse disk %s", path)
		return false
	}
	return true
}

large_disk_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	large_disk_prepare(TEST_LARGE_DISK, LARGE_DISK_SIZE) or_return
	machine_test(part, scenario_large_disk_first[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_LARGE_DISK, 1), exit_status = build.MACHINE_STOP_OK, data_disk = TEST_LARGE_DISK}) or_return
	ok := machine_test(part, scenario_large_disk_second[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_LARGE_DISK, 2), exit_status = build.MACHINE_STOP_OK, data_disk = TEST_LARGE_DISK})
	ok = ok && large_disk_leaf_break(TEST_LARGE_DISK, LARGE_DISK_SIZE)
	ok = ok && machine_test(part, scenario_large_disk_third[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_LARGE_DISK, 3), exit_status = build.MACHINE_STOP_OK, data_disk = TEST_LARGE_DISK})
	os.remove(TEST_LARGE_DISK)
	return ok
}

// A binary of the tool runs the test part large_disk only when it holds
// this file (test_parts.odin, test_part_scenario_register).
@(init)
large_disk_test_part_register :: proc "contextless" () {
	test_part_scenario_register("large_disk", large_disk_tests_run)
}

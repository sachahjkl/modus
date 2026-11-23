package machine

import "core:fmt"
import "core:os"
import "modustool:foundation"
import "modustool:build"

// A data disk larger than the tables of the storage service
// (src/md/data/storage_capacity.md, "The open has two forms"): 32 GiB,
// where the budget of the service holds the tables of 16 GiB. The first
// machine formats the whole disk with its count tree and commits an
// object; the second opens the disk from its count tree, with no walk of
// its blocks, and reads the object back.

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
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
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
	os.remove(TEST_LARGE_DISK)
	return ok
}

// A binary of the tool runs the test part large_disk only when it holds
// this file (test_parts.odin, test_part_scenario_register).
@(init)
large_disk_test_part_register :: proc "contextless" () {
	test_part_scenario_register("large_disk", large_disk_tests_run)
}

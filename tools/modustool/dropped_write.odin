package modustool

import format "modus:contract/store"
import "core:fmt"
import "core:os"
import "core:sync"
import "modus:support/storage_mount"

// The dropped write (src/md/features/dropped_write.md): the disk that the
// tool serves answers Ok to one write of a commit and does not keep it. The
// write is the block of data of the second version of an object that the
// console writes: its bytes start with a marker that nothing else on the
// disk starts with. The disk keeps every other write of that commit, its
// root included, then takes no more write, and the tool ends the machine.
//
// What the durable image must give, on the host with the code of the open,
// then on a second machine:
//   - the open refuses the newest root, which names the dropped block, and
//     uses the root before it, with no wrong block;
//   - the object reads as its first version, never the bytes of the block.

DROPPED_WRITE_MARKER :: "the version that the disk drops"
DROPPED_WRITE_FIRST_VERSION :: "the version that the disk keeps"
DROPPED_WRITE_OBJECT :: "kept"
DROPPED_WRITE_STORE :: "console" // The private store of the console.
TEST_DROPPED_WRITE_DISK :: BUILD_FOLDER + "/test_dropped_write_disk.img"
TEST_OUTPUT_DROPPED_WRITE :: BUILD_FOLDER + "/test_output_dropped_write_%d.txt"

// The line of the open when the newest root names a wrong block and the
// root before it names none (src/programs/storage/main.odin).
DROPPED_WRITE_FALLBACK_LINE :: "storage: the newest root names a block with a wrong check, and the root before it names none: the root before it is used"

// The first machine: a new disk, a first version of the object, then the
// second version, whose block of data the disk drops. Each line of the
// console commits the line history after it, so the second write is the
// commit 2 after the base, and the save of its line is the first write
// that the disk does not take.
scenario_dropped_write_first := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"storage\")"},
	{kind = .Wait, text = "[console]   module     storage"},
	{kind = .Type, text = "storage.write(0, \"" + DROPPED_WRITE_OBJECT + "\", \"" + DROPPED_WRITE_FIRST_VERSION + "\")"},
	{kind = .Wait, text = "> storage.write(0, \"" + DROPPED_WRITE_OBJECT + "\", \"" + DROPPED_WRITE_FIRST_VERSION + "\")"},
	{kind = .Generation, text = "[console] "},
	{kind = .Type, text = "storage.write(0, \"" + DROPPED_WRITE_OBJECT + "\", \"" + DROPPED_WRITE_MARKER + "\")"},
	// The service answers with the generation of its commit: the disk
	// reported no fault.
	{kind = .Wait, text = "[console] {generation+2}"},
	{kind = .Quit},
}

// root_generations gives the generation of each valid root of an image,
// or 0 for a place whose root is not valid.
@(private = "file")
root_generations :: proc(image: []u8) -> (generations: [ROOT_BLOCK_PLACES]u64) {
	disk_blocks := u64(len(image)) / format.BLOCK_SIZE
	for place in 0 ..< ROOT_BLOCK_PLACES {
		root := (^format.Root)(raw_data(image[place * format.BLOCK_SIZE:]))^
		if format.root_valid(&root, disk_blocks) {
			generations[place] = root.generation
		}
	}
	return generations
}

dropped_write_run :: proc() -> bool {
	fresh := make([]u8, DATA_DISK_SIZE)
	defer delete(fresh)
	server: Network_Block_Device
	if !disk_server_start(&server, fresh) {
		return false
	}
	defer disk_server_free(&server)
	// The thread of the server reads the marker at the first write; no
	// machine is connected yet.
	sync.mutex_lock(&server.lock)
	server.drop_marker = DROPPED_WRITE_MARKER
	sync.mutex_unlock(&server.lock)
	address := fmt.tprintf("nbd://127.0.0.1:%d", server.port)
	ran := machine_test(scenario_dropped_write_first[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_DROPPED_WRITE, 1), 0, address, disk_server = &server)
	disk_server_stop(&server)
	if !ran {
		return false
	}
	sync.mutex_lock(&server.lock)
	defer sync.mutex_unlock(&server.lock)
	if server.drop_state < .Root_Durable {
		fmt.eprintfln("modustool: test failed: the dropped write: the disk reached the state %v, not a durable root after the dropped write", server.drop_state)
		return false
	}
	generations := root_generations(server.durable)
	newest := max(generations[0], generations[1])
	state := new(storage_mount.State)
	defer free(state)
	contents := disk_contents(server.durable, state)
	kept := stored_object_of(&contents, DROPPED_WRITE_STORE, DROPPED_WRITE_OBJECT)
	switch {
	case contents.mount.failed || contents.mount.needs_format:
		fmt.eprintfln("modustool: test failed: the dropped write: the durable image does not open")
		return false
	case !contents.mount.older || contents.mount.generation + 1 != newest:
		fmt.eprintfln("modustool: test failed: the dropped write: the open uses the generation %d, and the newest root has the generation %d: it must refuse the newest root and use the one before it", contents.mount.generation, newest)
		return false
	case contents.mount.wrong != 0 || contents.mount.damaged_objects != 0 || contents.mount.damaged_versions != 0:
		fmt.eprintfln("modustool: test failed: the dropped write: the root before the newest one gives %d wrong blocks, %d damaged objects and %d damaged versions", contents.mount.wrong, contents.mount.damaged_objects, contents.mount.damaged_versions)
		return false
	case kept == nil || kept.damaged || kept.hash_wrong || string(kept.bytes) != DROPPED_WRITE_FIRST_VERSION:
		fmt.eprintfln("modustool: test failed: the dropped write: the object %s of the store %s is not its first version on the durable image", DROPPED_WRITE_OBJECT, DROPPED_WRITE_STORE)
		return false
	}
	test_passed_print("the dropped write: the disk answered Ok to the write of block %d and kept the rest of the commit of generation %d; the open on the host refuses that root and uses the generation %d, with 0 wrong blocks, and the object %s is its first version", server.dropped_block, newest, contents.mount.generation, DROPPED_WRITE_OBJECT)
	if err := os.write_entire_file(TEST_DROPPED_WRITE_DISK, server.durable); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", TEST_DROPPED_WRITE_DISK, err)
		return false
	}
	// The steps live in memory of their own: the run of a scenario frees the
	// temporary memory after each step.
	second := make([dynamic]Step)
	defer delete(second)
	append(&second, Step{kind = .Wait, text = "compositor: surface console", any_order = true})
	append(&second, Step{kind = .Wait, text = DROPPED_WRITE_FALLBACK_LINE, any_order = true})
	append(&second, Step{kind = .Wait, text = fmt.aprintf("storage: ok, generation %d: ", contents.mount.generation), any_order = true})
	append(&second, Step{kind = .Wait, text = " blocks checked, 0 wrong, in "})
	append(&second, Step{kind = .Front, text = "console"})
	append(&second, Step{kind = .Type, text = "connect(\"storage\")"})
	append(&second, Step{kind = .Wait, text = "[console]   module     storage"})
	append(&second, Step{kind = .Type, text = "storage.read(0, \"" + DROPPED_WRITE_OBJECT + "\")"})
	append(&second, Step{kind = .Wait, text = "[console] " + DROPPED_WRITE_FIRST_VERSION, fails_on = "[console] " + DROPPED_WRITE_MARKER})
	append(&second, Step{kind = .Quit})
	return machine_test(second[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_DROPPED_WRITE, 2), 0, TEST_DROPPED_WRITE_DISK)
}

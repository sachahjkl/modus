package modustool

import format "modus:contract/store"
import "core:fmt"
import "core:os"
import "core:sync"
import "modus:private/storage/storage_mount"

// The dropped write (src/md/features/dropped_write.md). The disk that the
// tool serves drops three writes of the console to one object, each found
// by a block whose bytes start with a marker that nothing else on the disk
// starts with:
//   - the dropped one: the disk answers Ok and keeps nothing of the block.
//     The commit read back finds it before the root: the service refuses
//     the commit with its line, the console gets the refusal, and the
//     object reads as its first version at once, with no restart;
//   - the dropped root: the disk keeps the blocks of a commit and drops its
//     root. The read back of the root refuses the commit, with its line,
//     and the object again reads as its first version;
//   - the hidden one: the disk answers Ok, gives the bytes at each read,
//     and never makes them durable, as a cache that a loss of power
//     empties. The read back passes, and the commit is taken.
// What the durable image when the root of the hidden commit became durable
// must give (a loss of power at that moment), on the host with the code of
// the open, then on a second machine: the open refuses the newest root,
// which names the lost block, and uses the root before it, with no wrong
// block, and the object is its first version.
// What the durable image at the end of the first machine must give: the
// limit of the read back. The commits after the hidden one name its block
// too, so the open takes the newest root with its damage: the object,
// whose current version is the hidden write, is damaged.

DROPPED_WRITE_MARKER :: "the version that the disk drops"
DROPPED_WRITE_HIDDEN_MARKER :: "the version that the cache of the disk hides"
DROPPED_WRITE_ROOT_MARKER :: "the version whose root the disk drops"
DROPPED_WRITE_FIRST_VERSION :: "the version that the disk keeps"
DROPPED_WRITE_OBJECT :: "kept"
DROPPED_WRITE_STORE :: "console" // The private store of the console.
TEST_DROPPED_WRITE_DISK :: BUILD_FOLDER + "/test_dropped_write_disk.img"
TEST_OUTPUT_DROPPED_WRITE :: BUILD_FOLDER + "/test_output_dropped_write_%d.txt"

// The line of the open when the newest root names a wrong block and the
// root before it names none (src/modules/system/storage/main.odin).
DROPPED_WRITE_FALLBACK_LINE :: "storage: the newest root names a block with a wrong check, and the root before it names none: the root before it is used"

// The first machine. Each line of the console commits the line history
// after it, and a refused commit takes no generation: the dropped write is
// the commit 2 after the base, the dropped root the commit 4, and the
// hidden write the commit 6.
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
	// The disk dropped one block of that commit: the read back finds it
	// before the root, and the service goes on from the commit before.
	{kind = .Wait, text = "storage: the read back of the commit of generation {generation+2} found 1 block with other bytes: the disk did not keep it; the commit is refused before its root, and the service goes on from generation {generation+1}"},
	{kind = .Wait, text = "[console] error: storage.write: the disk did not keep 1 block of the commit: the commit is refused, and the store keeps its state before it (-6)"},
	// The same machine, with no restart: the object is its first version.
	{kind = .Type, text = "storage.read(0, \"" + DROPPED_WRITE_OBJECT + "\")"},
	{kind = .Wait, text = "[console] " + DROPPED_WRITE_FIRST_VERSION, fails_on = "[console] " + DROPPED_WRITE_MARKER},
	// The dropped root: the disk keeps the blocks of the commit and drops
	// its root. The read back of the root refuses it.
	{kind = .Type, text = "storage.write(0, \"" + DROPPED_WRITE_OBJECT + "\", \"" + DROPPED_WRITE_ROOT_MARKER + "\")"},
	{kind = .Wait, text = "storage: the read back of the root of the commit of generation {generation+4} found other bytes: the disk did not keep it; the commit is refused, and the service goes on from generation {generation+3}"},
	{kind = .Wait, text = "[console] error: storage.write: the disk did not keep 1 block of the commit: the commit is refused, and the store keeps its state before it (-6)"},
	{kind = .Type, text = "storage.read(0, \"" + DROPPED_WRITE_OBJECT + "\")"},
	{kind = .Wait, text = "[console] " + DROPPED_WRITE_FIRST_VERSION, fails_on = "[console] " + DROPPED_WRITE_ROOT_MARKER},
	// The hidden write: the read back passes, and the commit is taken. It
	// writes the same object: the store of the console has a limit of 3
	// blocks, and a second object needs 4.
	{kind = .Type, text = "storage.write(0, \"" + DROPPED_WRITE_OBJECT + "\", \"" + DROPPED_WRITE_HIDDEN_MARKER + "\")"},
	{kind = .Wait, text = "[console] {generation+6}"},
	// The cost of the read back: a measure, which no step reads.
	{kind = .Type, text = "storage.stores()"},
	{kind = .Wait, text = " blocks read back in "},
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

// What the open of an image must give.
@(private = "file")
Dropped_Write_Expected :: enum {
	Fallback, // The open refuses the newest root and uses the one before it, with no wrong block, and the object is its first version.
	Hidden_Damage, // The open uses the newest root, with the object damaged, as its current version names the lost block, and no other object damaged.
}

// dropped_write_image_check opens an image on the host with the code of
// the open, and checks it against `expected`. In both cases the first
// object is its first version. It gives the generation that the open uses.
@(private = "file")
dropped_write_image_check :: proc(image: []u8, expected: Dropped_Write_Expected, what: string) -> (generation: u64, ok: bool) {
	generations := root_generations(image)
	newest := max(generations[0], generations[1])
	state := new(storage_mount.State)
	defer free(state)
	contents := disk_contents(image, state)
	kept := stored_object_of(&contents, DROPPED_WRITE_STORE, DROPPED_WRITE_OBJECT)
	if contents.mount.failed || contents.mount.needs_format {
		fmt.eprintfln("modustool: test failed: the dropped write: %s does not open", what)
		return 0, false
	}
	switch expected {
	case .Fallback:
		switch {
		case !contents.mount.older || contents.mount.generation + 1 != newest:
			fmt.eprintfln("modustool: test failed: the dropped write: the open of %s uses the generation %d, and the newest root has the generation %d: it must refuse the newest root and use the one before it", what, contents.mount.generation, newest)
			return 0, false
		case contents.mount.wrong != 0 || contents.mount.damaged_objects != 0 || contents.mount.damaged_versions != 0:
			fmt.eprintfln("modustool: test failed: the dropped write: the open of %s gives %d wrong blocks, %d damaged objects and %d damaged versions", what, contents.mount.wrong, contents.mount.damaged_objects, contents.mount.damaged_versions)
			return 0, false
		case kept == nil || kept.damaged || kept.hash_wrong || string(kept.bytes) != DROPPED_WRITE_FIRST_VERSION:
			fmt.eprintfln("modustool: test failed: the dropped write: the object %s of the store %s is not its first version on %s", DROPPED_WRITE_OBJECT, DROPPED_WRITE_STORE, what)
			return 0, false
		}
	case .Hidden_Damage:
		switch {
		case contents.mount.older || contents.mount.generation != newest:
			fmt.eprintfln("modustool: test failed: the dropped write: the open of %s uses the generation %d, and the newest root has the generation %d: both roots name the lost block, so it must use the newest root with its damage", what, contents.mount.generation, newest)
			return 0, false
		case contents.mount.damaged_objects != 1 || kept == nil || !kept.damaged:
			fmt.eprintfln("modustool: test failed: the dropped write: the open of %s gives %d damaged objects: only the object %s, whose current version is the hidden write, must be damaged", what, contents.mount.damaged_objects, DROPPED_WRITE_OBJECT)
			return 0, false
		}
	}
	return contents.mount.generation, true
}

dropped_write_run :: proc(part: ^Test_Part_Run) -> bool {
	fresh := make([]u8, DATA_DISK_SIZE)
	defer delete(fresh)
	server: Network_Block_Device
	if !disk_server_start(&server, fresh) {
		return false
	}
	defer disk_server_free(&server)
	// The thread of the server reads the markers at the first write; no
	// machine is connected yet.
	sync.mutex_lock(&server.lock)
	server.drop_marker = DROPPED_WRITE_MARKER
	server.hide_marker = DROPPED_WRITE_HIDDEN_MARKER
	server.root_drop_marker = DROPPED_WRITE_ROOT_MARKER
	sync.mutex_unlock(&server.lock)
	address := fmt.tprintf("nbd://127.0.0.1:%d", server.port)
	ran := machine_test(part, scenario_dropped_write_first[:], {volume = BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_DROPPED_WRITE, 1), exit_status = 0, data_disk = address, disk_server = &server})
	disk_server_stop(&server)
	if !ran {
		return false
	}
	sync.mutex_lock(&server.lock)
	defer sync.mutex_unlock(&server.lock)
	if !server.dropped || server.root_drop_state != .Root_Dropped || server.hide_state != .Root_Durable || server.durable_at_hidden_root == nil {
		fmt.eprintfln("modustool: test failed: the dropped write: the disk dropped a block: %v; the dropped root reached the state %v; the hidden write reached the state %v, not a durable root after it", server.dropped, server.root_drop_state, server.hide_state)
		return false
	}
	end_generation, end_ok := dropped_write_image_check(server.durable, .Hidden_Damage, "the durable image at the end")
	if !end_ok {
		return false
	}
	hidden_generations := root_generations(server.durable_at_hidden_root)
	hidden_commit := max(hidden_generations[0], hidden_generations[1])
	before, before_ok := dropped_write_image_check(server.durable_at_hidden_root, .Fallback, "the durable image at the root of the hidden write")
	if !before_ok {
		return false
	}
	test_passed_print("the dropped write: the disk answered Ok to the write of block %d and did not keep it; the read back refused that commit before its root; the disk dropped the root of a later commit, and the read back of the root refused it; the object %s read its first version after each, with no restart", server.dropped_block, DROPPED_WRITE_OBJECT)
	test_passed_print("the dropped write: the disk hid the loss of block %d from the read back; the open on the host of the image at the root of generation %d refuses that root and uses the generation %d, with 0 wrong blocks; the image at the end opens its generation %d with the object %s damaged, the limit of the read back", server.hidden_block, hidden_commit, before, end_generation, DROPPED_WRITE_OBJECT)
	if err := os.write_entire_file(TEST_DROPPED_WRITE_DISK, server.durable_at_hidden_root); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", TEST_DROPPED_WRITE_DISK, err)
		return false
	}
	// The second machine: a loss of power right after the hidden commit.
	// The steps live in memory of their own: the run of a scenario frees
	// the temporary memory after each step.
	second := make([dynamic]Step)
	defer delete(second)
	append(&second, Step{kind = .Wait, text = "compositor: surface console", any_order = true})
	append(&second, Step{kind = .Wait, text = DROPPED_WRITE_FALLBACK_LINE, any_order = true})
	append(&second, Step{kind = .Wait, text = fmt.aprintf("storage: ok, generation %d: ", before), any_order = true})
	append(&second, Step{kind = .Wait, text = " blocks checked, 0 wrong, in "})
	append(&second, Step{kind = .Front, text = "console"})
	append(&second, Step{kind = .Type, text = "connect(\"storage\")"})
	append(&second, Step{kind = .Wait, text = "[console]   module     storage"})
	append(&second, Step{kind = .Type, text = "storage.read(0, \"" + DROPPED_WRITE_OBJECT + "\")"})
	append(&second, Step{kind = .Wait, text = "[console] " + DROPPED_WRITE_FIRST_VERSION, fails_on = "[console] " + DROPPED_WRITE_MARKER})
	append(&second, Step{kind = .Quit})
	return machine_test(part, second[:], {volume = BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_DROPPED_WRITE, 2), exit_status = 0, data_disk = TEST_DROPPED_WRITE_DISK})
}

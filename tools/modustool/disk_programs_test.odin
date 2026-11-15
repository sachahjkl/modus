package modustool

import "core:slice"
import "core:testing"
import "modus:contract/blake3"
import format "modus:contract/store"
import "modus:support/disk_program"
import "modus:support/principals"
import "modus:support/storage_mount"

// The line that the scenario of the debugger names is the line of the
// call of sleep_for_ever in the entry of visitor.
@(test)
visitor_line_of_the_sleep_is_the_call :: proc(t: ^testing.T) {
	content, read := read_file(PROGRAM_SOURCES + DISK_PROGRAM_MODULE + "/main.odin")
	if !testing.expect(t, read) {
		return
	}
	line, found := source_line_of_content(string(content), 93)
	testing.expect_value(t, VISITOR_LINE_OF_THE_SLEEP, "93")
	testing.expect(t, found && line == "\tsleep_for_ever()", line)
}

// The line that the scenario of the stop report names is the line of the
// write to the address 0 in fault_three of visitor.
@(test)
visitor_line_of_the_fault_is_the_write :: proc(t: ^testing.T) {
	content, read := read_file(PROGRAM_SOURCES + DISK_PROGRAM_MODULE + "/main.odin")
	if !testing.expect(t, read) {
		return
	}
	line, found := source_line_of_content(string(content), 169)
	testing.expect_value(t, VISITOR_LINE_OF_THE_FAULT, "169")
	testing.expect(t, found && line == "\tintrinsics.volatile_store((^u64)(address), 1)", line)
}

// The bytes of a test file: no block of them is all zero.
@(private = "file")
test_file_bytes :: proc(count: int, seed: u8) -> []u8 {
	bytes := make([]u8, count, context.temp_allocator)
	for &byte, index in bytes {
		byte = u8(index * 31 + index / 251) ~ seed | 1
	}
	return bytes
}

@(private = "file")
stored_program :: proc(contents: ^Disk_Contents, name: string) -> ^Stored_Object {
	for &item in contents.objects {
		if item.store == disk_program.STORE_NAME && item.name == name {
			return &item
		}
	}
	return nil
}

// The open of the storage service takes the disk that the tool writes: no
// block is wrong, the counts of the store are the counts of what it names,
// and each object gives its bytes and has the hash of its entry.
@(test)
the_storage_open_takes_the_disk_of_the_tool :: proc(t: ^testing.T) {
	// One block, a part of a block, two blocks with one object node, and
	// 70 blocks with two levels of object nodes.
	files := [?]Program_File {
		{"one_block", test_file_bytes(format.BLOCK_SIZE, 1)},
		{"small", test_file_bytes(10, 2)},
		{"two_blocks", test_file_bytes(format.BLOCK_SIZE + 904, 3)},
		{"two_levels", test_file_bytes(69 * format.BLOCK_SIZE + 17, 4)},
	}
	image, encoded := program_disk_encode(files[:], 256 * format.BLOCK_SIZE)
	if !testing.expect(t, encoded) {
		return
	}
	defer delete(image)
	state := new(storage_mount.State)
	defer free(state)
	contents := disk_contents(image, state)
	mount := contents.mount
	testing.expect(t, !mount.failed && !mount.needs_format, "the open takes the disk")
	testing.expect_value(t, mount.generation, u64(PROGRAM_DISK_GENERATION))
	testing.expect_value(t, mount.stores, u64(1))
	testing.expect_value(t, mount.objects, u64(len(files)))
	testing.expect_value(t, mount.trees, u64(0))
	testing.expect_value(t, mount.wrong, u64(0))
	testing.expect_value(t, mount.damaged_objects, u64(0))
	testing.expect_value(t, mount.damaged_stores, u64(0))
	testing.expect_value(t, mount.stores_with_wrong_count, u64(0))
	testing.expect_value(t, mount.stores_recounted, u64(0))
	testing.expect_value(t, mount.named_twice, u64(0))
	testing.expect_value(t, hashes_wrong(&contents), 0)
	// The limit of the store is the limit that the root service grants for
	// a read: a read then writes no root.
	testing.expect_value(t, state.root.stores[0].limit, u64(disk_program.STORE_BLOCKS_LIMIT))
	// The blocks: 1, 1, 2 with one node, 70 with two nodes of level 1 and
	// one of level 2; one leaf and the store block.
	testing.expect_value(t, state.root.stores[0].used, u64(1 + 1 + 3 + 73 + 2))
	for file in files {
		stored := stored_program(&contents, file.name)
		if !testing.expectf(t, stored != nil, "the store has the entry %s", file.name) {
			continue
		}
		testing.expectf(t, !stored.tree && !stored.damaged && !stored.hash_wrong, "the entry %s is an object with no damage", file.name)
		testing.expectf(t, slice.equal(stored.bytes, file.bytes), "the entry %s gives its bytes", file.name)
		testing.expect_value(t, len(stored.versions), 0)
	}
}

// The disk of a named principal: the store programs of principal 1 has the
// name that the root service gives it, and the open of the storage service
// takes a disk with both stores, each with its own objects.
@(test)
the_store_of_the_module_files_of_a_named_principal :: proc(t: ^testing.T) {
	buffer: [32]u8
	testing.expect(t, principals.store_name_write(&buffer, disk_program.STORE_NAME, 1, false))
	testing.expect_value(t, string(buffer[:len(PRINCIPAL_PROGRAMS_STORE)]), PRINCIPAL_PROGRAMS_STORE)
	testing.expect_value(t, buffer[len(PRINCIPAL_PROGRAMS_STORE)], u8(0))
	files := [?]Program_File{{"one", test_file_bytes(100, 1)}, {"two", test_file_bytes(200, 2)}}
	principal_files := [?]Program_File{{"one", test_file_bytes(300, 3)}}
	image, encoded := program_disk_encode(files[:], 64 * format.BLOCK_SIZE, principal_files[:])
	if !testing.expect(t, encoded) {
		return
	}
	defer delete(image)
	state := new(storage_mount.State)
	defer free(state)
	contents := disk_contents(image, state)
	testing.expect(t, !contents.mount.failed && !contents.mount.needs_format)
	testing.expect_value(t, contents.mount.stores, u64(2))
	testing.expect_value(t, contents.mount.objects, u64(3))
	testing.expect_value(t, contents.mount.wrong, u64(0))
	testing.expect_value(t, contents.mount.stores_with_wrong_count, u64(0))
	found := false
	for &item in contents.objects {
		if item.store == PRINCIPAL_PROGRAMS_STORE && item.name == "one" {
			found = true
			testing.expect(t, slice.equal(item.bytes, principal_files[0].bytes))
		}
	}
	testing.expect(t, found)
	stored := stored_program(&contents, "one")
	testing.expect(t, stored != nil && slice.equal(stored.bytes, files[0].bytes))
}

// A file with no hole has the BLAKE3 hash of its bytes as the hash of its
// entry: the hash that the root service computes on the bytes that it
// reads is then the hash that a reader of the store sees.
@(test)
the_hash_of_an_entry_is_the_hash_of_the_bytes :: proc(t: ^testing.T) {
	for count in ([]int{1, 1024, format.BLOCK_SIZE, format.BLOCK_SIZE + 1, 5 * format.BLOCK_SIZE, 64 * format.BLOCK_SIZE, 64 * format.BLOCK_SIZE + 1, 100_000}) {
		bytes := test_file_bytes(count, 9)
		disk := Program_Disk {
			image = make([]u8, 256 * format.BLOCK_SIZE, context.temp_allocator),
			next  = 2,
		}
		entry, held, written := program_object_write(&disk, bytes)
		testing.expectf(t, written, "an object of %d bytes is written", count)
		testing.expectf(t, entry.hash == blake3.hash(bytes), "an object of %d bytes has the hash of its bytes", count)
		testing.expect_value(t, entry.size, u64(count))
		// Each block of data, and each object node above them.
		blocks := format.object_blocks(u64(count))
		nodes: u64
		for level in 1 ..= format.object_levels(u64(count)) {
			span := format.object_span(level)
			nodes += (blocks + span - 1) / span
		}
		testing.expectf(t, held == blocks + nodes, "an object of %d bytes holds %d blocks, and must hold %d", count, held, blocks + nodes)
		testing.expect_value(t, disk.next, 2 + held)
	}
}

// A block of zero bytes is a hole: the writer writes no block for it, and
// the open of the storage service still takes the object and gives its
// bytes. The hash of its entry is then not the BLAKE3 hash of its bytes,
// which is why the root service hashes the bytes that it reads.
@(test)
a_file_with_a_hole :: proc(t: ^testing.T) {
	bytes := test_file_bytes(6 * format.BLOCK_SIZE + 100, 5)
	for &byte in bytes[2 * format.BLOCK_SIZE:][:2 * format.BLOCK_SIZE] {
		byte = 0
	}
	files := [?]Program_File{{"holed", bytes}}
	image, encoded := program_disk_encode(files[:], 64 * format.BLOCK_SIZE)
	if !testing.expect(t, encoded) {
		return
	}
	defer delete(image)
	state := new(storage_mount.State)
	defer free(state)
	contents := disk_contents(image, state)
	testing.expect(t, !contents.mount.failed && !contents.mount.needs_format)
	testing.expect_value(t, contents.mount.wrong, u64(0))
	testing.expect_value(t, contents.mount.damaged_objects, u64(0))
	testing.expect_value(t, contents.mount.stores_with_wrong_count, u64(0))
	// 7 blocks, 2 of them holes, and one object node; the leaf and the
	// store block.
	testing.expect_value(t, state.root.stores[0].used, u64(5 + 1 + 2))
	stored := stored_program(&contents, "holed")
	if !testing.expect(t, stored != nil) {
		return
	}
	testing.expect(t, !stored.damaged && !stored.hash_wrong)
	testing.expect(t, slice.equal(stored.bytes, bytes))
	testing.expect_value(t, len(stored.blocks), 5)
}

// A debug object goes beside its module file under the hash of the module,
// with a limit of its own; the open of the storage service takes it as an
// object of the store. A debug object that names another module is refused.
@(test)
a_debug_object_beside_its_module_file :: proc(t: ^testing.T) {
	module_file := test_file_bytes(300, 7)
	// A debug object that the readers take is made by the build: here,
	// only the refusals that need no build are checked, and the name.
	refused, accepted := program_debug_object_file("small", module_file, test_file_bytes(200, 8))
	testing.expect(t, !accepted && refused.name == "")
	digits: [disk_program.HASH_DIGITS]u8
	disk_program.debug_object_name_write(&digits, blake3.hash(module_file))
	// An object larger than a module file may be, and under the limit of a
	// debug object.
	large := test_file_bytes(disk_program.FILE_BYTES_LIMIT + format.BLOCK_SIZE, 9)
	files := [?]Program_File{{"small", module_file}, {string(digits[:]), large}}
	image, encoded := program_disk_encode(files[:], 2 * disk_program.FILE_BYTES_LIMIT)
	if !testing.expect(t, encoded) {
		return
	}
	defer delete(image)
	state := new(storage_mount.State)
	defer free(state)
	contents := disk_contents(image, state)
	testing.expect(t, !contents.mount.failed && !contents.mount.needs_format)
	testing.expect_value(t, contents.mount.objects, u64(2))
	stored := stored_program(&contents, string(digits[:]))
	// The reader of the test keeps the bytes of an object of at most
	// CONTENTS_BYTES_LIMIT only: this one is larger, so its size and its
	// blocks are checked.
	if testing.expect(t, stored != nil) {
		testing.expect_value(t, stored.size, u64(len(large)))
		testing.expect(t, !stored.damaged)
	}
	over := [?]Program_File{{string(digits[:]), test_file_bytes(disk_program.DEBUG_OBJECT_BYTES_LIMIT + 1, 3)}}
	_, over_encoded := program_disk_encode(over[:], 4 * disk_program.DEBUG_OBJECT_BYTES_LIMIT)
	testing.expect(t, !over_encoded)
}

// The writer refuses what the root service would refuse: a name that is no
// name of a disk program, two files of one name, a file with no byte, and
// more files than one leaf holds.
@(test)
the_writer_refuses_a_wrong_store :: proc(t: ^testing.T) {
	good := test_file_bytes(100, 1)
	refused := [][]Program_File {
		{},
		{{"", good}},
		{{"a/b", good}},
		{{"programs", good}},
		{{"twenty_four_bytes_long__", good}},
		{{"same", good}, {"same", good}},
		{{"empty", nil}},
	}
	for files in refused {
		image, encoded := program_disk_encode(files, 64 * format.BLOCK_SIZE)
		testing.expectf(t, !encoded && image == nil, "%d files are refused", len(files))
	}
	// A debug object takes the hash of its module as its name, and no other
	// name of 64 bytes: upper case digits are no such name.
	upper_case_digits := "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789"
	_, upper_encoded := program_disk_encode([]Program_File{{upper_case_digits, good}}, 64 * format.BLOCK_SIZE)
	testing.expect(t, !upper_encoded)
	many := make([]Program_File, format.LEAF_CAPACITY + 1, context.temp_allocator)
	for &file in many {
		file = {"x", good}
	}
	_, encoded := program_disk_encode(many, 64 * format.BLOCK_SIZE)
	testing.expect(t, !encoded)
	// A disk that is too small for the file.
	large := [?]Program_File{{"large", test_file_bytes(40 * format.BLOCK_SIZE, 1)}}
	_, encoded = program_disk_encode(large[:], 16 * format.BLOCK_SIZE)
	testing.expect(t, !encoded)
}

#+build !freestanding
#+build !modus
package system

import "modus:contract/blake3"
import info "modus:contract/boot_info"
import module "modus:contract/module"
import "core:testing"

// The table of the checked entries of an image (Load_Source.image_checks,
// docs/TRUSTED_BOOT.md, "Layer 1: the signed system description"): the
// loader hashes an entry once, refuses an entry whose bytes do not have its
// hash, and hashes every other file on its bytes.

// A module with no code and no import: a header and an empty table of imports.
@(private = "file")
module_alone :: proc(storage: []u8, mark: u8) -> []u8 {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	directory: Directory
	offset := u64(size_of(module.Header) + size_of(Directory))
	directory[module.Table_Kind.Imports] = {offset = offset, count = 1, record_size = size_of(module.Import)}
	(^module.Header)(&storage[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^Directory)(&storage[size_of(module.Header)])^ = directory
	end := offset + size_of(module.Import)
	storage[end] = mark // One byte after the tables: two modules of two marks have two hashes.
	return storage[:end + 1]
}

// An image of one module entry, with the hash of the file that it holds.
@(private = "file")
image_of_one :: proc(storage: []u8, name: string, file: []u8) -> []u8 {
	(^info.Image_Header)(&storage[0])^ = {magic = info.IMAGE_MAGIC, count = 1}
	entry := (^info.Image_Entry)(&storage[size_of(info.Image_Header)])
	offset := u64(size_of(info.Image_Header) + size_of(info.Image_Entry))
	entry^ = {hash = blake3.hash(file), offset = offset, size = u64(len(file))}
	copy(entry.name[:], name)
	copy(storage[offset:], file)
	return storage[:offset + u64(len(file))]
}

@(private = "file")
entry_bytes :: proc(image: []u8) -> []u8 {
	entry := &image_entries(image)[0]
	return image[entry.offset:][:entry.size]
}

@(test)
the_loader_refuses_an_entry_whose_bytes_changed :: proc(t: ^testing.T) {
	module_storage: [512]u8
	file := module_alone(module_storage[:], 1)
	image_storage: [1024]u8
	image := image_of_one(image_storage[:], "alpha", file)
	hash := image_entries(image)[0].hash
	entry_bytes(image)[len(file) - 1] ~= 0xFF
	// With no table: the hash of the bytes differs, the import is refused.
	_, stage, _ := source_file({image = image}, hash)
	testing.expect_value(t, stage, module.Load_Stage.Read)
	// With a table: refused too, and the table keeps no mark.
	checks: Image_Checks
	source := Load_Source{image = image, image_checks = &checks}
	_, stage, _ = source_file(source, hash)
	testing.expect_value(t, stage, module.Load_Stage.Read)
	testing.expect(t, !checks.checked[0], "a refused entry is not marked")
	// As the first file of a load: refused before any read of its tables.
	named, agrees := first_file_hash(source, entry_bytes(image))
	testing.expect(t, !agrees)
	testing.expect(t, named == hash, "the refusal names the entry")
	space := Module_Space{source = source}
	error: module.Load_Error
	index, loaded := module_space_load(&space, entry_bytes(image), &error)
	testing.expect(t, !loaded && index == -1)
	testing.expect_value(t, error.stage, u32(module.Load_Stage.Read))
}

@(test)
the_loader_refuses_a_changed_file_beside_the_image :: proc(t: ^testing.T) {
	module_storage, other_storage: [512]u8
	file := module_alone(module_storage[:], 2)
	other := module_alone(other_storage[:], 3)
	checks: Image_Checks
	image_storage: [1024]u8
	image := image_of_one(image_storage[:], "alpha", other)
	// A file of the store that the starter names by a hash that its bytes
	// do not have.
	hash := blake3.hash(file)
	file[len(file) - 1] ~= 0xFF
	_, stage, _ := source_file({image = image, files = []Source_File{{hash = hash, bytes = file, name = "beta"}}, image_checks = &checks}, hash)
	testing.expect_value(t, stage, module.Load_Stage.Read)
}

@(test)
the_loader_hashes_each_file_that_is_not_a_whole_entry :: proc(t: ^testing.T) {
	module_storage, outside_storage: [512]u8
	file := module_alone(module_storage[:], 4)
	image_storage: [1024]u8
	image := image_of_one(image_storage[:], "alpha", file)
	checks: Image_Checks
	checks.checked[0] = true // The table says the entry agrees: only the whole entry takes it.
	source := Load_Source{image = image, image_checks = &checks}
	whole := entry_bytes(image)
	entry_hash := image_entries(image)[0].hash
	// A file outside the image.
	outside := module_alone(outside_storage[:], 5)
	hash, agrees := first_file_hash(source, outside)
	testing.expect(t, agrees && hash == blake3.hash(outside))
	// A part of the entry, at its address.
	hash, agrees = first_file_hash(source, whole[:len(whole) - 1])
	testing.expect(t, agrees && hash == blake3.hash(whole[:len(whole) - 1]))
	// The address of the entry with one byte more (the storage of the test
	// has room past the image).
	longer := ([^]u8)(raw_data(whole))[:len(whole) + 1]
	hash, agrees = first_file_hash(source, longer)
	testing.expect(t, agrees && hash == blake3.hash(longer) && hash != entry_hash)
	// A part of the entry from its second byte.
	hash, agrees = first_file_hash(source, whole[1:])
	testing.expect(t, agrees && hash == blake3.hash(whole[1:]))
	// The bytes of the entry in another buffer.
	copy_storage: [512]u8
	copied := copy_storage[:len(whole)]
	copy(copied, whole)
	copied[len(copied) - 1] ~= 0xFF
	hash, agrees = first_file_hash(source, copied)
	testing.expect(t, agrees && hash == blake3.hash(copied) && hash != entry_hash)
	// A file of no byte: refused by the load, with no kernel call.
	space := Module_Space{source = source}
	error: module.Load_Error
	_, loaded := module_space_load(&space, nil, &error)
	testing.expect(t, !loaded)
	testing.expect_value(t, error.stage, u32(module.Load_Stage.Read))
}

@(test)
the_loader_hashes_an_entry_once :: proc(t: ^testing.T) {
	module_storage: [512]u8
	file := module_alone(module_storage[:], 6)
	image_storage: [1024]u8
	image := image_of_one(image_storage[:], "alpha", file)
	hash := image_entries(image)[0].hash
	checks: Image_Checks
	source := Load_Source{image = image, image_checks = &checks}
	found, stage, _ := source_file(source, hash)
	testing.expect_value(t, stage, module.Load_Stage.None)
	testing.expect(t, raw_data(found) == raw_data(entry_bytes(image)) && len(found) == len(file))
	testing.expect(t, checks.checked[0], "the entry that agrees is marked")
	named, agrees := first_file_hash(source, entry_bytes(image))
	testing.expect(t, agrees && named == hash)
	// Marked: the table answers, the bytes are not hashed again. The pages
	// of an image are never written while the table lives (the condition
	// of TRUSTED_BOOT.md); here a write shows that no second hash runs.
	entry_bytes(image)[len(file) - 1] ~= 0xFF
	_, stage, _ = source_file(source, hash)
	testing.expect_value(t, stage, module.Load_Stage.None)
	// With no table, the same bytes are refused: each call hashes.
	_, stage, _ = source_file({image = image}, hash)
	testing.expect_value(t, stage, module.Load_Stage.Read)
}

#+build !freestanding
package system

import "base:runtime"
import "core:sys/posix"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/fixed_addresses"
import module "modus:contract/module"

// A module with no code whose one import is the module of next_hash: the
// header, its table of imports (the record 0 is no import), and a mark.
@(private = "file")
module_importing :: proc(storage: []u8, next_hash: [32]u8, has_import: bool, mark: u8) -> []u8 {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	directory: Directory
	offset := u64(size_of(module.Header) + size_of(Directory))
	count := u32(has_import ? 2 : 1)
	directory[module.Table_Kind.Imports] = {offset = offset, count = count, record_size = size_of(module.Import)}
	(^module.Header)(&storage[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^Directory)(&storage[size_of(module.Header)])^ = directory
	if has_import {
		(^module.Import)(&storage[offset + size_of(module.Import)])^ = {hash = next_hash}
	}
	end := offset + u64(count) * size_of(module.Import)
	storage[end] = mark
	return storage[:end + 1]
}

// The load of a chain: what the thread with a small stack gives back.
Chain_Load :: struct {
	space:  Module_Space,
	first:  []u8,
	error:  module.Load_Error,
	loaded: bool,
	ran:    bool,
}

// A chain of MODULE_SPACE_CAPACITY modules, each the import of the one
// before, loads to its last module on a stack of 64 KiB: place walks the
// imports with the frames of the space, not with a call for each import. The space starts
// so near the band of the fixed ranges that the last module has no room:
// the load ends there, before its first kernel call, which a host test
// cannot make; each module before it was placed, one frame each.
@(test)
a_chain_of_the_most_modules_loads_on_a_small_stack :: proc(t: ^testing.T) {
	CHAIN :: MODULE_SPACE_CAPACITY
	storages := make([][1024]u8, CHAIN, context.temp_allocator)
	files := make([]Source_File, CHAIN, context.temp_allocator)
	next_hash: [32]u8
	for index := CHAIN - 1; index >= 0; index -= 1 {
		file := module_importing(storages[index][:], next_hash, index < CHAIN - 1, u8(index))
		testing.expect_value(t, module.validate(file), module.Error.None)
		next_hash = blake3.hash(file)
		files[index] = {hash = next_hash, bytes = file, name = "chain"}
	}
	chain := new(Chain_Load, context.temp_allocator)
	chain.space = {source = {files = files}, next = fixed_addresses.MODULES_END - (CHAIN - 1) * PAGE_SIZE}
	chain.first = files[0].bytes

	run :: proc "c" (argument: rawptr) -> rawptr {
		context = runtime.default_context()
		chain := (^Chain_Load)(argument)
		_, chain.loaded = module_space_load(&chain.space, chain.first, &chain.error)
		chain.ran = true
		return nil
	}
	attributes: posix.pthread_attr_t
	testing.expect_value(t, posix.pthread_attr_init(&attributes), posix.Errno.NONE)
	testing.expect_value(t, posix.pthread_attr_setstacksize(&attributes, 64 * 1024), posix.Errno.NONE)
	thread: posix.pthread_t
	testing.expect_value(t, posix.pthread_create(&thread, &attributes, run, chain), posix.Errno.NONE)
	posix.pthread_join(thread, nil)
	posix.pthread_attr_destroy(&attributes)

	testing.expect(t, chain.ran)
	testing.expect(t, !chain.loaded)
	testing.expect_value(t, chain.error.stage, u32(module.Load_Stage.Room))
	testing.expect(t, chain.error.imported.hash == files[CHAIN - 1].hash, "the refusal names the last module of the chain")
	testing.expect(t, chain.error.module.hash == files[CHAIN - 2].hash, "the refusal names its importer")
	// The failed load leaves the space as it was.
	for item in chain.space.modules {
		testing.expect_value(t, item.users, 0)
	}
}

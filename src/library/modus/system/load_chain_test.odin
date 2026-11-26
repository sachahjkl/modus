#+build !freestanding
#+build !modus
package system

import "base:intrinsics"
import "base:runtime"
import "core:sys/posix"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/fixed_addresses"
import module "modus:contract/module"
import op "modus:contract/operation"

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

// The maps of a load with no kernel: the order of the modules that the walk
// maps, each after its imports.
Fake_Maps :: struct {
	order: [MODULE_SPACE_CAPACITY]int,
	count: int,
	space: ^Module_Space,
}

fake_maps: Fake_Maps

@(private = "file")
fake_map :: proc "contextless" (space: ^Module_Space, item: ^Placed, head: module.Header, imports: []module.Bound_Import, error: ^module.Load_Error) -> bool {
	// Each import is mapped before the module that imports it.
	for number in 0 ..< int(item.import_count) {
		used := &space.modules[item.import_places[number]]
		if used.loading {
			return false
		}
	}
	fake_maps.order[fake_maps.count] = int(intrinsics.ptr_sub(item, &space.modules[0]))
	fake_maps.count += 1
	return true
}

// A chain of MODULE_SPACE_CAPACITY modules loads whole on a stack of 64
// KiB: each module is mapped after its import, the last of the chain first,
// and each holds one user and no load in progress.
@(test)
a_chain_of_the_most_modules_loads_whole :: proc(t: ^testing.T) {
	CHAIN :: MODULE_SPACE_CAPACITY
	storages := make([][1024]u8, CHAIN, context.temp_allocator)
	files := make([]Source_File, CHAIN, context.temp_allocator)
	next_hash: [32]u8
	for index := CHAIN - 1; index >= 0; index -= 1 {
		file := module_importing(storages[index][:], next_hash, index < CHAIN - 1, u8(index))
		next_hash = blake3.hash(file)
		files[index] = {hash = next_hash, bytes = file, name = "chain"}
	}
	chain := new(Chain_Load, context.temp_allocator)
	chain.space = {source = {files = files}, next = op.MODULE_BASE, map_module = fake_map}
	chain.first = files[0].bytes
	fake_maps = {}
	run :: proc "c" (argument: rawptr) -> rawptr {
		context = runtime.default_context()
		chain := (^Chain_Load)(argument)
		_, chain.loaded = module_space_load(&chain.space, chain.first, &chain.error)
		chain.ran = true
		return nil
	}
	attributes: posix.pthread_attr_t
	posix.pthread_attr_init(&attributes)
	posix.pthread_attr_setstacksize(&attributes, 64 * 1024)
	thread: posix.pthread_t
	testing.expect_value(t, posix.pthread_create(&thread, &attributes, run, chain), posix.Errno.NONE)
	posix.pthread_join(thread, nil)
	posix.pthread_attr_destroy(&attributes)

	testing.expect(t, chain.ran && chain.loaded)
	testing.expect_value(t, fake_maps.count, CHAIN)
	for item in chain.space.modules {
		testing.expect_value(t, item.users, 1)
		testing.expect(t, !item.loading)
	}
	// The place of a module is the order of its first sight: the first
	// module has the place 0, its import 1, and the last of the chain is
	// mapped first.
	for index in 0 ..< CHAIN {
		testing.expect_value(t, fake_maps.order[index], CHAIN - 1 - index)
	}
}

// A cycle: the second module imports a hash that a replacement of the load
// source gives as the first module, which loads. The load refuses it with
// the stage Cycle, names the replacement that made it, maps nothing, and
// leaves the space as it was.
@(test)
a_cycle_of_imports_is_refused :: proc(t: ^testing.T) {
	first_storage, second_storage: [1024]u8
	elsewhere := blake3.hash(transmute([]u8)string("a module that the source does not hold"))
	second := module_importing(second_storage[:], elsewhere, true, 2)
	first := module_importing(first_storage[:], blake3.hash(second), true, 1)
	first_hash := blake3.hash(first)
	files := []Source_File{{hash = first_hash, bytes = first, name = "first"}, {hash = blake3.hash(second), bytes = second, name = "second"}}
	replacements := []module.Replacement{{from = elsewhere, to = first_hash}}
	space := new(Module_Space, context.temp_allocator)
	space^ = {source = {files = files, replacements = replacements}, next = op.MODULE_BASE, map_module = fake_map}
	fake_maps = {}
	error: module.Load_Error
	index, loaded := module_space_load(space, first, &error)
	testing.expect(t, !loaded && index == -1)
	testing.expect_value(t, error.stage, u32(module.Load_Stage.Cycle))
	testing.expect(t, error.module.hash == blake3.hash(second), "the cycle names the module whose import closes it")
	testing.expect(t, error.replaced.hash == elsewhere && error.replacement.hash == first_hash, "the cycle names the replacement that made it")
	testing.expect_value(t, fake_maps.count, 0)
	for item in space.modules {
		testing.expect_value(t, item.users, 0)
	}
}

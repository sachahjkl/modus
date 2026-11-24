package system

import "base:intrinsics"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "modus:contract/fixed_addresses"
import op "modus:contract/operation"
import module "modus:contract/module"
import "modus:contract/ring"
import "modus:contract/system_description"
import "modus:contract/value_kinds"

// The loader (docs/ARCHITECTURE.md, U3): it builds a process from a module
// and its imports. It runs in user space. The kernel only creates the empty
// process and maps memory.

// image_entries gives the entries of the boot image.
image_entries :: proc "contextless" (image: []u8) -> []info.Image_Entry {
	if len(image) < size_of(info.Image_Header) {
		return nil
	}
	header := (^info.Image_Header)(raw_data(image))
	if header.magic != info.IMAGE_MAGIC || size_of(info.Image_Header) + int(header.count) * size_of(info.Image_Entry) > len(image) {
		return nil
	}
	return ([^]info.Image_Entry)(raw_data(image[size_of(info.Image_Header):]))[:header.count]
}

// image_resources gives the entries of the resources of the boot image:
// the table after the table of the modules.
image_resources :: proc "contextless" (image: []u8) -> []info.Image_Entry {
	modules := image_entries(image)
	if modules == nil {
		return nil
	}
	header := (^info.Image_Header)(raw_data(image))
	first := size_of(info.Image_Header) + len(modules) * size_of(info.Image_Entry)
	if first + int(header.resource_count) * size_of(info.Image_Entry) > len(image) {
		return nil
	}
	return ([^]info.Image_Entry)(raw_data(image[first:]))[:header.resource_count]
}

// image_resource_find gives the entry of the resource with this name, or
// nil. The entry is inside the image and starts on a page. The caller
// checks the hash of the bytes.
image_resource_find :: proc "contextless" (image: []u8, name: string) -> ^info.Image_Entry {
	for &entry in image_resources(image) {
		if name_of(entry.name[:]) == name && entry.offset % PAGE_SIZE == 0 && entry.offset <= u64(len(image)) && entry.size <= u64(len(image)) - entry.offset {
			return &entry
		}
	}
	return nil
}

// image_find gives the module file with this name. The result is empty when
// the image has no such module.
image_find :: proc "contextless" (image: []u8, name: string) -> []u8 {
	for &entry in image_entries(image) {
		if name_of(entry.name[:]) == name && entry.offset <= u64(len(image)) && entry.size <= u64(len(image)) - entry.offset {
			return image[entry.offset:][:entry.size]
		}
	}
	return nil
}

// image_entry_of gives the entry that names a hash, or nil. The entry is
// what the image says: the caller checks the hash of the file.
image_entry_of :: proc "contextless" (image: []u8, hash: [32]u8) -> ^info.Image_Entry {
	for &entry in image_entries(image) {
		if entry.hash == hash && entry.offset <= u64(len(image)) && entry.size <= u64(len(image)) - entry.offset {
			return &entry
		}
	}
	return nil
}

// A grant: a handle that a new process receives, and the rights of its copy.
//
// `process_start` gives each grant with `give` at its index of the context;
// a zero handle is no grant. Example, in the root service:
// `grants[system.GRANT_MACHINE] = {machine, {.Inspect, .Stop}}`.
Grant :: struct {
	handle: Handle, // A handle of the starter. 0: no grant at this index.
	rights: Rights, // The rights of the copy: at most the rights of `handle`.
}

// A part of a memory object at an address of a process.
//
// `process_start` maps each one in the new process before its start: a
// starter gives a fixed range this way.
Mapping :: struct {
	memory:     Handle, // The memory object, with the rights of `flags`.
	address:    u64, // The address in the new process.
	first:      u64, // The first page of the memory object.
	page_count: u64, // 0: all pages from first.
	flags:      op.Map_Flags, // The access of the pages.
}

PREPARED_CAPACITY :: 64 // Two parts for each module: the code, and the fixed part for one base.

// The parts of a module for a loader (Module_Part).
//   Code:  the segments with no Write: the code and the constants. The
//          loader never writes them (a rebase or an import slot is in a segment
//          with Write), so their pages are the same at each base, with
//          each binding: one copy for all the processes of the table.
//   Fixed: the segments that are read-only after the load: the loader
//          writes their rebases and their import slots, so their pages are for
//          one base and one binding.
//   All:   each segment: the copy of a module that has no table.
Module_Part :: enum u8 {
	All, // Each segment, for one process.
	Code, // The segments with no Write, shared by every process.
	Fixed, // The segments read-only after the load, for one base and one binding.
}

// A prepared module: a memory object that holds one part of a module as the
// loader prepared it, its segments copied from the file, and for the part
// Fixed rebased at base and bound. Each process that runs the module maps
// the pages that do not change (the shared code of the module), and
// receives its own copy of the writable pages. The loader writes the
// memory object one time; after that, the table holds it with the rights
// Read and Execute only, so no process writes it.
Prepared :: struct {
	hash:    [32]u8, // The hash of the module file.
	part:    Module_Part, // Which segments the memory object holds.
	base:    u64, // Fixed: the address of the module in each process that maps it.
	binding: [32]u8, // Fixed: what its import slots hold (binding_of): zero for a module with no import.
	first:   u64, // The offset in the module of the first page of the memory object.
	memory:  Handle, // 0: the place is free.
	pages:   u64, // The pages of the memory object.
	// The value of Prepared_Modules.uses at its last find: the order of use
	// that prepared_yield reads. A count of the finds, no time.
	last_use: u64,
}

// The prepared modules of a process that starts processes. The zero value is
// an empty table. The budget of the process that owns the table pays for
// each prepared module. A prepared module stays while a process maps it:
// each start closes the ones that no process maps. The table is a cache:
// each part holds one handle of its owner, and prepared_yield closes the
// parts used least recently when the owner needs the room of its handle
// table. A process that maps a part keeps its mapping; the next start of
// that module prepares the part again.
Prepared_Modules :: struct {
	lock:    Lock, // The threads of the owner that start processes take it.
	modules: [PREPARED_CAPACITY]Prepared,
	uses:    u64, // The finds of the table: the last one stamps the part that it gives.
}

// The load source: where a loader finds the imports of a module. Nothing
// else: the loader has no search path and no ambient module store, so a
// process reaches only the modules that it was granted.
Load_Source :: struct {
	image:        []u8, // The files that the process was granted, in the form of the boot image. A file has the hash that names it, or the loader refuses it.
	files:        []Source_File, // Files beside the image, which the starter read and gives. A file of the image with the same hash is taken first.
	replacements: []module.Replacement, // From the party that starts the process. The process cannot change them.
	// The entries of the image whose bytes were hashed against their
	// entry, or nil: then the loader hashes each file at each load. Only
	// the root service gives one, for its boot image, whose entries its
	// start checked against the system description (docs/TRUSTED_BOOT.md,
	// "Layer 1: the signed system description"); `modustool check` refuses
	// the name elsewhere.
	image_checks: ^Image_Checks,
}

// The entries of an image whose bytes have the hash of their entry. A
// party that hashed an entry marks it, and does not hash it again: the
// rule holds while no process writes the pages of the image (the kernel
// gives them with Read only, and a device reaches them only with no IOMMU).
IMAGE_CHECK_CAPACITY :: system_description.ENTRY_CAPACITY
Image_Checks :: struct {
	checked: [IMAGE_CHECK_CAPACITY]bool, // By the place of the entry: the modules, then the resources.
}

// image_entry_place gives the place of an entry of the image in a table
// of checks: the modules first, then the resources. ok is false for an
// entry of no table of the image, and past the capacity.
image_entry_place :: proc "contextless" (image: []u8, entry: ^info.Image_Entry) -> (place: int, ok: bool) {
	modules := image_entries(image)
	for &candidate, index in modules {
		if &candidate == entry {
			return index, index < IMAGE_CHECK_CAPACITY
		}
	}
	for &candidate, index in image_resources(image) {
		if &candidate == entry {
			place = len(modules) + index
			return place, place < IMAGE_CHECK_CAPACITY
		}
	}
	return 0, false
}

// image_entry_check says whether the bytes of an entry of the image have
// the hash of the entry. A table of checks answers for an entry hashed
// before, and keeps each entry whose bytes agree; with no table, each call
// hashes. An entry outside the image does not agree.
image_entry_check :: proc "contextless" (image: []u8, checks: ^Image_Checks, entry: ^info.Image_Entry) -> bool {
	if entry.offset > u64(len(image)) || entry.size > u64(len(image)) - entry.offset {
		return false
	}
	place, placed := image_entry_place(image, entry)
	if checks != nil && placed && checks.checked[place] {
		return true
	}
	if blake3.hash(image[entry.offset:][:entry.size]) != entry.hash {
		return false
	}
	if checks != nil && placed {
		checks.checked[place] = true
	}
	return true
}

// A module file of a load source that is not in the image: the root
// service gives the files of the store `module_files` that an import scan kept
// (docs/MODULE_CONTRACT.md, "A module from a disk"). The loader checks the
// hash and the tables of the bytes before it uses them, as for a file of
// the image.
Source_File :: struct {
	hash:  [32]u8, // The hash that names the file.
	bytes: []u8, // The file. The starter keeps it mapped until the load ends.
	name:  string, // The name that a load error gives the hash: for a file of a store, the name of its entry. It names no module.
}

MODULE_SPACE_CAPACITY :: op.PROCESS_MODULE_CAPACITY // The modules of one space: the module records that the kernel keeps for one process.
// The imports of one module that this loader binds: each import of a
// module can be another module of the space, so the bound follows the
// module records of a process. A load keeps one table of bound imports on
// the stack for each level of its imports (place).
IMPORT_CAPACITY :: MODULE_SPACE_CAPACITY
#assert(IMPORT_CAPACITY <= 255) // import_places holds each place in one byte.

// One module that a loader put in a process: a place of a module space.
Placed :: struct {
	hash:          [32]u8, // The module that is loaded.
	replaces:      [32]u8, // Zero, or the hash of the import that a replacement changed to this module.
	file:          []u8, // The file of the module, in the load source.
	original:      []u8, // The file of the module that this one replaces: the names of the exports that an import slot uses.
	base:          u64, // The address of the module in the process.
	users:         u32, // The modules that import it, and each load of it by the caller. 0: the place is free.
	loading:       bool, // Its imports are not all loaded: a module that imports it now makes a cycle.
	mapped:        bool, // Its segments are mapped in the process.
	import_count:  u8, // The entries of `import_places` in use.
	import_places: [IMPORT_CAPACITY]u8, // The place of each import.
}

// The modules that a loader put in one process. Each module is in it one
// time: two modules that import a third one call the same copy.
Module_Space :: struct {
	process:     Handle, // 0: this process.
	budget:      Handle, // Pays for the memory of the modules. 0: the budget of this process.
	source:      Load_Source, // Where the imports come from.
	next:        u64, // Where the next module goes.
	modules:     [MODULE_SPACE_CAPACITY]Placed,
	prepared:    ^Prepared_Modules, // Not nil: each module maps its shared code from this table. nil: each module is a copy of its own.
	// The modules that place loads now, the first at the bottom: the path
	// from the module of the caller to the import that loads. place walks
	// the imports with this table, not with a call for each import, so a
	// chain of MODULE_SPACE_CAPACITY modules costs the stack one frame.
	frames: [MODULE_SPACE_CAPACITY]Place_Frame,
	// The map of a module whose imports are placed: nil is place_map, with
	// the kernel; a host test gives one that maps nothing and counts, so the
	// walk of a load runs with no kernel.
	map_module: proc "contextless" (space: ^Module_Space, item: ^Placed, head: module.Header, imports: []module.Bound_Import, error: ^module.Load_Error) -> bool,
}

// One module that place loads: its place, the hash that its importer
// named and the hash of its file, the import that a replacement changed to
// it, its header, and its next import to place.
Place_Frame :: struct {
	item:         int,
	replaces:     [32]u8,
	hash:         [32]u8,
	head:         module.Header,
	import_count: int,
	next_import:  int,
}

// cycles gives the cycle counter of the processor (`rdtsc`), with no kernel
// entry. `nanoseconds` turns it into a time.
cycles :: #force_inline proc "contextless" () -> u64 {
	return u64(intrinsics.read_cycle_counter())
}

// module_space_load loads a module and its imports, each one time, in the
// process of the space. A replacement of the load source applies to each
// import, and not to the module that the caller names. On a failure, the
// space is as it was before, and error has the stage and the modules of the
// failure: the caller owns the record.
//
// details: an optional table of error details (docs/MODULE_CONTRACT.md,
// section 8, "The table of error details"). When the load fails because a
// file of the load source is missing or is not the file of its hash, the
// loader appends one load error for each such import of the whole graph,
// not only the first (load_source_problems).
module_space_load :: proc "contextless" (space: ^Module_Space, file: []u8, error: ^module.Load_Error, details: ^Table_To_Append(module.Load_Error) = nil) -> (index: int, ok: bool) {
	error^ = {}
	hash, agrees := first_file_hash(space.source, file)
	if !agrees {
		// An entry of the image whose bytes do not have its hash: refused
		// before any read of its tables.
		error^ = {stage = u32(module.Load_Stage.Read), module = named_of(space.source, hash)}
		if details != nil {
			table_append(details, error^)
		}
		return -1, false
	}
	if file_error := module.validate(file); len(file) == 0 || file_error != .None {
		error^ = {stage = u32(module.Load_Stage.Read), file_error = u32(file_error), module = named_of(space.source, hash)}
		if details != nil {
			table_append(details, error^)
		}
		return -1, false
	}
	defer if !ok && details != nil && (error.stage == u32(module.Load_Stage.Find) || error.stage == u32(module.Load_Stage.Read)) {
		load_source_problems(space.source, file, details)
	}
	before: [MODULE_SPACE_CAPACITY]u32
	for item, number in space.modules {
		before[number] = item.users
	}
	next := space.next
	index = place(space, hash, file, error)
	if index >= 0 {
		return index, true
	}
	for &item, number in space.modules {
		if before[number] == 0 && item.users != 0 {
			place_remove(space, &item)
		} else {
			item.users = before[number]
			item.loading = false
		}
	}
	space.next = next
	return -1, false
}

// module_space_release ends one use of a module. A module with no use leaves
// the process, and its imports lose one use. If the kernel refuses to
// remove a module, error has the stage Unmap and the module: the space
// forgets the module, and its memory stays in the process.
module_space_release :: proc "contextless" (space: ^Module_Space, index: int, error: ^module.Load_Error) -> bool {
	item := &space.modules[index]
	if item.users == 0 {
		return true
	}
	item.users -= 1
	if item.users > 0 {
		return true
	}
	imports := item.import_places
	count := item.import_count
	if status := place_remove(space, item); status != .Succeeded && error.stage == u32(module.Load_Stage.None) {
		error^ = {stage = u32(module.Load_Stage.Unmap), status = u32(status), module = named_of(space.source, item.hash)}
	}
	for number in 0 ..< count {
		module_space_release(space, int(imports[number]), error)
	}
	return error.stage == u32(module.Load_Stage.None)
}

// load_source_problems appends one load error for each import of the graph
// of a module that the load source does not have (the stage Find), or has
// with another hash or with tables that are not valid (Read), in the order
// in which a load meets them: the order of the imports, depth first. So the
// first of them is the load error of a load that failed at such an import.
// Each module of the graph is read one time. It loads nothing and calls no
// kernel operation.
load_source_problems :: proc "contextless" (source: Load_Source, file: []u8, details: ^Table_To_Append(module.Load_Error)) {
	visited: Visited_Modules
	import_problems(source, blake3.hash(file), file, {}, {}, details, &visited)
}

// The modules that load_source_problems read: a module that two modules
// import is read one time, and a cycle of replacements ends.
@(private = "file")
Visited_Modules :: struct {
	hashes: [MODULE_SPACE_CAPACITY][32]u8,
	count:  int,
}

// import_problems appends the problems of the imports of one module, then
// of their imports. replaced and replacement: the nearest replacement on
// the path from the first module, as a load error names it.
@(private = "file")
import_problems :: proc "contextless" (source: Load_Source, importer: [32]u8, file: []u8, replaced, replacement: module.Named, details: ^Table_To_Append(module.Load_Error), visited: ^Visited_Modules) {
	for hash in visited.hashes[:visited.count] {
		if hash == importer {
			return
		}
	}
	// The space of a process holds no more modules: the walk ends there too.
	if visited.count == len(visited.hashes) {
		return
	}
	visited.hashes[visited.count] = importer
	visited.count += 1
	import_count := int(max(module.count(file, .Imports), 1)) - 1
	for number in 0 ..< min(import_count, IMPORT_CAPACITY) {
		record, _ := module.record(file, .Imports, u32(number + 1), module.Import)
		hash := record.hash
		nearest_replaced, nearest_replacement := replaced, replacement
		replaces: [32]u8
		for item in source.replacements {
			if item.from == record.hash {
				hash, replaces = item.to, record.hash
				nearest_replaced, nearest_replacement = named_of(source, record.hash), named_of(source, item.to)
				break
			}
		}
		problem := module.Load_Error {
			module      = named_of(source, importer),
			imported    = named_of(source, record.hash),
			replaced    = nearest_replaced,
			replacement = nearest_replacement,
		}
		imported_file, stage, file_error := source_file(source, hash)
		if stage != .None {
			problem.stage, problem.file_error = u32(stage), u32(file_error)
			table_append(details, problem)
			continue
		}
		// The names of the exports that the import slots use are in the module that
		// the import names: the load reads it too.
		if replaces != {} {
			if _, original_stage, original_error := source_file(source, replaces); original_stage != .None {
				problem.stage, problem.file_error = u32(original_stage), u32(original_error)
				table_append(details, problem)
				continue
			}
		}
		import_problems(source, hash, imported_file, nearest_replaced, nearest_replacement, details, visited)
	}
}

// named_of gives a hash with the name that the load source gives to it.
named_of :: proc "contextless" (source: Load_Source, hash: [32]u8) -> (value: module.Named) {
	value.hash = hash
	if entry := image_entry_of(source.image, hash); entry != nil {
		module.name_set(&value.name, name_of(entry.name[:]))
		return value
	}
	for item in source.files {
		if item.hash == hash {
			module.name_set(&value.name, item.name)
			break
		}
	}
	return value
}

// source_file gives the file of the load source with a hash, after it
// checked the hash and the tables. The image comes first: a file beside it
// with the same hash has the same bytes, or it fails its check.
@(private)
source_file :: proc "contextless" (source: Load_Source, hash: [32]u8) -> (file: []u8, stage: module.Load_Stage, file_error: module.Error) {
	found, agrees := false, false
	if entry := image_entry_of(source.image, hash); entry != nil {
		file, found = source.image[entry.offset:][:entry.size], true
		agrees = image_entry_check(source.image, source.image_checks, entry)
	} else {
		for item in source.files {
			if item.hash == hash {
				file, found = item.bytes, true
				agrees = blake3.hash(file) == hash
				break
			}
		}
	}
	if !found {
		return nil, .Find, .None
	}
	// The hash before the tables: a file that is not the one of its hash is
	// not read.
	if !agrees {
		return nil, .Read, .None
	}
	if file_error = module.validate(file); file_error != .None {
		return nil, .Read, file_error
	}
	return file, .None, .None
}

// first_file_hash gives the hash of the first file of a load. With a
// table of checks, a file that is the whole bytes of an entry of the image
// has the hash of its entry, which image_entry_check proves or refuses
// (agrees false). Any other file, and each file with no table, has the
// hash of its bytes.
@(private)
first_file_hash :: proc "contextless" (source: Load_Source, file: []u8) -> (hash: [32]u8, agrees: bool) {
	if source.image_checks != nil && len(file) > 0 {
		for &entry in image_entries(source.image) {
			if entry.size == u64(len(file)) && entry.offset < u64(len(source.image)) && raw_data(source.image[entry.offset:]) == raw_data(file) {
				return entry.hash, image_entry_check(source.image, source.image_checks, &entry)
			}
		}
	}
	return blake3.hash(file), true
}

// module_fits_below_band says if a module of memory_size bytes at the
// address next, with the page with no memory after it, ends at or before
// the end of the addresses of the modules: the band of the fixed ranges,
// where the system maps the settings page, the glyph caches and the files
// of the modules, starts there. No sum wraps: the size is compared first.
module_fits_below_band :: proc "contextless" (next, memory_size: u64) -> bool {
	if memory_size > fixed_addresses.MODULES_END - PAGE_SIZE {
		return false
	}
	return next <= fixed_addresses.MODULES_END - PAGE_SIZE - memory_size
}

// place puts a module in the space, after its imports. named is the hash
// that the caller names, and first is its file. It walks the imports in
// depth with the frames of the space: an import is placed before the
// module that imports it, and a module waits in its frame while its
// imports load. A failure stops the walk, and the space keeps the places
// for module_space_load to undo.
@(private)
place :: proc "contextless" (space: ^Module_Space, named: [32]u8, first: []u8, error: ^module.Load_Error) -> int {
	root, new := place_enter(space, named, first, nil, error)
	if root < 0 || !new {
		return root
	}
	depth := 1
	for depth > 0 {
		frame := &space.frames[depth - 1]
		item := &space.modules[frame.item]
		if frame.next_import < frame.import_count {
			number := frame.next_import
			record, _ := module.record(item.file, .Imports, u32(number + 1), module.Import)
			at, entered := place_enter(space, record.hash, nil, item, error)
			if at < 0 {
				return place_failed(space, depth, error)
			}
			item.import_places[number] = u8(at)
			item.import_count += 1
			frame.next_import += 1
			// A module that the space held already needs no frame. Each new
			// module takes a free place, so the depth never passes the places.
			if entered {
				depth += 1
			}
			continue
		}
		if !place_finish(space, item, frame.head, frame.import_count, error) {
			return place_failed(space, depth, error)
		}
		depth -= 1
	}
	return root
}

// place_failed ends a walk that failed with depth frames: a failure on the
// path of a replaced import says which replacement the loader applied, if
// no replacement nearer to the failure says it. The nearest is the frame on
// top.
@(private)
place_failed :: proc "contextless" (space: ^Module_Space, depth: int, error: ^module.Load_Error) -> int {
	for index := depth - 1; index >= 0; index -= 1 {
		frame := &space.frames[index]
		if frame.replaces != {} && error.replaced.hash == {} {
			error.replaced = named_of(space.source, frame.replaces)
			error.replacement = named_of(space.source, frame.hash)
		}
	}
	return -1
}

// place_enter finds the module of a hash that the caller or an import of
// importer names. A module that the space holds gains one user (new is
// false). Else it takes a free place, its addresses and its file, and its
// frame on top of the frames of the space (new is true): its imports are
// not placed yet. index is -1 on a failure, with the error record.
@(private)
place_enter :: proc "contextless" (space: ^Module_Space, named: [32]u8, first: []u8, importer: ^Placed, error: ^module.Load_Error) -> (index: int, new: bool) {
	hash := named
	replaces: [32]u8
	if importer != nil {
		for item in space.source.replacements {
			if item.from == named {
				hash, replaces = item.to, named
				break
			}
		}
	}
	// A failure here concerns this module, as the import of importer. A
	// replaced import says which replacement the loader applied.
	fail :: proc "contextless" (space: ^Module_Space, error: ^module.Load_Error, stage: module.Load_Stage, importer: ^Placed, named: [32]u8, hash: [32]u8, replaces: [32]u8) -> (int, bool) {
		error.stage = u32(stage)
		if importer != nil {
			error.module = named_of(space.source, importer.hash)
			error.imported = named_of(space.source, named)
		} else {
			error.module = named_of(space.source, hash)
		}
		if replaces != {} && error.replaced.hash == {} {
			error.replaced = named_of(space.source, replaces)
			error.replacement = named_of(space.source, hash)
		}
		return -1, false
	}
	free := -1
	for &item, place_index in space.modules {
		if item.users == 0 {
			free = free < 0 ? place_index : free
		} else if item.hash == hash {
			if item.loading {
				return fail(space, error, .Cycle, importer, named, hash, replaces)
			}
			item.users += 1
			return place_index, false
		}
	}
	if free < 0 {
		return fail(space, error, .Room, importer, named, hash, replaces)
	}
	file := first
	original: []u8
	stage: module.Load_Stage
	file_error: module.Error
	if importer != nil {
		if file, stage, file_error = source_file(space.source, hash); stage != .None {
			error.file_error = u32(file_error)
			return fail(space, error, stage, importer, named, hash, replaces)
		}
	}
	if replaces != {} {
		// The names of the exports that the import slots use are in the module of the import.
		if original, stage, file_error = source_file(space.source, replaces); stage != .None {
			error.file_error = u32(file_error)
			return fail(space, error, stage, importer, named, hash, replaces)
		}
	}
	// Each file here was validated (module_space_load, source_file); a
	// header that is not valid still stops the load at once, before its
	// size is used.
	head, header_error := module.header(file)
	if header_error != .None {
		error.file_error = u32(header_error)
		return fail(space, error, .Read, importer, named, hash, replaces)
	}
	import_count := int(max(module.count(file, .Imports), 1)) - 1
	if import_count > IMPORT_CAPACITY {
		return fail(space, error, .Room, importer, named, hash, replaces)
	}
	if !module_fits_below_band(space.next, head.memory_size) {
		return fail(space, error, .Room, importer, named, hash, replaces)
	}
	item := &space.modules[free]
	item^ = {hash = hash, replaces = replaces, file = file, original = original, base = space.next, users = 1, loading = true}
	// A page with no memory between two modules.
	space.next += head.memory_size + PAGE_SIZE
	// The frames on the stack of the walk are the modules that load: each
	// holds a place with loading set, so they are fewer than the places.
	depth := 0
	for &placed in space.modules {
		if placed.loading && &placed != item {
			depth += 1
		}
	}
	space.frames[depth] = {item = free, replaces = replaces, hash = hash, head = head, import_count = import_count}
	return free, true
}

// place_finish binds a module whose imports are all placed, maps it, and
// ends its load.
@(private)
place_finish :: proc "contextless" (space: ^Module_Space, item: ^Placed, head: module.Header, import_count: int, error: ^module.Load_Error) -> bool {
	imports: [IMPORT_CAPACITY]module.Bound_Import
	for number in 0 ..< import_count {
		record, _ := module.record(item.file, .Imports, u32(number + 1), module.Import)
		used := &space.modules[item.import_places[number]]
		imports[number] = {file = used.file, base = uintptr(used.base)}
		if used.hash != record.hash {
			// A replacement: the import slots name exports of the module of the import.
			imports[number].named = used.replaces == record.hash ? used.original : nil
			if imports[number].named == nil {
				stage: module.Load_Stage
				file_error: module.Error
				if imports[number].named, stage, file_error = source_file(space.source, record.hash); stage != .None {
					error.file_error = u32(file_error)
					error.stage = u32(stage)
					error.module = named_of(space.source, item.hash)
					error.imported = named_of(space.source, record.hash)
					return false
				}
			}
		}
	}
	map_module := space.map_module != nil ? space.map_module : place_map
	if !map_module(space, item, head, imports[:import_count], error) {
		return false
	}
	item.loading = false
	return true
}

// place_map puts a module in the process of the space, bound to its
// imports, and writes its module record. With a table of prepared modules,
// the process maps the shared code of the module from the table, and
// receives its own copy of each writable segment. With no table, the
// process maps a prepared module of its own, all of it, and the budget of
// the space pays for it.
@(private)
place_map :: proc "contextless" (space: ^Module_Space, item: ^Placed, head: module.Header, imports: []module.Bound_Import, error: ^module.Load_Error) -> bool {
	status: call_outcome.Call_Outcome
	if space.prepared == nil {
		// Keep executable, fixed, and writable segments in separate memory
		// objects so no memory object holds both Write and Execute mappings.
		code, fixed: Prepared
		if code, status = module_prepare(item.file, item.hash, .Code, item.base, space.budget, imports, error); status == .Succeeded {
			if fixed, status = module_prepare(item.file, item.hash, .Fixed, item.base, space.budget, imports, error); status == .Succeeded {
				status = segments_map(item.file, item.hash, &code, &fixed, space.process, item.base, space.budget, imports, error)
				if fixed.memory != 0 {
					close(fixed.memory)
				}
			}
			if code.memory != 0 {
				close(code.memory)
			}
		}
	} else {
		// The code from the table at any base; the fixed part for this base
		// and this binding; the writable segments of this process.
		lock(&space.prepared.lock)
		prepared_sweep(space.prepared)
		code, fixed: ^Prepared
		if code, status = prepared_find(space.prepared, item.file, item.hash, .Code, 0, {}, nil, error); status == .Succeeded {
			if fixed, status = prepared_find(space.prepared, item.file, item.hash, .Fixed, item.base, binding_of(space, item), imports, error, keep = code); status == .Succeeded {
				status = segments_map(item.file, item.hash, code, fixed, space.process, item.base, space.budget, imports, error)
			}
		}
		unlock(&space.prepared.lock)
	}
	if status != .Succeeded {
		place_unmap(space, item)
		stage, stage_ok := module.load_stage_of_word(error.stage)
		if !stage_ok {
			error^ = {stage = u32(module.Load_Stage.Map), status = u32(status), module = named_of(space.source, item.hash)}
			return false
		}
		switch stage {
		case .Check, .Bind:
			// The import of the import slot, and its replacement if the loader applied one.
			error.module = named_of(space.source, item.hash)
			import_slot, _ := module.record(item.file, .Import_Slots, error.import_slot, module.Import_Slot)
			if record, has_import := module.record(item.file, .Imports, import_slot.import_index, module.Import); has_import && import_slot.import_index != 0 {
				error.imported = named_of(space.source, record.hash)
				if used := &space.modules[item.import_places[import_slot.import_index - 1]]; used.hash != record.hash {
					error.replaced = error.imported
					error.replacement = named_of(space.source, used.hash)
				}
			}
		case .Read, .Room:
			error.module = named_of(space.source, item.hash)
		case .None, .Find, .Cycle, .Map, .Unmap:
			// No stage of this load said why: a kernel operation of the map failed.
			error^ = {stage = u32(module.Load_Stage.Map), status = u32(status), module = named_of(space.source, item.hash)}
		}
		return false
	}
	item.mapped = true
	record := op.Module_Record {
		base     = item.base,
		size     = head.memory_size,
		hash     = item.hash,
		replaces = item.replaces,
	}
	if _, status = call(.Process_Module, u64(space.process), u64(uintptr(&record))); status != .Succeeded {
		error^ = {stage = u32(module.Load_Stage.Map), status = u32(status), module = named_of(space.source, item.hash)}
		return false
	}
	return true
}

// binding_of gives what the import slots of a module hold, as one hash: the hash
// and the base of the module of each import. Two processes with the same
// module at the same base and the same binding can map the same pages.
@(private)
binding_of :: proc "contextless" (space: ^Module_Space, item: ^Placed) -> [32]u8 {
	if item.import_count == 0 {
		return {}
	}
	// The hash of the hash and the base of each import, one after the
	// other, by an incremental hash: no buffer of all of them.
	hasher := blake3.hasher_make()
	for number in 0 ..< int(item.import_count) {
		used := &space.modules[item.import_places[number]]
		base := transmute([8]u8)used.base
		blake3.hasher_update(&hasher, used.hash[:])
		blake3.hasher_update(&hasher, base[:])
	}
	return blake3.hasher_finish(&hasher)
}

// place_unmap removes each segment of a module that is mapped. It gives the
// first status that is not Ok.
@(private)
place_unmap :: proc "contextless" (space: ^Module_Space, item: ^Placed) -> (result: call_outcome.Call_Outcome) {
	for index in 1 ..< module.count(item.file, .Segments) {
		segment, _ := module.record(item.file, .Segments, index, module.Segment)
		if status := memory_unmap(rawptr(uintptr(item.base + segment.memory_offset)), space.process); status != .Succeeded && result == .Succeeded {
			result = status
		}
	}
	return result
}

@(private)
place_remove :: proc "contextless" (space: ^Module_Space, item: ^Placed) -> (status: call_outcome.Call_Outcome) {
	if item.mapped {
		status = place_unmap(space, item)
		record := op.Module_Record {
			base = item.base,
		}
		if _, removed := call(.Process_Module, u64(space.process), u64(uintptr(&record))); removed != .Succeeded && status == .Succeeded {
			status = removed
		}
	}
	item^ = {}
	return status
}

// segment_flags gives the protection of a segment in a process.
@(private)
segment_flags :: proc "contextless" (segment: module.Segment) -> (flags: op.Map_Flags) {
	if .Write in segment.flags && .Read_Only_After_Load not_in segment.flags {
		flags += {.Write}
	}
	if .Execute in segment.flags {
		flags += {.Execute}
	}
	return flags
}

// in_part says if a segment is in a part of a module.
@(private)
in_part :: proc "contextless" (segment: module.Segment, part: Module_Part) -> bool {
	switch part {
	case .All:
		return true
	case .Code:
		return .Write not_in segment.flags
	case .Fixed:
		return .Write in segment.flags && .Read_Only_After_Load in segment.flags
	}
	return false
}

// part_range gives the offsets of the first and of the end of the pages of
// a part of a module. end is 0 when the part has no segment.
@(private)
part_range :: proc "contextless" (file: []u8, part: Module_Part) -> (first, end: u64) {
	first = max(u64)
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if in_part(segment, part) {
			first = min(first, segment.memory_offset)
			end = max(end, segment.memory_offset + segment.memory_size)
		}
	}
	return end == 0 ? 0 : first, end
}

// module_prepare makes a memory object with one part of the module as it
// runs at base: the segments of the part copied from the file; for the
// parts Fixed and All, rebased and bound to the imports, with the hash of
// the module at its own-hash place. Its first page is the page of the
// module at offset `first`. The budget pays for it.
@(private)
module_prepare :: proc "contextless" (file: []u8, hash: [32]u8, part: Module_Part, base: u64, budget: Handle, imports: []module.Bound_Import, error: ^module.Load_Error) -> (prepared: Prepared, status: call_outcome.Call_Outcome) {
	first, end := part_range(file, part)
	if end == 0 {
		return {part = part}, .Succeeded
	}
	memory := memory_create((end - first) / PAGE_SIZE, budget) or_return
	address: rawptr
	if address, status = memory_map(memory); status != .Succeeded {
		close(memory)
		return {}, status
	}
	// The view starts where the module would start: an offset of the
	// module is an index, and only the part is memory.
	view := ([^]u8)(uintptr(address) - uintptr(first))[:end]
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if in_part(segment, part) && segment.file_size != 0 {
			intrinsics.mem_copy_non_overlapping(&view[segment.memory_offset], &file[segment.file_offset], int(segment.file_size))
		}
	}
	// The part Code has no rebase and no import slot: the file checks it (rebase
	// and bind refuse a location in a segment with no Write).
	ok := part == .Code || code_ready(file, hash, view, base, imports, error, first, end)
	memory_unmap(address)
	if !ok {
		close(memory)
		return {}, .Argument_Refused
	}
	return {part = part, base = base, first = first, memory = memory, pages = (end - first) / PAGE_SIZE}, .Succeeded
}

// code_ready rebases and binds the locations of a module from offset first
// to offset end, and writes the hash of the module at its own-hash place
// when the place is there: a log fact of the module names its module by it
// (src/md/features/log_facts.md, "The record"). A failure fills the stage
// of error: Read for a rebase and for the place, Check or Bind for an import slot.
@(private)
code_ready :: proc "contextless" (file: []u8, hash: [32]u8, view: []u8, base: u64, imports: []module.Bound_Import, error: ^module.Load_Error, first, end: u64) -> bool {
	if rebased := module.rebase_range(file, view, uintptr(base), first, end); rebased != .None {
		error.stage, error.file_error = u32(module.Load_Stage.Read), u32(rebased)
		return false
	}
	if !module.own_hash_write(file, view, hash, first, end) {
		error.stage, error.file_error = u32(module.Load_Stage.Read), u32(module.Error.Bad_Own_Hash_Place)
		return false
	}
	// The index of each record stream, which the library reads in its
	// variable (src/md/features/module_outputs.md, "The declaration in the
	// module").
	if !module.record_stream_indexes_write(file, view, first, end) {
		error.stage, error.file_error = u32(module.Load_Stage.Read), u32(module.Error.Bad_Record_Stream_Place)
		return false
	}
	return module.bind(file, view, imports, error, first, end)
}

// prepared_sweep closes each prepared module of a table that no process
// maps: the count of the holdings of its handle is 0. The caller holds the
// lock of the table, and sweeps before it finds the parts of one module.
@(private)
prepared_sweep :: proc "contextless" (table: ^Prepared_Modules) {
	for &item in table.modules {
		if item.memory != 0 && handle_holdings(item.memory) == 0 {
			close(item.memory)
			item = {}
		}
	}
}

// prepared_find gives one part of the prepared module of a file from a
// table, and prepares it if the table does not have it. The part Code is
// for each base and each binding; the part Fixed is for one base and one
// binding of its import slots. The caller checked the hash of the file. A part
// with no segment has no memory object. A table with no free place closes
// its part used least recently, but never keep, the part that the caller
// still holds.
@(private)
prepared_find :: proc "contextless" (table: ^Prepared_Modules, file: []u8, hash: [32]u8, part: Module_Part, base: u64, binding: [32]u8, imports: []module.Bound_Import, error: ^module.Load_Error, keep: ^Prepared = nil) -> (found: ^Prepared, status: call_outcome.Call_Outcome) {
	free: ^Prepared
	table.uses += 1
	for &item in table.modules {
		if item.memory != 0 && item.hash == hash && item.part == part && item.base == base && item.binding == binding {
			item.last_use = table.uses
			return &item, .Succeeded
		}
		if item.memory == 0 && free == nil {
			free = &item
		}
	}
	if free == nil {
		// A full table is a cache too: it closes the part used least
		// recently, never the part that this load already holds (keep).
		uses: [PREPARED_CAPACITY]Prepared_Use
		for item, place in table.modules {
			uses[place] = {held = item.memory != 0, last_use = item.last_use, in_use = &table.modules[place] == keep}
		}
		chosen: [1]int
		if prepared_drop_choose(uses[:], 1, chosen[:]) == 0 {
			error.stage = u32(module.Load_Stage.Room)
			return nil, .Budget_Or_Capacity_Exhausted
		}
		free = &table.modules[chosen[0]]
		close(free.memory)
		free^ = {}
	}
	written := module_prepare(file, hash, part, base, 0, imports, error) or_return
	if written.memory == 0 {
		free^ = {} // No segment: nothing to keep, and the place stays free.
		return free, .Succeeded
	}
	defer close(written.memory)
	// After the preparation, nobody writes the module: the table keeps a
	// handle without Write, and closes the one that wrote.
	free^ = written
	free.hash, free.binding = hash, binding
	free.last_use = table.uses
	// A refused copy leaves the place free: the place must never name the
	// handle that the defer above closes.
	given, given_status := give(0, written.memory, {.Read, .Execute})
	if given_status != .Succeeded {
		free^ = {}
		return nil, given_status
	}
	free.memory = given
	return free, .Succeeded
}

// segments_map maps each segment of a module in a process, with the
// protection of the segment: a segment of the part Code from code, a
// segment of the part Fixed from fixed, and a writable segment from a new
// memory object that the budget pays for, with the bytes of the file,
// rebased and bound, when code is not the part All. A process does not
// write a prepared module.
@(private)
segments_map :: proc "contextless" (file: []u8, hash: [32]u8, code, fixed: ^Prepared, process: Handle, base: u64, budget: Handle, imports: []module.Bound_Import, error: ^module.Load_Error) -> call_outcome.Call_Outcome {
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		flags := segment_flags(segment)
		from := code
		if code.part != .All && .Write in flags {
			own := segment_copy(file, hash, segment, base, budget, imports, error) or_return
			_, status := memory_map(own, flags, process, base + segment.memory_offset)
			close(own)
			if status != .Succeeded {
				return status
			}
			continue
		}
		if code.part != .All && in_part(segment, .Fixed) {
			from = fixed
		}
		memory_map(from.memory, flags, process, base + segment.memory_offset, (segment.memory_offset - from.first) / PAGE_SIZE, segment.memory_size / PAGE_SIZE) or_return
	}
	return .Succeeded
}

// segment_copy makes the memory of one writable segment for one process:
// the bytes of the file, rebased and bound. The pages that the copy does
// not write stay pages on first use.
@(private)
segment_copy :: proc "contextless" (file: []u8, hash: [32]u8, segment: module.Segment, base: u64, budget: Handle, imports: []module.Bound_Import, error: ^module.Load_Error) -> (memory: Handle, status: call_outcome.Call_Outcome) {
	memory = memory_create(segment.memory_size / PAGE_SIZE, budget) or_return
	address: rawptr
	if address, status = memory_map(memory); status != .Succeeded {
		close(memory)
		return 0, status
	}
	end := segment.memory_offset + segment.memory_size
	// The view starts where the module would start: an offset of the
	// module is an index, and only the segment is memory.
	view := ([^]u8)(uintptr(address) - uintptr(segment.memory_offset))[:end]
	if segment.file_size != 0 {
		intrinsics.mem_copy_non_overlapping(&view[segment.memory_offset], &file[segment.file_offset], int(segment.file_size))
	}
	ok := code_ready(file, hash, view, base, imports, error, segment.memory_offset, end)
	memory_unmap(address)
	if !ok {
		close(memory)
		return 0, .Argument_Refused
	}
	return memory, .Succeeded
}

// source_closure gives the files that a load of a module reads from a load
// source: the module and each import, at each level, and for a replaced
// import both the module that the import names and the module of the
// replacement. files[0] is the module. A caller gives these files, and only
// these, to a process that loads the module (a call host). A hash that the
// image of the load source does not have is left out, a file beside the
// image too: the loader of the other process reports it.
source_closure :: proc "contextless" (source: Load_Source, file: []u8, files: ^[MODULE_SPACE_CAPACITY + IMPORT_CAPACITY]^info.Image_Entry) -> (count: int) {
	add :: proc "contextless" (files: ^[MODULE_SPACE_CAPACITY + IMPORT_CAPACITY]^info.Image_Entry, count: ^int, entry: ^info.Image_Entry) -> bool {
		if entry == nil {
			return false
		}
		for item in files[:count^] {
			if item == entry {
				return false
			}
		}
		if count^ == len(files) {
			return false
		}
		files[count^] = entry
		count^ += 1
		return true
	}
	first := image_entry_of(source.image, blake3.hash(file))
	if !add(files, &count, first) {
		return
	}
	// Each file that was added is read for its imports one time: the list is
	// the queue of the walk.
	for walked := 0; walked < count; walked += 1 {
		entry := files[walked]
		current := source.image[entry.offset:][:entry.size]
		if module.validate(current) != .None {
			continue
		}
		for number in 1 ..< module.count(current, .Imports) {
			record, _ := module.record(current, .Imports, number, module.Import)
			add(files, &count, image_entry_of(source.image, record.hash))
			for item in source.replacements {
				if item.from == record.hash {
					add(files, &count, image_entry_of(source.image, item.to))
				}
			}
		}
	}
	return count
}

// process_start builds and starts a process from a module file and its
// imports.
//   grants:  each handle that is not 0 is copied to the process with the
//            rights of the grant; the context of the process has the copy
//            at the same index.
//            The index CONTEXT_BUDGET must be 0: the process receives its
//            new budget there.
//   values:   copied to the context.
//   amounts:  the budget of the process. It comes from the budget of this
//             process. It pays for the process and for all that the loader
//             creates. When the process stops, what remains returns.
//   mappings: memory that the process has from its start, with no handle to
//             it: the process cannot map it again with other flags.
//   prepared: not nil: the process maps the shared code of each module from
//             this table, and the table keeps the prepared module for the
//             next process of the same module, base and binding. nil: the
//             process has its own copy of each module, and its budget pays.
//   source:   where the loader finds the imports, and the replacements that
//             the caller gives to the process.
//   error:    when the load fails, the record of the failure.
//   from_budget: the budget that pays `amounts`, with the right Spend; 0:
//             the budget of this process.
//   wiring:   not nil: the wiring ring of the process and the ends that it
//             takes before its first instruction, and the handles that the
//             starter keeps (Start_Wiring), with the end of the record
//             output log. Its handle slots CONTEXT_WIRING_RING,
//             CONTEXT_LOG_OUTPUT and CONTEXT_LOG_OUTPUT_END must be 0: only
//             a wiring fills them. On a failure its outputs are 0.
//   held_entry: not nil: the process is built whole and held before its
//             first instruction, and this receives its entry address;
//             process_release starts it. A debugger records it from that
//             instruction (src/md/features/record_and_replay.md).
// The module is at PROCESS_BASE, its imports after it.
// The process stops when the last handle to it closes.
process_start :: proc "contextless" (file: []u8, name: string, grants: [op.CONTEXT_HANDLES]Grant, values: [op.CONTEXT_VALUES]u64, amounts: Budget_Amounts, mappings: []Mapping = nil, prepared: ^Prepared_Modules = nil, source: Load_Source = {}, error: ^module.Load_Error = nil, from_budget: Handle = 0, wiring: ^Start_Wiring = nil, held_entry: ^u64 = nil, ready: ^Ready_Ring = nil, process_flags: op.Process_Flags = {}) -> (process: Handle, status: call_outcome.Call_Outcome) {
	if len(file) == 0 || module.validate(file) != .None || grants[op.CONTEXT_BUDGET].handle != 0 || grants[op.CONTEXT_WIRING_RING].handle != 0 || grants[op.CONTEXT_LOG_OUTPUT].handle != 0 || grants[op.CONTEXT_LOG_OUTPUT_END].handle != 0 || grants[op.CONTEXT_READY_RING].handle != 0 {
		return 0, .Argument_Refused
	}
	// Each process has a random seed from its starter (docs/RANDOMNESS.md):
	// a starter that forgot it does not start a process with no seed.
	seed_given: u64
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		seed_given |= values[op.CONTEXT_VALUE_SEED + index]
	}
	if seed_given == 0 {
		return 0, .Argument_Refused
	}
	head, _ := module.header(file)
	entry, has_entry := module.export_address(file, op.PROCESS_BASE, head.entry_export)
	if !has_entry {
		return 0, .Argument_Refused
	}

	// The process holds the one handle to its budget: when the process
	// stops, the budget ends.
	budget: Handle
	budget, status = budget_create(amounts, from_budget)
	if status != .Succeeded {
		return 0, status
	}
	defer close(budget)
	results: [7]u64
	results, status = call(.Process_Create, u64(budget), u64(uintptr(raw_data(name))), u64(len(name)), transmute(u64)process_flags)
	if status != .Succeeded {
		return 0, status
	}
	process = Handle(results[0])
	space := Module_Space {
		process  = process,
		budget   = budget,
		source   = source,
		next     = op.PROCESS_BASE,
		prepared = prepared,
	}
	loaded: module.Load_Error
	if _, ok := module_space_load(&space, file, &loaded); !ok {
		status = .Argument_Refused
		if loaded.stage == u32(module.Load_Stage.Map) {
			status, _ = call_outcome.outcome_of_word(u64(loaded.status))
		}
	}
	if error != nil {
		error^ = loaded
	}
	if status == .Succeeded && wiring != nil && wiring.keep_budget {
		// The starter keeps a handle of the budget, to pay what the child
		// asks for from it.
		wiring.budget, status = give(0, budget, {.Read, .Spend})
	}
	// The ready ring: the budget of the process pays it, as each object of
	// its start, so the floor of its module counts it.
	given := grants
	if status == .Succeeded && ready != nil {
		ready^ = {}
		ready.memory, status = memory_create(ring.pages(READY_RING_CAPACITY), budget)
		if status == .Succeeded {
			ready.mapped, status = ring_open(ready.memory)
		}
		given[op.CONTEXT_READY_RING] = {ready.memory, {.Read, .Write}}
	}
	if status == .Succeeded {
		status = process_fill(process, budget, given, values, mappings, file, wiring)
	}
	if status == .Succeeded {
		if held_entry != nil {
			held_entry^ = u64(entry)
		} else {
			status = process_release(process, u64(entry))
		}
	}
	if status != .Succeeded {
		process_stop(process)
		close(process)
		if wiring != nil {
			if wiring.budget != 0 {
				close(wiring.budget)
			}
			if wiring.wiring_memory != 0 {
				close(wiring.wiring_memory)
			}
			wiring.budget, wiring.wiring_memory = 0, 0
		}
		if ready != nil {
			ready_ring_close(ready)
		}
		return 0, status
	}
	return process, .Succeeded
}

// process_release starts a process that process_start built and held
// before its first instruction, at the entry address that it gave.
process_release :: proc "contextless" (process: Handle, entry: u64) -> call_outcome.Call_Outcome {
	_, status := call(.Process_Start, u64(process), entry, op.STACK_TOP, op.CONTEXT_ADDRESS)
	return status
}

@(private)
process_fill :: proc "contextless" (process: Handle, budget: Handle, grants: [op.CONTEXT_HANDLES]Grant, values: [op.CONTEXT_VALUES]u64, mappings: []Mapping, file: []u8 = nil, wiring: ^Start_Wiring = nil) -> call_outcome.Call_Outcome {
	for mapping in mappings {
		memory_map(mapping.memory, mapping.flags, process, mapping.address, mapping.first, mapping.page_count) or_return
	}

	stack := memory_create(op.STACK_PAGES, budget) or_return
	defer close(stack)
	memory_map(stack, {.Write}, process, op.STACK_TOP - op.STACK_PAGES * PAGE_SIZE) or_return

	record_memory := memory_create(1, budget) or_return
	defer close(record_memory)
	record := (^op.Context)(memory_map(record_memory) or_return)
	defer memory_unmap(record)
	for grant, index in grants {
		if grant.handle != 0 {
			record.handles[index] = give(process, grant.handle, grant.rights) or_return
		}
	}
	record.handles[op.CONTEXT_BUDGET] = give(process, budget, {.Give, .Read, .Spend}) or_return
	if wiring != nil {
		// The objects of the ends come after the load of the modules: the
		// loader prepared each module with the table of the starter free
		// of them.
		if wiring.ends_make != nil {
			wiring.ends = wiring.ends_make(wiring.ends_data) or_return
		}
		start_wiring_give(process, budget, record, file, wiring) or_return
	}
	record.values = values
	memory_map(record_memory, {.Write}, process, op.CONTEXT_ADDRESS) or_return
	return .Succeeded
}

@(rodata)
file_error_names := [module.Error]string {
	.None            = "no error",
	.Too_Small       = "the file is smaller than a header",
	.Bad_Magic       = "it does not start with the bytes of a module",
	.Unknown_Version = "its format version is not known",
	.Unknown_Feature = "it needs a feature that this loader does not know",
	.Unknown_Machine = "it is for another machine",
	.Bad_Table       = "a table is outside the file",
	.Bad_Segment     = "a segment is not valid",
	.Bad_Rebase      = "a rebase is not in writable data",
	.Bad_Import_Slot = "an import slot is not valid",
	.Bad_Import      = "an import is not valid",
	.Bad_Export      = "an export is not valid",
	.Bad_Own_Hash_Place = "its own-hash place is not in writable data",
	.Bad_Record_Stream_Place = "the place of a record output or a record input is not in writable data",
	.Too_Many_Record_Streams = "it declares more record outputs or more record inputs than a module can",
	.Unknown_Category = "its header states a category or a tag that names nothing",
}

// load_error_text writes a load error for a reader: one line or more, each
// one ended by a line feed. The record has the names: the text needs no
// other data.
load_error_text :: proc "contextless" (writer: ^Writer, error: ^module.Load_Error) {
	name :: proc "contextless" (writer: ^Writer, value: ^module.Named) {
		if value.name[0] != 0 {
			write_part(writer, module.name_get(&value.name))
		} else {
			write_hash(writer, value.hash)
		}
	}
	described :: proc "contextless" (writer: ^Writer, value: ^module.Described) {
		// The record can come from another process: a byte that names no
		// type is written as "?", never as a type.
		type, type_ok := module.type_of_word(value.type)
		if !type_ok {
			write_part(writer, "?")
			return
		}
		switch type {
		case .None:
			write_part(writer, "nothing")
		case .Record:
			write_part(writer, "the record ")
			write_part(writer, module.name_get(&value.record))
		case .Table:
			write_part(writer, "Table(")
			write_part(writer, module.name_get(&value.record))
			write_part(writer, ", ")
			write_part(writer, direction_name(value.direction))
			write_part(writer, ")")
		case .Integer:
			// The unit is the meaning of the number, so a difference of it
			// is named: "Integer in pages". A detail out of the contract
			// comes from a hostile file and is shown as a number.
			write_part(writer, "Integer")
			if value.detail != 0 {
				if integer_unit, valid := value_kinds.integer_unit_of_detail(value.detail); valid {
					write_part(writer, " in")
					write_part(writer, value_kinds.integer_unit_text(integer_unit))
				} else {
					write_part(writer, " with the detail ")
					write_part(writer, u64(value.detail))
				}
			}
		case .Enum:
			write_part(writer, "the enum ")
			write_part(writer, module.name_get(&value.record))
		case .Text, .Handle, .Bytes:
			write_parameter_type(writer, nil, type, value.detail, value.direction)
		}
	}
	// The module that the stage concerns: the import, or the module itself.
	subject := error.imported.hash != {} ? &error.imported : &error.module
	stage, stage_ok := module.load_stage_of_word(error.stage)
	if !stage_ok {
		write_part(writer, "load failed at stage ")
		write_part(writer, u64(error.stage))
		write_part(writer, ", which this process does not know\n")
		return
	}
	switch stage {
	case .None:
		return
	case .Find:
		if error.imported.hash != {} {
			name(writer, &error.module)
			write_part(writer, " imports ")
			name(writer, &error.imported)
			write_part(writer, ", and the load source has no file with its hash\n")
		} else {
			write_part(writer, "the load source has no file with the hash of ")
			name(writer, &error.module)
			write_part(writer, "\n")
		}
	case .Read:
		write_part(writer, "the file of ")
		name(writer, subject)
		file_error, file_error_ok := module.file_error_of_word(error.file_error)
		if file_error_ok && file_error == .None {
			write_part(writer, " does not have the hash that names it\n")
		} else {
			write_part(writer, " is not a valid module: ")
			write_part(writer, file_error_ok ? file_error_names[file_error] : "an error that this process does not know")
			write_part(writer, "\n")
		}
	case .Cycle:
		write_part(writer, "an import cycle: ")
		name(writer, &error.module)
		write_part(writer, " imports ")
		name(writer, &error.imported)
		write_part(writer, ", and ")
		name(writer, error.replacement.hash != {} ? &error.replacement : &error.imported)
		write_part(writer, " still loads its imports\n")
	case .Check:
		name(writer, &error.module)
		write_part(writer, " imports ")
		name(writer, &error.imported)
		write_part(writer, ", and its replacement ")
		name(writer, &error.replacement)
		write_part(writer, " fails the check\n")
		write_part(writer, "export ")
		write_part(writer, module.name_get(&error.export))
		write_part(writer, " of ")
		name(writer, &error.replacement)
		write_part(writer, ": ")
		difference, difference_ok := module.difference_of_word(error.difference)
		if !difference_ok {
			write_part(writer, "a difference that this process does not know (")
			write_part(writer, u64(error.difference))
			write_part(writer, ")")
		} else {
			switch difference {
			case .None:
			case .Missing_Export:
				write_part(writer, "no export has this name")
			case .Parameter_Count:
				write_part(writer, u64(error.found.detail))
				write_part(writer, " parameters, ")
				name(writer, &error.imported)
				write_part(writer, " has ")
				write_part(writer, u64(error.expected.detail))
			case .Parameter_Range:
				write_part(writer, "parameter ")
				write_part(writer, u64(error.parameter))
				write_part(writer, " has another range than ")
				name(writer, &error.imported)
				write_part(writer, " gives")
			case .Parameter_Type, .Parameter_Detail, .Parameter_Direction:
				write_part(writer, "parameter ")
				write_part(writer, u64(error.parameter))
				write_part(writer, " is ")
				described(writer, &error.found)
				write_part(writer, ", ")
				name(writer, &error.imported)
				write_part(writer, " has ")
				described(writer, &error.expected)
			case .Result_Type, .Result_Detail:
				write_part(writer, "the result is ")
				described(writer, &error.found)
				write_part(writer, ", ")
				name(writer, &error.imported)
				write_part(writer, " has ")
				described(writer, &error.expected)
			case .Error_Record:
				write_part(writer, "the error record is ")
				described(writer, &error.found)
				write_part(writer, ", ")
				name(writer, &error.imported)
				write_part(writer, " has ")
				described(writer, &error.expected)
			}
		}
		write_part(writer, "\n")
		return // The first line names the replacement.
	case .Bind:
		write_part(writer, "import slot ")
		write_part(writer, u64(error.import_slot))
		write_part(writer, " of ")
		name(writer, &error.module)
		write_part(writer, " cannot be bound")
		if error.export != {} {
			write_part(writer, ": export ")
			write_part(writer, module.name_get(&error.export))
			write_part(writer, " of ")
			name(writer, &error.imported)
		}
		write_part(writer, "\n")
	case .Map, .Unmap:
		write_part(writer, stage == .Map ? "the kernel refused to map " : "the kernel refused to remove ")
		name(writer, &error.module)
		// The name of the contract (call_outcome.CALL_OUTCOME_NAMES). The
		// record can come from another process: a word that names no outcome
		// is written as its number.
		write_part(writer, ": status ")
		if outcome, known := enum_word.member_of_word(call_outcome.Call_Outcome, u64(error.status)); known {
			write_part(writer, call_outcome.CALL_OUTCOME_NAMES[outcome])
		} else {
			write_part(writer, u64(error.status))
		}
		write_part(writer, "\n")
	case .Room:
		write_part(writer, "no room for ")
		name(writer, subject)
		write_part(writer, ": a process has 16 modules at most, a module 8 imports, a table of prepared modules 64 parts, and its modules fit below the fixed ranges of the system\n")
	}
	if error.replaced.hash != {} && stage != .Cycle {
		write_part(writer, "on the path of the load, the replacement table gives ")
		name(writer, &error.replacement)
		write_part(writer, " in place of ")
		name(writer, &error.replaced)
		write_part(writer, "\n")
	} else if stage == .Cycle && error.replaced.hash != {} {
		write_part(writer, "the replacement table gives ")
		name(writer, &error.replacement)
		write_part(writer, " in place of ")
		name(writer, &error.replaced)
		write_part(writer, ": that makes the cycle\n")
	}
}

// write_hash writes the first 8 bytes of a hash, in hexadecimal, and "...".
write_hash :: proc "contextless" (writer: ^Writer, value: [32]u8) {
	hash := value
	digits: [16]u8
	alphabet := HEX_DIGITS
	for b, index in hash[:8] {
		digits[2 * index], digits[2 * index + 1] = alphabet[b >> 4], alphabet[b & 0xF]
	}
	write_part(writer, string(digits[:]))
	write_part(writer, "...")
}

// process_entries gives the count of kernel entries of a process, from its
// start. The handle needs the right Read.
process_entries :: proc "contextless" (process: Handle) -> u64 {
	results, _ := call(.Process_State, u64(process))
	return results[3]
}

// process_place gives the process slot and the process serial of a
// process: its place in the reports of `Inspect`, which names this process
// and no later one. The handle needs the right Read.
//
// Example: `slot, serial, status := system.process_place(child)`.
process_place :: proc "contextless" (process: Handle) -> (slot: u64, serial: u64, status: call_outcome.Call_Outcome) {
	results: [7]u64
	results, status = call(.Process_State, u64(process))
	return results[4], results[5], status
}

// process_state gives the state of a process, and its stop cause and its
// stop outcome when it stopped. A triple that the border refuses (a word
// that names no member, a stopped process with no cause, a cause of a
// process that runs, an outcome with a cause other than itself) is a fault
// of the kernel: the process stops, and never reads a stop that did not
// happen.
//
// Example: `state, cause, outcome := system.process_state(child)`, then a
// whole switch on `cause`; for `Fault`, `system.process_stop_report(child).vector`.
process_state :: proc "contextless" (process: Handle) -> (state: op.Process_State, cause: op.Stop_Cause, outcome: op.Stop_Outcome) {
	results, _ := call(.Process_State, u64(process))
	known: bool
	state, cause, outcome, known = op.stop_of_words(results[0], results[1], results[2])
	if !known {
		if _, state_known := enum_word.member_of_word(op.Process_State, results[0]); !state_known {
			kernel_word_refused("the state of a process", results[0])
		}
		if _, cause_known := op.stop_cause_of_word(results[1]); !cause_known {
			kernel_word_refused("the stop cause of a process", results[1])
		}
		kernel_word_refused("the stop outcome of a process, or a stop fact that does not fit its state or its cause,", results[2])
	}
	return state, cause, outcome
}

// process_stop stops another process through a process handle with
// Control. The process gets the stop cause `Holder` and no outcome: only a
// process says what its own work gave. A holder writes why it stopped the
// process in its own log. It returns when no thread of the process runs an
// instruction any more.
//
// Example: `system.process_stop(child)`, then `system.close(child)`.
process_stop :: proc "contextless" (process: Handle) -> call_outcome.Call_Outcome {
	_, status := call(.Process_Stop, u64(process), 0, 0)
	return status
}

// stop_outcome_of_grant gives the stop outcome of a process that cannot use
// a handle of its context: `Refused` when the starter gave no handle there
// (0) or one that names no such object or lacks a right (`Argument_Refused`,
// `Grant_Or_Right_Missing`), since the context is then wrong; `Failed` for
// each other outcome, a budget or a memory that ran short, since the same
// context can work at the next start. A start policy starts a row again
// after `Failed` and never after `Refused`.
//
// Example: `system.stop(system.stop_outcome_of_grant(ctx.handles[GRANT_PAGE], outcome))`.
stop_outcome_of_grant :: proc "contextless" (handle: Handle, outcome: call_outcome.Call_Outcome) -> op.Stop_Outcome {
	if handle == 0 || outcome == .Argument_Refused || outcome == .Grant_Or_Right_Missing {
		return .Refused
	}
	return .Failed
}

// process_stop_wait waits until a process stopped, or until the deadline,
// and gives its stop cause and its stop outcome. The handle needs the right
// Read. In a test, the deadline only ends a hang.
//
// Example: `_, outcome, stopped := system.process_stop_wait(child,
// system.time() + system.TEST_HANG_BOUND_MILLISECONDS)`, then
// `stopped && outcome == .Done`.
process_stop_wait :: proc "contextless" (process: Handle, deadline: u64) -> (cause: op.Stop_Cause, outcome: op.Stop_Outcome, stopped: bool) {
	for {
		// The event word first: a stop after the read of the state still
		// ends the wait, since the kernel adds to it at each stop of a
		// process that this process holds.
		wait := wait_begin()
		state: op.Process_State
		state, cause, outcome = process_state(process)
		if state == .Stopped {
			return cause, outcome, true
		}
		if time() >= deadline {
			return .None, .None, false
		}
		wait_end(&wait, deadline)
	}
}

// stop_write writes the words of a stop for a line or a cell: the text of
// the stop cause, and the text of the outcome for a stop of itself.
//
// Example: "itself, done", "a holder", "a fault".
stop_write :: proc "contextless" (writer: ^Writer, cause: op.Stop_Cause, outcome: op.Stop_Outcome) {
	write_part(writer, op.STOP_CAUSE_TEXTS[cause])
	switch cause {
	case .Itself:
		write_part(writer, ", ")
		write_part(writer, op.STOP_OUTCOME_TEXTS[outcome])
	case .None, .Holder, .Last_Thread_Ended, .Handles_Closed, .Fault, .Not_Committed, .Cannot_Return, .Fault_Unanswered:
	}
}

// process_stop_report gives where a process stopped on a fault, and the
// module of the instruction. The handle needs the right Read.
process_stop_report :: proc "contextless" (process: Handle) -> (report: op.Stop_Report) {
	call(.Process_State, u64(process), u64(uintptr(&report)))
	return report
}

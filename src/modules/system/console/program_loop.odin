package console

// The loop of a program written in the system
// (src/md/features/program_loop.md): build reads the C source of a project
// from its store, as the principal of this console, gives it to
// recipes.build_c and puts the module in the store module_files; run reads
// the module back, checks its hash against the hash that the last build of
// this console gave, isolates it in a call host with no grant, and calls
// its export main. Each step is a call of a service by its name, as a line
// of the principal would make it.

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/errors"
import pr "modus:contract/plans_recipes"
import "modus:contract/value_kinds"
import "modus:disk_process"
import "modus:system"

// The pages of the first memory of a module: a small program fits them.
// A larger module gives its bytes in the Too_Small error record of the
// call, and the console calls again with a memory object of that size
// (program_call_with_room), up to the bound of the output of the native C
// builder.
PROGRAM_MODULE_FIRST_PAGES :: 16
PROGRAM_MODULE_BYTES_MOST :: pr.C_MODULE_BYTES_LIMIT

// The projects whose last build this console keeps the hash of.
PROGRAM_BUILD_CAPACITY :: 16

// The hash of the module that the last build of a project in this console
// put in the store module_files: run compares the bytes that it reads with
// it.
Program_Build :: struct {
	project:        [disk_process.NAME_LIMIT]u8,
	project_length: int,
	digits:         [disk_process.HASH_DIGITS]u8,
}

program_builds: [PROGRAM_BUILD_CAPACITY]Program_Build

// program_build_find gives the place of the last build of a project, or nil.
@(private = "file")
program_build_find :: proc "contextless" (project: string) -> ^Program_Build {
	for &build in program_builds {
		if build.project_length != 0 && string(build.project[:build.project_length]) == project {
			return &build
		}
	}
	return nil
}

// program_build_keep keeps the hash of the module of a build. With no free
// place, the place of the first project goes: its next run then reads a
// module whose build this console no longer knows.
@(private = "file")
program_build_keep :: proc "contextless" (project: string, digits: string) {
	place := program_build_find(project)
	if place == nil {
		for &build in program_builds {
			if build.project_length == 0 {
				place = &build
				break
			}
		}
	}
	if place == nil {
		place = &program_builds[0]
	}
	place^ = {}
	place.project_length = copy(place.project[:], project)
	copy(place.digits[:], digits)
}

// program_memory makes a memory object of pages and copies bytes into it.
// The caller closes it.
@(private = "file")
program_memory :: proc "contextless" (pages: u64, bytes: []u8) -> (memory: system.Handle, ok: bool) {
	if u64(len(bytes)) > pages * system.PAGE_SIZE {
		return 0, false
	}
	created, status := system.memory_create(pages)
	if status != .Ok {
		return 0, false
	}
	if len(bytes) > 0 {
		address, map_status := system.memory_map(created)
		if map_status != .Ok {
			system.close(created)
			return 0, false
		}
		intrinsics.mem_copy_non_overlapping(address, raw_data(bytes), len(bytes))
		system.memory_unmap(address)
	}
	return created, true
}

// program_call_with_room calls a command whose argument memory_argument is
// a memory object for its output, of first_pages. When the call fails with
// Too_Small and the bytes that it needs, at most most_bytes, the console
// makes a memory object of that size and calls again, once. On success the
// caller closes memory; on a failure the line has failed.
@(private = "file")
program_call_with_room :: proc "contextless" (name: string, arguments: []Value, memory_argument: int, first_pages: u64, most_bytes: u64) -> (result: Value, memory: system.Handle, ok: bool) {
	pages := first_pages
	for attempt in 0 ..< 2 {
		created, created_ok := program_memory(pages, nil)
		if !created_ok {
			_ = fail(name, ": the budget of the console cannot pay for ", i64(pages * system.PAGE_SIZE), " bytes of memory for the output")
			return {}, 0, false
		}
		arguments[memory_argument] = {kind = .Handle, integer = i64(created)}
		result = call_run(name, arguments)
		if !failed {
			return result, created, true
		}
		system.close(created)
		needed := failure.record.limit
		if attempt == 1 || !failure.has_record || failure.record.kind != i64(errors.Kind.Too_Small) || i64(failure.record.argument) != i64(memory_argument + 1) || needed <= 0 || u64(needed) <= pages * system.PAGE_SIZE || u64(needed) > most_bytes {
			return {}, 0, false
		}
		// The first call failed only for the room of its output: the line
		// goes on with the second.
		failed = false
		failure_reset()
		pages = (u64(needed) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	}
	return {}, 0, false
}

// program_source_read reads the object file of the store at place into a
// new memory object of its size, by ranges: a source passes the call region
// of the connection to the storage service. The caller closes memory.
@(private = "file")
program_source_read :: proc "contextless" (place: Value, file: string) -> (memory: system.Handle, size: i64, ok: bool) {
	size_arguments := [2]Value{place, {kind = .Text, text = file}}
	size_value := call_run("storage.size", size_arguments[:])
	if failed {
		return 0, 0, false
	}
	size = size_value.integer
	if size <= 0 {
		_ = fail("build: the object ", file, " of the store is empty: there is no source to build")
		return 0, 0, false
	}
	if size > pr.C_SOURCE_BYTES_LIMIT {
		_ = fail("build: the source ", file, " has ", size, " bytes; a build takes 1 to ", i64(pr.C_SOURCE_BYTES_LIMIT))
		return 0, 0, false
	}
	created, created_ok := program_memory((u64(size) + system.PAGE_SIZE - 1) / system.PAGE_SIZE, nil)
	if !created_ok {
		_ = fail("build: the budget of the console cannot pay for the memory of the source ", file)
		return 0, 0, false
	}
	address, map_status := system.memory_map(created, {.Write})
	if map_status != .Ok {
		system.close(created)
		_ = fail("build: the memory of the source ", file, " does not map")
		return 0, 0, false
	}
	defer system.memory_unmap(address)
	read: i64 = 0
	for read < size {
		range_arguments := [3]Value{place, {kind = .Text, text = file}, {kind = .Integer, integer = read}}
		piece := call_run("storage.read_range", range_arguments[:])
		if failed {
			system.close(created)
			return 0, 0, false
		}
		// A piece of no byte before the size, or past it: the object
		// changed during the read.
		if len(piece.text) == 0 || i64(len(piece.text)) > size - read {
			system.close(created)
			_ = fail("build: the source ", file, " changed during its read: build it again")
			return 0, 0, false
		}
		intrinsics.mem_copy_non_overlapping(rawptr(uintptr(address) + uintptr(read)), raw_data(piece.text), len(piece.text))
		read += i64(len(piece.text))
	}
	return created, size, true
}

// program_project_check fails the line when the name is no name of a
// project, or when the principal has no project of that name:
// projects.pins refuses an unknown project.
@(private = "file")
program_project_check :: proc "contextless" (command: string, project: string) -> bool {
	if refusal := disk_process.nickname_refusal(project, len(project), 1, .Make); refusal.kind != 0 {
		_ = fail(command, ": \"", project, "\" is no name of a project: 1 to ", i64(disk_process.NAME_LIMIT), " visible characters, with no / and not module_files or grant_table")
		return false
	}
	project_arguments := [1]Value{{kind = .Text, text = project}}
	_ = call_run("projects.pins", project_arguments[:])
	return !failed
}

// build_program runs build(project, file).
build_program :: proc "contextless" (arguments: []Value) -> Value {
	project := arguments[0].text
	file := arguments[1].text
	if !program_project_check("build", project) {
		return {}
	}
	// The source, from the store of the project: this console acts for
	// the principal that owns it. It comes by ranges into a memory object
	// of its size, so it passes the call region of the connection.
	store_arguments := [1]Value{{kind = .Text, text = project}}
	place := call_run("storage.open_store", store_arguments[:])
	if failed {
		return {}
	}
	source_memory, source_size, source_ok := program_source_read(place, file)
	if !source_ok {
		return {}
	}
	defer system.close(source_memory)
	build_arguments := [4]Value{{kind = .Text, text = file}, {kind = .Handle, integer = i64(source_memory)}, {kind = .Integer, integer = source_size}, {}}
	size, module_memory, built := program_call_with_room("recipes.build_c", build_arguments[:], 3, PROGRAM_MODULE_FIRST_PAGES, PROGRAM_MODULE_BYTES_MOST)
	if !built {
		return {}
	}
	defer system.close(module_memory)
	put_arguments := [3]Value{{kind = .Text, text = project}, {kind = .Handle, integer = i64(module_memory)}, size}
	digits := call_run("module_files.put", put_arguments[:])
	if failed {
		return {}
	}
	program_build_keep(project, digits.text)
	return {kind = .Text, text = scratch_text(project, ": module ", digits.text)}
}

// run_program runs run(project) and run(project, grant).
run_program :: proc "contextless" (arguments: []Value) -> Value {
	project := arguments[0].text
	// A grant is checked before anything else: a run that asks for one
	// is refused before any call host starts.
	if len(arguments) > 1 {
		grant := arguments[1].text
		if len(grant) == 0 {
			return fail("run: the name of the grant is empty: name a grant that the project ", project, " declares, or leave it out")
		}
		// A project declares no grant yet.
		system.log_fact(.Warning, Program_Grant_Refused{project = value_kinds.module_name_field(project)}, grant)
		return fail("run: the project ", project, " declares no grant ", grant, ": its program runs with the grants of its project, and it declares none")
	}
	if !program_project_check("run", project) {
		return {}
	}
	read_arguments := [2]Value{{kind = .Text, text = project}, {}}
	size, module_memory, read_ok := program_call_with_room("module_files.read", read_arguments[:], 1, PROGRAM_MODULE_FIRST_PAGES, PROGRAM_MODULE_BYTES_MOST)
	if !read_ok {
		return {}
	}
	defer system.close(module_memory)
	if size.integer <= 0 || size.integer > i64(PROGRAM_MODULE_BYTES_MOST) {
		return fail("run: the module of ", project, " has ", size.integer, " bytes; a run takes 1 to ", i64(PROGRAM_MODULE_BYTES_MOST))
	}
	address, map_status := system.memory_map(module_memory, {})
	if map_status != .Ok {
		return fail("run: the memory of the module of ", project, " does not map")
	}
	hash := blake3.hash(([^]u8)(address)[:size.integer])
	system.memory_unmap(address)
	digits: [disk_process.HASH_DIGITS]u8
	disk_process.hash_write(&digits, hash)
	// The bytes that run reads must be the bytes that the last build of
	// this console put. A project built in another console has no hash
	// here: its run names the hash of what it runs in the log.
	if build := program_build_find(project); build != nil && build.digits != digits {
		return fail("run: the module of ", project, " in the store module_files has the hash ", string(digits[:]), ", not the hash ", string(build.digits[:]), " that its build gave: build it again")
	}
	// The module of the run before goes: a run after a build calls the new
	// module.
	for &item in loaded[:loaded_count] {
		if item.name == project {
			unload_arguments := [1]Value{{kind = .Text, text = project}}
			_ = call_run("unload", unload_arguments[:])
			if failed {
				return {}
			}
			break
		}
	}
	isolate_arguments := [3]Value{{kind = .Text, text = project}, {kind = .Handle, integer = i64(module_memory)}, size}
	_ = isolate_from_memory(isolate_arguments[:])
	if failed {
		return {}
	}
	// The export main of the module of this project: another module that
	// the console loaded can have an export main too.
	main_command: ^Command
	for &command in commands[:command_count] {
		if command.name == "main" && command.sandbox != 0 && !sandboxes[command.sandbox - 1].service && sandboxes[command.sandbox - 1].name == project {
			main_command = &command
		}
	}
	if main_command == nil || main_command.parameter_count != 0 {
		return fail("run: the module of ", project, " has no export main with no parameter")
	}
	value := call_isolated(main_command, nil)
	if failed {
		return {}
	}
	system.log_fact(.Info, Program_Ran{result = value.integer, module_hash = value_kinds.Hash_Field(hash), project = value_kinds.module_name_field(project)})
	return value
}

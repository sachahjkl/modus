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
import pr "modus:contract/plans_recipes"
import "modus:contract/value_kinds"
import "modus:disk_process"
import "modus:system"

// The pages of the memory of a module: the bound of the output of the
// native C builder.
PROGRAM_MODULE_PAGES :: pr.C_MODULE_BYTES_LIMIT / system.PAGE_SIZE

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
	// the principal that owns it. storage.read gives it as a Text through
	// the call region of the connection, so a source has at most the bytes
	// that the region holds beside the record of the call; recipes.build_c
	// itself takes the 256 KiB of compile.
	store_arguments := [1]Value{{kind = .Text, text = project}}
	place := call_run("storage.open_store", store_arguments[:])
	if failed {
		return {}
	}
	read_arguments := [2]Value{place, {kind = .Text, text = file}}
	source := call_run("storage.read", read_arguments[:])
	if failed {
		return {}
	}
	if len(source.text) == 0 {
		return fail("build: the object ", file, " of the store ", project, " is empty: there is no source to build")
	}
	source_pages := (u64(len(source.text)) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	source_memory, source_ok := program_memory(source_pages, transmute([]u8)source.text)
	if !source_ok {
		return fail("build: the budget of the console cannot pay for the memory of the source ", file)
	}
	defer system.close(source_memory)
	module_memory, module_ok := program_memory(PROGRAM_MODULE_PAGES, nil)
	if !module_ok {
		return fail("build: the budget of the console cannot pay for the memory of the module")
	}
	defer system.close(module_memory)
	build_arguments := [4]Value{{kind = .Text, text = file}, {kind = .Handle, integer = i64(source_memory)}, {kind = .Integer, integer = i64(len(source.text))}, {kind = .Handle, integer = i64(module_memory)}}
	size := call_run("recipes.build_c", build_arguments[:])
	if failed {
		return {}
	}
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
	module_memory, module_ok := program_memory(PROGRAM_MODULE_PAGES, nil)
	if !module_ok {
		return fail("run: the budget of the console cannot pay for the memory of the module")
	}
	defer system.close(module_memory)
	read_arguments := [2]Value{{kind = .Text, text = project}, {kind = .Handle, integer = i64(module_memory)}}
	size := call_run("module_files.read", read_arguments[:])
	if failed {
		return {}
	}
	if size.integer <= 0 || size.integer > pr.C_MODULE_BYTES_LIMIT {
		return fail("run: the module of ", project, " has ", size.integer, " bytes; a run takes 1 to ", i64(pr.C_MODULE_BYTES_LIMIT))
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

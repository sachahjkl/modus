package console

// The loop of a program written in the system
// (src/md/features/program_loop.md): build reads the C source of a project
// from its store, as the principal of this console, gives it to
// recipes.build_c and puts the module in the store module_files; run reads
// the module back, checks its hash, isolates it in a call host with no
// grant, and calls its export main. Each step is a call of a service by
// its name, as a line of the principal would make it.

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/value_kinds"
import "modus:disk_process"
import "modus:system"

// The pages of the memory of a source and of a module: the bound of the
// output of the native C builder (recipes.build_c).
PROGRAM_MEMORY_PAGES :: 16

// program_memory makes a memory object of PROGRAM_MEMORY_PAGES and copies
// bytes into it. The caller closes it.
@(private = "file")
program_memory :: proc "contextless" (bytes: []u8) -> (memory: system.Handle, ok: bool) {
	if len(bytes) > PROGRAM_MEMORY_PAGES * system.PAGE_SIZE {
		return 0, false
	}
	created, status := system.memory_create(PROGRAM_MEMORY_PAGES)
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

// program_project_check fails the line when the principal has no project of
// that name: projects.pins refuses an unknown project.
@(private = "file")
program_project_check :: proc "contextless" (project: string) -> bool {
	project_arguments := [1]Value{{kind = .Text, text = project}}
	_ = call_run("projects.pins", project_arguments[:])
	return !failed
}

// build_program runs build(project, file).
build_program :: proc "contextless" (arguments: []Value) -> Value {
	project := arguments[0].text
	file := arguments[1].text
	if problem, _ := disk_process.name_problem(project); problem != .None {
		return fail("build: \"", project, "\" is no name of a project: 1 to ", i64(disk_process.NAME_LIMIT), " bytes, with no zero byte and no /")
	}
	if !program_project_check(project) {
		return {}
	}
	// The source, from the store of the project: this console acts for
	// the principal that owns it.
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
		return fail("build: the object ", file, " of the store ", project, " is empty")
	}
	source_memory, source_ok := program_memory(transmute([]u8)source.text)
	if !source_ok {
		return fail("build: the source ", file, " has ", i64(len(source.text)), " bytes; a build takes at most ", i64(PROGRAM_MEMORY_PAGES * system.PAGE_SIZE))
	}
	defer system.close(source_memory)
	module_memory, module_ok := program_memory(nil)
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
	return {kind = .Text, text = scratch_text(project, ": module ", digits.text)}
}

// run_program runs run(project) and run(project, grant).
run_program :: proc "contextless" (arguments: []Value) -> Value {
	project := arguments[0].text
	if problem, _ := disk_process.name_problem(project); problem != .None {
		return fail("run: \"", project, "\" is no name of a project: 1 to ", i64(disk_process.NAME_LIMIT), " bytes, with no zero byte and no /")
	}
	if !program_project_check(project) {
		return {}
	}
	// A project declares no grant yet: a run that asks for one is refused
	// before any call host starts.
	if len(arguments) > 1 && arguments[1].text != "" {
		system.log_fact(.Warning, Program_Grant_Refused{project = value_kinds.module_name_field(project)}, arguments[1].text)
		return fail("run: the project ", project, " declares no grant ", arguments[1].text, ": its program runs with the grants of its project, and it declares none")
	}
	module_memory, module_ok := program_memory(nil)
	if !module_ok {
		return fail("run: the budget of the console cannot pay for the memory of the module")
	}
	defer system.close(module_memory)
	read_arguments := [2]Value{{kind = .Text, text = project}, {kind = .Handle, integer = i64(module_memory)}}
	size := call_run("module_files.read", read_arguments[:])
	if failed {
		return {}
	}
	address, map_status := system.memory_map(module_memory, {})
	if map_status != .Ok || size.integer <= 0 || size.integer > PROGRAM_MEMORY_PAGES * system.PAGE_SIZE {
		return fail("run: the module of ", project, " has ", size.integer, " bytes; a run takes 1 to ", i64(PROGRAM_MEMORY_PAGES * system.PAGE_SIZE))
	}
	hash := blake3.hash(([^]u8)(address)[:size.integer])
	system.memory_unmap(address)
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
	main_command := command_find("main")
	if main_command == nil || main_command.parameter_count != 0 {
		return fail("run: the module of ", project, " has no export main with no parameter")
	}
	value := call_run("main", nil)
	if failed {
		return {}
	}
	system.log_fact(.Info, Program_Ran{result = value.integer, module_hash = value_kinds.Hash_Field(hash), project = value_kinds.module_name_field(project)})
	return value
}

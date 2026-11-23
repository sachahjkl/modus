package machine

import "modustool:build"
import "modustool:foundation"

// The loop of a program written in the system
// (src/md/features/program_loop.md), part of `modustool test
// disk_processes`: one machine on a new data disk, driven by keys, with
// no file from the host. Its log is the seventh of the part,
// test_output_disk_processes_7, so a step range names it with
// `of test_output_disk_processes_7`. The console makes the project hello,
// edit takes the C source, build gives the module, run calls its export main. The
// same source again is substituted with no compile; a run that asks for a
// grant that the project does not declare is refused; a changed source
// builds a new module that run calls; a source with a C error builds
// nothing, and run still calls the module before it.

TEST_PROGRAM_LOOP_DISK :: foundation.BUILD_FOLDER + "/test_program_loop_disk.img"

// The window of edit, by its title: the name of the object that it edits.
PROGRAM_LOOP_EDIT_WINDOW :: "edit: hello.c"

// The lines that a failed step of the loop writes.
PROGRAM_BUILD_FAILED :: "recipes: the C build failed at the step "

scenario_program_loop := [?]Step {
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	// The project and its source.
	{kind = .Type, text = "projects.new(\"hello\")"},
	{kind = .Wait, text = "projects: made the project hello of principal 0"},
	{kind = .Type, text = "edit(\"hello\", \"hello.c\")"},
	{kind = .Wait, text = "edit: ok, the first picture is presented", any_order = true},
	{kind = .Wait, text = "compositor: surface edit"},
	{kind = .Front, text = PROGRAM_LOOP_EDIT_WINDOW},
	{kind = .Keys, text = "long main(void) { return 42; }"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "edit: kept a text of 31 bytes in the generation "},
	// The first build compiles; run calls the module.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "build(\"hello\", \"hello.c\")"},
	{kind = .Wait, text = "recipes: built hello.c into a module of ", fails_on = PROGRAM_BUILD_FAILED},
	{kind = .Wait, text = "module_files: put hello: "},
	{kind = .Wait, text = "[console] hello: module "},
	{kind = .Type, text = "run(\"hello\")"},
	{kind = .Wait, text = "console: ran hello, module "},
	{kind = .Wait, text = "[console] 42"},
	// The same source: the recipe is realised, no compile runs.
	{kind = .Type, text = "build(\"hello\", \"hello.c\")"},
	{kind = .Wait, text = "recipes: substituted hello.c: the recipe ", fails_on = "recipes: built hello.c"},
	{kind = .Wait, text = "[console] hello: module "},
	// A grant that the project does not declare: no call host starts.
	{kind = .Type, text = "run(\"hello\", \"store\")"},
	{kind = .Wait, text = "console: refused the run of hello with the grant store: the project declares no such grant", fails_on = "console: ran hello"},
	{kind = .Wait, text = "[console] error: run: the project hello declares no grant store"},
	// A changed source builds a new module.
	{kind = .Front, text = PROGRAM_LOOP_EDIT_WINDOW},
	{kind = .Key, text = "ctrl-a"},
	{kind = .Keys, text = "long main(void) { return 43; }"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "edit: kept a text of 31 bytes in the generation "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "build(\"hello\", \"hello.c\")"},
	{kind = .Wait, text = "recipes: built hello.c into a module of ", fails_on = PROGRAM_BUILD_FAILED},
	{kind = .Wait, text = "[console] hello: module "},
	{kind = .Type, text = "run(\"hello\")"},
	{kind = .Wait, text = "[console] 43"},
	// A C error: the compile fails, nothing is kept, and the module before
	// stays.
	{kind = .Front, text = PROGRAM_LOOP_EDIT_WINDOW},
	{kind = .Key, text = "ctrl-a"},
	{kind = .Keys, text = "long main(void) { return 44 }"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "edit: kept a text of 30 bytes in the generation "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "build(\"hello\", \"hello.c\")"},
	{kind = .Wait, text = "recipes: the C build failed at the step 2: ", fails_on = "recipes: built hello.c"},
	{kind = .Wait, text = "[console] error: recipes.build_c: the argument source has the byte 125 at offset 28"},
	{kind = .Type, text = "run(\"hello\")"},
	{kind = .Wait, text = "[console] 43"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// program_loop_run runs the machine of the loop on a new data disk.
program_loop_run :: proc(part: ^Test_Part_Run) -> bool {
	disk_prepare(TEST_PROGRAM_LOOP_DISK, build.DATA_DISK_SIZE, true) or_return
	return machine_test(part, scenario_program_loop[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_DISK_PROCESSES, 7), exit_status = build.MACHINE_STOP_OK, data_disk = TEST_PROGRAM_LOOP_DISK})
}
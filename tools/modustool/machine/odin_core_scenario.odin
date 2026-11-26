package machine

import "core:fmt"
import "core:os"
import "modus:contract/blake3"
import "modus:disk_process"
import "modustool:build"
import "modustool:foundation"

// The machine test of the Odin core target on modus
// (src/md/infrastructure/odin_core_target.md): builds core_probe and
// core_probe_panic outside the system sources with target: modus, writes both
// and their debug objects onto a module disk, starts core_probe without a store
// grant to verify zero ambient authority and refusal, grants Store and restarts
// core_probe to exercise core:fmt, heap/temp allocators, core:mem/virtual,
// core:time, core:sync, core:thread, and core:os private store I/O through a
// clean Done exit, then starts core_probe_panic to verify runtime panic logging
// and stop_report frame resolution.

TEST_ODIN_CORE_DISK :: foundation.BUILD_FOLDER + "/test_odin_core_disk.img"
TEST_OUTPUT_ODIN_CORE :: foundation.BUILD_FOLDER + "/test_output_odin_core.txt"
TEST_ODIN_CORE_OUT :: foundation.BUILD_FOLDER + "/odin_core_modules"

CORE_PROBE_SOURCE :: "src/outside/projects/core_probe"
CORE_PROBE_PANIC_SOURCE :: "src/outside/projects/core_probe_panic"

@(private = "file")
odin_core_build_probe :: proc(tool_path, system_folder, source_folder, name: string) -> (mod_file: []u8, dbg_file: []u8, ok: bool) {
	out_dir := foundation.join(TEST_ODIN_CORE_OUT, "/", name)
	foundation.reset_folder(out_dir) or_return
	command := [?]string{tool_path, "module-build", source_folder, "--system", system_folder, "--out", out_dir}
	state, stdout, stderr, start_err := os.process_exec({command = command[:]}, context.temp_allocator)
	os.write(os.stdout, stdout)
	os.write(os.stderr, stderr)
	if start_err != nil || !state.exited || !state.success {
		fmt.eprintfln("modustool: test failed: `module-build %s` did not build %s", source_folder, name)
		return nil, nil, false
	}
	mod_file = foundation.read_file(foundation.join(out_dir, "/", name, ".module")) or_return
	dbg_file = foundation.read_file(foundation.join(out_dir, "/", name, ".debug")) or_return
	return mod_file, dbg_file, true
}

odin_core_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	tool_path := foundation.tool_executable_path() or_return
	system_folder, folder_error := os.get_working_directory(context.temp_allocator)
	if folder_error != nil {
		fmt.eprintfln("modustool: test failed: cannot read the folder of the system: %v", folder_error)
		return false
	}

	probe_file, probe_debug_raw := odin_core_build_probe(tool_path, system_folder, CORE_PROBE_SOURCE, "core_probe") or_return
	panic_file, panic_debug_raw := odin_core_build_probe(tool_path, system_folder, CORE_PROBE_PANIC_SOURCE, "core_probe_panic") or_return

	probe_debug_file := build.module_debug_object_file("core_probe", probe_file, probe_debug_raw) or_return
	panic_debug_file := build.module_debug_object_file("core_probe_panic", panic_file, panic_debug_raw) or_return

	files := [?]build.Module_File {
		{name = "core_probe", bytes = probe_file},
		probe_debug_file,
		{name = "core_probe_panic", bytes = panic_file},
		panic_debug_file,
	}
	build.module_disk_write(TEST_ODIN_CORE_DISK, files[:]) or_return

	probe_digits, panic_digits: [disk_process.HASH_DIGITS]u8
	disk_process.hash_write(&probe_digits, blake3.hash(probe_file))
	disk_process.hash_write(&panic_digits, blake3.hash(panic_file))
	probe_hash := fmt.aprintf("%s", string(probe_digits[:]))
	defer delete(probe_hash)
	panic_hash := fmt.aprintf("%s", string(panic_digits[:]))
	defer delete(panic_hash)

	steps := make([dynamic]Step)
	defer delete(steps)
	// The storage service opens the data disk in parallel with console window startup.
	append(&steps, Step{kind = .Wait, text = "storage: ok, generation 2: 1 stores, 4 objects", any_order = true})
	append(&steps, Step{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true})
	append(&steps, Step{kind = .Front, text = "console"})
	append(&steps, Step{kind = .Type, text = "connect(\"storage\")"})
	append(&steps, Step{kind = .Wait, text = "[console]   module     storage"})

	// Start core_probe with no grants: verify zero ambient authority and store refusal.
	append(&steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"core_probe\", \"%s\")", probe_hash)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: started core_probe from the disk, hash %s, with no grant", probe_hash), any_order = true})
	append(&steps, Step{kind = .Wait, text = "core_probe: no store grant, waiting for store", fails_on = "Panic:"})

	// Grant private store access, stop, and restart core_probe to run the full core suite.
	append(&steps, Step{kind = .Type, text = "allow(\"core_probe\", \"store\")"})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: the nickname core_probe, the file %s, has the grant store for principal 0", probe_hash)})
	append(&steps, Step{kind = .Type, text = "stop(\"core_probe\")"})
	append(&steps, Step{kind = .Wait, text = "root: core_probe stopped: "})

	append(&steps, Step{kind = .Type, text = "start_from_disk(\"core_probe\", \"\")"})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: started core_probe from the disk, hash %s, with the grant store: the store disk-core_probe", probe_hash), any_order = true})
	append(&steps, Step{kind = .Wait, text = "core_probe: ok, all core packages passed", fails_on = "Panic:"})
	append(&steps, Step{kind = .Wait, text = "root: core_probe stopped: itself, done"})

	// Start core_probe_panic: verify panic message on log, fault stop, and stop_report frame.
	append(&steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"core_probe_panic\", \"%s\")", panic_hash)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: started core_probe_panic from the disk, hash %s, with no grant", panic_hash), any_order = true})
	append(&steps, Step{kind = .Wait, text = "core_probe_panic: deliberate panic"})
	append(&steps, Step{kind = .Wait, text = "root: core_probe_panic stopped: a fault", any_order = true})
	append(&steps, Step{kind = .Wait, text = "root: kept the stop report of core_probe_panic, a disk process of principal 0: stop_report(\"core_probe_panic\") names its frames"})
	append(&steps, Step{kind = .Type, text = "columns(where(stop_report(\"core_probe_panic\"), procedure = \"core_probe_panic::trigger_panic\"), module, procedure, file)"})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("debugger: read the debug object %s of core_probe_panic from the store %s of principal 0: ", panic_hash, disk_process.STORE_NAME)})
	append(&steps, Step{kind = .Wait, text = "root: disconnected module_files from the service storage", any_order = true})
	append(&steps, Step{kind = .Wait, text = "[console] core_probe_panic  core_probe_panic::trigger_panic  core_probe_panic/main.odin"})

	append(&steps, Step{kind = .Type, text = "shutdown()"})
	append(&steps, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})

	return machine_test(part, steps[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_ODIN_CORE, exit_status = build.MACHINE_STOP_OK, data_disk = TEST_ODIN_CORE_DISK})
}

@(init)
odin_core_test_part_register :: proc "contextless" () {
	test_part_scenario_register("odin_core", odin_core_tests_run)
}

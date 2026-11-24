package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "modus:contract/blake3"
import "modustool:foundation"

// Every optimization mode maps to its exact argument word, and any other word
// is refused.
@(test)
optimization_mode_arguments_and_refusals :: proc(t: ^testing.T) {
	for mode in Optimization_Mode {
		word := optimization_mode_argument(mode)
		testing.expect(t, word != "", "each mode has a non-empty argument")
		parsed, ok := optimization_mode_of_argument(word)
		testing.expect(t, ok, "the argument of a mode parses back")
		testing.expect_value(t, parsed, mode)
	}
	testing.expect_value(t, optimization_mode_argument(.Speed), "speed")
	testing.expect_value(t, optimization_mode_argument(.None), "none")

	for bad in ([]string{"", "fast", "Speed", "SPEED", "None", "NONE", "0", "O0", "minimal", "size", "speed ", " none"}) {
		_, ok := optimization_mode_of_argument(bad)
		testing.expectf(t, !ok, "unknown optimization mode `%s` is refused", bad)
	}
}

// User modules switch compiler, IR optimizer, and llc flags between Speed and
// None. Kernel modules and the boot program always stay at Speed.
@(test)
module_commands_follow_optimization_mode_and_keep_kernel_at_speed :: proc(t: ^testing.T) {
	user_module := foundation.Module_Build{name = "console", source = foundation.SOURCE_FOLDER_MODULES + "/console"}
	kernel_module := foundation.Module_Build{name = "kernel", source = foundation.SOURCE_FOLDER_KERNEL, kernel = true}
	library_module := foundation.Module_Build{name = "text_rendering", source = foundation.LIBRARY_MODULE_SOURCES + "text_rendering", library = true}
	main_volume := Boot_Volume{path = BOOT_VOLUME, image = BOOT_IMAGE, kernel = "kernel"}

	testing.expect_value(t, module_effective_optimization(user_module, .Speed), Optimization_Mode.Speed)
	testing.expect_value(t, module_effective_optimization(user_module, .None), Optimization_Mode.None)
	testing.expect_value(t, module_effective_optimization(kernel_module, .Speed), Optimization_Mode.Speed)
	testing.expect_value(t, module_effective_optimization(kernel_module, .None), Optimization_Mode.Speed)
	testing.expect_value(t, module_effective_optimization(library_module, .Speed), Optimization_Mode.Speed)
	testing.expect_value(t, module_effective_optimization(library_module, .None), Optimization_Mode.Speed)

	// Speed mode: user module and kernel both use -o:speed, no opt pass, llc -O3.
	user_speed_compile := module_compile_command(user_module, .Speed)
	testing.expect(t, slice.contains(user_speed_compile, "-o:speed"), "Speed compiles user modules with -o:speed")
	testing.expect(t, !slice.contains(user_speed_compile, "-o:none"), "Speed does not pass -o:none")
	testing.expect(t, !slice.contains(user_speed_compile, "-use-single-module"), "Speed does not pass -use-single-module")
	testing.expect(t, !slice.contains(user_speed_compile, "-no-thread-local"), "Speed does not pass -no-thread-local")
	testing.expect_value(t, len(module_fast_ir_command(user_module, .Speed)), 0)
	testing.expect(t, slice.contains(module_object_command(user_module, .Speed), "-O3"), "Speed runs llc -O3")

	// None mode (--fast): user module uses -o:none, -use-single-module,
	// -no-thread-local, opt -O1 -S, and llc -O0.
	user_none_compile := module_compile_command(user_module, .None)
	testing.expect(t, slice.contains(user_none_compile, "-o:none"), "None compiles user modules with -o:none")
	testing.expect(t, slice.contains(user_none_compile, "-use-single-module"), "None passes -use-single-module")
	testing.expect(t, slice.contains(user_none_compile, "-no-thread-local"), "None passes -no-thread-local")
	testing.expect(t, !slice.contains(user_none_compile, "-o:speed"), "None does not pass -o:speed for user modules")

	fast_ir := module_fast_ir_command(user_module, .None)
	testing.expect(t, len(fast_ir) > 0 && fast_ir[0] == "opt", "None runs opt on user module IR")
	testing.expect(t, slice.contains(fast_ir, "-O1"), "None runs opt -O1")
	testing.expect(t, slice.contains(fast_ir, "-S"), "None writes textual LLVM IR from opt")

	user_none_object := module_object_command(user_module, .None)
	testing.expect(t, slice.contains(user_none_object, "-O0"), "None runs llc -O0 on user modules")
	testing.expect(t, !slice.contains(user_none_object, "-O3"), "None does not run llc -O3 on user modules")

	// Kernel stays at Speed even when requested optimization is None.
	kernel_compile := module_compile_command(kernel_module, .None)
	testing.expect(t, slice.contains(kernel_compile, "-o:speed"), "kernel stays on -o:speed in --fast")
	testing.expect(t, !slice.contains(kernel_compile, "-o:none"), "kernel never compiles with -o:none")
	testing.expect_value(t, len(module_fast_ir_command(kernel_module, .None)), 0)
	testing.expect(t, slice.contains(module_object_command(kernel_module, .None), "-O3"), "kernel stays on llc -O3 in --fast")

	// Boot program stays at Speed regardless of build mode.
	boot_compile := boot_program_compile_command(main_volume)
	testing.expect(t, slice.contains(boot_compile, "-o:speed"), "boot program stays on -o:speed in --fast")
	testing.expect(t, !slice.contains(boot_compile, "-o:none"), "boot program never compiles with -o:none")
}

// `build` argument parsing accepts valid combinations in any order and refuses
// unknown flags, unknown volumes, duplicates, and invalid process counts.
@(test)
build_command_arguments_parse_and_refusals :: proc(t: ^testing.T) {
	for volume in boot_volumes() {
		name := boot_volume_name(volume.path)
		path, found := boot_volume_path_of_name(name)
		testing.expectf(t, found && path == volume.path, "volume name `%s` resolves to `%s`", name, volume.path)
	}
	for bad_name in ([]string{"", "mains", "Main", "main ", "boot_volume.img", "self_test_0", "self_test_99"}) {
		_, found := boot_volume_path_of_name(bad_name)
		testing.expectf(t, !found, "unknown volume name `%s` is refused", bad_name)
	}

	// Refusal cases first.
	refused := [][]string {
		{"whole", "whole"},
		{"--fast", "--fast"},
		{"--slow"},
		{"-O0"},
		{"-"},
		{"0"},
		{"00"},
		{"-1"},
		{"4abc"},
		{"9999999999999999999999999"},
		{"2", "4"},
		{""},
		{"mains"},
		{"Main"},
		{"main", "shortage"},
		{"--fast", "unknown_volume"},
	}
	for args in refused {
		_, problem := build_arguments_parse(args)
		testing.expectf(t, problem != "", "`build %v` is refused", args)
	}
	// Unknown volume refusal lists known names.
	_, unknown_volume_problem := build_arguments_parse([]string{"mains"})
	testing.expect(t, strings.contains(unknown_volume_problem, MAIN_BOOT_VOLUME_NAME), "unknown volume refusal lists `main`")
	testing.expect(t, strings.contains(unknown_volume_problem, "shortage"), "unknown volume refusal lists `shortage`")

	// Valid combinations.
	opts, problem := build_arguments_parse(nil)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, opts, Build_Command_Options{whole = false, optimization = .Speed, volume_path = "", host_processes = 0})

	opts, problem = build_arguments_parse([]string{"--fast"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, opts, Build_Command_Options{whole = false, optimization = .None, volume_path = "", host_processes = 0})

	opts, problem = build_arguments_parse([]string{"--fast", "main"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, opts, Build_Command_Options{whole = false, optimization = .None, volume_path = BOOT_VOLUME, host_processes = 0})

	opts, problem = build_arguments_parse([]string{"whole", "--fast", "shortage", "4"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, opts, Build_Command_Options{whole = true, optimization = .None, volume_path = BOOT_VOLUME_SHORTAGE, host_processes = 4})

	opts, problem = build_arguments_parse([]string{"2", "measure", "whole"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, opts, Build_Command_Options{whole = true, optimization = .Speed, volume_path = BOOT_VOLUME_MEASURE, host_processes = 2})
}

// `module` and `volume` subcommand argument parsers accept valid optimization
// modes and refuse malformed or unknown arguments.
@(test)
module_and_volume_subcommand_arguments_parse_and_refusals :: proc(t: ^testing.T) {
	// `module` refusals.
	bad_module := [][]string {
		nil,
		{"console"},
		{"console", "with_checks", "with_debug_information"},
		{"", "with_checks", "with_debug_information", "speed"},
		{"console", "checks", "with_debug_information", "speed"},
		{"console", "with_checks", "debug", "speed"},
		{"console", "with_checks", "with_debug_information", "fast"},
		{"console", "with_checks", "with_debug_information", "SPEED"},
		{"console", "with_checks", "with_debug_information", "speed", "link"},
		{"console", "with_checks", "with_debug_information", "speed", "compile", "extra"},
	}
	for args in bad_module {
		_, ok := module_arguments_parse(args)
		testing.expectf(t, !ok, "`module %v` is refused", args)
	}

	// `module` valid forms.
	mod_opts, mod_ok := module_arguments_parse([]string{"console", "with_checks", "with_debug_information", "none"})
	testing.expect(t, mod_ok)
	testing.expect_value(t, mod_opts, Module_Command_Options{name = "console", checks = true, debug_information = true, optimization = .None, step = ""})

	mod_opts, mod_ok = module_arguments_parse([]string{"kernel", "without_checks", "without_debug_information", "speed", MODULE_STEP_COMPILE})
	testing.expect(t, mod_ok)
	testing.expect_value(t, mod_opts, Module_Command_Options{name = "kernel", checks = false, debug_information = false, optimization = .Speed, step = MODULE_STEP_COMPILE})

	mod_opts, mod_ok = module_arguments_parse([]string{"console", "with_checks", "with_debug_information", "none", MODULE_STEP_CONVERT})
	testing.expect(t, mod_ok)
	testing.expect_value(t, mod_opts, Module_Command_Options{name = "console", checks = true, debug_information = true, optimization = .None, step = MODULE_STEP_CONVERT})

	// `volume` refusals.
	bad_volume := [][]string {
		nil,
		{""},
		{"main", "fast"},
		{"main", "SPEED"},
		{"main", ""},
		{"main", "speed", "extra"},
	}
	for args in bad_volume {
		_, _, ok := volume_arguments_parse(args)
		testing.expectf(t, !ok, "`volume %v` is refused", args)
	}

	// `volume` valid forms.
	vol_name, vol_mode, vol_ok := volume_arguments_parse([]string{"main"})
	testing.expect(t, vol_ok)
	testing.expect_value(t, vol_name, "main")
	testing.expect_value(t, vol_mode, Optimization_Mode.Speed)

	vol_name, vol_mode, vol_ok = volume_arguments_parse([]string{"main", "none"})
	testing.expect(t, vol_ok)
	testing.expect_value(t, vol_name, "main")
	testing.expect_value(t, vol_mode, Optimization_Mode.None)

	vol_name, vol_mode, vol_ok = volume_arguments_parse([]string{"shortage", "speed"})
	testing.expect(t, vol_ok)
	testing.expect_value(t, vol_name, "shortage")
	testing.expect_value(t, vol_mode, Optimization_Mode.Speed)
}

// Switching between Speed and None invalidates module build records cleanly in
// both directions, and keeps kernel compile keys unchanged across modes.
@(test)
incremental_build_switches_between_speed_and_none_cleanly :: proc(t: ^testing.T) {
	// Real module compile key inputs: user module differs across Speed/None;
	// kernel module stays identical across Speed/None.
	user_row := foundation.Module_Build{name = "agenda", source = foundation.DEMONSTRATION_MODULE_SOURCES + "agenda"}
	kernel_row := foundation.Module_Build{name = "kernel", source = foundation.SOURCE_FOLDER_KERNEL, kernel = true}

	user_speed_inputs, ok1 := module_compile_key_inputs(user_row, .Speed)
	kernel_speed_inputs, ok2 := module_compile_key_inputs(kernel_row, .Speed)
	user_none_inputs, ok3 := module_compile_key_inputs(user_row, .None)
	kernel_none_inputs, ok4 := module_compile_key_inputs(kernel_row, .None)
	testing.expect(t, ok1 && ok2 && ok3 && ok4, "compile key inputs can be built")
	testing.expect(t, strings.join(user_speed_inputs.settings, "\n", context.temp_allocator) != strings.join(user_none_inputs.settings, "\n", context.temp_allocator), "user module settings differ between Speed and None")
	testing.expect_value(t, strings.join(kernel_speed_inputs.settings, "\n", context.temp_allocator), strings.join(kernel_none_inputs.settings, "\n", context.temp_allocator))

	// Simulated module steps switching Speed -> None -> Speed.
	root, err := os.make_directory_temp("", "fast_build_test_*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(root)

	source_dir := fmt.tprintf("%s/app", root)
	_ = os.make_directory_all(source_dir)
	source_file := fmt.tprintf("%s/main.odin", source_dir)
	_ = os.write_entire_file(source_file, "package app\nmain :: proc() {}\n")

	linked_file := fmt.tprintf("%s/app.elf", root)
	module_file := fmt.tprintf("%s/app.module", root)
	debug_file := fmt.tprintf("%s/app.debug", root)
	compile_record := fmt.tprintf("%s/compile%s", root, BUILD_RECORD_SUFFIX)
	convert_record := fmt.tprintf("%s/convert%s", root, BUILD_RECORD_SUFFIX)

	make_steps :: proc(source_file, linked_file, module_file, debug_file, compile_record, convert_record: string, mode: Optimization_Mode) -> Module_Steps {
		settings := make([]string, 2, context.temp_allocator)
		settings[0] = "optimization"
		settings[1] = optimization_mode_argument(mode)
		sources := make([]string, 1, context.temp_allocator)
		sources[0] = source_file
		compile_out := make([]string, 1, context.temp_allocator)
		compile_out[0] = linked_file
		convert_out := make([]string, 2, context.temp_allocator)
		convert_out[0] = module_file
		convert_out[1] = debug_file
		return {
			optimization        = mode,
			compile_record_path = compile_record,
			convert_record_path = convert_record,
			compile_inputs      = {settings = settings, source_files = sources},
			convert_inputs      = {},
			compile_outputs     = compile_out,
			convert_outputs     = convert_out,
		}
	}

	write_outputs :: proc(linked_file, module_file, debug_file: string, tag: string) {
		_ = os.write_entire_file(linked_file, fmt.tprintf("linked %s", tag))
		_ = os.write_entire_file(module_file, fmt.tprintf("module %s", tag))
		_ = os.write_entire_file(debug_file, fmt.tprintf("debug %s", tag))
	}

	// Build in Speed. The build starts one hour after the sources were written
	// so INPUT_FILE_AGE_LEAST admits writing the record.
	speed_steps := make_steps(source_file, linked_file, module_file, debug_file, compile_record, convert_record, .Speed)
	write_outputs(linked_file, module_file, debug_file, "speed")
	table := input_file_table_make(root, {"app"})
	defer input_file_table_destroy(table)
	table.started = time.time_add(time.now(), time.Hour)
	testing.expect(t, module_step_records_write(speed_steps, table, true, speed_steps.compile_inputs.source_files, nil), "Speed records are written")

	step, reason := module_step_needed(speed_steps, table)
	testing.expect_value(t, step, Module_Step.Kept)
	testing.expect_value(t, reason, "")

	// Switch to None: compile record mode disagrees -> Built with OPTIMIZATION_CHANGED_REASON.
	none_steps := make_steps(source_file, linked_file, module_file, debug_file, compile_record, convert_record, .None)
	step, reason = module_step_needed(none_steps, table)
	testing.expect_value(t, step, Module_Step.Built)
	testing.expect_value(t, reason, OPTIMIZATION_CHANGED_REASON)

	// Build in None and keep it in None.
	write_outputs(linked_file, module_file, debug_file, "none")
	testing.expect(t, module_step_records_write(none_steps, table, true, none_steps.compile_inputs.source_files, nil), "None records are written")
	step, reason = module_step_needed(none_steps, table)
	testing.expect_value(t, step, Module_Step.Kept)
	testing.expect_value(t, reason, "")

	// Switch back to Speed: invalidated cleanly with OPTIMIZATION_CHANGED_REASON.
	step, reason = module_step_needed(speed_steps, table)
	testing.expect_value(t, step, Module_Step.Built)
	testing.expect_value(t, reason, OPTIMIZATION_CHANGED_REASON)

	// Rebuild in Speed, then overwrite convert record with None mode -> Converted with OPTIMIZATION_CHANGED_REASON.
	write_outputs(linked_file, module_file, debug_file, "speed")
	testing.expect(t, module_step_records_write(speed_steps, table, true, speed_steps.compile_inputs.source_files, nil), "Speed records rewritten")
	convert_rec, has_convert := build_record_read(convert_record)
	testing.expect(t, has_convert)
	testing.expect(t, build_record_write(convert_record, convert_rec.key, speed_steps.convert_outputs, speed_steps.compile_inputs.source_files, nil, .None), "mismatched convert record written")
	step, reason = module_step_needed(speed_steps, table)
	testing.expect_value(t, step, Module_Step.Converted)
	testing.expect_value(t, reason, OPTIMIZATION_CHANGED_REASON)
}

// Boot volume build keys and records track the requested optimization mode so
// switching between Speed and None never reuses a volume from the other mode.
@(test)
boot_volume_records_invalidate_across_optimization_modes :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "fast_volume_test_*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(root)

	for dir in ([]string{foundation.SOURCE_FOLDER_BOOT, foundation.SOURCE_FOLDER_RUNTIME, "resources/keys"}) {
		_ = os.make_directory_all(fmt.tprintf("%s/%s", root, dir))
	}
	_ = os.write_entire_file(fmt.tprintf("%s/%s/main.odin", root, foundation.SOURCE_FOLDER_BOOT), "package boot\nefi_main :: proc() {}\n")
	_ = os.write_entire_file(fmt.tprintf("%s/%s", root, BOOT_PROGRAM_JUMP_SOURCE), "global jump\njump: ret\n")
	_ = os.write_entire_file(fmt.tprintf("%s/%s", root, RUNTIME_MEMORY), "global copy\ncopy: ret\n")
	_ = os.write_entire_file(fmt.tprintf("%s/%s", root, TEST_SIGNING_KEY_FILE), "00\n")

	built_files := make([dynamic]Record_Output, context.temp_allocator)
	append(&built_files, Record_Output{path = BOOT_IMAGE, hash = blake3.hash(transmute([]u8)string("boot image"))})
	append(&built_files, Record_Output{path = foundation.module_path("kernel"), hash = blake3.hash(transmute([]u8)string("kernel"))})
	append(&built_files, Record_Output{path = DEBUG_IMAGE, hash = blake3.hash(transmute([]u8)string("debug image"))})
	append(&built_files, Record_Output{path = SYSTEM_KEY_FILE, hash = blake3.hash(transmute([]u8)string("system key"))})
	settings := make([]string, 1, context.temp_allocator)
	settings[0] = "host program odin: /store/odin"
	shared := Boot_Volume_Shared_Inputs{settings = settings, built_files = built_files[:]}

	sources := []string{fmt.tprintf("%s/%s/main.odin", root, foundation.SOURCE_FOLDER_BOOT)}
	main_volume := Boot_Volume{path = BOOT_VOLUME, image = BOOT_IMAGE, kernel = "kernel"}

	table := input_file_table_make(root, {foundation.SOURCE_FOLDER_BOOT})
	defer input_file_table_destroy(table)
	table.started = time.time_add(time.now(), time.Hour)

	speed_inputs, speed_ok := boot_volume_key_inputs(main_volume, shared, sources, nil, .Speed)
	testing.expect(t, speed_ok)
	speed_key, speed_complete := build_key(speed_inputs, table)
	testing.expect(t, speed_complete)

	none_inputs, none_ok := boot_volume_key_inputs(main_volume, shared, sources, nil, .None)
	testing.expect(t, none_ok)
	none_key, none_complete := build_key(none_inputs, table)
	testing.expect(t, none_complete)
	testing.expect(t, speed_key != none_key, "boot volume build keys differ between Speed and None")

	volume_file := fmt.tprintf("%s/boot_volume.img", root)
	record_file := fmt.tprintf("%s/main%s", root, BUILD_RECORD_SUFFIX)
	_ = os.write_entire_file(volume_file, "volume bytes")

	testing.expect(t, build_record_write(record_file, speed_key, {volume_file}, sources, nil, .Speed))
	kept, reason := recorded_build_is_kept(record_file, speed_inputs, table, {volume_file}, .Speed)
	testing.expectf(t, kept, "volume is kept in Speed: %s", reason)

	kept, reason = recorded_build_is_kept(record_file, none_inputs, table, {volume_file}, .None)
	testing.expect(t, !kept, "Speed volume is not kept in None")
	testing.expect_value(t, reason, OPTIMIZATION_CHANGED_REASON)

	testing.expect(t, build_record_write(record_file, none_key, {volume_file}, sources, nil, .None))
	kept, reason = recorded_build_is_kept(record_file, none_inputs, table, {volume_file}, .None)
	testing.expectf(t, kept, "volume is kept in None: %s", reason)

	kept, reason = recorded_build_is_kept(record_file, speed_inputs, table, {volume_file}, .Speed)
	testing.expect(t, !kept, "None volume is not kept in Speed")
	testing.expect_value(t, reason, OPTIMIZATION_CHANGED_REASON)
}

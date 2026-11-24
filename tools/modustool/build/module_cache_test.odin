package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "modus:contract/blake3"

// Two worktrees at different host paths with identical source bytes compute the
// exact same canonical compile key and module key, and a module stored by the
// first worktree restores cleanly into the second worktree.
@(test)
module_cache_reuses_artifacts_across_worktrees_and_invalidates_on_changes :: proc(t: ^testing.T) {
	base, err := os.make_directory_temp("", "module_cache_test_*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(base)

	cache_dir := fmt.tprintf("%s/shared_cache", base)
	wt_a := fmt.tprintf("%s/worktree_alpha", base)
	wt_b := fmt.tprintf("%s/worktree_beta_longer_name", base)

	setup_worktree :: proc(root: string, app_source: string, import_bytes: string) {
		_ = os.make_directory_all(fmt.tprintf("%s/src/app", root))
		_ = os.make_directory_all(fmt.tprintf("%s/src/runtime", root))
		_ = os.make_directory_all(fmt.tprintf("%s/build/modules/app", root))
		_ = os.write_entire_file(fmt.tprintf("%s/src/app/main.odin", root), app_source)
		_ = os.write_entire_file(fmt.tprintf("%s/src/runtime/memory.asm", root), "global copy\ncopy: ret\n")
		_ = os.write_entire_file(fmt.tprintf("%s/build/modules/dep.module", root), import_bytes)
	}

	make_steps :: proc(root: string, mode: Optimization_Mode, with_debug: bool) -> (steps: Module_Steps, outputs: []Cache_Output_Spec) {
		compile_settings := make([]string, 3, context.temp_allocator)
		compile_settings[0] = "host program odin: /nix/store/test/bin/odin"
		compile_settings[1] = "optimization"
		compile_settings[2] = optimization_mode_argument(mode)

		fixed_files := make([]string, 1, context.temp_allocator)
		fixed_files[0] = "src/runtime/memory.asm"

		convert_settings := make([]string, 3, context.temp_allocator)
		convert_settings[0] = with_debug ? "with a debug object" : "with no debug object"
		convert_settings[1] = "imports"
		convert_settings[2] = "dep"

		built_files := make([]string, 1, context.temp_allocator)
		built_files[0] = fmt.tprintf("%s/build/modules/dep.module", root)

		steps = {
			optimization        = mode,
			compile_record_path = fmt.tprintf("%s/build/modules/app.compile%s", root, BUILD_RECORD_SUFFIX),
			convert_record_path = fmt.tprintf("%s/build/modules/app.convert%s", root, BUILD_RECORD_SUFFIX),
			compile_inputs      = {
				subject     = "the compile step of the module app",
				settings    = compile_settings,
				fixed_files = fixed_files,
			},
			convert_inputs = {
				subject     = "the conversion of the module app",
				settings    = convert_settings,
				built_files = built_files,
			},
		}
		list := make([dynamic]Cache_Output_Spec, context.temp_allocator)
		append(&list, Cache_Output_Spec{cache_name = "module.bin", local_path = fmt.tprintf("%s/build/modules/app.module", root)})
		append(&list, Cache_Output_Spec{cache_name = "sources.list", local_path = fmt.tprintf("%s/build/modules/app/sources.list", root)})
		append(&list, Cache_Output_Spec{cache_name = "reached_facts.list", local_path = fmt.tprintf("%s/build/modules/app/reached_facts.list", root)})
		if with_debug {
			append(&list, Cache_Output_Spec{cache_name = "module.debug", local_path = fmt.tprintf("%s/build/modules/app.debug", root)})
		}
		return steps, list[:]
	}

	setup_worktree(wt_a, "package app\nmain :: proc() {}\n", "dep v1")
	setup_worktree(wt_b, "package app\nmain :: proc() {}\n", "dep v1")

	// Write built artifacts in worktree A.
	_ = os.write_entire_file(fmt.tprintf("%s/build/modules/app.module", wt_a), "MODUS_MODULE_BYTES_V1")
	_ = os.write_entire_file(fmt.tprintf("%s/build/modules/app/sources.list", wt_a), "src/app/main.odin\n")
	_ = os.write_entire_file(fmt.tprintf("%s/build/modules/app/reached_facts.list", wt_a), "")
	_ = os.write_entire_file(fmt.tprintf("%s/build/modules/app.debug", wt_a), "MODUS_DEBUG_BYTES_V1")

	table_a := input_file_table_make(wt_a, {"src"})
	defer input_file_table_destroy(table_a)
	table_a.started = time.time_add(time.now(), time.Hour)

	table_b := input_file_table_make(wt_b, {"src"})
	defer input_file_table_destroy(table_b)
	table_b.started = time.time_add(time.now(), time.Hour)

	steps_a, outputs_a := make_steps(wt_a, .None, true)
	steps_b, outputs_b := make_steps(wt_b, .None, true)
	// convert_inputs.built_files uses relative paths in real builds; mirror that here.
	steps_a.convert_inputs.built_files = nil
	steps_b.convert_inputs.built_files = nil
	dep_hash := blake3.hash(transmute([]u8)string("dep v1"))
	steps_a.convert_inputs.hashed_built_files = {{path = "build/modules/dep.module", hash = dep_hash}}
	steps_b.convert_inputs.hashed_built_files = {{path = "build/modules/dep.module", hash = dep_hash}}

	// Canonical keys must match across different worktree roots.
	src_a := []string{fmt.tprintf("%s/src/app/main.odin", wt_a)}
	src_b := []string{fmt.tprintf("%s/src/app/main.odin", wt_b)}
	key_a, ok_a := module_cache_compile_key(steps_a, table_a, src_a, nil)
	key_b, ok_b := module_cache_compile_key(steps_b, table_b, src_b, nil)
	testing.expect(t, ok_a && ok_b, "canonical compile keys compute cleanly")
	testing.expect_value(t, key_a, key_b)

	// Store from worktree A.
	testing.expect(t, module_cache_store_entries(cache_dir, steps_a, table_a, outputs_a, src_a, nil), "worktree A stores module into shared cache")

	// Restore into worktree B (which has an empty build/modules/app*).
	testing.expect(t, module_cache_restore_entries(cache_dir, steps_b, table_b, outputs_b), "worktree B restores module from shared cache")
	restored_mod, read_err := os.read_entire_file(fmt.tprintf("%s/build/modules/app.module", wt_b), context.temp_allocator)
	testing.expect_value(t, read_err, nil)
	testing.expect_value(t, string(restored_mod), "MODUS_MODULE_BYTES_V1")
	restored_dbg, dbg_err := os.read_entire_file(fmt.tprintf("%s/build/modules/app.debug", wt_b), context.temp_allocator)
	testing.expect_value(t, dbg_err, nil)
	testing.expect_value(t, string(restored_dbg), "MODUS_DEBUG_BYTES_V1")

	// Optimization mode switch misses cleanly (.Speed != .None).
	steps_speed, outputs_speed := make_steps(wt_b, .Speed, true)
	steps_speed.convert_inputs.built_files = nil
	steps_speed.convert_inputs.hashed_built_files = {{path = "build/modules/dep.module", hash = dep_hash}}
	testing.expect(t, !module_cache_restore_entries(cache_dir, steps_speed, table_b, outputs_speed), "Speed mode does not reuse None cache entry")

	// Import module hash change misses cleanly.
	steps_dep_changed := steps_b
	dep_v2_hash := blake3.hash(transmute([]u8)string("dep v2"))
	steps_dep_changed.convert_inputs.hashed_built_files = {{path = "build/modules/dep.module", hash = dep_v2_hash}}
	testing.expect(t, !module_cache_restore_entries(cache_dir, steps_dep_changed, table_b, outputs_b), "changed import hash misses shared cache")

	// Adding a sibling source file in the package folder misses cleanly.
	_ = os.write_entire_file(fmt.tprintf("%s/src/app/extra.odin", wt_b), "package app\nhelper :: proc() {}\n")
	table_b2 := input_file_table_make(wt_b, {"src"})
	defer input_file_table_destroy(table_b2)
	table_b2.started = time.time_add(time.now(), time.Hour)
	testing.expect(t, !module_cache_restore_entries(cache_dir, steps_b, table_b2, outputs_b), "new file in package folder invalidates shared cache")

	// Store a second manifest under the same base_key (simulating a second
	// branch that imports extra.odin), then verify BOTH branches hit cleanly.
	_ = os.write_entire_file(fmt.tprintf("%s/build/modules/app.module", wt_b), "MODUS_MODULE_BYTES_V2")
	_ = os.write_entire_file(fmt.tprintf("%s/build/modules/app/sources.list", wt_b), "src/app/extra.odin\nsrc/app/main.odin\n")
	_ = os.write_entire_file(fmt.tprintf("%s/build/modules/app/reached_facts.list", wt_b), "")
	_ = os.write_entire_file(fmt.tprintf("%s/build/modules/app.debug", wt_b), "MODUS_DEBUG_BYTES_V2")
	src_b2 := []string{fmt.tprintf("%s/src/app/main.odin", wt_b), fmt.tprintf("%s/src/app/extra.odin", wt_b)}
	testing.expect(t, module_cache_store_entries(cache_dir, steps_b, table_b2, outputs_b, src_b2, nil), "second branch stores alongside first")

	// Remove wt_a's output and verify wt_a (branch 1) still hits V1 while wt_b (branch 2) hits V2.
	_ = os.remove(fmt.tprintf("%s/build/modules/app.module", wt_a))
	testing.expect(t, module_cache_restore_entries(cache_dir, steps_a, table_a, outputs_a), "branch 1 still hits V1 after branch 2 stored")
	branch1_mod, _ := os.read_entire_file(fmt.tprintf("%s/build/modules/app.module", wt_a), context.temp_allocator)
	testing.expect_value(t, string(branch1_mod), "MODUS_MODULE_BYTES_V1")

	_ = os.remove(fmt.tprintf("%s/build/modules/app.module", wt_b))
	testing.expect(t, module_cache_restore_entries(cache_dir, steps_b, table_b2, outputs_b), "branch 2 hits V2")
	branch2_mod, _ := os.read_entire_file(fmt.tprintf("%s/build/modules/app.module", wt_b), context.temp_allocator)
	testing.expect_value(t, string(branch2_mod), "MODUS_MODULE_BYTES_V2")
}

// Corrupted cached blobs, truncated records, and malformed manifests are
// refused as cache misses and never corrupt local outputs.
@(test)
module_cache_refuses_corrupt_entries_and_whole_builds :: proc(t: ^testing.T) {
	// Manifest parser refusals.
	for bad in ([]string{"", "wrong header\n", BUILD_CACHE_MANIFEST_FIRST_LINE + "\n", BUILD_CACHE_MANIFEST_FIRST_LINE + "\nunknown x\n", BUILD_CACHE_MANIFEST_FIRST_LINE + "\nsource \n"}) {
		_, ok := module_cache_manifest_parse(bad)
		testing.expectf(t, !ok, "malformed cache manifest `%s` is refused", bad)
	}

	base, err := os.make_directory_temp("", "module_cache_corrupt_*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(base)

	cache_dir := fmt.tprintf("%s/cache", base)
	wt := fmt.tprintf("%s/wt", base)
	_ = os.make_directory_all(fmt.tprintf("%s/src/app", wt))
	_ = os.make_directory_all(fmt.tprintf("%s/build/modules/app", wt))
	src := fmt.tprintf("%s/src/app/main.odin", wt)
	_ = os.write_entire_file(src, "package app\nmain :: proc() {}\n")
	mod_path := fmt.tprintf("%s/build/modules/app.module", wt)
	_ = os.write_entire_file(mod_path, "GOOD_MODULE")

	table := input_file_table_make(wt, {"src"})
	defer input_file_table_destroy(table)
	table.started = time.time_add(time.now(), time.Hour)

	steps := Module_Steps {
		optimization        = .None,
		compile_record_path = fmt.tprintf("%s/build/modules/app.compile%s", wt, BUILD_RECORD_SUFFIX),
		convert_record_path = fmt.tprintf("%s/build/modules/app.convert%s", wt, BUILD_RECORD_SUFFIX),
		compile_inputs      = {subject = "app", settings = {"optimization", "none"}},
		convert_inputs      = {subject = "app convert"},
	}
	outputs := []Cache_Output_Spec{{cache_name = "module.bin", local_path = mod_path}}
	testing.expect(t, module_cache_store_entries(cache_dir, steps, table, outputs, {src}, nil), "initial store succeeds")

	// Tamper with the cached blob by 1 byte.
	compile_key, _ := module_cache_compile_key(steps, table, {src}, nil)
	module_key, _ := module_cache_module_key(steps, compile_key, table)
	cached_blob := fmt.tprintf("%s/%s/%s/module.bin", cache_dir, BUILD_CACHE_ENTRIES_FOLDER, hash_as_hexadecimal(module_key))
	_ = os.write_entire_file(cached_blob, "EVIL_MODULE")

	_ = os.write_entire_file(mod_path, "LOCAL_UNTOUCHED")
	testing.expect(t, !module_cache_restore_entries(cache_dir, steps, table, outputs), "tampered cached blob is refused by BLAKE3 check")
	local_after, _ := os.read_entire_file(mod_path, context.temp_allocator)
	testing.expect_value(t, string(local_after), "LOCAL_UNTOUCHED")

	// Whole builds disable the cache even when build_cache_folder is set.
	saved_whole := build_whole
	saved_cache := build_cache_folder
	saved_inputs := build_inputs
	defer {
		build_whole = saved_whole
		build_cache_folder = saved_cache
		build_inputs = saved_inputs
	}
	build_cache_folder = cache_dir
	build_inputs = {table = table, usable = true}
	build_whole = false
	testing.expect(t, build_cache_active(), "cache is active when configured and not a whole build")
	build_whole = true
	testing.expect(t, !build_cache_active(), "whole builds always disable the shared cache")
}

// `build --cache <dir>` argument parsing accepts valid combinations and refuses
// missing paths, duplicates, and `--cache` combined with `whole`.
@(test)
build_cache_flag_parse_and_refusals :: proc(t: ^testing.T) {
	refused := [][]string {
		{BUILD_CACHE_FLAG},
		{BUILD_CACHE_FLAG, ""},
		{BUILD_CACHE_FLAG, "/tmp/a", BUILD_CACHE_FLAG, "/tmp/b"},
		{"whole", BUILD_CACHE_FLAG, "/tmp/a"},
		{BUILD_CACHE_FLAG, "/tmp/a", "whole"},
	}
	for args in refused {
		_, problem := build_arguments_parse(args)
		testing.expectf(t, problem != "", "`build %v` is refused", args)
	}

	opts, problem := build_arguments_parse([]string{BUILD_FAST_FLAG, BUILD_CACHE_FLAG, "/tmp/modus_cache", "console", "4"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, opts, Build_Command_Options{whole = false, optimization = .None, cache_folder = "/tmp/modus_cache", volume_path = BOOT_VOLUME_CONSOLE, host_processes = 4})
	testing.expect(t, !strings.contains(problem, "unknown"))
}

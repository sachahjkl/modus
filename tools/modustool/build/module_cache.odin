package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "modus:contract/blake3"
import "modustool:foundation"

// Shared content-addressed host module build cache
// (src/md/infrastructure/fast_build.md, "Shared content-addressed host module
// build cache").
//
// Opt-in via MODUS_BUILD_CACHE=<dir> or --cache <dir>. Never active during
// whole builds, `check`, `repeat`, `release`, or `ship`.
//
// Layout under <cache_dir>:
//   manifests/<base_key_hex>/<manifest_hash_hex>.manifest
//     Canonical repo-relative source and load file lists discovered by earlier
//     compilations with the same pre-compile base key (module, tool identity,
//     host programs, flags, optimization mode, assembly files).
//   entries/<module_key_hex>/
//     module.bin, sources.list, reached_facts.list, optional module.debug and
//     kernel_stack.measure, and build.record (written last via atomic rename).
//
// All writes use a unique temporary file in the destination folder followed by
// os.rename so concurrent worktrees sharing one cache never observe partial
// files. Every restore verifies the BLAKE3 hash of every cached output in
// memory before atomically writing into build/modules/, avoiding hard-link
// O_TRUNC corruption and TOCTOU races.

BUILD_CACHE_ENV :: "MODUS_BUILD_CACHE"
BUILD_CACHE_FLAG :: "--cache"

BUILD_CACHE_MANIFESTS_FOLDER :: "manifests"
BUILD_CACHE_ENTRIES_FOLDER :: "entries"
BUILD_CACHE_RECORD_FILE :: "build.record"
BUILD_CACHE_MANIFEST_FIRST_LINE :: "module cache manifest, form 1"

// Active shared module cache folder for this process, or "" when disabled.
// Owned on the heap via build_cache_folder_set so temporary allocator resets
// never invalidate it.
build_cache_folder: string

// build_cache_folder_set records folder in heap memory (or clears it when
// folder is "") so callers never leave a context.temp_allocator slice in the
// package global.
build_cache_folder_set :: proc(folder: string) {
	delete(build_cache_folder)
	if folder == "" {
		build_cache_folder = ""
		return
	}
	build_cache_folder = strings.clone(folder)
}

@(private = "file")
cache_temp_sequence: u64

// One artifact stored in a module cache entry and its local build path.
Cache_Output_Spec :: struct {
	cache_name: string,
	local_path: string,
}

// One candidate compiler dependency list (canonical repo-relative paths for
// repository files; absolute paths for external store files).
Cache_Manifest :: struct {
	source_files: []string,
	load_files:   []string,
}

// build_cache_resolve picks the shared cache directory: an explicit CLI
// `--cache <dir>` takes precedence over MODUS_BUILD_CACHE.
build_cache_resolve :: proc(cli_folder: string) -> string {
	if cli_folder != "" {
		return cli_folder
	}
	return os.get_env(BUILD_CACHE_ENV, context.temp_allocator)
}

// build_cache_active says whether the shared host module cache can be read and
// written in this build. Whole builds (check, repeat, release, `build whole`)
// always disable the cache.
build_cache_active :: proc() -> bool {
	return !build_whole && build_cache_folder != "" && build_inputs.table != nil && build_inputs.usable
}

// atomic_write_file writes data to a unique temp file in the same folder as
// path and atomically renames it into place. On any failure, the temp file is
// removed and the destination is untouched.
atomic_write_file :: proc(path: string, data: []u8) -> bool {
	folder := folder_of_path(path)
	if folder != "" && folder != "." {
		if !foundation.make_folder(folder) {
			return false
		}
	}
	seq := sync.atomic_add(&cache_temp_sequence, 1) + 1
	tmp_path := fmt.tprintf("%s.tmp.%d.%d", path, os.get_pid(), seq)
	if err := os.write_entire_file(tmp_path, data); err != nil {
		_ = os.remove(tmp_path)
		return false
	}
	if err := os.rename(tmp_path, path); err != nil {
		_ = os.remove(tmp_path)
		return false
	}
	return true
}

// canonical_paths_of normalizes a list of compiler-reported paths relative to
// table_root, sorted and deduplicated in temporary memory.
canonical_paths_of :: proc(table_root: string, paths: []string) -> []string {
	if len(paths) == 0 {
		return nil
	}
	normalized := make([dynamic]string, 0, len(paths), context.temp_allocator)
	for path in paths {
		append(&normalized, canonical_key_path(table_root, path))
	}
	slice.sort(normalized[:])
	deduped := make([dynamic]string, 0, len(normalized), context.temp_allocator)
	for path, index in normalized {
		if index == 0 || normalized[index - 1] != path {
			append(&deduped, path)
		}
	}
	return deduped[:]
}

// module_cache_manifest_text encodes one manifest of canonical source and load
// paths, one per line.
module_cache_manifest_text :: proc(source_files, load_files: []string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, "%s\n", BUILD_CACHE_MANIFEST_FIRST_LINE)
	for path in source_files {
		fmt.sbprintf(&builder, "source %s\n", path)
	}
	for path in load_files {
		fmt.sbprintf(&builder, "load %s\n", path)
	}
	return strings.to_string(builder)
}

// module_cache_manifest_parse decodes a cache manifest. Any unknown line or
// empty source list makes the manifest invalid.
module_cache_manifest_parse :: proc(text: string) -> (manifest: Cache_Manifest, ok: bool) {
	sources := make([dynamic]string, context.temp_allocator)
	loads := make([dynamic]string, context.temp_allocator)
	rest := text
	line_number := 0
	for line in strings.split_lines_iterator(&rest) {
		line_number += 1
		if line_number == 1 {
			if line != BUILD_CACHE_MANIFEST_FIRST_LINE {
				return {}, false
			}
			continue
		}
		switch {
		case line == "":
		case strings.has_prefix(line, "source ") && len(line) > len("source "):
			append(&sources, line[len("source "):])
		case strings.has_prefix(line, "load ") && len(line) > len("load "):
			append(&loads, line[len("load "):])
		case:
			return {}, false
		}
	}
	if len(sources) == 0 {
		return {}, false
	}
	return {source_files = sources[:], load_files = loads[:]}, true
}

// module_cache_base_key hashes the pre-compile inputs of a module (without
// compiler-discovered source/load files) using canonical repo-relative paths.
module_cache_base_key :: proc(steps: Module_Steps, table: ^Input_File_Table) -> (key: blake3.Hash, ok: bool) {
	inputs := steps.compile_inputs
	inputs.source_files = nil
	inputs.load_files = nil
	return build_key(inputs, table, inputs_must_be_unchanged = false, canonical_paths = true)
}

// module_cache_compile_key hashes the full compile inputs of a module (with
// source/load files and package folder listings) using canonical repo-relative
// paths so identical checkouts at different worktree paths hash identically.
module_cache_compile_key :: proc(steps: Module_Steps, table: ^Input_File_Table, source_files, load_files: []string, inputs_must_be_unchanged := false) -> (key: blake3.Hash, ok: bool) {
	inputs := steps.compile_inputs
	inputs.source_files = source_files
	inputs.load_files = load_files
	return build_key(inputs, table, inputs_must_be_unchanged = inputs_must_be_unchanged, canonical_paths = true)
}

// module_cache_module_key hashes the combined compile key and conversion
// inputs (imports, children, debug setting, optimization mode, start grants,
// tool identity) using canonical repo-relative paths. Because conversion
// outputs are deterministic functions of these inputs, this key uniquely
// identifies the finished module artifacts without needing linked.elf.
module_cache_module_key :: proc(steps: Module_Steps, compile_key: blake3.Hash, table: ^Input_File_Table, inputs_must_be_unchanged := false) -> (key: blake3.Hash, ok: bool) {
	inputs := steps.convert_inputs
	settings := make([dynamic]string, context.temp_allocator)
	append(&settings, ..inputs.settings)
	append(&settings, "optimization", optimization_mode_argument(steps.optimization))
	append(&settings, "the canonical compile key", hash_as_hexadecimal(compile_key))
	inputs.settings = settings[:]
	inputs.source_files = nil
	inputs.load_files = nil
	return build_key(inputs, table, inputs_must_be_unchanged = inputs_must_be_unchanged, canonical_paths = true)
}

// module_cache_outputs lists the host-path-free outputs stored in a shared cache
// entry for one module. linked.elf is intentionally omitted because its DWARF
// DW_AT_comp_dir holds the originating worktree path.
module_cache_outputs :: proc(build: foundation.Module_Build) -> []Cache_Output_Spec {
	list := make([dynamic]Cache_Output_Spec, context.temp_allocator)
	append(&list, Cache_Output_Spec{cache_name = "module.bin", local_path = foundation.module_path(build.name)})
	append(&list, Cache_Output_Spec{cache_name = "sources.list", local_path = module_source_list_file(build.name)})
	append(&list, Cache_Output_Spec{cache_name = "reached_facts.list", local_path = module_reached_facts_file(build.name)})
	if debug_information {
		append(&list, Cache_Output_Spec{cache_name = "module.debug", local_path = debug_object_path(build.name)})
	}
	if build.kernel {
		append(&list, Cache_Output_Spec{cache_name = "kernel_stack.measure", local_path = kernel_stack_measure_file(build.name)})
	}
	return list[:]
}

// module_cache_store_entries writes a verified module artifact set and its
// manifest into cache_dir using atomic temp+rename writes. Returns false without
// polluting cache_dir if any input changed during the build or any output
// cannot be read.
module_cache_store_entries :: proc(cache_dir: string, steps: Module_Steps, table: ^Input_File_Table, outputs: []Cache_Output_Spec, source_files, load_files: []string) -> bool {
	if cache_dir == "" || table == nil || len(outputs) == 0 || len(source_files) == 0 {
		return false
	}
	canonical_sources := canonical_paths_of(table.root, source_files)
	canonical_loads := canonical_paths_of(table.root, load_files)
	if len(canonical_sources) == 0 {
		return false
	}
	base_key, base_ok := module_cache_base_key(steps, table)
	if !base_ok {
		return false
	}
	compile_key, compile_ok := module_cache_compile_key(steps, table, canonical_sources, canonical_loads, inputs_must_be_unchanged = true)
	if !compile_ok {
		return false
	}
	module_key, module_ok := module_cache_module_key(steps, compile_key, table, inputs_must_be_unchanged = true)
	if !module_ok {
		return false
	}

	entry_dir := foundation.join(cache_dir, "/", BUILD_CACHE_ENTRIES_FOLDER, "/", hash_as_hexadecimal(module_key))
	if !foundation.make_folder(entry_dir) {
		return false
	}

	record_outputs := make([]Record_Output, len(outputs), context.temp_allocator)
	for spec, index in outputs {
		data, read_err := os.read_entire_file(spec.local_path, context.temp_allocator)
		if read_err != nil {
			return false
		}
		record_outputs[index] = {
			path = spec.cache_name,
			hash = blake3.hash(data),
		}
		target := foundation.join(entry_dir, "/", spec.cache_name)
		if !atomic_write_file(target, data) {
			return false
		}
	}

	record := Build_Record {
		optimization = steps.optimization,
		key          = module_key,
		outputs      = record_outputs,
		source_files = canonical_sources,
		load_files   = canonical_loads,
	}
	record_path := foundation.join(entry_dir, "/", BUILD_CACHE_RECORD_FILE)
	record_text := build_record_text(record)
	if !atomic_write_file(record_path, transmute([]u8)record_text) {
		return false
	}

	manifest_text := module_cache_manifest_text(canonical_sources, canonical_loads)
	manifest_hash := blake3.hash(transmute([]u8)manifest_text)
	manifest_dir := foundation.join(cache_dir, "/", BUILD_CACHE_MANIFESTS_FOLDER, "/", hash_as_hexadecimal(base_key))
	manifest_path := foundation.join(manifest_dir, "/", hash_as_hexadecimal(manifest_hash), ".manifest")
	return atomic_write_file(manifest_path, transmute([]u8)manifest_text)
}

@(private = "file")
cache_candidate_manifests :: proc(cache_dir: string, steps: Module_Steps, base_key: blake3.Hash, table: ^Input_File_Table) -> []Cache_Manifest {
	candidates := make([dynamic]Cache_Manifest, context.temp_allocator)
	if local_record, ok := build_record_read(steps.compile_record_path); ok {
		canonical_sources := canonical_paths_of(table.root, local_record.source_files)
		canonical_loads := canonical_paths_of(table.root, local_record.load_files)
		if len(canonical_sources) > 0 {
			append(&candidates, Cache_Manifest{source_files = canonical_sources, load_files = canonical_loads})
		}
	}
	manifest_dir := foundation.join(cache_dir, "/", BUILD_CACHE_MANIFESTS_FOLDER, "/", hash_as_hexadecimal(base_key))
	entries, err := os.read_all_directory_by_path(manifest_dir, context.temp_allocator)
	if err != nil {
		return candidates[:]
	}
	names := make([dynamic]string, 0, len(entries), context.temp_allocator)
	for entry in entries {
		if entry.type == .Regular && strings.has_suffix(entry.name, ".manifest") && !strings.contains(entry.name, ".tmp.") {
			append(&names, entry.name)
		}
	}
	slice.sort(names[:])
	for name in names {
		bytes, read_err := os.read_entire_file(foundation.join(manifest_dir, "/", name), context.temp_allocator)
		if read_err != nil {
			continue
		}
		if manifest, parsed := module_cache_manifest_parse(string(bytes)); parsed {
			append(&candidates, manifest)
		}
	}
	return candidates[:]
}

// module_cache_restore_entries looks up a cached module entry in cache_dir,
// verifies the optimization mode, build key, and BLAKE3 hash of every output
// file in memory, and atomically writes the verified bytes into the local
// build paths. Any missing, malformed, or hash-mismatched cache entry is
// treated as a cache miss (returns false, leaves local files intact).
module_cache_restore_entries :: proc(cache_dir: string, steps: Module_Steps, table: ^Input_File_Table, outputs: []Cache_Output_Spec) -> bool {
	if cache_dir == "" || table == nil || len(outputs) == 0 {
		return false
	}
	base_key, base_ok := module_cache_base_key(steps, table)
	if !base_ok {
		return false
	}
	candidates := cache_candidate_manifests(cache_dir, steps, base_key, table)
	if len(candidates) == 0 {
		return false
	}

	required_names := make([]string, len(outputs), context.temp_allocator)
	for spec, index in outputs {
		required_names[index] = spec.cache_name
	}

	for candidate in candidates {
		compile_key, compile_ok := module_cache_compile_key(steps, table, candidate.source_files, candidate.load_files)
		if !compile_ok {
			continue
		}
		module_key, module_ok := module_cache_module_key(steps, compile_key, table)
		if !module_ok {
			continue
		}
		entry_dir := foundation.join(cache_dir, "/", BUILD_CACHE_ENTRIES_FOLDER, "/", hash_as_hexadecimal(module_key))
		record, has_record := build_record_read(foundation.join(entry_dir, "/", BUILD_CACHE_RECORD_FILE))
		if !has_record || record.optimization != steps.optimization || record.key != module_key {
			continue
		}
		if !record_names_each_output(record, required_names) {
			continue
		}

		// Read and verify every cached blob in memory before touching local
		// build outputs, eliminating TOCTOU races and partial restores.
		verified_blobs := make([][]u8, len(outputs), context.temp_allocator)
		expected_hashes := make([]blake3.Hash, len(outputs), context.temp_allocator)
		all_valid := true
		for spec, index in outputs {
			expected: blake3.Hash
			found := false
			for rec_out in record.outputs {
				if rec_out.path == spec.cache_name {
					expected = rec_out.hash
					found = true
					break
				}
			}
			if !found {
				all_valid = false
				break
			}
			data, read_err := os.read_entire_file(foundation.join(entry_dir, "/", spec.cache_name), context.temp_allocator)
			if read_err != nil || blake3.hash(data) != expected {
				all_valid = false
				break
			}
			verified_blobs[index] = data
			expected_hashes[index] = expected
		}
		if !all_valid {
			continue
		}

		// Remove stale local records so a later run without --cache never
		// confuses restored outputs with a previous local compilation.
		_ = os.remove(steps.compile_record_path)
		_ = os.remove(steps.convert_record_path)

		restored_all := true
		for spec, index in outputs {
			existing := file_content_read(spec.local_path)
			if existing.readable && existing.hash == expected_hashes[index] {
				continue
			}
			if !atomic_write_file(spec.local_path, verified_blobs[index]) {
				restored_all = false
				break
			}
		}
		if restored_all {
			return true
		}
	}
	return false
}

// module_cache_restore attempts to restore build's finished outputs from
// build_cache_folder into the local build folder.
module_cache_restore :: proc(build: foundation.Module_Build) -> bool {
	if !build_cache_active() {
		return false
	}
	steps, ok := module_steps_of(build)
	if !ok {
		return false
	}
	return module_cache_restore_entries(build_cache_folder, steps, build_inputs.table, module_cache_outputs(build))
}

// module_cache_store publishes build's finished outputs to build_cache_folder
// after module_records_write proved its inputs were unchanged.
module_cache_store :: proc(build: foundation.Module_Build, step: Module_Step) -> bool {
	if !build_cache_active() {
		return false
	}
	steps, ok := module_steps_of(build)
	if !ok {
		return false
	}
	source_files, load_files: []string
	listed := false
	if step == .Built {
		source_files, load_files, listed = dependency_list_read(module_dependency_file(build.name))
	} else {
		compile_record: Build_Record
		compile_record, listed = build_record_read(module_compile_record_path(build.name))
		source_files, load_files = compile_record.source_files, compile_record.load_files
	}
	if !listed {
		return false
	}
	return module_cache_store_entries(build_cache_folder, steps, build_inputs.table, module_cache_outputs(build), source_files, load_files)
}

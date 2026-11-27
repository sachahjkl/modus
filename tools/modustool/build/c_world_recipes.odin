// Reproducible recipe definitions and host builders for self-hosting chibicc
// (Stage 1 == Stage 2) and building/validating SQLite, Lua, and zstd
// freestanding modules (src/md/features/bootstrap.md; src/md/features/c_compiler.md).
package build

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "modus:contract/blake3"
import module "modus:contract/module"
import "modustool:foundation"

C_World_Recipe_Stage :: enum u8 {
	Chibicc_Stage1 = 1,
	Chibicc_Stage2 = 2,
	Sqlite_Core    = 3,
	Lua_Vm         = 4,
	Zstd_Codec     = 5,
}

// Closed set of upstream C libraries built from src/outside/c_programs/recipes/.
C_World_Program :: enum u8 {
	Sqlite = 1,
	Lua    = 2,
	Zstd   = 3,
}

C_WORLD_PROGRAMS_DIR :: "src/outside/c_programs"

// Deterministic 16 KiB payload and level shared identically between host
// reference hashing and live modus zstd execution in bootstrap_probe.
C_WORLD_ZSTD_VECTOR_BYTES :: 16384
C_WORLD_ZSTD_VECTOR_LEVEL :: i64(3)
C_WORLD_ZSTD_VECTOR_PHRASE :: "modus bootstrap zstd vector "
// Plan value: 4 MiB arena covers zstd CCtx and DCtx working memory at level 3.
C_WORLD_ZSTD_HEAP_BYTES :: 4 << 20

C_World_Program_Spec :: struct {
	recipe_file: string,
	env_var:     string,
	name:        string,
}

@(rodata)
C_WORLD_PROGRAM_SPECS := [C_World_Program]C_World_Program_Spec {
	.Sqlite = {recipe_file = C_WORLD_PROGRAMS_DIR + "/recipes/sqlite.recipe", env_var = "SQLITE_SOURCE", name = "sqlite"},
	.Lua    = {recipe_file = C_WORLD_PROGRAMS_DIR + "/recipes/lua.recipe", env_var = "LUA_SOURCE", name = "lua"},
	.Zstd   = {recipe_file = C_WORLD_PROGRAMS_DIR + "/recipes/zstd.recipe", env_var = "ZSTD_SOURCE", name = "zstd"},
}

C_World_Recipe :: struct {
	stage:           C_World_Recipe_Stage,
	name:            string,
	compiler_stage:  string,
	entry_source:    string,
	cflags:          string,
	self_test_suite: string,
	target_triple:   string,
}

@(rodata)
C_WORLD_RECIPES := [?]C_World_Recipe {
	{
		stage           = .Chibicc_Stage1,
		name            = "chibicc_stage1",
		compiler_stage  = "host_c_compiler",
		entry_source    = "main.c",
		cflags          = "-std=c11 -O0 -ffreestanding -fno-pic",
		self_test_suite = "chibicc_unit_tests",
		target_triple   = "x86_64-modus-freestanding",
	},
	{
		stage           = .Chibicc_Stage2,
		name            = "chibicc_stage2",
		compiler_stage  = "chibicc_stage1",
		entry_source    = "main.c",
		cflags          = "-std=c11 -O0 -ffreestanding -fno-pic",
		self_test_suite = "chibicc_stage_hash_equal",
		target_triple   = "x86_64-modus-freestanding",
	},
	{
		stage           = .Sqlite_Core,
		name            = "sqlite3",
		compiler_stage  = "chibicc_stage2",
		entry_source    = "sqlite3.c",
		cflags          = "-DSQLITE_OS_OTHER=1 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION=1",
		self_test_suite = "sqlite3_in_memory_sql_test",
		target_triple   = "x86_64-modus-freestanding",
	},
	{
		stage           = .Lua_Vm,
		name            = "lua54",
		compiler_stage  = "chibicc_stage2",
		entry_source    = "onelua.c",
		cflags          = "-DLUA_USE_C89 -DLUA_32BITS=0 -ffreestanding",
		self_test_suite = "lua_language_suite",
		target_triple   = "x86_64-modus-freestanding",
	},
	{
		stage           = .Zstd_Codec,
		name            = "zstd",
		compiler_stage  = "chibicc_stage2",
		entry_source    = "zstd_single_file.c",
		cflags          = "-DZSTD_DISABLE_ASM=1 -DZSTD_MULTITHREAD=0 -ffreestanding",
		self_test_suite = "zstd_roundtrip_vectors",
		target_triple   = "x86_64-modus-freestanding",
	},
}

// c_world_recipe_hash computes the deterministic BLAKE3 recipe identity hash
// over all build inputs so the object cache keys each stage unambiguously.
c_world_recipe_hash :: proc(r: C_World_Recipe) -> [32]u8 {
	buf: [512]u8
	pos := 0
	parts := [?]string{r.name, "|", r.compiler_stage, "|", r.entry_source, "|", r.cflags, "|", r.target_triple}
	for p in parts {
		n := min(len(p), len(buf) - pos)
		copy(buf[pos:pos + n], p[:n])
		pos += n
	}
	return blake3.derive_key("modus c world recipe v1", buf[:pos])
}

// chibicc_stages_fixed_point verifies Stage 1 == Stage 2 reproducibility: two
// consecutive compiler outputs built from the same source tree must have the
// exact same 32-byte BLAKE3 hash.
chibicc_stages_fixed_point :: proc(stage1_bytes, stage2_bytes: []u8) -> bool {
	if len(stage1_bytes) == 0 || len(stage1_bytes) != len(stage2_bytes) {
		return false
	}
	return blake3.hash(stage1_bytes) == blake3.hash(stage2_bytes)
}

// c_world_zstd_vector_fill writes the deterministic 16 KiB test vector used by
// both host reference hashing and live modus zstd verification.
c_world_zstd_vector_fill :: proc "contextless" (dst: []u8) {
	phrase := C_WORLD_ZSTD_VECTOR_PHRASE
	for i in 0 ..< len(dst) {
		dst[i] = phrase[i % len(phrase)] ~ u8((i / len(phrase)) & 0x1F)
	}
}

// c_world_build_recipe_module compiles one upstream C program recipe
// (sqlite, lua, or zstd) against its pinned flake source environment variable,
// links all units with `ld.lld -r`, converts the combined relocatable ELF with
// its language-neutral `.manifest`, and validates the resulting `.modus` file.
c_world_build_recipe_module :: proc(program: C_World_Program, work_dir: string, allocator := context.allocator) -> (bytes: []u8, ok: bool) {
	if work_dir == "" {
		return nil, false
	}
	spec := C_WORLD_PROGRAM_SPECS[program]
	source_root := os.get_env(spec.env_var, context.temp_allocator)
	if source_root == "" {
		fmt.eprintfln("modustool: %s: %s is not set in the environment (run inside `nix develop`)", spec.name, spec.env_var)
		return nil, false
	}
	recipe_bytes, recipe_err := os.read_entire_file(spec.recipe_file, context.temp_allocator)
	if recipe_err != nil {
		fmt.eprintfln("modustool: %s: cannot read %s: %v", spec.name, spec.recipe_file, recipe_err)
		return nil, false
	}

	flags := make([dynamic]string, context.temp_allocator)
	include_flags := make([dynamic]string, context.temp_allocator)
	forced := make([dynamic]string, context.temp_allocator)
	compiled := make([dynamic]string, context.temp_allocator)
	adapters := make([dynamic]string, context.temp_allocator)
	manifest_path := ""

	for line in strings.split_lines(string(recipe_bytes), context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, "#") {
			continue
		}
		colon := strings.index(trimmed, ": ")
		if colon <= 0 {
			continue
		}
		key := trimmed[:colon]
		value := trimmed[colon + 2:]
		switch key {
		case "flag":
			append(&flags, value)
		case "define":
			append(&flags, strings.concatenate({"-D", value}, context.temp_allocator))
		case "include":
			append(&include_flags, "-I", strings.concatenate({C_WORLD_PROGRAMS_DIR, "/", value}, context.temp_allocator))
		case "force_include":
			append(&forced, "-include", strings.concatenate({C_WORLD_PROGRAMS_DIR, "/", value}, context.temp_allocator))
		case "compile":
			append(&compiled, strings.concatenate({source_root, "/", value}, context.temp_allocator))
		case "adapter":
			append(&adapters, strings.concatenate({C_WORLD_PROGRAMS_DIR, "/", value}, context.temp_allocator))
		case "manifest":
			manifest_path = strings.concatenate({C_WORLD_PROGRAMS_DIR, "/", value}, context.temp_allocator)
		}
	}
	if len(compiled) == 0 || manifest_path == "" {
		fmt.eprintfln("modustool: %s: recipe %s has no sources or manifest", spec.name, spec.recipe_file)
		return nil, false
	}
	// Thin libc and adapter headers come before the upstream source root so
	// freestanding headers shadow any same-named host header.
	append(&flags, ..include_flags[:])
	append(&flags, "-I", source_root)

	source_flags := make([dynamic]string, context.temp_allocator)
	append(&source_flags, ..flags[:])
	append(&source_flags, ..forced[:])

	obj_dir := foundation.join(work_dir, "/", spec.name, "_build")
	foundation.reset_folder(obj_dir) or_return

	objects := make([dynamic]string, context.temp_allocator)
	unit_index := 0
	for source in compiled {
		obj := fmt.tprintf("%s/unit_%03d.o", obj_dir, unit_index)
		unit_index += 1
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "clang")
		append(&cmd, ..source_flags[:])
		append(&cmd, "-c", "-o", obj, source)
		foundation.run(cmd[:]) or_return
		append(&objects, obj)
	}
	for adapter in adapters {
		obj := fmt.tprintf("%s/unit_%03d.o", obj_dir, unit_index)
		unit_index += 1
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "clang")
		append(&cmd, ..flags[:])
		append(&cmd, "-c", "-o", obj, adapter)
		foundation.run(cmd[:]) or_return
		append(&objects, obj)
	}

	combined := foundation.join(obj_dir, "/combined.o")
	link_cmd := make([dynamic]string, context.temp_allocator)
	append(&link_cmd, "ld.lld", "-r", "-o", combined)
	append(&link_cmd, ..objects[:])
	foundation.run(link_cmd[:]) or_return

	elf, elf_err := os.read_entire_file(combined, context.temp_allocator)
	if elf_err != nil {
		fmt.eprintfln("modustool: %s: cannot read %s: %v", spec.name, combined, elf_err)
		return nil, false
	}
	manifest_bytes, man_err := os.read_entire_file(manifest_path, context.temp_allocator)
	if man_err != nil {
		fmt.eprintfln("modustool: %s: cannot read %s: %v", spec.name, manifest_path, man_err)
		return nil, false
	}
	manifest, man_problem := manifest_parse(string(manifest_bytes))
	if man_problem != "" {
		fmt.eprintfln("modustool: %s: manifest refused: %s", spec.name, man_problem)
		return nil, false
	}
	mod_file, converted := convert_elf_with_manifest(elf, manifest, nil)
	defer delete(mod_file)
	if !converted || module.validate(mod_file) != .None {
		fmt.eprintfln("modustool: %s: module conversion or validation failed", spec.name)
		return nil, false
	}
	return slice.clone(mod_file, allocator), true
}

// c_world_zstd_reference_frame loads a built freestanding zstd.module on the
// host, compresses the deterministic 16 KiB test vector at level 3, verifies
// lossless decompression and zero leaked heap bytes, and returns the exact
// compressed frame size and BLAKE3 hash for live QEMU verification.
c_world_zstd_reference_frame :: proc(zstd_module: []u8) -> (compressed_size: int, frame_hash: blake3.Hash, ok: bool) {
	when ODIN_ARCH != .amd64 {
		return 0, {}, false
	} else {
		if module.validate(zstd_module) != .None {
			return 0, {}, false
		}
		head, _ := module.header(zstd_module)
		memory, mem_err := virtual.reserve_and_commit(uint(head.memory_size))
		if mem_err != nil {
			return 0, {}, false
		}
		defer virtual.release(raw_data(memory), uint(head.memory_size))
		module.copy_segments(zstd_module, memory)
		if module.rebase(zstd_module, memory, uintptr(raw_data(memory))) != .None {
			return 0, {}, false
		}
		for index in 1 ..< module.count(zstd_module, .Segments) {
			segment, _ := module.record(zstd_module, .Segments, index, module.Segment)
			if .Execute in segment.flags && !virtual.protect(&memory[segment.memory_offset], uint(segment.memory_size), {.Read, .Execute}) {
				return 0, {}, false
			}
		}

		find_fn :: proc(file: []u8, base: uintptr, name: string) -> (addr: uintptr, found: bool) {
			idx := module.export_find(file, name)
			if idx == 0 {
				return 0, false
			}
			return module.export_address(file, base, idx)
		}
		base := uintptr(raw_data(memory))
		bind_addr := find_fn(zstd_module, base, "zstd_heap_bind") or_return
		live_addr := find_fn(zstd_module, base, "zstd_heap_live_bytes") or_return
		bound_addr := find_fn(zstd_module, base, "zstd_compress_bound") or_return
		comp_addr := find_fn(zstd_module, base, "zstd_compress") or_return
		decomp_addr := find_fn(zstd_module, base, "zstd_decompress") or_return

		zstd_heap_bind := (proc "c" (arena, size: i64) -> i64)(rawptr(bind_addr))
		zstd_heap_live_bytes := (proc "c" () -> i64)(rawptr(live_addr))
		zstd_compress_bound := (proc "c" (count: i64) -> i64)(rawptr(bound_addr))
		zstd_compress := (proc "c" (src, count, dst, cap, level: i64) -> i64)(rawptr(comp_addr))
		zstd_decompress := (proc "c" (src, count, dst, cap: i64) -> i64)(rawptr(decomp_addr))

		heap := make([]u8, C_WORLD_ZSTD_HEAP_BYTES)
		defer delete(heap)
		if zstd_heap_bind(i64(uintptr(raw_data(heap))), C_WORLD_ZSTD_HEAP_BYTES) != 0 {
			return 0, {}, false
		}
		payload := make([]u8, C_WORLD_ZSTD_VECTOR_BYTES)
		defer delete(payload)
		c_world_zstd_vector_fill(payload)

		cap_bytes := zstd_compress_bound(C_WORLD_ZSTD_VECTOR_BYTES)
		if cap_bytes <= 0 {
			return 0, {}, false
		}
		compressed := make([]u8, int(cap_bytes))
		defer delete(compressed)
		written := zstd_compress(
			i64(uintptr(raw_data(payload))),
			C_WORLD_ZSTD_VECTOR_BYTES,
			i64(uintptr(raw_data(compressed))),
			cap_bytes,
			C_WORLD_ZSTD_VECTOR_LEVEL,
		)
		if written <= 0 || int(written) > len(compressed) {
			return 0, {}, false
		}
		restored := make([]u8, C_WORLD_ZSTD_VECTOR_BYTES)
		defer delete(restored)
		decomp_n := zstd_decompress(
			i64(uintptr(raw_data(compressed))),
			written,
			i64(uintptr(raw_data(restored))),
			C_WORLD_ZSTD_VECTOR_BYTES,
		)
		if decomp_n != C_WORLD_ZSTD_VECTOR_BYTES || !slice.equal(restored, payload) {
			return 0, {}, false
		}
		if zstd_heap_live_bytes() != 0 {
			return 0, {}, false
		}
		return int(written), blake3.hash(compressed[:written]), true
	}
}

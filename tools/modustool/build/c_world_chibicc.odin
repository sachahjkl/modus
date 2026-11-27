// Compile upstream C library recipes (Lua 5.4.7, zstd 1.5.7, SQLite 3.54.1)
// using chibicc itself (Stage 1 self-hosted or Stage 0) and the modus native
// x86-64 assembler instead of host clang (src/md/features/bootstrap.md;
// src/md/features/c_compiler.md).
package build

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "internal:assemble/assembler"
import "modus:contract/blake3"
import module "modus:contract/module"
import writer "modus:contract/module_file_writer"

// Computed: virtual reservation for one chibicc compilation of a large unit
// such as sqlite3.c (9 MiB amalgamation). Linux commits pages on first write.
C_WORLD_CHIBICC_ARENA_BYTES :: 1 << 30

// Assembly support unit providing setjmp, longjmp, and sqrtsd for C programs
// compiled by chibicc (which lacks GCC inline assembly constraints).
C_WORLD_THIN_LIBC_CHIBICC_ASM :: C_WORLD_PROGRAMS_DIR + "/thin_libc/modus_thin_libc_chibicc.s"

// Report produced when compiling an upstream C library with chibicc.
C_World_Chibicc_Build_Report :: struct {
	program:         C_World_Program,
	unit_count:      int,
	assembly_bytes:  int,
	module_size:     int,
	module_hash:     blake3.Hash,
	failing_unit:    string,
	diagnostic:      string,
}

// Headers supplied directly by chibicc's built-in `include/` table so its
// compiler-specific `va_list`, `offsetof`, and float macros remain active.
@(private = "file")
c_world_is_chibicc_builtin_header :: proc(basename: string) -> bool {
	switch basename {
	case "float.h", "stdalign.h", "stdarg.h", "stdatomic.h", "stdbool.h", "stddef.h", "stdnoreturn.h":
		return true
	}
	return false
}

// Recursively collect all `.h` files under current_dir and register them under
// logical_prefix/<relpath> in the header table.
@(private = "file")
c_world_collect_headers_recursive :: proc(
	current_dir: string,
	rel_dir: string,
	logical_prefixes: []string,
	skip_chibicc_builtins: bool,
	headers: ^[dynamic]C_Readable_File,
	seen: ^map[string]bool,
	allocator := context.temp_allocator,
) -> bool {
	entries, err := os.read_all_directory_by_path(current_dir, allocator)
	if err != nil {
		return false
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {
		return a.name < b.name
	})
	for entry in entries {
		rel := rel_dir == "" ? entry.name : strings.concatenate({rel_dir, "/", entry.name}, allocator)
		if entry.type == .Directory {
			c_world_collect_headers_recursive(entry.fullpath, rel, logical_prefixes, skip_chibicc_builtins, headers, seen, allocator) or_return
			continue
		}
		if !strings.has_suffix(entry.name, ".h") {
			continue
		}
		if skip_chibicc_builtins && c_world_is_chibicc_builtin_header(entry.name) {
			continue
		}
		bytes, read_err := os.read_entire_file(entry.fullpath, allocator)
		if read_err != nil {
			return false
		}
		for prefix in logical_prefixes {
			logical := prefix == "" ? rel : strings.concatenate({prefix, "/", rel}, allocator)
			if seen[logical] {
				continue
			}
			seen[logical] = true
			append(headers, C_Readable_File{
				name  = strings.clone_to_cstring(logical, allocator),
				bytes = raw_data(bytes),
				size  = u64(len(bytes)),
			})
		}
	}
	return true
}

// Format a recipe `define:` value (`NAME` or `NAME=VALUE`) into a C `#define` line.
@(private = "file")
c_world_format_define_line :: proc(b: ^strings.Builder, define_value: string) {
	eq := strings.index_byte(define_value, '=')
	if eq < 0 {
		fmt.sbprintf(b, "#define %s 1\n", define_value)
	} else {
		fmt.sbprintf(b, "#define %s %s\n", define_value[:eq], define_value[eq + 1:])
	}
}

// Run one chibicc stage module on a single C unit with a large on-demand arena
// and non-NULL empty export list so all non-static functions emit `global`
// labels and manifest binding can attach full typed metadata.
@(private = "file")
c_world_chibicc_compile_unit :: proc(
	stage_compiler: []u8,
	headers: []C_Readable_File,
	source: C_Program_File,
	allocator := context.allocator,
) -> (text: []u8, diagnostic: string, ok: bool) {
	when ODIN_ARCH != .amd64 {
		return nil, "chibicc compilation runs on x86-64 hosts only", false
	} else {
		if problem := module.validate(stage_compiler); problem != .None {
			return nil, fmt.tprintf("compiler stage module is invalid: %v", problem), false
		}
		head, _ := module.header(stage_compiler)
		memory, mem_err := virtual.reserve_and_commit(uint(head.memory_size))
		if mem_err != nil {
			return nil, "cannot allocate memory for chibicc stage", false
		}
		defer virtual.release(raw_data(memory), uint(head.memory_size))
		module.copy_segments(stage_compiler, memory)
		if module.rebase(stage_compiler, memory, uintptr(raw_data(memory))) != .None {
			return nil, "cannot rebase chibicc stage", false
		}
		for index in 1 ..< module.count(stage_compiler, .Segments) {
			segment, _ := module.record(stage_compiler, .Segments, index, module.Segment)
			if .Execute in segment.flags && !virtual.protect(&memory[segment.memory_offset], uint(segment.memory_size), {.Read, .Execute}) {
				return nil, "cannot mark chibicc stage code executable", false
			}
		}
		export_index := module.export_find(stage_compiler, C_SELF_HOST_EXPORT)
		address, found := module.export_address(stage_compiler, uintptr(raw_data(memory)), export_index)
		if !found {
			return nil, "compiler stage module lacks " + C_SELF_HOST_EXPORT, false
		}

		arena_memory, arena_err := virtual.reserve_and_commit(C_WORLD_CHIBICC_ARENA_BYTES)
		if arena_err != nil {
			return nil, "cannot reserve arena for chibicc unit", false
		}
		defer virtual.release(raw_data(arena_memory), C_WORLD_CHIBICC_ARENA_BYTES)

		arena := C_Arena{memory = arena_memory}
		diagnostic_bytes: [C_SELF_HOST_DIAGNOSTIC_BYTES]u8
		// Non-NULL export_names with count 0 tells compile.c to emit `global`
		// labels for all external functions without enforcing integer-only
		// inline `export` directives; manifest binding defines the exports.
		empty_export_sentinel: [1]cstring = {""}
		call := C_Compile_Call{
			source                  = raw_data(source.bytes),
			source_size             = u64(len(source.bytes)),
			memory_provider         = c_arena_provide,
			memory_provider_context = &arena,
			diagnostic              = &diagnostic_bytes[0],
			diagnostic_capacity     = C_SELF_HOST_DIAGNOSTIC_BYTES,
			source_name             = strings.clone_to_cstring(source.name, context.temp_allocator),
			program_files           = raw_data(headers),
			program_file_count      = u64(len(headers)),
			export_names            = &empty_export_sentinel[0],
			export_name_count       = 0,
			error_offset            = -1,
		}
		entry := (proc "c" (record_address: i64) -> i64)(rawptr(address))
		word := entry(i64(uintptr(&call)))
		switch word {
		case i64(C_Compile_Result.Done):
			text = make([]u8, int(call.text_size), allocator)
			copy(text, call.text[:call.text_size])
			return text, "", true
		case i64(C_Compile_Result.Refused):
			return nil, strings.clone(string(diagnostic_bytes[:min(call.diagnostic_size, C_SELF_HOST_DIAGNOSTIC_BYTES)]), context.temp_allocator), false
		}
		return nil, fmt.tprintf("chibicc returned unknown status word %d", word), false
	}
}

// Assemble a multi-unit AT&T assembly program with dynamic workspace scaling
// and bind its global code symbols to a parsed Module_Manifest via
// module_parts_finalize.
c_world_assemble_with_manifest :: proc(
	name: string,
	assembly_text: string,
	manifest: Module_Manifest,
	allocator := context.allocator,
) -> (file: []u8, diagnostic: string, ok: bool) {
	if len(assembly_text) == 0 {
		return nil, "assembly text is empty", false
	}
	scale := assembler.workspace_scale_of_text(u64(len(assembly_text)))
	for {
		bounds := assembler.workspace_bounds_of_scale(scale)
		ws_bytes := assembler.workspace_bytes(bounds)
		ws_mem, mem_err := virtual.reserve_and_commit(uint(ws_bytes))
		if mem_err != nil {
			return nil, fmt.tprintf("cannot allocate assembler workspace (scale %d, %d bytes)", scale, ws_bytes), false
		}
		workspace, carved := assembler.workspace_carve(ws_mem, bounds)
		if !carved {
			virtual.release(raw_data(ws_mem), uint(ws_bytes))
			return nil, "cannot carve assembler workspace", false
		}
		parts, refusal := assembler.assemble(assembly_text, &workspace)
		next_scale, grow := assembler.workspace_scale_after(refusal, scale)
		if grow {
			virtual.release(raw_data(ws_mem), uint(ws_bytes))
			scale = next_scale
			continue
		}
		defer virtual.release(raw_data(ws_mem), uint(ws_bytes))
		if refusal.refusal != .None {
			line_start := int(refusal.place.offset) - int(refusal.place.column) + 1
			if line_start < 0 {
				line_start = 0
			}
			line_end := line_start
			for line_end < len(assembly_text) && assembly_text[line_end] != '\n' {
				line_end += 1
			}
			return nil, fmt.tprintf(
				"assembler refused line %d, col %d (%v, %s, val %d): %s",
				refusal.place.line,
				refusal.place.column,
				refusal.refusal,
				assembler.refusal_sentence(refusal.refusal),
				refusal.value,
				assembly_text[line_start:line_end],
			), false
		}

		// Build a map of defined global labels from the assembled workspace.
		global_code := make(map[string]u64, 256, context.temp_allocator)
		global_data := make(map[string]u64, 64, context.temp_allocator)
		data_base := len(parts.segments) > 1 ? parts.segments[1].memory_offset : u64(0)
		for i in 0 ..< workspace.label_count {
			lbl := workspace.labels[i]
			if !lbl.global || !lbl.defined {
				continue
			}
			switch lbl.section {
			case .Code:
				global_code[lbl.name] = lbl.offset
			case .Data:
				global_data[lbl.name] = data_base + lbl.offset
			}
		}

		export_parts := make([]writer.Export_Part, len(manifest.description.exports), context.temp_allocator)
		for exp, idx in manifest.description.exports {
			code_offset, found := global_code[exp.name]
			if !found {
				return nil, fmt.tprintf("manifest export %q was not defined as a global code symbol", exp.name), false
			}
			export_parts[idx] = export_part_from_description(exp, code_offset)
		}

		images := make([]Segment_Image, len(parts.segments), context.temp_allocator)
		memory_size := u64(0)
		for seg, idx in parts.segments {
			images[idx] = Segment_Image{
				record = module.Segment{
					memory_offset = seg.memory_offset,
					memory_size   = seg.memory_size,
					flags         = seg.flags,
				},
				data = seg.data,
			}
			end := seg.memory_offset + seg.memory_size
			if end > memory_size {
				memory_size = end
			}
		}

		rebases := make([]u64, len(parts.rebases), context.temp_allocator)
		copy(rebases, parts.rebases)

		own_hash_place, has_own_hash := global_data[module.OWN_HASH_PLACE_SYMBOL]
		built, finalized := module_parts_finalize(
			name,
			images,
			memory_size,
			manifest.description,
			export_parts,
			nil,
			nil,
			rebases,
			own_hash_place,
			has_own_hash,
			nil,
			nil,
		)
		if !finalized {
			return nil, fmt.tprintf("module_parts_finalize refused assembled %s", name), false
		}
		defer delete(built)
		if val_err := module.validate(built); val_err != .None {
			return nil, fmt.tprintf("assembled %s failed module.validate: %v", name, val_err), false
		}
		return slice.clone(built, allocator), "", true
	}
}

// c_world_build_recipe_with_chibicc compiles one upstream C library recipe
// (Lua 5.4.7, zstd 1.5.7, or SQLite 3.54.1) using the given chibicc stage
// module (e.g. Stage 1 self-hosted chibicc) and the modus native x86-64
// assembler, returning a validated freestanding `.modus` module with its full
// manifest description and zero host clang or ld.lld invocation.
c_world_build_recipe_with_chibicc :: proc(
	stage_compiler: []u8,
	program: C_World_Program,
	allocator := context.allocator,
) -> (mod_bytes: []u8, report: C_World_Chibicc_Build_Report, ok: bool) {
	report.program = program
	spec := C_WORLD_PROGRAM_SPECS[program]
	source_root := os.get_env(spec.env_var, context.temp_allocator)
	if source_root == "" {
		report.diagnostic = fmt.tprintf("%s is not set in the environment", spec.env_var)
		return nil, report, false
	}
	recipe_bytes, recipe_err := os.read_entire_file(spec.recipe_file, context.temp_allocator)
	if recipe_err != nil {
		report.diagnostic = fmt.tprintf("cannot read %s: %v", spec.recipe_file, recipe_err)
		return nil, report, false
	}

	defines := make([dynamic]string, context.temp_allocator)
	include_dirs := make([dynamic]string, context.temp_allocator)
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
		case "define":
			append(&defines, value)
		case "include":
			append(&include_dirs, value)
		case "force_include":
			append(&forced, value)
		case "compile":
			append(&compiled, value)
		case "adapter":
			append(&adapters, value)
		case "manifest":
			manifest_path = strings.concatenate({C_WORLD_PROGRAMS_DIR, "/", value}, context.temp_allocator)
		}
	}
	if len(compiled) == 0 || manifest_path == "" {
		report.diagnostic = fmt.tprintf("recipe %s has no sources or manifest", spec.recipe_file)
		return nil, report, false
	}

	manifest_bytes, man_err := os.read_entire_file(manifest_path, context.temp_allocator)
	if man_err != nil {
		report.diagnostic = fmt.tprintf("cannot read manifest %s: %v", manifest_path, man_err)
		return nil, report, false
	}
	manifest, man_problem := manifest_parse(string(manifest_bytes))
	if man_problem != "" {
		report.diagnostic = fmt.tprintf("manifest refused: %s", man_problem)
		return nil, report, false
	}

	// Build the in-memory header table for chibicc.
	headers := make([dynamic]C_Readable_File, context.temp_allocator)
	seen := make(map[string]bool, 256, context.temp_allocator)

	// 1. Recipe `include:` folders first (thin_libc/include, thin_libc, program adapters).
	for rel_dir in include_dirs {
		full_dir := strings.concatenate({C_WORLD_PROGRAMS_DIR, "/", rel_dir}, context.temp_allocator)
		is_libc_include := rel_dir == "thin_libc/include"
		prefixes: []string
		if rel_dir == "thin_libc/include" {
			prefixes = {"libc/include"}
		} else if rel_dir == "thin_libc" {
			// Register under both `libc/` (for `../modus_thin_libc.h` from
			// `libc/include/*.h`) and `libc/include/` (for `#include "modus_thin_libc.h"`).
			prefixes = {"libc", "libc/include", "thin_libc"}
		} else {
			prefixes = {"libc/include", rel_dir}
		}
		if !c_world_collect_headers_recursive(full_dir, "", prefixes, is_libc_include, &headers, &seen) {
			report.diagnostic = fmt.tprintf("cannot collect headers from %s", full_dir)
			return nil, report, false
		}
	}

	// 2. Upstream source tree headers under `<program>/<relpath>` and `libc/include/<relpath>`.
	if !c_world_collect_headers_recursive(source_root, "", {spec.name, "libc/include"}, false, &headers, &seen) {
		report.diagnostic = fmt.tprintf("cannot collect headers from %s", source_root)
		return nil, report, false
	}

	// Build shared define prologue and forced-include prologue.
	define_builder := strings.builder_make(context.temp_allocator)
	for def in defines {
		c_world_format_define_line(&define_builder, def)
	}
	define_prologue := strings.to_string(define_builder)

	source_prologue_builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&source_prologue_builder, define_prologue)
	for inc in forced {
		// Forced headers live in C_WORLD_PROGRAMS_DIR/<inc> and were added to libc/include.
		slash := strings.last_index_byte(inc, '/')
		inc_name := slash >= 0 ? inc[slash + 1:] : inc
		fmt.sbprintf(&source_prologue_builder, "#include %q\n", inc_name)
	}
	source_prologue := strings.to_string(source_prologue_builder)

	joined := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&joined)

	// Compile every upstream C translation unit with chibicc.
	for rel_src in compiled {
		full_path := strings.concatenate({source_root, "/", rel_src}, context.temp_allocator)
		raw_bytes, read_err := os.read_entire_file(full_path, context.temp_allocator)
		if read_err != nil {
			report.failing_unit = rel_src
			report.diagnostic = fmt.tprintf("cannot read source %s: %v", full_path, read_err)
			return nil, report, false
		}
		logical_name := strings.concatenate({spec.name, "/", rel_src}, context.temp_allocator)
		unit_bytes := raw_bytes
		if len(source_prologue) > 0 {
			combined := make([]u8, len(source_prologue) + len(raw_bytes), context.temp_allocator)
			copy(combined, source_prologue)
			copy(combined[len(source_prologue):], raw_bytes)
			unit_bytes = combined
		}
		asm_text, diag, compiled_ok := c_world_chibicc_compile_unit(stage_compiler, headers[:], {name = logical_name, bytes = unit_bytes}, context.temp_allocator)
		if !compiled_ok {
			report.failing_unit = logical_name
			report.diagnostic = diag
			return nil, report, false
		}
		strings.write_bytes(&joined, asm_text)
		report.unit_count += 1
	}

	// Compile every adapter C translation unit with chibicc.
	for rel_adapter in adapters {
		full_path := strings.concatenate({C_WORLD_PROGRAMS_DIR, "/", rel_adapter}, context.temp_allocator)
		raw_bytes, read_err := os.read_entire_file(full_path, context.temp_allocator)
		if read_err != nil {
			report.failing_unit = rel_adapter
			report.diagnostic = fmt.tprintf("cannot read adapter %s: %v", full_path, read_err)
			return nil, report, false
		}
		unit_bytes := raw_bytes
		if len(define_prologue) > 0 {
			combined := make([]u8, len(define_prologue) + len(raw_bytes), context.temp_allocator)
			copy(combined, define_prologue)
			copy(combined[len(define_prologue):], raw_bytes)
			unit_bytes = combined
		}
		asm_text, diag, compiled_ok := c_world_chibicc_compile_unit(stage_compiler, headers[:], {name = rel_adapter, bytes = unit_bytes}, context.temp_allocator)
		if !compiled_ok {
			report.failing_unit = rel_adapter
			report.diagnostic = diag
			return nil, report, false
		}
		strings.write_bytes(&joined, asm_text)
		report.unit_count += 1
	}

	// Append the thin_libc assembly unit (setjmp, longjmp, sqrt).
	asm_support, asm_read_err := os.read_entire_file(C_WORLD_THIN_LIBC_CHIBICC_ASM, context.temp_allocator)
	if asm_read_err != nil {
		report.failing_unit = C_WORLD_THIN_LIBC_CHIBICC_ASM
		report.diagnostic = fmt.tprintf("cannot read %s: %v", C_WORLD_THIN_LIBC_CHIBICC_ASM, asm_read_err)
		return nil, report, false
	}
	strings.write_bytes(&joined, asm_support)

	full_asm := strings.to_string(joined)
	report.assembly_bytes = len(full_asm)

	assembled, asm_diag, asm_ok := c_world_assemble_with_manifest(spec.name, full_asm, manifest, allocator)
	if !asm_ok {
		report.failing_unit = "assemble"
		report.diagnostic = asm_diag
		return nil, report, false
	}
	report.module_size = len(assembled)
	report.module_hash = blake3.hash(assembled)
	return assembled, report, true
}

// The self-hosting of the C compiler (src/md/features/bootstrap.md, "The
// self-hosting of the C compiler"; docs/TOOLS.md, "The self-hosting of the
// C compiler"). chibicc built by clang, stage 0, compiles each C source of
// chibicc into a unit of assembly; the units and the units of assembly of
// the program are one text, which the assembler of modus turns into the
// module of stage 1. Stage 1 compiles the same sources, and its text gives
// the module of stage 2. The check is the equality of the BLAKE3 hashes of
// the two modules.
//
// Each stage is a module file that the tool loads on the host: a copy of
// its segments in fresh memory for each source, because chibicc keeps its
// state in static variables, then a call of its export with the record of
// compile.c. The C part calls no procedure of the host: it reads its files
// from the table of the record, and takes its memory from the arena of the
// tool through the procedure of the record.
package build

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "internal:assemble/assembler"
import "modus:contract/blake3"
import module "modus:contract/module"
import writer "modus:contract/module_file_writer"
import "modustool:foundation"

C_SELF_HOST_FOLDER :: foundation.BUILD_FOLDER + "/c_self_host"
C_SELF_HOST_USAGE :: "modustool: c-self-host [--libraries]"

// The export of the compiler in each stage: compile_record_at of compile.c,
// which takes the address of the record of the call.
C_SELF_HOST_EXPORT :: "compile_record_at"
// The folders of the names of the table of files. A quoted include of a
// source names a file of its folder, and chibicc searches its include path
// for the headers of the thin libc.
C_SELF_HOST_SOURCE_FOLDER :: "chibicc"
C_SELF_HOST_HEADER_FOLDER :: "libc/include"
// The folder of the outside source that holds the units which chibicc
// compiles in when it builds itself: C sources, and texts of assembly.
C_SELF_HOST_UNIT_FOLDER :: "self_host"

// The arena of one compile. chibicc never frees: the largest source, parse.c,
// takes 13 MiB (one measure). The host gives a page at its first write only.
C_SELF_HOST_ARENA_BYTES :: 256 << 20
C_SELF_HOST_DIAGNOSTIC_BYTES :: 4096

// The workspace of the assembler for the whole program. chibicc gives 295
// KiB of code, 52 KiB of data, 6928 labels, 8505 operands that name a label
// and 246 rebases (one measure); each bound is four times or more.
C_SELF_HOST_CODE_BYTES :: 2 << 20
C_SELF_HOST_DATA_BYTES :: 1 << 20
C_SELF_HOST_LABELS :: 64 * 1024
C_SELF_HOST_REFERENCES :: 128 * 1024
C_SELF_HOST_REBASES :: 16 * 1024
C_SELF_HOST_EXPORTS :: 1024

// The record Readable_File of thin_libc.h.
C_Readable_File :: struct {
	name:  cstring,
	bytes: [^]u8,
	size:  u64,
}

// The record Compile_Call of compile.c, with the same fields in the same
// order, each of 8 bytes (src/modules/system/c_compiler/c_compiler.odin has
// the same record).
C_Compile_Call :: struct {
	source:                  [^]u8,
	source_size:             u64,
	memory_provider:         proc "c" (provider_context: rawptr, size: u64, alignment: u64) -> rawptr,
	memory_provider_context: rawptr,
	diagnostic:              [^]u8,
	diagnostic_capacity:     u64,
	source_name:             cstring,
	program_files:           [^]C_Readable_File,
	program_file_count:      u64,
	export_names:            [^]cstring,
	export_name_count:       u64,
	text:                    [^]u8,
	text_size:               u64,
	error_offset:            i64,
	diagnostic_size:         u64,
}
#assert(size_of(C_Compile_Call) == 15 * 8)

// What the C entry gives: the values of compile.c.
C_Compile_Result :: enum i64 {
	Done    = 0, // The text is in the record.
	Refused = 1, // chibicc ended through exit: the diagnostic says why.
}

// A file of the program: its name in the table, and its bytes.
C_Program_File :: struct {
	name:  string,
	bytes: []u8,
}

// The program of chibicc as it builds itself: the C sources in the order of
// their names, the texts of assembly after them, the headers of the table,
// and the exports of the module.
C_Program :: struct {
	sources:      []C_Program_File,
	assembly:     []C_Program_File,
	headers:      []C_Readable_File,
	export_names: []cstring,
}

// A stage of the chain.
C_Stage :: enum u8 {
	Zero = 0, // chibicc built by clang, from the module pipeline of the tool.
	One  = 1, // chibicc built by stage 0 and the assembler of modus.
	Two  = 2, // chibicc built by stage 1 and the assembler of modus.
}

// What the check found.
C_Self_Host_Report :: struct {
	sources:                 []string, // The names of the C sources that each stage compiled.
	assembly:                []string, // The names of the texts of assembly of the program.
	stage_one_hash:          blake3.Hash,
	stage_two_hash:          blake3.Hash,
	stage_one_size:          int,
	stage_two_size:          int,
	texts_equal:             bool, // Stage 1 gave the text of stage 0 for each source.
	first_text_difference:   string, // The first source whose two texts differ, or "".
	text_difference_offset:  int,
	first_module_difference: int, // The first byte where the two modules differ; -1: none.
	fixed_point:             bool, // blake3(stage 1) == blake3(stage 2).
}

// The arena of one compile: the Memory_Provider of the thin libc pushes on it.
@(private)
C_Arena :: struct {
	memory: []u8,
	used:   u64,
}

@(private)
c_arena_provide :: proc "c" (provider_context: rawptr, size: u64, alignment: u64) -> rawptr {
	arena := (^C_Arena)(provider_context)
	if alignment == 0 || alignment & (alignment - 1) != 0 {
		return nil
	}
	start := (arena.used + alignment - 1) & ~(alignment - 1)
	if start < arena.used || start > u64(len(arena.memory)) || size > u64(len(arena.memory)) - start {
		return nil
	}
	arena.used = start + size
	return &arena.memory[start]
}

// c_self_host_program reads the program of chibicc from the folder of its
// outside source: each C file at its top and in the folder of the units of
// the self-hosting, each text of assembly of that folder, and each header
// at its top and in the folder of the thin libc.
c_self_host_program :: proc(folder: string) -> (program: C_Program, ok: bool) {
	unit_folder := foundation.join(folder, "/", C_SELF_HOST_UNIT_FOLDER)
	sources := make([dynamic]C_Program_File, context.temp_allocator)
	for path in foundation.files_with_suffix(folder, ".c") or_return {
		append(&sources, C_Program_File{name = foundation.join(C_SELF_HOST_SOURCE_FOLDER, "/", path[len(folder) + 1:]), bytes = foundation.read_file(path) or_return})
	}
	for path in foundation.files_with_suffix(unit_folder, ".c") or_return {
		append(&sources, C_Program_File{name = foundation.join(C_SELF_HOST_SOURCE_FOLDER, "/", path[len(folder) + 1:]), bytes = foundation.read_file(path) or_return})
	}
	assembly := make([dynamic]C_Program_File, context.temp_allocator)
	for path in foundation.files_with_suffix(unit_folder, ".s") or_return {
		append(&assembly, C_Program_File{name = foundation.join(C_SELF_HOST_SOURCE_FOLDER, "/", path[len(folder) + 1:]), bytes = foundation.read_file(path) or_return})
	}
	headers := make([dynamic]C_Readable_File, context.temp_allocator)
	header_add :: proc(headers: ^[dynamic]C_Readable_File, name: string, path: string) -> bool {
		bytes := foundation.read_file(path) or_return
		append(headers, C_Readable_File{name = strings.clone_to_cstring(name, context.temp_allocator), bytes = raw_data(bytes), size = u64(len(bytes))})
		return true
	}
	for path in foundation.files_with_suffix(folder, ".h") or_return {
		header_add(&headers, foundation.join(C_SELF_HOST_SOURCE_FOLDER, "/", path[len(folder) + 1:]), path) or_return
	}
	header_folder := foundation.join(folder, "/", C_SELF_HOST_HEADER_FOLDER)
	for path in foundation.files_with_suffix(header_folder, ".h") or_return {
		header_add(&headers, foundation.join(C_SELF_HOST_HEADER_FOLDER, "/", path[len(header_folder) + 1:]), path) or_return
	}
	if len(sources) == 0 || len(assembly) == 0 {
		fmt.eprintfln("modustool: c-self-host: the folder %s has no C source or no text of assembly in %s", folder, C_SELF_HOST_UNIT_FOLDER)
		return {}, false
	}
	export_names := make([]cstring, 1, context.temp_allocator)
	export_names[0] = C_SELF_HOST_EXPORT
	return {sources = sources[:], assembly = assembly[:], headers = headers[:], export_names = export_names}, true
}

// c_self_host_stage_zero builds stage 0: the C files of chibicc with the
// flags of a module, the copies and the fills of the runtime, linked and
// converted by the pipeline of a module, with the one export of compile.c.
c_self_host_stage_zero :: proc(work_folder: string) -> (file: []u8, ok: bool) {
	folder := foundation.join(work_folder, "/stage_zero")
	objects := foundation.join(folder, "/objects")
	foundation.reset_folder(objects) or_return
	commands := outside_source_c_commands(foundation.CHIBICC, "c-self-host", objects) or_return
	for command in commands {
		foundation.run(command) or_return
	}
	foundation.run({"nasm", "-f", "elf64", "-o", foundation.join(objects, "/memory.asm.o"), RUNTIME_MEMORY}) or_return
	linked := foundation.join(folder, "/linked.elf")
	module_objects_link(folder, objects, {C_SELF_HOST_EXPORT}, linked) or_return
	elf := foundation.read_file(linked) or_return
	parameters := []module.Type{.Integer}
	names := []string{"record_address"}
	exports := []Export_Description {
		{
			name       = C_SELF_HOST_EXPORT,
			parameters = parameters,
			names      = names,
			result     = .Integer,
			about      = "Compiles the source of a record of compile.c, and gives 0 or 1.",
			text       = "Compiles the source of a record of compile.c, and gives 0 or 1.",
		},
	}
	description := Module_Description {
		about   = "chibicc built by clang: stage 0 of the self-hosting of the C compiler.",
		text    = "chibicc built by clang: stage 0 of the self-hosting of the C compiler.",
		exports = exports,
	}
	return convert("chibicc_stage_zero", elf, description, nil)
}

// c_stage_compile runs a stage on one source: a fresh copy of the module,
// rebased at its place, then a call of its export. ok is false when the
// module does not load or the stage refuses the source; diagnostic then
// holds the words of chibicc.
c_stage_compile :: proc(stage: []u8, program: C_Program, source: C_Program_File, allocator := context.allocator) -> (text: []u8, diagnostic: string, ok: bool) {
	when ODIN_ARCH != .amd64 {
		return nil, "a stage runs on an x86-64 host only", false
	} else {
		if problem := module.validate(stage); problem != .None {
			return nil, fmt.tprintf("the module of the stage is not valid: %v", problem), false
		}
		head, _ := module.header(stage)
		memory, memory_error := virtual.reserve_and_commit(uint(head.memory_size))
		if memory_error != nil {
			return nil, "the host gave no memory for the module", false
		}
		defer virtual.release(raw_data(memory), uint(head.memory_size))
		module.copy_segments(stage, memory)
		if module.rebase(stage, memory, uintptr(raw_data(memory))) != .None {
			return nil, "the rebase of the module failed", false
		}
		for index in 1 ..< module.count(stage, .Segments) {
			segment, _ := module.record(stage, .Segments, index, module.Segment)
			if .Execute in segment.flags && !virtual.protect(&memory[segment.memory_offset], uint(segment.memory_size), {.Read, .Execute}) {
				return nil, "the host refused to make the code executable", false
			}
		}
		export_index := module.export_find(stage, C_SELF_HOST_EXPORT)
		address, found := module.export_address(stage, uintptr(raw_data(memory)), export_index)
		if !found {
			return nil, "the module has no export " + C_SELF_HOST_EXPORT, false
		}

		arena_memory, arena_error := virtual.reserve_and_commit(C_SELF_HOST_ARENA_BYTES)
		if arena_error != nil {
			return nil, "the host gave no memory for the arena", false
		}
		defer virtual.release(raw_data(arena_memory), C_SELF_HOST_ARENA_BYTES)
		arena := C_Arena{memory = arena_memory}
		diagnostic_bytes: [C_SELF_HOST_DIAGNOSTIC_BYTES]u8
		call := C_Compile_Call {
			source                  = raw_data(source.bytes),
			source_size             = u64(len(source.bytes)),
			memory_provider         = c_arena_provide,
			memory_provider_context = &arena,
			diagnostic              = &diagnostic_bytes[0],
			diagnostic_capacity     = C_SELF_HOST_DIAGNOSTIC_BYTES,
			source_name             = strings.clone_to_cstring(source.name, context.temp_allocator),
			program_files           = raw_data(program.headers),
			program_file_count      = u64(len(program.headers)),
			export_names            = raw_data(program.export_names),
			export_name_count       = u64(len(program.export_names)),
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
		return nil, fmt.tprintf("the stage gave the word %d, which names no result", word), false
	}
}

// c_program_assemble joins the texts of the sources and the texts of
// assembly of the program into one text, each a unit, and gives the module
// file that the assembler of modus writes for it.
c_program_assemble :: proc(texts: [][]u8, program: C_Program, allocator := context.allocator) -> (file: []u8, ok: bool) {
	joined := strings.builder_make(context.temp_allocator)
	for text in texts {
		strings.write_bytes(&joined, text)
	}
	for unit in program.assembly {
		strings.write_bytes(&joined, unit.bytes)
	}
	text := strings.to_string(joined)

	code := make([]u8, C_SELF_HOST_CODE_BYTES)
	defer delete(code)
	data := make([]u8, C_SELF_HOST_DATA_BYTES)
	defer delete(data)
	labels := make([]assembler.Label, C_SELF_HOST_LABELS)
	defer delete(labels)
	label_slots := make([]assembler.Label_Slot, C_SELF_HOST_LABELS * assembler.LABEL_SLOTS_PER_LABEL)
	defer delete(label_slots)
	references := make([]assembler.Reference, C_SELF_HOST_REFERENCES)
	defer delete(references)
	data_references := make([]assembler.Data_Reference, C_SELF_HOST_REBASES)
	defer delete(data_references)
	rebases := make([]u64, C_SELF_HOST_REBASES)
	defer delete(rebases)
	exports := make([]assembler.Export_Declaration, C_SELF_HOST_EXPORTS)
	defer delete(exports)
	export_parts := make([]writer.Export_Part, C_SELF_HOST_EXPORTS)
	defer delete(export_parts)
	workspace := assembler.workspace_make(code, data, labels, label_slots, references, data_references, rebases, exports, export_parts)

	parts, refusal := assembler.assemble(text, &workspace)
	if refusal.refusal != .None {
		line_start := int(refusal.place.offset) - int(refusal.place.column) + 1
		line_end := line_start
		for line_end < len(text) && text[line_end] != '\n' {
			line_end += 1
		}
		fmt.eprintfln("modustool: c-self-host: the assembler refused line %d, column %d: %s (%v, value %d): %s", refusal.place.line, refusal.place.column, assembler.refusal_sentence(refusal.refusal), refusal.refusal, refusal.value, text[line_start:line_end])
		return nil, false
	}
	size, needed := writer.file_size_needed(parts)
	if needed.refusal != .None {
		fmt.eprintfln("modustool: c-self-host: the module file writer refused the parts: %v", needed)
		return nil, false
	}
	file = make([]u8, int(size), allocator)
	written, written_refusal := writer.write(parts, file)
	if written_refusal.refusal != .None || written != size {
		fmt.eprintfln("modustool: c-self-host: the module file writer refused the file: %v", written_refusal)
		delete(file, allocator)
		return nil, false
	}
	return file, true
}

// c_stage_build runs a stage on each source of the program, writes each
// text into the folder, and gives the texts.
c_stage_build :: proc(stage: []u8, stage_name: C_Stage, program: C_Program, folder: string) -> (texts: [][]u8, ok: bool) {
	foundation.reset_folder(folder) or_return
	list := make([][]u8, len(program.sources), context.temp_allocator)
	for source, index in program.sources {
		text, diagnostic, compiled := c_stage_compile(stage, program, source, context.temp_allocator)
		if !compiled {
			fmt.eprintfln("modustool: c-self-host: stage %d refused %s: %s", u8(stage_name), source.name, diagnostic)
			return nil, false
		}
		list[index] = text
		path := foundation.join(folder, "/", strings.trim_suffix(source.name[strings.last_index(source.name, "/") + 1:], ".c"), ".s")
		if err := os.write_entire_file(path, text); err != nil {
			fmt.eprintfln("modustool: c-self-host: cannot write %s: %v", path, err)
			return nil, false
		}
	}
	return list, true
}

// c_self_host runs the chain in the work folder, and gives what it found.
// ok is false when a step fails: a build, a refusal of a stage or of the
// assembler. A report with ok and no fixed point is a difference of bytes.
c_self_host :: proc(work_folder: string) -> (report: C_Self_Host_Report, ok: bool) {
	source_folder := c_source_folder(foundation.CHIBICC, "c-self-host") or_return
	program := c_self_host_program(source_folder) or_return
	stage_zero := c_self_host_stage_zero(work_folder) or_return
	defer delete(stage_zero)
	return c_self_host_chain(program, stage_zero, work_folder)
}

// c_self_host_chain runs stage 0 on each source, assembles stage 1, runs
// stage 1 on each source, assembles stage 2, and compares.
c_self_host_chain :: proc(program: C_Program, stage_zero: []u8, work_folder: string) -> (report: C_Self_Host_Report, ok: bool) {
	report.first_module_difference = -1
	report.sources = make([]string, len(program.sources), context.temp_allocator)
	for source, index in program.sources {
		report.sources[index] = source.name
	}
	report.assembly = make([]string, len(program.assembly), context.temp_allocator)
	for unit, index in program.assembly {
		report.assembly[index] = unit.name
	}

	texts_zero := c_stage_build(stage_zero, .Zero, program, foundation.join(work_folder, "/stage_zero/texts")) or_return
	stage_one := c_program_assemble(texts_zero, program) or_return
	defer delete(stage_one)
	texts_one := c_stage_build(stage_one, .One, program, foundation.join(work_folder, "/stage_one/texts")) or_return
	stage_two := c_program_assemble(texts_one, program) or_return
	defer delete(stage_two)
	foundation.make_folder(foundation.join(work_folder, "/stage_two")) or_return
	for item in ([?]struct {
			path: string,
			file: []u8,
		}{{foundation.join(work_folder, "/stage_one/chibicc.modus"), stage_one}, {foundation.join(work_folder, "/stage_two/chibicc.modus"), stage_two}}) {
		if err := os.write_entire_file(item.path, item.file); err != nil {
			fmt.eprintfln("modustool: c-self-host: cannot write %s: %v", item.path, err)
			return report, false
		}
	}

	report.texts_equal = true
	for index in 0 ..< len(program.sources) {
		if string(texts_zero[index]) != string(texts_one[index]) {
			report.texts_equal = false
			report.first_text_difference = program.sources[index].name
			report.text_difference_offset = first_difference(texts_zero[index], texts_one[index])
			break
		}
	}
	report.stage_one_hash = blake3.hash(stage_one)
	report.stage_two_hash = blake3.hash(stage_two)
	report.stage_one_size = len(stage_one)
	report.stage_two_size = len(stage_two)
	if string(stage_one) != string(stage_two) {
		report.first_module_difference = first_difference(stage_one, stage_two)
	}
	report.fixed_point = report.stage_one_hash == report.stage_two_hash
	return report, true
}

// first_difference gives the first offset where two byte sequences differ:
// the length of the shorter one when one is the start of the other.
@(private = "file")
first_difference :: proc(first, second: []u8) -> int {
	for index in 0 ..< min(len(first), len(second)) {
		if first[index] != second[index] {
			return index
		}
	}
	return min(len(first), len(second))
}

// c_self_host_program_pack encodes the chibicc self-hosting sources, headers,
// and assembly units into private-store objects for live QEMU execution in
// bootstrap_probe:
//   - "chibicc_manifest": lines "<kind> <object_name> <logical_name>\n"
//     where <kind> is "C" for a C source unit and "S" for an assembly unit;
//   - "chibicc_headers": program_files wire-format list of every header;
//   - "src_00".., "asm_00"..: the raw unit bytes.
c_self_host_program_pack :: proc(program: C_Program, allocator := context.temp_allocator) -> (objects: []Module_File, ok: bool) {
	if len(program.sources) == 0 || len(program.assembly) == 0 {
		return nil, false
	}
	list := make([dynamic]Module_File, allocator)
	manifest := strings.builder_make(allocator)

	for source, index in program.sources {
		obj_name := fmt.aprintf("src_%02d", index, allocator = allocator)
		fmt.sbprintf(&manifest, "C %s %s\n", obj_name, source.name)
		append(&list, Module_File{name = obj_name, bytes = source.bytes})
	}
	for unit, index in program.assembly {
		obj_name := fmt.aprintf("asm_%02d", index, allocator = allocator)
		fmt.sbprintf(&manifest, "S %s %s\n", obj_name, unit.name)
		append(&list, Module_File{name = obj_name, bytes = unit.bytes})
	}

	// Encode program.headers into the exact program_files binary list format:
	// [u32 name_len LE][u32 content_len LE][name bytes][content bytes]...
	header_total := 0
	for header in program.headers {
		name_str := string(header.name)
		header_total += 8 + len(name_str) + int(header.size)
	}
	header_buf := make([]u8, header_total, allocator)
	pos := 0
	for header in program.headers {
		name_str := string(header.name)
		name_len := u32(len(name_str))
		content_len := u32(header.size)
		header_buf[pos + 0] = u8(name_len)
		header_buf[pos + 1] = u8(name_len >> 8)
		header_buf[pos + 2] = u8(name_len >> 16)
		header_buf[pos + 3] = u8(name_len >> 24)
		header_buf[pos + 4] = u8(content_len)
		header_buf[pos + 5] = u8(content_len >> 8)
		header_buf[pos + 6] = u8(content_len >> 16)
		header_buf[pos + 7] = u8(content_len >> 24)
		pos += 8
		copy(header_buf[pos:], name_str)
		pos += len(name_str)
		if content_len > 0 {
			copy(header_buf[pos:], header.bytes[:content_len])
			pos += int(content_len)
		}
	}

	append(&list, Module_File{name = "chibicc_manifest", bytes = transmute([]u8)strings.to_string(manifest)})
	append(&list, Module_File{name = "chibicc_headers", bytes = header_buf})
	return list[:], true
}

// run_c_self_host is the command `modustool c-self-host [--libraries]`.
run_c_self_host :: proc(args: []string) -> int {
	build_libraries := false
	if len(args) == 1 && args[0] == "--libraries" {
		build_libraries = true
	} else if len(args) != 0 {
		fmt.eprintln(C_SELF_HOST_USAGE)
		return 2
	}
	report, ok := c_self_host(C_SELF_HOST_FOLDER)
	if !ok {
		return 1
	}
	fmt.printfln("c-self-host: stage 0 and stage 1 compiled each of the %d C sources; the program adds %d texts of assembly", len(report.sources), len(report.assembly))
	for name in report.sources {
		fmt.printfln("  %s", name)
	}
	for name in report.assembly {
		fmt.printfln("  %s", name)
	}
	if report.texts_equal {
		fmt.println("c-self-host: stage 1 gave the text of stage 0 for each source")
	} else {
		fmt.printfln("c-self-host: stage 1 and stage 0 gave other texts for %s, from the byte %d", report.first_text_difference, report.text_difference_offset)
	}
	fmt.printfln("c-self-host: stage 1: %d bytes, BLAKE3 %s", report.stage_one_size, hash_as_hexadecimal(report.stage_one_hash))
	fmt.printfln("c-self-host: stage 2: %d bytes, BLAKE3 %s", report.stage_two_size, hash_as_hexadecimal(report.stage_two_hash))
	if !report.fixed_point {
		fmt.printfln("c-self-host: the modules differ from the byte %d", report.first_module_difference)
		return 1
	}
	fmt.println("c-self-host: blake3(stage 1) == blake3(stage 2)")
	if build_libraries {
		stage_one_path := foundation.join(C_SELF_HOST_FOLDER, "/stage_one/chibicc.modus")
		stage_one, read_err := os.read_entire_file(stage_one_path, context.allocator)
		if read_err != nil {
			fmt.eprintfln("c-self-host: cannot read %s: %v", stage_one_path, read_err)
			return 1
		}
		defer delete(stage_one)
		for prog in ([3]C_World_Program{.Lua, .Zstd, .Sqlite}) {
			spec := C_WORLD_PROGRAM_SPECS[prog]
			mod_bytes, lib_rep, lib_ok := c_world_build_recipe_with_chibicc(stage_one, prog)
			if !lib_ok {
				fmt.eprintfln("c-self-host: chibicc failed on %s (%s): %s", spec.name, lib_rep.failing_unit, lib_rep.diagnostic)
				return 1
			}
			defer delete(mod_bytes)
			out_path := foundation.join(C_SELF_HOST_FOLDER, "/", spec.name, ".modus")
			if w_err := os.write_entire_file(out_path, mod_bytes); w_err != nil {
				fmt.eprintfln("c-self-host: cannot write %s: %v", out_path, w_err)
				return 1
			}
			fmt.printfln("c-self-host: chibicc built %s: %d units, %d bytes, BLAKE3 %s", spec.name, lib_rep.unit_count, lib_rep.module_size, hash_as_hexadecimal(lib_rep.module_hash))
		}
	}
	return 0
}

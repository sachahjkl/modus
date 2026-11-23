// The C compiler as a module: chibicc, ported. It reads a C source and
// writes a text of assembly that the module assemble takes, into memory
// that the caller lends (docs/MODULE_CONTRACT.md, "The C compiler").
//
// **What it is for.** A machine with no host compiles C. The console calls
// it in a call host, gives its text to the assembler, and isolates the
// module that the assembler wrote:
//
// ```
// > isolate("c_compiler")
// > isolate("assemble")
// > t = buffer(1)
// > n = compile("int add(int a, int b) { return a + b; }", t)
// > f = buffer(4)
// > m = assemble(bytes(t, 0, n), f)
// > isolate_memory("adder", f, m)
// > add(2, 3)
// 5
// ```
//
// The C part is not in this folder: the flake fetches chibicc at one commit
// with the patches of the system and the thin libc, and the tool links its
// objects into this module (src/md/infrastructure/outside_source.md). This
// package states the export, gives the C part an arena of the budget, and
// copies the text into the memory of the caller.
//
// The export compile_unit compiles one C source of a program of several
// sources: the source names its headers, which the caller gives as a file
// list, and the caller names the exports of the program. Each unit is the
// one source of a fresh call host: the module assemble joins the texts.
//
// It has no entry: it runs in the call host of its caller, with no grant.
// Its memory is an arena of the budget of the call host, made at each call
// and ended at its return.
package c_compiler

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/value_kinds"
import "internal:c_compiler/program_files"
import "modus:system"

// The bytes of a source that the module takes: 64 MiB, more than one
// amalgamation of SQLite (9 MB). The source is copied before the C part
// reads it: in an isolated call it is in the call region or in a memory
// object, which the caller can change during the call. The copy is in the
// arena, so a short source does not pay for the bound, and a budget that
// cannot pay a long one refuses it with its error record.
SOURCE_BYTES_MOST :: 64 * 1024 * 1024

// The bytes of an export list of compile_unit: each export, with one
// separator after it.
EXPORT_LIST_BYTES_MOST :: program_files.EXPORTS_MOST * (program_files.NAME_BYTES_MOST + 1)

// The bytes of the diagnostic of chibicc that the module keeps for its
// log. It is memory of the module, not of the arena: a diagnostic still
// has room after the budget refused the arena.
DIAGNOSTIC_BYTES :: 4096

// The result of an export that fails: the error record says why.
ERROR :: -1

// The argument numbers of `compile`, which an error record names.
ARGUMENT_SOURCE :: 1
ARGUMENT_OUTPUT :: 2

// The argument numbers of `compile_unit`.
UNIT_ARGUMENT_NAME :: 1
UNIT_ARGUMENT_SOURCE :: 2
UNIT_ARGUMENT_FILES :: 3
UNIT_ARGUMENT_EXPORTS :: 4
UNIT_ARGUMENT_OUTPUT :: 5

// The value of the Memory_Map command that holds the memory handle, from 1:
// the argument that an error record of the kernel names for it.
MEMORY_MAP_ARGUMENT_MEMORY :: 1

// The record Readable_File of thin_libc.h: a file of the table of files.
Readable_File :: struct {
	name:  cstring,
	bytes: [^]u8,
	size:  u64,
}
#assert(size_of(Readable_File) == 3 * 8)

// The record of one call of the C entry: the record Compile_Call of the
// file src/outside/chibicc/system/compile.c, with the same fields in the
// same order, each of 8 bytes, so the two layouts agree with no padding.
Compile_Call :: struct {
	// Given to the C part.
	source:                  [^]u8,
	source_size:             u64,
	memory_provider:         proc "c" (provider_context: rawptr, size: u64, alignment: u64) -> rawptr,
	memory_provider_context: rawptr,
	diagnostic:              [^]u8,
	diagnostic_capacity:     u64,
	// A unit of a program of several sources. `compile` gives one source,
	// so it leaves them zero: the source is "source.c", and each function
	// of it that is not static is an export.
	source_name:             cstring,
	program_files:           [^]Readable_File, // Each other file of the program.
	program_file_count:      u64,
	export_names:            [^]cstring, // nil: each function that is not static is an export.
	export_name_count:       u64,
	// Given back.
	text:                    [^]u8,
	text_size:               u64,
	error_offset:            i64, // The byte of the source that the diagnostic names; -1: none.
	diagnostic_size:         u64,
}
#assert(size_of(Compile_Call) == 15 * 8)

// What the C entry gives. The values are those of compile.c.
Compile_Result :: enum i32 {
	Done    = 0, // The text is in the record.
	Refused = 1, // chibicc ended through exit: the diagnostic says why.
}

foreign _ {
	// The C entry: a procedure of the C part of this module, not of an
	// import. It gives a word of Compile_Result.
	chibicc_compile :: proc "c" (call: ^Compile_Call) -> i32 ---
}

diagnostic: [DIAGNOSTIC_BYTES]u8

// chibicc keeps its state in static variables, and the module is loaded
// once in its call host: the first call that reaches the C entry is the
// only one (src/md/features/c_compiler.md, "One source for each call host").
compiler_used: bool

// The arena of the call, and the record of a push that its budget refused.
arena: system.Arena
memory_refusal: errors.Error_Record
memory_refused: bool

// The place of a Text argument: the slice record {address, count}.
@(private)
Text_Place :: struct {
	bytes: [^]u8,
	count: u64,
}
#assert(size_of(Text_Place) == size_of(string))

// What compile_unit gives beside the source: the views of its arguments in
// the memory of the caller, and their counts, each read once.
@(private)
Unit_Arguments :: struct {
	name:          ^Text_Place,
	name_count:    u64,
	files:         ^system.Bytes_To_Read,
	files_count:   u64,
	exports:       ^Text_Place,
	exports_count: u64,
}

// The argument numbers of the source and of the output of an export.
@(private)
Argument_Numbers :: struct {
	source: i64,
	output: i64,
}

// memory_provide gives the C part `size` bytes of the arena: the
// Memory_Provider of the thin libc. A refusal is kept for the error record
// of the export, and gives the C part no address, which ends its work.
@(private)
memory_provide :: proc "c" (provider_context: rawptr, size: u64, alignment: u64) -> rawptr {
	address, status := system.arena_push((^system.Arena)(provider_context), size, alignment, &memory_refusal)
	if status != .Ok {
		memory_refused = true
		return nil
	}
	return address
}

// compile_result_of_word is the border of the word that the C entry gives:
// a word that names no member is refused.
@(private)
compile_result_of_word :: proc "contextless" (word: i32) -> (result: Compile_Result, known: bool) {
	switch word {
	case i32(Compile_Result.Done):
		return .Done, true
	case i32(Compile_Result.Refused):
		return .Refused, true
	}
	return .Refused, false
}

// diagnostic_log writes the diagnostic of chibicc on the log, one line of
// the log for each line of the diagnostic.
@(private)
diagnostic_log :: proc "contextless" (size: u64) {
	text := string(diagnostic[:min(size, DIAGNOSTIC_BYTES)])
	start := 0
	for index in 0 ..= len(text) {
		if index == len(text) || text[index] == '\n' {
			// A line that passes the field is one fact for each piece.
			for piece := start; piece < index; piece += DIAGNOSTIC_PIECE_FIELD_BYTES - 1 {
				end := min(index, piece + DIAGNOSTIC_PIECE_FIELD_BYTES - 1)
				system.log_fact(.Info, Diagnostic_Line{diagnostic = value_kinds.text_field(text[piece:end], DIAGNOSTIC_PIECE_FIELD_BYTES)})
			}
			start = index + 1
		}
	}
}

// output_map maps the memory object of the text, for the time of one call.
// ok is false when the kernel refuses; then the error record holds the
// refusal, in the words of the export.
@(private)
output_map :: proc "contextless" (memory: system.Handle, argument: i64, error: ^errors.Error_Record) -> (bytes: []u8, ok: bool) {
	refusal: errors.Error_Record
	address, status := system.memory_map(memory, {.Write}, error = &refusal)
	if status != .Ok {
		if error != nil {
			// The record of the kernel names an argument of Memory_Map, and
			// the kernel operation: the caller called the export, with its
			// own arguments.
			error^ = refusal
			error.operation = 0
			error.argument = refusal.argument == MEMORY_MAP_ARGUMENT_MEMORY ? argument : 0
			if refusal.kind == i64(errors.Kind.None) {
				error^ = errors.error_make(.Refused, argument = argument, found = i64(status))
			}
		}
		return nil, false
	}
	// The map took the handle, so the kernel gives its size.
	pages, _ := system.memory_size(memory)
	return ([^]u8)(address)[:pages * system.PAGE_SIZE], true
}

// arena_refusal_give writes a refusal of the arena in the words of the
// export, and ends the arena: the call of the caller asked for no
// operation.
@(private)
arena_refusal_give :: proc "contextless" (error: ^errors.Error_Record, refusal: errors.Error_Record) -> i64 {
	system.arena_end(&arena)
	if error != nil {
		error^ = refusal
		error.operation = 0
		error.argument = 0
	}
	return ERROR
}

// program_refusal_give writes a refusal of a file list, an export list or
// a source name in the words of the export, and ends the arena.
@(private)
program_refusal_give :: proc "contextless" (error: ^errors.Error_Record, refusal: program_files.Refusal_Record, argument: i64, argument_bytes: u64) -> i64 {
	system.arena_end(&arena)
	switch refusal.refusal {
	case .None:
		return errors.fail(error, ERROR, .Refused, .None, argument, 0, 0, 0)
	case .List_Too_Long:
		return errors.fail(error, ERROR, .Too_Long, .Bytes, argument, i64(refusal.value), program_files.LIST_BYTES_MOST)
	case .Head_Cut, .Content_Cut:
		return errors.fail(error, ERROR, .Out_Of_Range, .Bytes, argument, i64(refusal.value), i64(argument_bytes))
	case .Name_Empty:
		return errors.fail(error, ERROR, .Empty, .Bytes, argument, i64(refusal.offset), program_files.NAME_BYTES_MOST)
	case .Name_Too_Long:
		return errors.fail(error, ERROR, .Too_Long, .Bytes, argument, i64(refusal.value), program_files.NAME_BYTES_MOST)
	case .Byte_Zero:
		return errors.fail(error, ERROR, .Bad_Byte, .None, argument, i64(refusal.offset), 0, 0)
	case .Name_Twice:
		return errors.fail(error, ERROR, .Exists, .None, argument, i64(refusal.offset))
	case .Too_Many_Files:
		return errors.fail(error, ERROR, .Over_Limit, .Records, argument, i64(refusal.value), program_files.FILES_MOST)
	case .Too_Many_Names:
		return errors.fail(error, ERROR, .Over_Limit, .Records, argument, i64(refusal.value), program_files.EXPORTS_MOST)
	}
	return errors.fail(error, ERROR, .Refused, .None, argument, 0, 0, 0)
}

// bytes_copy copies bytes of the caller into the arena, with `zero_after`
// more bytes of 0 after them.
@(private)
bytes_copy :: proc "contextless" (from: [^]u8, count: u64, zero_after: u64, refusal: ^errors.Error_Record) -> (copied: [^]u8, status: system.Status) {
	// The arena refuses a push of 0 bytes: an empty list is no bytes.
	if count + zero_after == 0 {
		return nil, .Ok
	}
	address: rawptr
	address, status = system.arena_push(&arena, count + zero_after, 1, refusal)
	if status != .Ok {
		return nil, status
	}
	copied = ([^]u8)(address)
	if count > 0 {
		intrinsics.mem_copy_non_overlapping(copied, from, int(count))
	}
	// A fresh page of the arena is zero, but a push can follow bytes that
	// an earlier push of the same page left.
	for index in count ..< count + zero_after {
		copied[index] = 0
	}
	return copied, .Ok
}

// unit_program_fill copies the name, the files and the exports of a unit
// into the arena, reads them at the border, and fills the fields of the
// call that name the program.
@(private)
unit_program_fill :: proc "contextless" (unit: ^Unit_Arguments, call: ^Compile_Call, error: ^errors.Error_Record) -> (ok: bool) {
	refusal: errors.Error_Record
	name_copy, name_status := bytes_copy(unit.name.bytes, unit.name_count, 1, &refusal)
	if name_status != .Ok {
		arena_refusal_give(error, refusal)
		return false
	}
	name := string(name_copy[:unit.name_count])
	if checked := program_files.name_check(name, 0); checked.refusal != .None {
		program_refusal_give(error, checked, UNIT_ARGUMENT_NAME, unit.name_count)
		return false
	}
	call.source_name = cstring(name_copy)

	list_copy, list_status := bytes_copy(unit.files.bytes, unit.files_count, 0, &refusal)
	if list_status != .Ok {
		arena_refusal_give(error, refusal)
		return false
	}
	files_address, files_status := system.arena_push(&arena, program_files.FILES_MOST * size_of(program_files.File), align_of(program_files.File), &refusal)
	if files_status != .Ok {
		arena_refusal_give(error, refusal)
		return false
	}
	files := ([^]program_files.File)(files_address)[:program_files.FILES_MOST]
	file_count, list_refusal := program_files.file_list_read(list_copy[:unit.files_count], name, files)
	if list_refusal.refusal != .None {
		program_refusal_give(error, list_refusal, UNIT_ARGUMENT_FILES, unit.files_count)
		return false
	}
	if file_count > 0 {
		table_address, table_status := system.arena_push(&arena, u64(file_count) * size_of(Readable_File), align_of(Readable_File), &refusal)
		if table_status != .Ok {
			arena_refusal_give(error, refusal)
			return false
		}
		table := ([^]Readable_File)(table_address)
		for file, index in files[:file_count] {
			// The thin libc compares a name up to its byte 0.
			file_name, file_name_status := bytes_copy(raw_data(file.name), u64(len(file.name)), 1, &refusal)
			if file_name_status != .Ok {
				arena_refusal_give(error, refusal)
				return false
			}
			table[index] = {name = cstring(file_name), bytes = raw_data(file.content), size = u64(len(file.content))}
		}
		call.program_files = table
		call.program_file_count = u64(file_count)
	}

	exports_copy, exports_status := bytes_copy(unit.exports.bytes, unit.exports_count, 0, &refusal)
	if exports_status != .Ok {
		arena_refusal_give(error, refusal)
		return false
	}
	// The views of the names are in the arena: a table of EXPORTS_MOST
	// views is too large for the stack of the call host.
	names_address, names_status := system.arena_push(&arena, program_files.EXPORTS_MOST * size_of(string), align_of(string), &refusal)
	if names_status != .Ok {
		arena_refusal_give(error, refusal)
		return false
	}
	names := ([^]string)(names_address)[:program_files.EXPORTS_MOST]
	export_count, export_refusal := program_files.export_list_read(string(exports_copy[:unit.exports_count]), names)
	if export_refusal.refusal != .None {
		program_refusal_give(error, export_refusal, UNIT_ARGUMENT_EXPORTS, unit.exports_count)
		return false
	}
	if export_count > 0 {
		pointers_address, pointers_status := system.arena_push(&arena, u64(export_count) * size_of(cstring), align_of(cstring), &refusal)
		if pointers_status != .Ok {
			arena_refusal_give(error, refusal)
			return false
		}
		pointers := ([^]cstring)(pointers_address)
		for export_name, index in names[:export_count] {
			copied, copied_status := bytes_copy(raw_data(export_name), u64(len(export_name)), 1, &refusal)
			if copied_status != .Ok {
				arena_refusal_give(error, refusal)
				return false
			}
			pointers[index] = cstring(copied)
		}
		call.export_names = pointers
		call.export_name_count = u64(export_count)
	}
	return true
}

// compile_to_output is the work of both exports. unit is nil for `compile`.
@(private)
compile_to_output :: proc "contextless" (source: ^system.Bytes_To_Read, unit: ^Unit_Arguments, output: system.Handle, numbers: Argument_Numbers, error: ^errors.Error_Record) -> i64 {
	// The count is read once: the caller can change the record during an
	// isolated call.
	count := intrinsics.volatile_load(&source.count)
	if count == 0 {
		return errors.fail(error, ERROR, .Empty, .Bytes, numbers.source, 0, SOURCE_BYTES_MOST)
	}
	if count > SOURCE_BYTES_MOST {
		return errors.fail(error, ERROR, .Too_Long, .Bytes, numbers.source, i64(count), SOURCE_BYTES_MOST)
	}

	amounts, budget_status := system.budget_read()
	if budget_status != .Ok {
		return errors.fail(error, ERROR, .Refused, .None, 0, 0, 0, i64(budget_status))
	}
	arena_refusal: errors.Error_Record
	arena_status: system.Status
	arena, arena_status = system.arena_create(system.arena_reservation_pages(amounts.pages), 0, &arena_refusal)
	if arena_status != .Ok {
		if error != nil {
			error^ = arena_refusal
			error.operation = 0
			error.argument = 0
		}
		return ERROR
	}
	source_copy, copy_status := bytes_copy(source.bytes, count, 0, &arena_refusal)
	if copy_status != .Ok {
		return arena_refusal_give(error, arena_refusal)
	}
	// chibicc reads a file up to its first byte 0: a source with one would
	// be compiled in part, with no word of it.
	for index in 0 ..< int(count) {
		if source_copy[index] == 0 {
			system.arena_end(&arena)
			return errors.fail(error, ERROR, .Bad_Byte, .None, numbers.source, i64(index), 0, 0)
		}
	}
	call := Compile_Call {
		source                  = source_copy,
		source_size             = count,
		memory_provider         = memory_provide,
		memory_provider_context = &arena,
		diagnostic              = &diagnostic[0],
		diagnostic_capacity     = DIAGNOSTIC_BYTES,
		error_offset            = -1,
	}
	if unit != nil && !unit_program_fill(unit, &call, error) {
		// unit_program_fill ended the arena and wrote the record.
		return ERROR
	}
	if compiler_used {
		system.arena_end(&arena)
		system.log_fact(.Info, Second_Source_Refused{})
		return errors.fail(error, ERROR, .Refused, .None, 0, 0, 0, 0)
	}
	compiler_used = true
	memory_refused = false

	word := chibicc_compile(&call)
	result, known := compile_result_of_word(word)
	if !known {
		system.log_fact(.Error, Entry_Word_Refused{word = i64(word)})
		system.arena_end(&arena)
		return errors.fail(error, ERROR, .Refused, .None, 0, 0, 0, i64(word))
	}
	diagnostic_log(call.diagnostic_size)

	switch result {
	case .Refused:
		// The byte that the diagnostic names is read before the arena ends:
		// the copy of the source is in the arena.
		named_byte: i64
		named := call.error_offset >= 0 && call.error_offset < i64(count)
		if named {
			named_byte = i64(source_copy[call.error_offset])
		}
		system.arena_end(&arena)
		if memory_refused {
			// The record of the refused commit, in the words of the export:
			// the call of the caller asked for no operation.
			if error != nil {
				error^ = memory_refusal
				error.operation = 0
				error.argument = 0
			}
			return ERROR
		}
		if named {
			return errors.fail(error, ERROR, .Bad_Byte, .None, numbers.source, call.error_offset, 0, named_byte)
		}
		return errors.fail(error, ERROR, .Refused, .None, numbers.source, 0, 0, 0)
	case .Done:
	}

	memory, mapped := output_map(output, numbers.output, error)
	if !mapped {
		system.arena_end(&arena)
		return ERROR
	}
	if call.text_size > u64(len(memory)) {
		system.memory_unmap(raw_data(memory))
		system.arena_end(&arena)
		return errors.fail(error, ERROR, .Too_Small, .Bytes, numbers.output, i64(len(memory)), i64(call.text_size))
	}
	size := call.text_size
	intrinsics.mem_copy_non_overlapping(raw_data(memory), call.text, int(size))
	system.memory_unmap(raw_data(memory))
	system.arena_end(&arena)
	system.log_fact(.Info, Text_Written{size = value_kinds.Size_In_Bytes(size)})
	return i64(size)
}

// compile writes the text of assembly of a C source into a memory object, and gives the bytes of the text.
//
// `source` is the C source, 1 byte to 64 MiB, with no byte 0. `output` is a memory object that the caller lends to
// write; the text starts at its first byte, and the module `assemble` takes it. Each function that is not `static`
// becomes an `export` of the text: its `int` and `long` parameters and result are Integers. A call host compiles one
// source: a second call that reaches the compiler fails with `Refused`, and `unload` then `isolate` give a new one. A
// source that chibicc refuses fails with -1 and the error record `Bad_Byte`, whose value is the offset of the byte
// that its diagnostic names, or `Refused` when the diagnostic names no byte of the source; the log has the
// diagnostic. A memory object smaller than the text fails with `Too_Small`, and the limit is the bytes of the text.
@(export, link_name = "compile")
compile :: proc "c" (source: ^system.Bytes_To_Read, output: system.Lent({.Read, .Write}), error: ^errors.Error_Record) -> i64 {
	return compile_to_output(source, nil, output.handle, {source = ARGUMENT_SOURCE, output = ARGUMENT_OUTPUT}, error)
}

// compile_unit writes the text of assembly of one C source of a program into a memory object, and gives the bytes of the text.
//
// `name` is the name of the source, 1 to 255 bytes: its folder is the folder of its quoted includes, and the diagnostic
// names it. `source` is the C source, as for `compile`. `files` is the file list of the other files of the program, its
// headers, at most 4096 files and 64 MiB: records of a name size and a content size of 4 bytes each, little endian, then
// the name and the content; an empty list has no file. `exports` names the exports of the program, separated by
// spaces or new lines, at most 4096; an empty text makes each function that is not `static` an export. The text starts
// with `unit`, and each function and variable that is not `static` is `global`, so the module `assemble` joins the texts
// of the units into one module. A call host compiles one unit, as for `compile`. A file list or an export list that
// breaks its form fails before the C part runs: `Out_Of_Range` for a record that passes the end of the list,
// `Too_Long` or `Empty` for a name, `Bad_Byte` for a byte 0, `Exists` for a name twice, `Over_Limit` for too many files
// or exports. The memory of the C part is an arena of the budget of the call host: the largest source of chibicc,
// parse.c, takes 13 MiB.
@(export, link_name = "compile_unit")
compile_unit :: proc "c" (name: ^string, source: ^system.Bytes_To_Read, files: ^system.Bytes_To_Read, exports: ^string, output: system.Lent({.Read, .Write}), error: ^errors.Error_Record) -> i64 {
	// The counts are read once: the caller can change the records during
	// an isolated call.
	unit := Unit_Arguments {
		name    = (^Text_Place)(name),
		files   = files,
		exports = (^Text_Place)(exports),
	}
	unit.name_count = intrinsics.volatile_load(&unit.name.count)
	unit.files_count = intrinsics.volatile_load(&files.count)
	unit.exports_count = intrinsics.volatile_load(&unit.exports.count)
	if unit.name_count == 0 {
		return errors.fail(error, ERROR, .Empty, .Bytes, UNIT_ARGUMENT_NAME, 0, program_files.NAME_BYTES_MOST)
	}
	if unit.name_count > program_files.NAME_BYTES_MOST {
		return errors.fail(error, ERROR, .Too_Long, .Bytes, UNIT_ARGUMENT_NAME, i64(unit.name_count), program_files.NAME_BYTES_MOST)
	}
	if unit.files_count > program_files.LIST_BYTES_MOST {
		return errors.fail(error, ERROR, .Too_Long, .Bytes, UNIT_ARGUMENT_FILES, i64(unit.files_count), program_files.LIST_BYTES_MOST)
	}
	if unit.exports_count > EXPORT_LIST_BYTES_MOST {
		return errors.fail(error, ERROR, .Too_Long, .Bytes, UNIT_ARGUMENT_EXPORTS, i64(unit.exports_count), EXPORT_LIST_BYTES_MOST)
	}
	return compile_to_output(source, &unit, output.handle, {source = UNIT_ARGUMENT_SOURCE, output = UNIT_ARGUMENT_OUTPUT}, error)
}

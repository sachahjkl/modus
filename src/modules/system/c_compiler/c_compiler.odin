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
// It has no entry: it runs in the call host of its caller, with no grant.
package c_compiler

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/value_kinds"
import "modus:support/system"

// The bytes of a source that the module takes. The source is copied
// before the C part reads it: in an isolated call it is in the call
// region, which the caller can change during the call.
SOURCE_BYTES_MOST :: 64 * 1024

// The bytes of the diagnostic of chibicc that the module keeps for its
// log. It is memory of the module, not of the arena: a diagnostic still
// has room after the budget refused the arena.
DIAGNOSTIC_BYTES :: 4096

// The result of an export that fails: the error record says why.
ERROR :: -1

// The argument numbers of `compile`, which an error record names.
ARGUMENT_SOURCE :: 1
ARGUMENT_OUTPUT :: 2

// The value of the Memory_Map command that holds the memory handle, from 1:
// the argument that an error record of the kernel names for it.
MEMORY_MAP_ARGUMENT_MEMORY :: 1

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
	// Given back.
	text:                    [^]u8,
	text_size:               u64,
	error_offset:            i64, // The byte of the source that the diagnostic names; -1: none.
	diagnostic_size:         u64,
}

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

source_copy: [SOURCE_BYTES_MOST]u8
diagnostic: [DIAGNOSTIC_BYTES]u8

// chibicc keeps its state in static variables, and the module is loaded
// once in its call host: the first call that reaches the C entry is the
// only one (src/md/features/c_compiler.md, "One source for each call host").
compiler_used: bool

// The arena of the call, and the record of a push that its budget refused.
arena: system.Arena
memory_refusal: errors.Error_Record
memory_refused: bool

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
output_map :: proc "contextless" (memory: system.Handle, error: ^errors.Error_Record) -> (bytes: []u8, ok: bool) {
	refusal: errors.Error_Record
	address, status := system.memory_map(memory, {.Write}, error = &refusal)
	if status != .Ok {
		if error != nil {
			// The record of the kernel names an argument of Memory_Map, and
			// the kernel operation: the caller called the export, with its
			// own arguments.
			error^ = refusal
			error.operation = 0
			error.argument = refusal.argument == MEMORY_MAP_ARGUMENT_MEMORY ? i64(ARGUMENT_OUTPUT) : 0
			if refusal.kind == i64(errors.Kind.None) {
				error^ = errors.error_make(.Refused, argument = ARGUMENT_OUTPUT, found = i64(status))
			}
		}
		return nil, false
	}
	// The map took the handle, so the kernel gives its size.
	pages, _ := system.memory_size(memory)
	return ([^]u8)(address)[:pages * system.PAGE_SIZE], true
}

// compile writes the text of assembly of a C source into a memory object, and gives the bytes of the text.
//
// `source` is the C source, 1 byte to 64 KiB, with no byte 0. `output` is a memory object that the caller lends to
// write; the text starts at its first byte, and the module `assemble` takes it. Each function that is not `static`
// becomes an `export` of the text: its `int` and `long` parameters and result are Integers. A call host compiles one
// source: a second call that reaches the compiler fails with `Refused`, and `unload` then `isolate` give a new one. A
// source that chibicc refuses fails with -1 and the error record `Bad_Byte`, whose value is the offset of the byte
// that its diagnostic names, or `Refused` when the diagnostic names no byte of the source; the log has the
// diagnostic. A memory object smaller than the text fails with `Too_Small`, and the limit is the bytes of the text.
@(export, link_name = "compile")
compile :: proc "c" (source: ^system.Bytes_To_Read, output: system.Lent({.Read, .Write}), error: ^errors.Error_Record) -> i64 {
	// The count is read once: the caller can change the record during an
	// isolated call.
	count := intrinsics.volatile_load(&source.count)
	if count == 0 {
		return errors.fail(error, ERROR, .Empty, .Bytes, ARGUMENT_SOURCE, 0, SOURCE_BYTES_MOST)
	}
	if count > SOURCE_BYTES_MOST {
		return errors.fail(error, ERROR, .Too_Long, .Bytes, ARGUMENT_SOURCE, i64(count), SOURCE_BYTES_MOST)
	}
	intrinsics.mem_copy_non_overlapping(&source_copy[0], source.bytes, int(count))
	// chibicc reads a file up to its first byte 0: a source with one would
	// be compiled in part, with no word of it.
	for index in 0 ..< int(count) {
		if source_copy[index] == 0 {
			return errors.fail(error, ERROR, .Bad_Byte, .None, ARGUMENT_SOURCE, i64(index), 0, 0)
		}
	}
	if compiler_used {
		system.log_fact(.Info, Second_Source_Refused{})
		return errors.fail(error, ERROR, .Refused, .None, 0, 0, 0, 0)
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
	compiler_used = true
	memory_refused = false

	call := Compile_Call {
		source                  = &source_copy[0],
		source_size             = count,
		memory_provider         = memory_provide,
		memory_provider_context = &arena,
		diagnostic              = &diagnostic[0],
		diagnostic_capacity     = DIAGNOSTIC_BYTES,
		error_offset            = -1,
	}
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
		if call.error_offset >= 0 && call.error_offset < i64(count) {
			return errors.fail(error, ERROR, .Bad_Byte, .None, ARGUMENT_SOURCE, call.error_offset, 0, i64(source_copy[call.error_offset]))
		}
		return errors.fail(error, ERROR, .Refused, .None, ARGUMENT_SOURCE, 0, 0, 0)
	case .Done:
	}

	memory, mapped := output_map(output.handle, error)
	if !mapped {
		system.arena_end(&arena)
		return ERROR
	}
	if call.text_size > u64(len(memory)) {
		system.memory_unmap(raw_data(memory))
		system.arena_end(&arena)
		return errors.fail(error, ERROR, .Too_Small, .Bytes, ARGUMENT_OUTPUT, i64(len(memory)), i64(call.text_size))
	}
	size := call.text_size
	intrinsics.mem_copy_non_overlapping(raw_data(memory), call.text, int(size))
	system.memory_unmap(raw_data(memory))
	system.arena_end(&arena)
	system.log_fact(.Info, Text_Written{size = value_kinds.Size_In_Bytes(size)})
	return i64(size)
}

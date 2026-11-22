// The assembler as a module: the first program of modus that writes a
// program. It reads a text of x86-64 assembly in the syntax of AT&T and
// writes a module file into memory that the caller lends
// (docs/MODULE_CONTRACT.md, "The assembler").
//
// **What it is for.** A machine with no host makes a module. The console
// calls it in a call host, then isolates the module that it wrote:
//
// ```
// > isolate("assemble")
// > f = buffer(4)
// > n = assemble("export add(a: Integer, b: Integer) -> Integer; add: mov %rdi, %rax; add %rsi, %rax; ret", f)
// > isolate_memory("adder", f, n)
// > add(2, 3)
// 5
// ```
//
// It has no entry: it runs in the call host of its caller, with no grant.
// Its memory is an arena of the budget of the call host, made at each call
// and ended at its return: the copy of the text and the workspace of the
// assembler. So an idle module holds no page of a workspace.
package assemble

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/errors"
import writer "modus:contract/module_file_writer"
import "modus:contract/value_kinds"
import "internal:assemble/assembler"
import "modus:system"

// The bytes of a text that the module takes: a program of many units. The
// text is copied before it is read: in an isolated call it is in the call
// region, which the caller can change during the call, and the labels are
// views of the text. The copy is in the arena, so a short text does not pay
// for the bound.
SOURCE_BYTES_MOST :: assembler.PROGRAM_TEXT_BYTES_MOST

// The result of an export that fails: the error record says why.
ERROR :: -1

// The argument numbers of `assemble` and `assemble_program`, which an error
// record names.
ARGUMENT_SOURCE :: 1
ARGUMENT_FILE :: 2
ARGUMENT_HASH :: 3

// The value of the Memory_Map command that holds the memory handle, from 1:
// the argument that an error record of the kernel names for it.
MEMORY_MAP_ARGUMENT_MEMORY :: 1

// file_map maps the memory object of the file to write, for the time of one
// call. ok is false when the kernel refuses; then the error record holds the
// refusal, in the words of the export.
@(private)
file_map :: proc "contextless" (memory: system.Handle, error: ^errors.Error_Record) -> (bytes: []u8, ok: bool) {
	refusal: errors.Error_Record
	address, status := system.memory_map(memory, {.Write}, error = &refusal)
	if status != .Ok {
		if error != nil {
			// The record of the kernel names an argument of Memory_Map, and
			// the kernel operation: the caller called the export, with its
			// own arguments.
			error^ = refusal
			error.operation = 0
			error.argument = refusal.argument == MEMORY_MAP_ARGUMENT_MEMORY ? i64(ARGUMENT_FILE) : 0
			if refusal.kind == i64(errors.Kind.None) {
				error^ = errors.error_make(.Refused, argument = ARGUMENT_FILE, found = i64(status))
			}
		}
		return nil, false
	}
	// The map took the handle, so the kernel gives its size.
	pages, _ := system.memory_size(memory)
	return ([^]u8)(address)[:pages * system.PAGE_SIZE], true
}

// refusal_give writes a refusal of the arena or of the budget in the words
// of the export: the call of the caller asked for no operation.
@(private)
refusal_give :: proc "contextless" (error: ^errors.Error_Record, refusal: errors.Error_Record) -> i64 {
	if error != nil {
		error^ = refusal
		error.operation = 0
		error.argument = 0
	}
	return ERROR
}

// text_and_workspace_push copies the text into the arena and carves a
// workspace of the tier after it.
@(private)
text_and_workspace_push :: proc "contextless" (arena: ^system.Arena, source: ^system.Bytes_To_Read, count: u64, tier: assembler.Workspace_Tier, refusal: ^errors.Error_Record) -> (text: string, workspace: assembler.Workspace, status: system.Status) {
	copy_address: rawptr
	copy_address, status = system.arena_push(arena, count, 1, refusal)
	if status != .Ok {
		return
	}
	intrinsics.mem_copy_non_overlapping(copy_address, source.bytes, int(count))
	workspace_size := assembler.workspace_bytes(tier)
	workspace_address: rawptr
	workspace_address, status = system.arena_push(arena, workspace_size, assembler.WORKSPACE_ALIGNMENT, refusal)
	if status != .Ok {
		return
	}
	// The push gives the size and the alignment that the carve takes.
	workspace, _ = assembler.workspace_carve(([^]u8)(workspace_address)[:workspace_size], tier)
	return string(([^]u8)(copy_address)[:count]), workspace, .Ok
}

// assemble_to_file is the work of both exports. hash is nil for `assemble`.
@(private)
assemble_to_file :: proc "contextless" (source: ^system.Bytes_To_Read, file: system.Handle, hash: ^system.Bytes_To_Append, error: ^errors.Error_Record) -> i64 {
	// The counts are read once: the caller can change the records during an
	// isolated call.
	count := intrinsics.volatile_load(&source.count)
	if count == 0 {
		return errors.fail(error, ERROR, .Empty, .Bytes, ARGUMENT_SOURCE, 0, SOURCE_BYTES_MOST)
	}
	if count > SOURCE_BYTES_MOST {
		return errors.fail(error, ERROR, .Too_Long, .Bytes, ARGUMENT_SOURCE, i64(count), SOURCE_BYTES_MOST)
	}
	hash_count, hash_capacity: u64
	if hash != nil {
		hash_count = intrinsics.volatile_load(&hash.count)
		hash_capacity = intrinsics.volatile_load(&hash.capacity)
		if hash_count > hash_capacity || hash_capacity - hash_count < blake3.HASH_SIZE {
			room := hash_count > hash_capacity ? 0 : hash_capacity - hash_count
			return errors.fail(error, ERROR, .Too_Small, .Bytes, ARGUMENT_HASH, i64(room), blake3.HASH_SIZE)
		}
	}

	amounts, budget_status := system.budget_read()
	if budget_status != .Ok {
		return errors.fail(error, ERROR, .Refused, .None, 0, 0, 0, i64(budget_status))
	}
	arena_refusal: errors.Error_Record
	arena, arena_status := system.arena_create(system.arena_reservation_pages(amounts.pages), 0, &arena_refusal)
	if arena_status != .Ok {
		return refusal_give(error, arena_refusal)
	}
	defer system.arena_end(&arena)

	// A text of one source takes the tier Unit, which costs what the module
	// kept in its data before; a text that passes its bounds takes the tier
	// Program, with the text copied again.
	tier := count > assembler.UNIT_TEXT_BYTES_MOST ? assembler.Workspace_Tier.Program : assembler.Workspace_Tier.Unit
	text: string
	workspace: assembler.Workspace
	parts: writer.Module_Parts
	refusal: assembler.Refusal_Record
	for {
		push_status: system.Status
		text, workspace, push_status = text_and_workspace_push(&arena, source, count, tier, &arena_refusal)
		if push_status != .Ok {
			return refusal_give(error, arena_refusal)
		}
		parts, refusal = assembler.assemble(text, &workspace)
		if tier == .Unit && assembler.refusal_is_capacity(refusal.refusal) {
			system.arena_reset(&arena)
			tier = .Program
			continue
		}
		break
	}
	if refusal.refusal != .None {
		system.log_fact(.Info, Source_Refused{line = refusal.place.line, column = refusal.place.column, value = refusal.value, refusal = u32(refusal.refusal), refusal_sentence = value_kinds.text_field(assembler.refusal_sentence(refusal.refusal), REFUSAL_SENTENCE_FIELD_BYTES)})
		found := i64(0)
		if int(refusal.place.offset) < len(text) {
			found = i64(text[refusal.place.offset])
		}
		return errors.fail(error, ERROR, .Bad_Byte, .None, ARGUMENT_SOURCE, i64(refusal.place.offset), 0, found)
	}
	size, needed := writer.file_size_needed(parts)
	if needed.refusal != .None {
		// The assembler gives parts that the writer takes: a refusal here is
		// a fault of the assembler.
		system.log_fact(.Error, Parts_Refused{index = needed.index, writer_refusal = writer_refusal_field(needed.refusal)})
		return errors.fail(error, ERROR, .Refused, .None, 0, 0, 0, i64(needed.refusal))
	}

	memory, mapped := file_map(file, error)
	if !mapped {
		return ERROR
	}
	if size > u64(len(memory)) {
		system.memory_unmap(raw_data(memory))
		return errors.fail(error, ERROR, .Too_Small, .Bytes, ARGUMENT_FILE, i64(len(memory)), i64(size))
	}
	written, written_refusal := writer.write(parts, memory)
	if written_refusal.refusal != .None {
		system.memory_unmap(raw_data(memory))
		system.log_fact(.Error, File_Refused{index = written_refusal.index, writer_refusal = writer_refusal_field(written_refusal.refusal)})
		return errors.fail(error, ERROR, .Refused, .None, 0, 0, 0, i64(written_refusal.refusal))
	}
	if hash != nil {
		digest := blake3.hash(memory[:written])
		intrinsics.mem_copy_non_overlapping(&hash.bytes[hash_count], &digest[0], blake3.HASH_SIZE)
		intrinsics.volatile_store(&hash.count, hash_count + blake3.HASH_SIZE)
	}
	system.memory_unmap(raw_data(memory))
	system.log_fact(.Info, Module_File_Written{size = value_kinds.Size_In_Bytes(written), exports = u64(len(parts.exports))})
	return i64(written)
}

// assemble writes the module file of an assembly text into a memory object, and gives the bytes of the file.
//
// `source` is the text, 1 byte to 4 MiB: statements separated by a new line or by `;`, in the syntax of AT&T, with the
// directives `section code`, `section data`, `export name(a: Integer, b: Text) -> Integer`, `byte`, `quad`, `zero`,
// `align`, `unit` and `global`; a `quad` of a label is its address, which the module rebases at its load, and `unit`
// starts the next unit of a program, whose labels other units reach only through `global`. `file` is a memory object
// that the caller lends to write; the file starts at its first byte. The copy of the text and the tables of the
// assembler are memory of the budget of the call host, for the time of the call: a text past the bounds of one source
// (128 KiB of code, 2048 labels) takes the tables of a program (512 KiB of code, 128 KiB of data, 16384 labels, 16384
// operands that name a label, 2048 rebases), and a budget that cannot pay them fails with its error record. A text
// that the assembler does not take whole fails with -1 and the error record `Bad_Byte`: the value is the offset of the
// first byte of the statement or the operand that it refuses, and found is that byte; the log has the line, the column
// and the reason. A memory object smaller than the file fails with `Too_Small`, and the limit is the bytes of the file.
@(export, link_name = "assemble")
assemble :: proc "c" (source: ^system.Bytes_To_Read, file: system.Lent({.Read, .Write}), error: ^errors.Error_Record) -> i64 {
	return assemble_to_file(source, file.handle, nil, error)
}

// assemble_program writes the module file of an assembly text into a memory object, appends its BLAKE3 hash, and gives the bytes of the file.
//
// `source` and `file` are those of `assemble`, and the refusals are its refusals. `hash` takes the 32 bytes of the
// BLAKE3 hash of the file after its count: a stage of a bootstrap compares the hash of two builds with no second read
// of the files. A `hash` with less than 32 bytes of room fails with `Too_Small` before the text is read, and the
// limit is 32.
@(export, link_name = "assemble_program")
assemble_program :: proc "c" (source: ^system.Bytes_To_Read, file: system.Lent({.Read, .Write}), hash: ^system.Bytes_To_Append, error: ^errors.Error_Record) -> i64 {
	return assemble_to_file(source, file.handle, hash, error)
}

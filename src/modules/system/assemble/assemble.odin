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
package assemble

import "base:intrinsics"
import "modus:contract/errors"
import writer "modus:contract/module_file_writer"
import "modus:private/assemble/assembler"
import "modus:support/system"

// The bytes of a text that the module takes. The text is copied before it
// is read: in an isolated call it is in the call region, which the caller
// can change during the call, and the labels are views of the text.
SOURCE_BYTES_MOST :: 64 * 1024

// The result of an export that fails: the error record says why.
ERROR :: -1

// The argument numbers of `assemble`, which an error record names.
ARGUMENT_SOURCE :: 1
ARGUMENT_FILE :: 2

source_copy: [SOURCE_BYTES_MOST]u8
workspace: assembler.Workspace

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

// assemble writes the module file of an assembly text into a memory object, and gives the bytes of the file.
//
// `source` is the text: statements separated by a new line or by `;`, in the syntax of AT&T, with the directives
// `section code`, `section data`, `export name(a: Integer, b: Text) -> Integer`, `byte` and `zero`. `file` is a
// memory object that the caller lends to write; the file starts at its first byte. A text that the assembler does not
// take whole fails with -1 and the error record `Bad_Byte`: the value is the offset of the first byte of the statement
// or the operand that it refuses, and found is that byte; the log has the line, the column and the reason. A memory
// object smaller than the file fails with `Too_Small`, and the limit is the bytes of the file.
@(export, link_name = "assemble")
assemble :: proc "c" (source: ^system.Bytes_To_Read, file: system.Lent({.Read, .Write}), error: ^errors.Error_Record) -> i64 {
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
	text := string(source_copy[:count])

	parts, refusal := assembler.assemble(text, &workspace)
	if refusal.refusal != .None {
		system.log(.Info, "assemble: line ", u64(refusal.place.line), ", column ", u64(refusal.place.column), ": ", assembler.refusal_sentence(refusal.refusal), " (refusal ", u64(refusal.refusal), ", value ", refusal.value, ")")
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
		system.log(.Error, "assemble: the module file writer refused the parts: refusal ", u64(needed.refusal), ", index ", needed.index)
		return errors.fail(error, ERROR, .Refused, .None, 0, 0, 0, i64(needed.refusal))
	}

	memory, mapped := file_map(file.handle, error)
	if !mapped {
		return ERROR
	}
	if size > u64(len(memory)) {
		system.memory_unmap(raw_data(memory))
		return errors.fail(error, ERROR, .Too_Small, .Bytes, ARGUMENT_FILE, i64(len(memory)), i64(size))
	}
	written, written_refusal := writer.write(parts, memory)
	system.memory_unmap(raw_data(memory))
	if written_refusal.refusal != .None {
		system.log(.Error, "assemble: the module file writer refused the file: refusal ", u64(written_refusal.refusal), ", index ", written_refusal.index)
		return errors.fail(error, ERROR, .Refused, .None, 0, 0, 0, i64(written_refusal.refusal))
	}
	system.log(.Info, "assemble: a module file of ", written, " bytes with ", u64(len(parts.exports)), " exports")
	return i64(written)
}

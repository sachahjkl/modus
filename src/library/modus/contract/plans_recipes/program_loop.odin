package plans_recipes

// The recipe of a C program and the project that holds its source
// (src/md/features/program_loop.md): the hash of the native C builder,
// the recipe of one C source, and the evaluation of a project that
// projects.new makes with no project.lex.

import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:contract/errors"
import module "modus:contract/module"
import "modus:contract/object_cache"
import "modus:contract/root_delegation"
import "modus:contract/tree_hash"

// The context of the hash of the native C builder.
C_BUILDER_DOMAIN :: "modus builder c v1"

// The bounds of a C build of one source by the service recipes: the source
// that the module c_compiler takes, the text that the module assemble
// takes, and the module that one object of a cache holds, as a realisation
// is shared through a cache. The service makes the memory object of the
// text and of the module of the size that the build needs
// (src/md/features/program_loop.md, "The native C builder"): these bounds
// cost no memory to a small build.
C_SOURCE_BYTES_LIMIT :: 64 * 1024 * 1024
C_TEXT_BYTES_LIMIT :: 256 * 1024 * 1024
// A module past the module file that a process loads builds and never
// runs, so the bound is the smaller of the two.
C_MODULE_BYTES_LIMIT :: min(RECIPE_OUTPUT_BYTES_MOST, u64(root_delegation.MODULE_BYTES_LIMIT))

// The blocks of the output of a C build: one module file, in blocks of
// 4 KiB.
C_BUILD_OUTPUT_BLOCK_LIMIT :: C_MODULE_BYTES_LIMIT / 4096

// The places of the arguments of recipes.build_c, which its error records
// name.
C_BUILD_ARGUMENT_NAME :: 1
C_BUILD_ARGUMENT_SOURCE :: 2
C_BUILD_ARGUMENT_SIZE :: 3
C_BUILD_ARGUMENT_MODULE :: 4

// c_build_name_refusal checks the length of the name of a source that the
// caller gave: 1 to MAX_ENTRY_NAME_BYTES. recipe_validate checks its bytes.
c_build_name_refusal :: proc "contextless" (length: int) -> errors.Error_Record {
	if length == 0 {
		return errors.error_make(.Empty, .Bytes, C_BUILD_ARGUMENT_NAME, 0, MAX_ENTRY_NAME_BYTES)
	}
	if length > MAX_ENTRY_NAME_BYTES {
		return errors.error_make(.Too_Long, .Bytes, C_BUILD_ARGUMENT_NAME, i64(min(length, int(max(i64)))), MAX_ENTRY_NAME_BYTES)
	}
	return {}
}

// c_build_source_refusal checks the count of bytes of a source that the
// caller lends in a memory object of memory_bytes: 1 to
// C_SOURCE_BYTES_LIMIT, and no byte past the memory object.
c_build_source_refusal :: proc "contextless" (size: i64, memory_bytes: u64) -> errors.Error_Record {
	if size < 1 || size > C_SOURCE_BYTES_LIMIT {
		return errors.error_make(.Out_Of_Range, .Bytes, C_BUILD_ARGUMENT_SIZE, size, C_SOURCE_BYTES_LIMIT)
	}
	if u64(size) > memory_bytes {
		return errors.error_make(.Out_Of_Range, .Bytes, C_BUILD_ARGUMENT_SIZE, size, i64(min(memory_bytes, u64(max(i64)))))
	}
	return {}
}

// c_build_written_refusal checks the count that a call host gave for the
// bytes that it wrote into a memory object of bound bytes: a count of no
// byte, or past the memory object, is no output.
c_build_written_refusal :: proc "contextless" (written: i64, bound: i64) -> errors.Error_Record {
	if written < 1 {
		return errors.error_make(.Empty, .Bytes, 0, written, bound)
	}
	if written > bound {
		return errors.error_make(.Out_Of_Range, .Bytes, 0, written, bound)
	}
	return {}
}

// c_build_module_refusal checks the bytes of the module that the assembler
// wrote: a module file that module.validate takes. A call host that wrote
// nothing leaves the bytes of a new memory object, all zero: Malformed.
c_build_module_refusal :: proc "contextless" (bytes: []u8) -> errors.Error_Record {
	if refusal := module.validate(bytes); refusal != .None {
		return errors.error_make(.Malformed, .None, 0, i64(refusal))
	}
	return {}
}


// c_build_module_room_refusal checks that the memory object of
// memory_bytes that the caller lends holds the module.
c_build_module_room_refusal :: proc "contextless" (module_bytes: int, memory_bytes: u64) -> errors.Error_Record {
	if u64(module_bytes) > memory_bytes {
		return errors.error_make(.Too_Small, .Bytes, C_BUILD_ARGUMENT_MODULE, i64(min(memory_bytes, u64(max(i64)))), i64(module_bytes))
	}
	return {}
}

// c_builder_hash gives the hash of the native C builder: the context, then
// the hash of the compiler module and the hash of the assembler module. A
// new compiler or a new assembler is a new builder, so a new recipe.
c_builder_hash :: proc "contextless" (compiler_hash, assembler_hash: blake3.Hash) -> blake3.Hash {
	parts: [2 * blake3.HASH_SIZE]u8
	compiler := compiler_hash
	assembler := assembler_hash
	copy(parts[:blake3.HASH_SIZE], compiler[:])
	copy(parts[blake3.HASH_SIZE:], assembler[:])
	return blake3.derive_key(C_BUILDER_DOMAIN, parts[:])
}

// c_build_recipe writes the recipe of the build of one C source: the
// native C builder, one input (the name of the source and the hash of its
// bytes), no argument, and a module file as its output. The refusal is the
// one of recipe_validate: a name of the source that no tree takes.
c_build_recipe :: proc "contextless" (compiler_hash, assembler_hash: blake3.Hash, source_name: string, source_hash: blake3.Hash, spec: ^Recipe_Spec) -> Recipe_Refusal {
	// Field by field: a literal of the whole record would be a value of
	// about 90 KiB on the stack.
	spec^ = {}
	spec.builder_hash = c_builder_hash(compiler_hash, assembler_hash)
	spec.output_kind = .Blob
	spec.output_block_limit = C_BUILD_OUTPUT_BLOCK_LIMIT
	spec.input_count = 1
	if len(source_name) == 0 || len(source_name) > MAX_ENTRY_NAME_BYTES {
		spec^ = {}
		return .Invalid_Input_Name
	}
	input := &spec.inputs[0]
	copy(input.name_bytes[:], source_name)
	input.name_length = u8(len(source_name))
	input.kind = object_cache.Cache_Object_Kind.Blob
	input.hash = source_hash
	if refusal, _ := recipe_validate(spec); refusal != .None {
		spec^ = {}
		return refusal
	}
	return .None
}

// The bytes of the evaluation of a new project, at most.
PROJECT_NEW_EVALUATION_BYTES :: 256

// project_new_evaluation writes the evaluation of the project that
// projects.new makes for name: its source the empty tree, and its console
// the store of the same name, with Read and Write, the store of its
// source. ok is false when the buffer is too small or the empty tree has
// no hash.
//
// Example: project_new_evaluation("hello", buffer[:]) gives the
// evaluation of project { source = <empty tree>, console = { stores =
// [store("hello", .Read, .Write)] } }.
project_new_evaluation :: proc "contextless" (name: string, buffer: []u8) -> (written: int, ok: bool) {
	empty: [tree_hash.HEADER_SIZE]u8
	encoded, encode_refusal := tree_hash.tree_encode(nil, empty[:])
	if encode_refusal != .None {
		return 0, false
	}
	source, hash_refusal := tree_hash.tree_hash(empty[:encoded])
	if hash_refusal != .None {
		return 0, false
	}
	writer := declaration_eval.output_writer_start(buffer, {status = .Ok})
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Project))
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	// The fields of a record come in the order of their names.
	declaration_eval.output_write_u32(&writer, 2)
	declaration_eval.output_write_string(&writer, "console")
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 1)
	declaration_eval.output_write_string(&writer, "stores")
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.List))
	declaration_eval.output_write_u32(&writer, 1)
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Store_Ref))
	declaration_eval.output_write_string(&writer, name)
	declaration_eval.output_write_u32(&writer, 2)
	declaration_eval.output_write_string(&writer, "Read")
	declaration_eval.output_write_string(&writer, "Write")
	// The source is a tree, as here() gives it: a bare hash names no kind.
	declaration_eval.output_write_string(&writer, "source")
	declaration_eval.output_write_tree(&writer, source)
	if writer.overflow {
		return 0, false
	}
	return writer.written, true
}

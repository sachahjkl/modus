package plans_recipes

// The recipe of a C program and the project that holds its source
// (src/md/features/program_loop.md): the hash of the native C builder,
// the recipe of one C source, and the evaluation of a project that
// projects.new makes with no project.lex.

import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:contract/object_cache"
import "modus:contract/tree_hash"

// The context of the hash of the native C builder.
C_BUILDER_DOMAIN :: "modus builder c v1"

// The blocks of the output of a C build: one module file of at most
// 256 KiB, in blocks of 4 KiB.
C_BUILD_OUTPUT_BLOCK_LIMIT :: 64

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
	spec^ = {
		builder_hash       = c_builder_hash(compiler_hash, assembler_hash),
		output_kind        = .Blob,
		output_block_limit = C_BUILD_OUTPUT_BLOCK_LIMIT,
		input_count        = 1,
	}
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
	declaration_eval.output_write_string(&writer, "source")
	declaration_eval.output_write_hash(&writer, source)
	if writer.overflow {
		return 0, false
	}
	return writer.written, true
}

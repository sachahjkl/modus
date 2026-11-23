#+build !freestanding
package plans_recipes

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:contract/object_cache"

@(private = "file")
conversion_hash :: proc(tag: u8) -> blake3.Hash {
	data := [3]u8{'c', 'v', tag}
	return blake3.hash(data[:])
}

// The arguments of collatz, as the evaluator writes them: the fields in the
// order of their names, path then source.
@(private = "file")
collatz_arguments :: proc(buffer: []u8, source: blake3.Hash) -> int {
	writer := declaration_eval.Output_Writer{buffer = buffer}
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 2)
	declaration_eval.output_write_string(&writer, "path")
	declaration_eval.output_write_text(&writer, "collatz.c")
	declaration_eval.output_write_string(&writer, "source")
	declaration_eval.output_write_tree(&writer, source)
	return writer.written
}

// The refusals of the conversion: a bare hash at the first level and
// deeper, a tag that names no kind, a damaged value, an input table past its
// bound, an input below the first level, a negative source date, a recipe
// among the arguments, and arguments that are no record. Each leaves an
// empty record.
@(test)
the_conversion_of_a_recipe_refuses_a_value_that_names_no_kind :: proc(t: ^testing.T) {
	builder := conversion_hash(1)
	spec := new(Recipe_Spec)
	defer free(spec)
	buffer: [8192]u8

	// A bare hash where an input would be.
	writer := declaration_eval.Output_Writer{buffer = buffer[:]}
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 1)
	declaration_eval.output_write_string(&writer, "source")
	declaration_eval.output_write_hash(&writer, conversion_hash(2))
	testing.expect_value(t, recipe_spec_of_arguments(builder, buffer[:writer.written], spec), Recipe_Refusal.Untyped_Hash)

	// A bare hash in a list of the arguments.
	writer = {buffer = buffer[:]}
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 1)
	declaration_eval.output_write_string(&writer, "flags")
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.List))
	declaration_eval.output_write_u32(&writer, 1)
	declaration_eval.output_write_hash(&writer, conversion_hash(2))
	testing.expect_value(t, recipe_spec_of_arguments(builder, buffer[:writer.written], spec), Recipe_Refusal.Untyped_Hash)

	// A tree below the first level: its input would have no name.
	writer = {buffer = buffer[:]}
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 1)
	declaration_eval.output_write_string(&writer, "deep")
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 1)
	declaration_eval.output_write_string(&writer, "source")
	declaration_eval.output_write_tree(&writer, conversion_hash(2))
	testing.expect_value(t, recipe_spec_of_arguments(builder, buffer[:writer.written], spec), Recipe_Refusal.Nested_Input)

	// A tag that names no kind, in place of the value of an input.
	length := collatz_arguments(buffer[:], conversion_hash(2))
	unknown := buffer
	place := length - blake3.HASH_SIZE - 1
	testing.expect_value(t, unknown[place], u8(declaration_eval.Value_Tag.Tree_Ref))
	unknown[place] = 200
	testing.expect_value(t, recipe_spec_of_arguments(builder, unknown[:length], spec), Recipe_Refusal.Damaged_Recipe)

	// A value that ends early, and one with a byte after its end.
	testing.expect_value(t, recipe_spec_of_arguments(builder, buffer[:length - 1], spec), Recipe_Refusal.Damaged_Recipe)
	testing.expect_value(t, recipe_spec_of_arguments(builder, buffer[:length + 1], spec), Recipe_Refusal.Damaged_Recipe)
	testing.expect_value(t, recipe_spec_of_arguments(builder, nil, spec), Recipe_Refusal.Damaged_Recipe)

	// Arguments that are no record.
	writer = {buffer = buffer[:]}
	declaration_eval.output_write_integer(&writer, 4)
	testing.expect_value(t, recipe_spec_of_arguments(builder, buffer[:writer.written], spec), Recipe_Refusal.Not_A_Recipe)

	// One input past the bound of the table: 33 trees. The names are in
	// the order of the bytes, as a record of the output holds them.
	writer = {buffer = buffer[:]}
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, MAX_RECIPE_INPUTS + 1)
	for index in 0 ..< MAX_RECIPE_INPUTS + 1 {
		name := [3]u8{'i', 'a' + u8(index / 26), 'a' + u8(index % 26)}
		declaration_eval.output_write_string(&writer, string(name[:]))
		declaration_eval.output_write_tree(&writer, conversion_hash(u8(10 + index)))
	}
	testing.expect_value(t, recipe_spec_of_arguments(builder, buffer[:writer.written], spec), Recipe_Refusal.Too_Many_Inputs)

	// A negative source date, and a recipe among the arguments.
	writer = {buffer = buffer[:]}
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 1)
	declaration_eval.output_write_string(&writer, SOURCE_DATE_FIELD)
	declaration_eval.output_write_integer(&writer, -1)
	testing.expect_value(t, recipe_spec_of_arguments(builder, buffer[:writer.written], spec), Recipe_Refusal.Unsupported_Argument)
	writer = {buffer = buffer[:]}
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 1)
	declaration_eval.output_write_string(&writer, "other")
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Recipe_Ref))
	declaration_eval.output_write_bytes(&writer, make_bytes(conversion_hash(3)))
	declaration_eval.output_write_bytes(&writer, make_bytes(builder))
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 0)
	testing.expect_value(t, recipe_spec_of_arguments(builder, buffer[:writer.written], spec), Recipe_Refusal.Unsupported_Argument)

	// A zero builder.
	length = collatz_arguments(buffer[:], conversion_hash(2))
	testing.expect_value(t, recipe_spec_of_arguments({}, buffer[:length], spec), Recipe_Refusal.Zero_Builder_Hash)
}

@(private = "file")
make_bytes :: proc(hash: blake3.Hash) -> []u8 {
	copy := new([blake3.HASH_SIZE]u8, context.temp_allocator)
	copy^ = hash
	return copy[:]
}

// An output whose value is no recipe, and an output whose written hash is
// not the hash of its record, are refused.
@(test)
the_recipe_of_an_output_must_carry_its_own_hash :: proc(t: ^testing.T) {
	builder := conversion_hash(1)
	spec := new(Recipe_Spec)
	defer free(spec)
	arguments: [512]u8
	length := collatz_arguments(arguments[:], conversion_hash(2))
	testing.expect_value(t, recipe_spec_of_arguments(builder, arguments[:length], spec), Recipe_Refusal.None)
	hash, _ := recipe_hash(spec)

	output: [1024]u8
	write :: proc(output: []u8, written_hash, builder: blake3.Hash, arguments: []u8) -> int {
		writer := declaration_eval.output_writer_start(output, {status = .Ok})
		declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Recipe_Ref))
		declaration_eval.output_write_bytes(&writer, make_bytes(written_hash))
		declaration_eval.output_write_bytes(&writer, make_bytes(builder))
		declaration_eval.output_write_bytes(&writer, arguments)
		return writer.written
	}
	wrong := write(output[:], conversion_hash(9), builder, arguments[:length])
	_, refusal := recipe_spec_of_output(output[:wrong], spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Damaged_Recipe)

	writer := declaration_eval.output_writer_start(output[:], {status = .Ok})
	declaration_eval.output_write_integer(&writer, 4)
	_, refusal = recipe_spec_of_output(output[:writer.written], spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Not_A_Recipe)

	right := write(output[:], hash, builder, arguments[:length])
	_, refusal = recipe_spec_of_output(output[:right - 1], spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Damaged_Recipe)

	// The success case: the hash that the output carries is the hash of
	// the record that the service registers.
	read_hash: blake3.Hash
	read_hash, refusal = recipe_spec_of_output(output[:right], spec)
	testing.expect_value(t, refusal, Recipe_Refusal.None)
	testing.expect(t, read_hash == hash, "the written hash is the hash of the record")
}

// The success case of the conversion: the tree is an input under its name,
// with the kind Tree; a module file is an input with the kind Blob; the
// text is the argument bytes, a record of the other fields; the source date
// is the date of the recipe; the same value gives the same hash, and
// another tree another one.
@(test)
the_conversion_gives_the_record_that_the_service_builds :: proc(t: ^testing.T) {
	builder := conversion_hash(1)
	spec := new(Recipe_Spec)
	defer free(spec)
	buffer: [512]u8
	writer := declaration_eval.Output_Writer{buffer = buffer[:]}
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 4)
	declaration_eval.output_write_string(&writer, "compiler")
	declaration_eval.output_write_module_ref(&writer, conversion_hash(5))
	declaration_eval.output_write_string(&writer, "path")
	declaration_eval.output_write_text(&writer, "collatz.c")
	declaration_eval.output_write_string(&writer, "source")
	declaration_eval.output_write_tree(&writer, conversion_hash(2))
	declaration_eval.output_write_string(&writer, SOURCE_DATE_FIELD)
	declaration_eval.output_write_integer(&writer, 1700000000)
	testing.expect_value(t, recipe_spec_of_arguments(builder, buffer[:writer.written], spec), Recipe_Refusal.None)
	testing.expect(t, spec.builder_hash == builder)
	testing.expect_value(t, spec.output_kind, object_cache.Cache_Object_Kind.Tree)
	testing.expect_value(t, spec.source_date_unix, u64(1700000000))
	testing.expect_value(t, spec.input_count, u32(2))
	testing.expect_value(t, string(spec.inputs[0].name_bytes[:spec.inputs[0].name_length]), "compiler")
	testing.expect_value(t, spec.inputs[0].kind, object_cache.Cache_Object_Kind.Blob)
	testing.expect_value(t, string(spec.inputs[1].name_bytes[:spec.inputs[1].name_length]), "source")
	testing.expect_value(t, spec.inputs[1].kind, object_cache.Cache_Object_Kind.Tree)

	// The argument bytes are the record of path and source_date only.
	reader := declaration_eval.Output_Reader{bytes = spec.arguments[:spec.arguments_length]}
	tag, _ := declaration_eval.output_read_tag(&reader)
	count, _ := declaration_eval.output_read_u32(&reader)
	first, _ := declaration_eval.output_read_string(&reader)
	testing.expect(t, tag == .Record && count == 2 && first == "path", "the arguments are the fields that are no input")

	first_hash, _ := recipe_hash(spec)
	again := new(Recipe_Spec)
	defer free(again)
	testing.expect_value(t, recipe_spec_of_arguments(builder, buffer[:writer.written], again), Recipe_Refusal.None)
	again_hash, _ := recipe_hash(again)
	testing.expect(t, first_hash == again_hash, "one value gives one hash")

	length := collatz_arguments(buffer[:], conversion_hash(3))
	testing.expect_value(t, recipe_spec_of_arguments(builder, buffer[:length], again), Recipe_Refusal.None)
	other_hash, _ := recipe_hash(again)
	testing.expect(t, other_hash != first_hash, "another tree gives another recipe")
}

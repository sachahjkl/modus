#+build !freestanding
#+build !modus
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

@(private = "file")
hash_bytes :: proc(hash: blake3.Hash) -> []u8 {
	copy := new([blake3.HASH_SIZE]u8, context.temp_allocator)
	copy^ = hash
	return copy[:]
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

@(private = "file")
record_start :: proc(writer: ^declaration_eval.Output_Writer, count: u32) {
	declaration_eval.output_write_u8(writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(writer, count)
}

// refused converts the bytes, expects the refusal, and checks that the
// record is left zero: a refusal leaves nothing half written.
@(private = "file")
refused :: proc(t: ^testing.T, bytes: []u8, expected: Recipe_Refusal, builder: blake3.Hash = {}, location := #caller_location) {
	spec := new(Recipe_Spec, context.temp_allocator)
	// A record full of bytes before the call: the refusal must clear it.
	spec.input_count = 3
	spec.arguments[0] = 9
	used_builder := builder == {} ? conversion_hash(1) : builder
	if builder == {} && expected == .Zero_Builder_Hash {
		used_builder = {}
	}
	refusal := recipe_spec_of_arguments(used_builder, bytes, spec)
	testing.expect_value(t, refusal, expected, loc = location)
	testing.expect(t, spec^ == {}, "a refusal leaves the record zero", loc = location)
}

// The refusals of a value that names no kind: a bare hash at the first level
// and in a list, a tree below the first level, a tag that names no kind, a
// zero tree hash, a recipe among the arguments, arguments that are no
// record, a zero builder, and a nil record.
@(test)
the_conversion_of_a_recipe_refuses_a_value_that_names_no_kind :: proc(t: ^testing.T) {
	buffer: [8192]u8

	writer := declaration_eval.Output_Writer{buffer = buffer[:]}
	record_start(&writer, 1)
	declaration_eval.output_write_string(&writer, "source")
	declaration_eval.output_write_hash(&writer, conversion_hash(2))
	refused(t, buffer[:writer.written], .Untyped_Hash)

	writer = {buffer = buffer[:]}
	record_start(&writer, 1)
	declaration_eval.output_write_string(&writer, "flags")
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.List))
	declaration_eval.output_write_u32(&writer, 1)
	declaration_eval.output_write_hash(&writer, conversion_hash(2))
	refused(t, buffer[:writer.written], .Untyped_Hash)

	writer = {buffer = buffer[:]}
	record_start(&writer, 1)
	declaration_eval.output_write_string(&writer, "deep")
	record_start(&writer, 1)
	declaration_eval.output_write_string(&writer, "source")
	declaration_eval.output_write_tree(&writer, conversion_hash(2))
	refused(t, buffer[:writer.written], .Nested_Input)

	length := collatz_arguments(buffer[:], conversion_hash(2))
	unknown := buffer
	place := length - blake3.HASH_SIZE - 1
	testing.expect_value(t, unknown[place], u8(declaration_eval.Value_Tag.Tree_Ref))
	unknown[place] = 200
	refused(t, unknown[:length], .Damaged_Recipe)

	length = collatz_arguments(buffer[:], {})
	refused(t, buffer[:length], .Zero_Input_Hash)

	writer = {buffer = buffer[:]}
	record_start(&writer, 1)
	declaration_eval.output_write_string(&writer, "other")
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Recipe_Ref))
	declaration_eval.output_write_bytes(&writer, hash_bytes(conversion_hash(3)))
	declaration_eval.output_write_bytes(&writer, hash_bytes(conversion_hash(1)))
	record_start(&writer, 0)
	refused(t, buffer[:writer.written], .Unsupported_Argument)

	writer = {buffer = buffer[:]}
	declaration_eval.output_write_integer(&writer, 4)
	refused(t, buffer[:writer.written], .Not_A_Recipe)

	length = collatz_arguments(buffer[:], conversion_hash(2))
	refused(t, buffer[:length], .Zero_Builder_Hash)
	testing.expect_value(t, recipe_spec_of_arguments(conversion_hash(1), buffer[:length], nil), Recipe_Refusal.Buffer_Too_Small)
}

// The source date is an integer of 0 or more: a negative one and one that
// is a text are refused; 0 is taken.
@(test)
the_source_date_of_a_recipe_is_an_integer :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := declaration_eval.Output_Writer{buffer = buffer[:]}
	record_start(&writer, 1)
	declaration_eval.output_write_string(&writer, SOURCE_DATE_FIELD)
	declaration_eval.output_write_integer(&writer, -1)
	refused(t, buffer[:writer.written], .Unsupported_Argument)

	writer = {buffer = buffer[:]}
	record_start(&writer, 1)
	declaration_eval.output_write_string(&writer, SOURCE_DATE_FIELD)
	declaration_eval.output_write_text(&writer, "2026-11-23")
	refused(t, buffer[:writer.written], .Unsupported_Argument)

	writer = {buffer = buffer[:]}
	record_start(&writer, 1)
	declaration_eval.output_write_string(&writer, SOURCE_DATE_FIELD)
	declaration_eval.output_write_integer(&writer, 0)
	spec := new(Recipe_Spec, context.temp_allocator)
	testing.expect_value(t, recipe_spec_of_arguments(conversion_hash(1), buffer[:writer.written], spec), Recipe_Refusal.None)
	testing.expect_value(t, spec.source_date_unix, u64(0))
}

// One value has one form: names out of the order of their bytes, a name
// twice, and a nested record out of order are refused, so {a = 1, b = 2}
// and {b = 2, a = 1} cannot give two argument forms.
@(test)
the_conversion_takes_only_the_canonical_form :: proc(t: ^testing.T) {
	buffer: [256]u8
	write_pair :: proc(buffer: []u8, first, second: string) -> int {
		writer := declaration_eval.Output_Writer{buffer = buffer}
		record_start(&writer, 2)
		declaration_eval.output_write_string(&writer, first)
		declaration_eval.output_write_integer(&writer, 1)
		declaration_eval.output_write_string(&writer, second)
		declaration_eval.output_write_integer(&writer, 2)
		return writer.written
	}
	refused(t, buffer[:write_pair(buffer[:], "b", "a")], .Damaged_Recipe)
	refused(t, buffer[:write_pair(buffer[:], "a", "a")], .Damaged_Recipe)

	writer := declaration_eval.Output_Writer{buffer = buffer[:]}
	record_start(&writer, 1)
	declaration_eval.output_write_string(&writer, "nested")
	record_start(&writer, 2)
	declaration_eval.output_write_string(&writer, "b")
	declaration_eval.output_write_integer(&writer, 2)
	declaration_eval.output_write_string(&writer, "a")
	declaration_eval.output_write_integer(&writer, 1)
	refused(t, buffer[:writer.written], .Damaged_Recipe)

	// The sorted form is the one that is taken.
	spec := new(Recipe_Spec, context.temp_allocator)
	testing.expect_value(t, recipe_spec_of_arguments(conversion_hash(1), buffer[:write_pair(buffer[:], "a", "b")], spec), Recipe_Refusal.None)
}

// The bounds: exactly MAX_RECIPE_INPUTS inputs are taken and one more is
// refused; argument bytes of exactly MAX_RECIPE_ARG_BYTES are taken and one
// more is refused; a nesting at the depth bound is taken and one level more
// is refused; a field count of 0xFFFFFFFF over a few bytes, a value that
// ends early and one with a byte after its end are refused.
@(test)
the_conversion_holds_its_bounds :: proc(t: ^testing.T) {
	buffer := new([MAX_RECIPE_ARGUMENT_VALUE_BYTES + 64]u8, context.temp_allocator)
	spec := new(Recipe_Spec, context.temp_allocator)

	inputs :: proc(buffer: []u8, count: int) -> int {
		writer := declaration_eval.Output_Writer{buffer = buffer}
		record_start(&writer, u32(count))
		for index in 0 ..< count {
			name := [3]u8{'i', 'a' + u8(index / 26), 'a' + u8(index % 26)}
			declaration_eval.output_write_string(&writer, string(name[:]))
			declaration_eval.output_write_tree(&writer, conversion_hash(u8(10 + index)))
		}
		return writer.written
	}
	testing.expect_value(t, recipe_spec_of_arguments(conversion_hash(1), buffer[:inputs(buffer[:], MAX_RECIPE_INPUTS)], spec), Recipe_Refusal.None)
	testing.expect_value(t, spec.input_count, u32(MAX_RECIPE_INPUTS))
	refused(t, buffer[:inputs(buffer[:], MAX_RECIPE_INPUTS + 1)], .Too_Many_Inputs)

	// The argument record: its head (5 bytes), the name "t" (5), the tag (1)
	// and the length of the text (4), then the text.
	text_of :: proc(buffer: []u8, argument_bytes: int) -> int {
		text := make([]u8, argument_bytes - 15, context.temp_allocator)
		for &item in text {
			item = 'x'
		}
		writer := declaration_eval.Output_Writer{buffer = buffer}
		record_start(&writer, 1)
		declaration_eval.output_write_string(&writer, "t")
		declaration_eval.output_write_text(&writer, string(text))
		return writer.written
	}
	testing.expect_value(t, recipe_spec_of_arguments(conversion_hash(1), buffer[:text_of(buffer[:], MAX_RECIPE_ARG_BYTES)], spec), Recipe_Refusal.None)
	testing.expect_value(t, spec.arguments_length, u32(MAX_RECIPE_ARG_BYTES))
	refused(t, buffer[:text_of(buffer[:], MAX_RECIPE_ARG_BYTES + 1)], .Arguments_Too_Large)

	// Lists inside lists under one field: the reader of the output refuses a
	// value at OUTPUT_DEPTH_LIMIT, and the record and its field take two levels.
	nested :: proc(buffer: []u8, lists: int) -> int {
		writer := declaration_eval.Output_Writer{buffer = buffer}
		record_start(&writer, 1)
		declaration_eval.output_write_string(&writer, "deep")
		for _ in 0 ..< lists {
			declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.List))
			declaration_eval.output_write_u32(&writer, 1)
		}
		declaration_eval.output_write_integer(&writer, 7)
		return writer.written
	}
	deepest := declaration_eval.OUTPUT_DEPTH_LIMIT - 2
	testing.expect_value(t, recipe_spec_of_arguments(conversion_hash(1), buffer[:nested(buffer[:], deepest)], spec), Recipe_Refusal.None)
	refused(t, buffer[:nested(buffer[:], deepest + 1)], .Damaged_Recipe)

	writer := declaration_eval.Output_Writer{buffer = buffer[:]}
	record_start(&writer, 0xFFFFFFFF)
	declaration_eval.output_write_string(&writer, "a")
	refused(t, buffer[:writer.written], .Damaged_Recipe)

	length := collatz_arguments(buffer[:], conversion_hash(2))
	refused(t, buffer[:length - 1], .Damaged_Recipe)
	refused(t, buffer[:length + 1], .Damaged_Recipe)
	refused(t, nil, .Damaged_Recipe)
}

// An output whose value is no recipe, an output of a refused evaluation, an
// output that ends early, and an output whose written hash is not the hash
// of its record, are refused and leave the record zero.
@(test)
the_recipe_of_an_output_must_carry_its_own_hash :: proc(t: ^testing.T) {
	builder := conversion_hash(1)
	spec := new(Recipe_Spec, context.temp_allocator)
	arguments: [512]u8
	length := collatz_arguments(arguments[:], conversion_hash(2))
	testing.expect_value(t, recipe_spec_of_arguments(builder, arguments[:length], spec), Recipe_Refusal.None)
	hash, _ := recipe_hash(spec)

	output: [1024]u8
	write :: proc(output: []u8, written_hash, builder: blake3.Hash, arguments: []u8) -> int {
		writer := declaration_eval.output_writer_start(output, {status = .Ok})
		declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Recipe_Ref))
		declaration_eval.output_write_bytes(&writer, hash_bytes(written_hash))
		declaration_eval.output_write_bytes(&writer, hash_bytes(builder))
		declaration_eval.output_write_bytes(&writer, arguments)
		return writer.written
	}
	expect_output_refused :: proc(t: ^testing.T, output: []u8, expected: Recipe_Refusal, location := #caller_location) {
		spec := new(Recipe_Spec, context.temp_allocator)
		spec.input_count = 1
		_, refusal := recipe_spec_of_output(output, spec)
		testing.expect_value(t, refusal, expected, loc = location)
		testing.expect(t, spec^ == {}, "a refusal leaves the record zero", loc = location)
	}
	expect_output_refused(t, output[:write(output[:], conversion_hash(9), builder, arguments[:length])], .Damaged_Recipe)

	writer := declaration_eval.output_writer_start(output[:], {status = .Ok})
	declaration_eval.output_write_integer(&writer, 4)
	expect_output_refused(t, output[:writer.written], .Not_A_Recipe)

	refusal_length, _ := declaration_eval.output_write_refusal(output[:], .Type_Error, 1, 2, 3, "no")
	expect_output_refused(t, output[:refusal_length], .Not_A_Recipe)

	right := write(output[:], hash, builder, arguments[:length])
	expect_output_refused(t, output[:right - 1], .Damaged_Recipe)
	_, nil_refusal := recipe_spec_of_output(output[:right], nil)
	testing.expect_value(t, nil_refusal, Recipe_Refusal.Buffer_Too_Small)

	// The success case: the hash that the output carries is the hash of
	// the record that the service registers.
	read_hash, refusal := recipe_spec_of_output(output[:right], spec)
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
	spec := new(Recipe_Spec, context.temp_allocator)
	buffer: [512]u8
	writer := declaration_eval.Output_Writer{buffer = buffer[:]}
	record_start(&writer, 4)
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

	reader := declaration_eval.Output_Reader{bytes = spec.arguments[:spec.arguments_length]}
	tag, _ := declaration_eval.output_read_tag(&reader)
	count, _ := declaration_eval.output_read_u32(&reader)
	first, _ := declaration_eval.output_read_string(&reader)
	testing.expect(t, tag == .Record && count == 2 && first == "path", "the arguments are the fields that are no input")

	first_hash, _ := recipe_hash(spec)
	again := new(Recipe_Spec, context.temp_allocator)
	testing.expect_value(t, recipe_spec_of_arguments(builder, buffer[:writer.written], again), Recipe_Refusal.None)
	again_hash, _ := recipe_hash(again)
	testing.expect(t, first_hash == again_hash, "one value gives one hash")

	length := collatz_arguments(buffer[:], conversion_hash(3))
	testing.expect_value(t, recipe_spec_of_arguments(builder, buffer[:length], again), Recipe_Refusal.None)
	other_hash, _ := recipe_hash(again)
	testing.expect(t, other_hash != first_hash, "another tree gives another recipe")
}

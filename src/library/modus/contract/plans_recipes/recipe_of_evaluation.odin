package plans_recipes

import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:contract/object_cache"

// The one identity of a recipe (src/md/features/application_projects.md,
// "One identity for a recipe"): a recipe that a declaration names, as the
// evaluator writes it, becomes the record that the service builds here, and
// its hash is recipe_hash of that record. The evaluator calls the same
// procedure to compute the hash that it writes, so the two cannot differ.

// The field of the arguments that is also the source date of the recipe.
SOURCE_DATE_FIELD :: "source_date"

// The bytes of one input as the evaluator writes it in the argument
// record: the name (a length of 4 bytes and its bytes), the tag and the hash.
INPUT_FIELD_BYTES_MOST :: 4 + MAX_ENTRY_NAME_BYTES + 1 + blake3.HASH_SIZE
// The bytes of the largest argument value that converts: MAX_RECIPE_INPUTS
// inputs whose names have the largest length, and the other fields, whose
// record is MAX_RECIPE_ARG_BYTES with its head. A writer of the arguments
// sizes its buffer by it, so a value that converts always fits.
MAX_RECIPE_ARGUMENT_VALUE_BYTES :: MAX_RECIPE_ARG_BYTES + MAX_RECIPE_INPUTS * INPUT_FIELD_BYTES_MOST
#assert(MAX_RECIPE_ARGUMENT_VALUE_BYTES == 7328)

// recipe_spec_of_arguments gives the record of a recipe from its builder and
// the bytes of its argument value, as the evaluator writes a value: each
// field that is a tree or a module file is an input, under its name and
// with its kind; the other fields are the argument bytes, a record in the
// canonical form of the output. A bare hash names no kind and is refused; so
// is a tree or a module file below the first level, whose input would have
// no name. On a refusal the record is zero.
//
// The caller gives bytes that do not change during the call: the
// evaluator its own buffer, the service a copy in its own memory. The value
// is checked whole first, in its canonical form, and then read again.
recipe_spec_of_arguments :: proc "contextless" (builder: blake3.Hash, arguments: []u8, spec: ^Recipe_Spec) -> Recipe_Refusal {
	if spec == nil {
		return .Buffer_Too_Small
	}
	refusal := spec_of_arguments(builder, arguments, spec)
	if refusal != .None {
		spec^ = {}
	}
	return refusal
}

@(private = "file")
spec_of_arguments :: proc "contextless" (builder: blake3.Hash, arguments: []u8, spec: ^Recipe_Spec) -> Recipe_Refusal {
	spec^ = {}
	spec.builder_hash = builder
	spec.output_kind = .Tree

	// The canonical form of the whole value: names sorted with no name
	// twice at each level, the bounds of a collection and of the nesting,
	// and nothing after the value. One value then has one form.
	whole := declaration_eval.Output_Reader{bytes = arguments}
	if declaration_eval.output_skip_value(&whole, 0) != .None || whole.offset != len(arguments) {
		return .Damaged_Recipe
	}

	reader := declaration_eval.Output_Reader{bytes = arguments}
	if tag, refusal := declaration_eval.output_read_tag(&reader); refusal != .None || tag != .Record {
		return refusal != .None ? .Damaged_Recipe : .Not_A_Recipe
	}
	field_count, count_refusal := declaration_eval.output_read_u32(&reader)
	if count_refusal != .None {
		return .Damaged_Recipe
	}
	fields_start := reader.offset

	// The first walk: the inputs, the checks of the other fields, and their count.
	other_count: u32
	for _ in 0 ..< field_count {
		name, name_refusal := declaration_eval.output_read_string(&reader)
		if name_refusal != .None {
			return .Damaged_Recipe
		}
		value_start := reader.offset
		tag, tag_refusal := declaration_eval.output_read_tag(&reader)
		if tag_refusal != .None {
			return .Damaged_Recipe
		}
		if name == SOURCE_DATE_FIELD && tag != .Integer {
			return .Unsupported_Argument
		}
		switch tag {
		case .Tree_Ref, .Module_Ref:
			hash, hash_refusal := declaration_eval.output_read_hash(&reader)
			if hash_refusal != .None {
				return .Damaged_Recipe
			}
			if spec.input_count >= MAX_RECIPE_INPUTS {
				return .Too_Many_Inputs
			}
			kind := tag == .Tree_Ref ? object_cache.Cache_Object_Kind.Tree : object_cache.Cache_Object_Kind.Blob
			input, input_refusal := recipe_input_make(name, kind, hash)
			if input_refusal != .None {
				return input_refusal
			}
			spec.inputs[spec.input_count] = input
			spec.input_count += 1
		case .Hash:
			return .Untyped_Hash
		case .Integer, .Boolean, .Text, .Member, .Record, .List, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan, .Project:
			reader.offset = value_start
			if refusal := argument_value_check(&reader, 0); refusal != .None {
				return refusal
			}
			if tag == .Integer && name == SOURCE_DATE_FIELD {
				date_reader := declaration_eval.Output_Reader{bytes = arguments, offset = value_start + 1}
				date, date_refusal := declaration_eval.output_read_i64(&date_reader)
				if date_refusal != .None {
					return .Damaged_Recipe
				}
				if date < 0 {
					return .Unsupported_Argument
				}
				spec.source_date_unix = u64(date)
			}
			other_count += 1
		}
	}

	// The second walk: the record of the other fields, in their sorted order.
	writer := declaration_eval.Output_Writer{buffer = spec.arguments[:]}
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, other_count)
	reader.offset = fields_start
	for _ in 0 ..< field_count {
		name_start := reader.offset
		if _, refusal := declaration_eval.output_read_string(&reader); refusal != .None {
			return .Damaged_Recipe
		}
		value_start := reader.offset
		tag, tag_refusal := declaration_eval.output_read_tag(&reader)
		if tag_refusal != .None {
			return .Damaged_Recipe
		}
		reader.offset = value_start
		if declaration_eval.output_skip_value(&reader, 1) != .None {
			return .Damaged_Recipe
		}
		if tag == .Tree_Ref || tag == .Module_Ref {
			continue
		}
		declaration_eval.output_write_bytes(&writer, arguments[name_start:reader.offset])
	}
	if writer.overflow {
		return .Arguments_Too_Large
	}
	spec.arguments_length = u32(writer.written)
	refusal, _ := recipe_validate(spec)
	return refusal
}

// argument_value_check walks an argument that is no input: a value that
// holds a bare hash is refused, a tree or a module file below the first
// level is refused, and so is each kind that a recipe does not take. The
// value was checked whole before, so the bounds hold.
@(private = "file")
argument_value_check :: proc "contextless" (reader: ^declaration_eval.Output_Reader, depth: int) -> Recipe_Refusal {
	if depth >= declaration_eval.OUTPUT_DEPTH_LIMIT {
		return .Damaged_Recipe
	}
	tag, tag_refusal := declaration_eval.output_read_tag(reader)
	if tag_refusal != .None {
		return .Damaged_Recipe
	}
	switch tag {
	case .Integer, .Boolean, .Text, .Member:
		reader.offset -= 1
		if declaration_eval.output_skip_value(reader, depth) != .None {
			return .Damaged_Recipe
		}
		return .None
	case .Hash:
		return .Untyped_Hash
	case .Tree_Ref, .Module_Ref:
		return .Nested_Input
	case .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan, .Project:
		return .Unsupported_Argument
	case .List:
		count, count_refusal := declaration_eval.output_read_u32(reader)
		if count_refusal != .None {
			return .Damaged_Recipe
		}
		for _ in 0 ..< count {
			if refusal := argument_value_check(reader, depth + 1); refusal != .None {
				return refusal
			}
		}
		return .None
	case .Record:
		count, count_refusal := declaration_eval.output_read_u32(reader)
		if count_refusal != .None {
			return .Damaged_Recipe
		}
		for _ in 0 ..< count {
			if _, name_refusal := declaration_eval.output_read_string(reader); name_refusal != .None {
				return .Damaged_Recipe
			}
			if refusal := argument_value_check(reader, depth + 1); refusal != .None {
				return refusal
			}
		}
		return .None
	}
	return .Damaged_Recipe
}

// recipe_spec_of_output gives the record and the hash of the recipe that
// an evaluation gives as its value: the output of declaration_eval whose
// value is a recipe, as outputs.default of a project. The hash that the
// evaluator wrote must be the hash of the record; another one is a damaged
// output. On a refusal the record is zero. The caller gives bytes that do
// not change during the call.
recipe_spec_of_output :: proc "contextless" (output: []u8, spec: ^Recipe_Spec) -> (hash: blake3.Hash, refusal: Recipe_Refusal) {
	if spec == nil {
		return {}, .Buffer_Too_Small
	}
	hash, refusal = spec_of_output(output, spec)
	if refusal != .None {
		spec^ = {}
		return {}, refusal
	}
	return hash, .None
}

@(private = "file")
spec_of_output :: proc "contextless" (output: []u8, spec: ^Recipe_Spec) -> (hash: blake3.Hash, refusal: Recipe_Refusal) {
	spec^ = {}
	header, header_refusal := declaration_eval.output_validate(output)
	if header_refusal != .None {
		return {}, .Damaged_Recipe
	}
	if header.status != .Ok {
		return {}, .Not_A_Recipe
	}
	_, reader, reader_refusal := declaration_eval.output_read_header(output)
	if reader_refusal != .None {
		return {}, .Damaged_Recipe
	}
	if tag, tag_refusal := declaration_eval.output_read_tag(&reader); tag_refusal != .None || tag != .Recipe_Ref {
		return {}, tag_refusal != .None ? .Damaged_Recipe : .Not_A_Recipe
	}
	written, written_refusal := declaration_eval.output_read_hash(&reader)
	builder, builder_refusal := declaration_eval.output_read_hash(&reader)
	if written_refusal != .None || builder_refusal != .None {
		return {}, .Damaged_Recipe
	}
	arguments_start := reader.offset
	if declaration_eval.output_skip_value(&reader, 1) != .None || reader.offset != len(output) {
		return {}, .Damaged_Recipe
	}
	if refusal = recipe_spec_of_arguments(builder, output[arguments_start:reader.offset], spec); refusal != .None {
		return {}, refusal
	}
	hash, refusal = recipe_hash(spec)
	if refusal != .None {
		return {}, refusal
	}
	if hash != written {
		return {}, .Damaged_Recipe
	}
	return hash, .None
}

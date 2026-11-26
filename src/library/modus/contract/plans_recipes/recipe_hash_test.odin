#+build !freestanding
#+build !modus
package plans_recipes

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/object_cache"

@(private = "file")
input_hash_of :: proc(tag: int) -> blake3.Hash {
	bytes := [3]u8{'i', u8(tag >> 8), u8(tag)}
	return blake3.hash(bytes[:])
}

// recipe_of_inputs fills spec with count inputs and argument_bytes bytes of
// arguments, the names in the reverse of their order.
@(private = "file")
recipe_of_inputs :: proc(spec: ^Recipe_Spec, count: int, argument_bytes: int) {
	spec^ = {}
	spec.builder_hash = input_hash_of(9999)
	spec.output_kind = .Tree
	spec.source_date_unix = 1_700_000_000
	spec.output_block_limit = 77
	for index in 0 ..< count {
		reverse := count - 1 - index
		name := [3]u8{'n', 'a' + u8(reverse / 26), 'a' + u8(reverse % 26)}
		spec.inputs[index], _ = recipe_input_make(string(name[:]), index % 2 == 0 ? .Blob : .Tree, input_hash_of(index))
	}
	spec.input_count = u32(count)
	for index in 0 ..< argument_bytes {
		spec.arguments[index] = u8(index * 7)
	}
	spec.arguments_length = u32(argument_bytes)
}

// The recipe hash read in pieces is the hash of the canonical bytes that
// the encoder of the contract writes whole: the form of the hash did not
// change, only the memory that it takes. The edges: no input, 33 inputs
// (past the bound of before), and the largest recipe.
@(test)
the_recipe_hash_is_the_hash_of_its_canonical_bytes :: proc(t: ^testing.T) {
	spec := new(Recipe_Spec, context.temp_allocator)
	canonical := make([]u8, size_of(Recipe_Spec) * 2, context.temp_allocator)
	cases := [?][2]int{{0, 0}, {1, 1}, {33, 4097}, {MAX_RECIPE_INPUTS, MAX_RECIPE_ARG_BYTES}}
	for item in cases {
		recipe_of_inputs(spec, item[0], item[1])
		order: [MAX_RECIPE_INPUTS]u32
		for index in 0 ..< item[0] {
			order[index] = u32(item[0] - 1 - index)
		}
		encoder := Canonical_Encoder{buffer = canonical}
		encoder_raw_bytes(&encoder, spec.builder_hash[:])
		encoder_byte(&encoder, u8(spec.output_kind))
		encoder_u64(&encoder, spec.source_date_unix)
		encoder_u64(&encoder, spec.output_block_limit)
		encoder_u32(&encoder, spec.input_count)
		for position in 0 ..< item[0] {
			input := &spec.inputs[order[position]]
			encoder_bytes(&encoder, input.name_bytes[:input.name_length])
			encoder_byte(&encoder, u8(input.kind))
			encoder_raw_bytes(&encoder, input.hash[:])
		}
		encoder_bytes(&encoder, spec.arguments[:spec.arguments_length])
		testing.expect(t, !encoder.overflow)
		digest, refusal := recipe_hash(spec)
		testing.expect_value(t, refusal, Recipe_Refusal.None)
		testing.expectf(t, digest == blake3.derive_key(RECIPE_HASH_DOMAIN, canonical[:encoder.position]), "%d inputs and %d argument bytes", item[0], item[1])
	}
}

// The bounds of a recipe: one input past MAX_RECIPE_INPUTS, and one byte of
// arguments past MAX_RECIPE_ARG_BYTES, are refused, and the largest recipe
// gives a sandbox with each input in the order of its name.
@(test)
a_recipe_past_its_bounds_is_refused :: proc(t: ^testing.T) {
	spec := new(Recipe_Spec, context.temp_allocator)
	recipe_of_inputs(spec, MAX_RECIPE_INPUTS, MAX_RECIPE_ARG_BYTES)
	spec.input_count = MAX_RECIPE_INPUTS + 1
	refusal, _ := recipe_validate(spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Too_Many_Inputs)
	spec.input_count = MAX_RECIPE_INPUTS
	spec.arguments_length = MAX_RECIPE_ARG_BYTES + 1
	refusal, _ = recipe_validate(spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Arguments_Too_Large)
	spec.arguments_length = MAX_RECIPE_ARG_BYTES

	sandbox := new(Builder_Sandbox_Spec, context.temp_allocator)
	testing.expect_value(t, builder_sandbox_prepare(spec, nil), Recipe_Refusal.Buffer_Too_Small)
	testing.expect_value(t, builder_sandbox_prepare(spec, sandbox), Recipe_Refusal.None)
	testing.expect_value(t, builder_sandbox_validate(sandbox), Recipe_Refusal.None)
	testing.expect_value(t, sandbox.input_count, u32(MAX_RECIPE_INPUTS))
	testing.expect_value(t, sandbox.inputs[0].hash, spec.inputs[MAX_RECIPE_INPUTS - 1].hash)
	testing.expect_value(t, sandbox.arguments_length, u32(MAX_RECIPE_ARG_BYTES))
	// A refused spec leaves a sandbox of zero.
	spec.builder_hash = {}
	testing.expect_value(t, builder_sandbox_prepare(spec, sandbox), Recipe_Refusal.Zero_Builder_Hash)
	testing.expect_value(t, sandbox.input_count, u32(0))
	testing.expect_value(t, sandbox.output_kind, object_cache.Cache_Object_Kind(0))
}

#+build !freestanding
package plans_recipes

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"

@(private = "file")
sample_recipe :: proc(spec: ^Recipe_Spec) {
	spec^ = {}
	spec.builder_hash = blake3.hash(transmute([]u8)string("builder"))
	spec.output_kind = .Tree
	spec.source_date_unix = 1_700_000_000
	spec.output_block_limit = 64
	first, _ := recipe_input_make("source", .Tree, blake3.hash(transmute([]u8)string("source")))
	second, _ := recipe_input_make("compiler", .Blob, blake3.hash(transmute([]u8)string("compiler")))
	// Out of the order of their names: the object is written in that order.
	spec.inputs[0] = first
	spec.inputs[1] = second
	spec.input_count = 2
	copy(spec.arguments[:], "--release")
	spec.arguments_length = 9
}

// Each damaged form of a recipe object is refused: no magic, one byte
// short, one byte more, a kind that names no kind, a count past its bound,
// a name of 0 or 65 bytes, arguments past their bound, and inputs out of
// the order of their names.
@(test)
recipe_object_refuses_each_damaged_form :: proc(t: ^testing.T) {
	spec := new(Recipe_Spec, context.temp_allocator)
	sample_recipe(spec)
	buffer: [MAX_RECIPE_OBJECT_BYTES + 1]u8
	written, refusal := recipe_object_encode(spec, buffer[:])
	testing.expect_value(t, refusal, Recipe_Refusal.None)
	object := buffer[:written]
	decoded := new(Recipe_Spec, context.temp_allocator)

	_, empty := recipe_object_decode(nil, decoded)
	testing.expect_value(t, empty, Recipe_Refusal.Damaged_Recipe)
	no_magic := make([]u8, written, context.temp_allocator)
	copy(no_magic, object)
	no_magic[0] = 'X'
	_, magic_refusal := recipe_object_decode(no_magic, decoded)
	testing.expect_value(t, magic_refusal, Recipe_Refusal.Damaged_Recipe)
	_, short := recipe_object_decode(object[:written - 1], decoded)
	testing.expect_value(t, short, Recipe_Refusal.Damaged_Recipe)
	_, long := recipe_object_decode(buffer[:written + 1], decoded)
	testing.expect_value(t, long, Recipe_Refusal.Damaged_Recipe)
	_, past_bound := recipe_object_decode(buffer[:], decoded)
	testing.expect_value(t, past_bound, Recipe_Refusal.Damaged_Recipe)

	damaged := make([]u8, written, context.temp_allocator)
	head := len(RECIPE_OBJECT_MAGIC) + blake3.HASH_SIZE
	copy(damaged, object)
	damaged[head] = 3
	_, output_kind := recipe_object_decode(damaged, decoded)
	testing.expect_value(t, output_kind, Recipe_Refusal.Bad_Output_Kind)
	copy(damaged, object)
	byte_order.write_u32_little_endian(damaged, head + 17, MAX_RECIPE_INPUTS + 1)
	_, count := recipe_object_decode(damaged, decoded)
	testing.expect_value(t, count, Recipe_Refusal.Too_Many_Inputs)
	first_input := head + 21
	copy(damaged, object)
	byte_order.write_u32_little_endian(damaged, first_input, 0)
	_, zero_name := recipe_object_decode(damaged, decoded)
	testing.expect_value(t, zero_name, Recipe_Refusal.Invalid_Input_Name)
	copy(damaged, object)
	byte_order.write_u32_little_endian(damaged, first_input, MAX_ENTRY_NAME_BYTES + 1)
	_, long_name := recipe_object_decode(damaged, decoded)
	testing.expect_value(t, long_name, Recipe_Refusal.Invalid_Input_Name)
	// The first input is "compiler" (8 bytes): its kind byte follows.
	copy(damaged, object)
	damaged[first_input + 4 + 8] = 0
	_, input_kind := recipe_object_decode(damaged, decoded)
	testing.expect_value(t, input_kind, Recipe_Refusal.Bad_Input_Kind)
	copy(damaged, object)
	byte_order.write_u32_little_endian(damaged, written - 9 - 4, MAX_RECIPE_ARG_BYTES + 1)
	_, arguments := recipe_object_decode(damaged, decoded)
	testing.expect_value(t, arguments, Recipe_Refusal.Arguments_Too_Large)

	// The inputs swapped: the same recipe hash, so not its object.
	swapped := make([]u8, written, context.temp_allocator)
	copy(swapped, object)
	first_size := 4 + 8 + 1 + blake3.HASH_SIZE
	second_size := 4 + 6 + 1 + blake3.HASH_SIZE
	copy(swapped[first_input:], object[first_input + first_size:first_input + first_size + second_size])
	copy(swapped[first_input + second_size:], object[first_input:first_input + first_size])
	_, out_of_order := recipe_object_decode(swapped, decoded)
	testing.expect_value(t, out_of_order, Recipe_Refusal.Damaged_Recipe)
}

// A recipe object gives the recipe hash of its recipe, from its bytes alone.
@(test)
recipe_object_gives_the_recipe_hash :: proc(t: ^testing.T) {
	spec := new(Recipe_Spec, context.temp_allocator)
	sample_recipe(spec)
	expected, hash_refusal := recipe_hash(spec)
	testing.expect_value(t, hash_refusal, Recipe_Refusal.None)
	buffer: [MAX_RECIPE_OBJECT_BYTES]u8
	written, refusal := recipe_object_encode(spec, buffer[:])
	testing.expect_value(t, refusal, Recipe_Refusal.None)
	decoded := new(Recipe_Spec, context.temp_allocator)
	digest, decode_refusal := recipe_object_decode(buffer[:written], decoded)
	testing.expect_value(t, decode_refusal, Recipe_Refusal.None)
	testing.expect(t, digest == expected)
	testing.expect_value(t, decoded.input_count, 2)
	testing.expect_value(t, string(decoded.inputs[0].name_bytes[:decoded.inputs[0].name_length]), "compiler")
	testing.expect_value(t, string(decoded.arguments[:decoded.arguments_length]), "--release")
	again, _ := recipe_hash(decoded)
	testing.expect(t, again == expected)
	// A buffer one byte too small, and an empty one, write nothing.
	small: [MAX_RECIPE_OBJECT_BYTES]u8
	for &value in small {
		value = 0xAA
	}
	for size in ([2]int{written - 1, 0}) {
		none, small_refusal := recipe_object_encode(spec, small[:size])
		testing.expect_value(t, small_refusal, Recipe_Refusal.Buffer_Too_Small)
		testing.expect_value(t, none, 0)
		for value, index in small {
			if value != 0xAA {
				testing.expectf(t, false, "the byte %d of the buffer changed", index)
				break
			}
		}
	}
}

// A hash as text: each length but 64, an uppercase digit and a byte that
// is no digit are refused; 64 lowercase digits give the hash back.
@(test)
hash_of_hexadecimal_refusals_then_round_trip :: proc(t: ^testing.T) {
	digest := blake3.hash([]u8{'h'})
	name := blob_object_name(digest)
	digits: [64]u8
	hex_digits := "0123456789abcdef"
	for value, index in digest {
		digits[2 * index] = hex_digits[value >> 4]
		digits[2 * index + 1] = hex_digits[value & 15]
	}
	for length in ([?]int{0, 1, 63}) {
		_, ok := hash_of_hexadecimal(digits[:length])
		testing.expect(t, !ok)
	}
	longer: [65]u8
	copy(longer[:], digits[:])
	_, long_ok := hash_of_hexadecimal(longer[:])
	testing.expect(t, !long_ok)
	for bad in ([?]u8{'A', 'g', ' ', 0}) {
		wrong := digits
		wrong[10] = bad
		_, ok := hash_of_hexadecimal(wrong[:])
		testing.expectf(t, !ok, "the byte %v is refused", bad)
	}
	back, ok := hash_of_hexadecimal(digits[:])
	testing.expect(t, ok && back == digest)
	testing.expect_value(t, private_object_name_text(&name)[5:], string(digits[:52]))
}

// The object of a recipe in a store has one name, which is not the name of
// a blob of the same hash.
@(test)
recipe_object_name_is_one_name :: proc(t: ^testing.T) {
	digest := blake3.hash([]u8{'r'})
	first := recipe_object_name(digest)
	second := recipe_object_name(digest)
	testing.expect_value(t, private_object_name_text(&first), private_object_name_text(&second))
	blob := blob_object_name(digest)
	testing.expect(t, private_object_name_text(&first) != private_object_name_text(&blob))
}

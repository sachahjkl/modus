#+build !freestanding
package plans_recipes

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"

@(private = "file")
recipe_object_test_spec :: proc() -> (spec: Recipe_Spec) {
	spec.builder_hash = guest_builder_hash()
	spec.output_kind = .Tree
	spec.source_date_unix = 1_700_000_000
	spec.output_block_limit = 16
	spec.input_count = 2
	spec.inputs[0], _ = recipe_input_make("src", .Tree, blake3.hash([]u8{1}))
	spec.inputs[1], _ = recipe_input_make("notes", .Blob, blake3.hash([]u8{2}))
	copy(spec.arguments[:], "make")
	spec.arguments_length = 4
	return
}

// A recipe object that is damaged decodes to nothing: a short object, a
// wrong magic, an output kind that names no kind, a count of inputs past
// the bound, arguments past the bound, a size that does not match the
// counts, an input kind that names no kind, a padding byte that is not 0,
// and a buffer too small for the encoding.
@(test)
recipe_object_refuses_each_damage :: proc(t: ^testing.T) {
	spec := recipe_object_test_spec()
	bytes: [RECIPE_OBJECT_WIRE_MOST]u8
	written, refusal := encode_recipe_object(&spec, bytes[:])
	testing.expect_value(t, refusal, Recipe_Refusal.None)
	_, small := encode_recipe_object(&spec, bytes[:written - 1])
	testing.expect_value(t, small, Recipe_Refusal.Buffer_Too_Small)

	HEAD_COUNTS :: 8 + blake3.HASH_SIZE
	damages := [?]struct {
		at:      int,
		value:   u8,
		refusal: Recipe_Refusal,
	}{
		{0, 'X', .Damaged_Recipe},
		{HEAD_COUNTS, 0xFF, .Bad_Output_Kind},
		{HEAD_COUNTS + 24, 0xFF, .Too_Many_Inputs},
		{HEAD_COUNTS + 29, 0xFF, .Arguments_Too_Large},
		{HEAD_COUNTS + 24, 1, .Damaged_Recipe},
		{RECIPE_OBJECT_HEAD_SIZE, 0xFF, .Bad_Input_Kind},
		{RECIPE_OBJECT_HEAD_SIZE + 2, 1, .Nonzero_Padding},
	}
	for damage in damages {
		damaged := bytes
		damaged[damage.at] = damage.value
		out := Recipe_Spec{output_block_limit = 99}
		got := decode_recipe_object(damaged[:written], &out)
		testing.expectf(t, got == damage.refusal, "a byte %x at %d gives %v, not %v", damage.value, damage.at, got, damage.refusal)
		testing.expect_value(t, out.output_block_limit, u64(0))
	}
	out: Recipe_Spec
	testing.expect_value(t, decode_recipe_object(bytes[:RECIPE_OBJECT_HEAD_SIZE - 1], &out), Recipe_Refusal.Damaged_Recipe)
	testing.expect_value(t, decode_recipe_object(bytes[:written - 1], &out), Recipe_Refusal.Damaged_Recipe)
	testing.expect_value(t, decode_recipe_object(bytes[:written + 1], &out), Recipe_Refusal.Damaged_Recipe)
	testing.expect_value(t, decode_recipe_object(bytes[:written], nil), Recipe_Refusal.Buffer_Too_Small)
	testing.expect_value(t, byte_order.read_u32_little_endian(bytes[:], HEAD_COUNTS + 24), u32(2))
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

// The successful case last: a recipe goes through its object whole, with
// the same recipe hash, and the object of a recipe has one name.
@(test)
recipe_object_keeps_the_recipe_hash :: proc(t: ^testing.T) {
	spec := recipe_object_test_spec()
	bytes: [RECIPE_OBJECT_WIRE_MOST]u8
	written, refusal := encode_recipe_object(&spec, bytes[:])
	testing.expect_value(t, refusal, Recipe_Refusal.None)
	testing.expect_value(t, written, RECIPE_OBJECT_HEAD_SIZE + 2 * RECIPE_OBJECT_INPUT_SIZE + 4)
	decoded: Recipe_Spec
	testing.expect_value(t, decode_recipe_object(bytes[:written], &decoded), Recipe_Refusal.None)
	before, _ := recipe_hash(&spec)
	after, _ := recipe_hash(&decoded)
	testing.expect_value(t, after, before)
	first := recipe_object_name(before)
	second := recipe_object_name(before)
	testing.expect_value(t, private_object_name_text(&first), private_object_name_text(&second))
	blob := blob_object_name(before)
	testing.expect(t, private_object_name_text(&first) != private_object_name_text(&blob))
}

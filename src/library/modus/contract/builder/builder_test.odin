#+build !freestanding
#+build !modus
package builder

import "core:testing"
import "modus:contract/blake3"
import op "modus:contract/operation"

@(private = "file")
recipe_of_test :: proc() -> blake3.Hash {
	text := "a recipe of the test of the builder context"
	return blake3.hash(transmute([]u8)text)
}

// The context that the service recipes makes: each part holds a handle,
// the seed is the recipe hash, its strength None, and the size of the file
// of the storage service is the one other value.
@(private = "file")
context_whole :: proc(recipe: blake3.Hash) -> (holds: [op.CONTEXT_HANDLES]bool, values: [op.CONTEXT_VALUES]u64) {
	for index in CONTEXT_SLOT_INDEX {
		holds[index] = true
	}
	seed := seed_values(recipe)
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		values[op.CONTEXT_VALUE_SEED + index] = seed[index]
	}
	values[op.CONTEXT_VALUE_SEED_STRENGTH] = u64(op.Seed_Strength.None)
	values[VALUE_STORAGE_FILE_SIZE] = 300 * 1024
	return holds, values
}

// Each slot that is no part of the context and holds a handle is refused:
// the first slot, the last slot, a datagram ring of the network (11), the
// slot of the private store of a process (7), the slot of a boot image (3
// is the input region here, so the image has no slot of its own). Each
// part with no handle is refused.
@(test)
a_context_with_a_slot_more_or_less_is_refused :: proc(t: ^testing.T) {
	recipe := recipe_of_test()
	for index in 0 ..< op.CONTEXT_HANDLES {
		holds, values := context_whole(recipe)
		part := false
		for slot_index in CONTEXT_SLOT_INDEX {
			part ||= slot_index == index
		}
		holds[index] = !part
		refusal, slot := context_check(holds, values, recipe)
		testing.expectf(t, refusal == (part ? Context_Refusal.Missing_Slot : Context_Refusal.Extra_Slot) && slot == index, "slot %d: %v at %d", index, refusal, slot)
	}
}

// The seed is the recipe hash: a seed with one bit changed in each of its
// four values is refused, and so is the seed of another recipe. Each
// strength but None is refused, and so is a word past the last member.
@(test)
a_context_whose_seed_is_not_the_recipe_is_refused :: proc(t: ^testing.T) {
	recipe := recipe_of_test()
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		holds, values := context_whole(recipe)
		values[op.CONTEXT_VALUE_SEED + index] ~= 1
		refusal, slot := context_check(holds, values, recipe)
		testing.expect_value(t, refusal, Context_Refusal.Wrong_Seed)
		testing.expect_value(t, slot, op.CONTEXT_VALUE_SEED + index)
	}
	holds, values := context_whole(recipe)
	other := blake3.hash(transmute([]u8)string("another recipe"))
	refusal, _ := context_check(holds, values, other)
	testing.expect_value(t, refusal, Context_Refusal.Wrong_Seed)

	for strength in ([?]u64{u64(op.Seed_Strength.Weak), u64(op.Seed_Strength.Processor), u64(op.Seed_Strength.Entropy), 4, max(u64)}) {
		holds, values = context_whole(recipe)
		values[op.CONTEXT_VALUE_SEED_STRENGTH] = strength
		refusal, _ = context_check(holds, values, recipe)
		testing.expectf(t, refusal == .Wrong_Strength, "strength %d: %v", strength, refusal)
	}
}

// Each value that the context does not hold, not 0, is refused: the first,
// the values of the files of the call host (the call host writes them),
// the value after the strength, and the last.
@(test)
a_context_with_a_value_more_is_refused :: proc(t: ^testing.T) {
	recipe := recipe_of_test()
	for index in ([?]int{0, 1, 2, 3, 5, op.CONTEXT_VALUE_SEED - 1, op.CONTEXT_VALUE_SEED_STRENGTH + 1, op.CONTEXT_VALUES - 1}) {
		holds, values := context_whole(recipe)
		values[index] = 1
		refusal, slot := context_check(holds, values, recipe)
		testing.expectf(t, refusal == .Extra_Value && slot == index, "value %d: %v at %d", index, refusal, slot)
	}
}

// The success case: the whole context is taken.
@(test)
the_context_of_a_builder_is_taken :: proc(t: ^testing.T) {
	recipe := recipe_of_test()
	holds, values := context_whole(recipe)
	refusal, _ := context_check(holds, values, recipe)
	testing.expect_value(t, refusal, Context_Refusal.None)
	seed := seed_values(recipe)
	testing.expect(t, transmute(blake3.Hash)seed == recipe, "the seed is the bytes of the recipe hash")
}

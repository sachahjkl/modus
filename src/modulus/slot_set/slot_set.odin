// A set of slots of a kernel table: one bit for each slot, in words of 64
// bits. The kernel keeps sets of process slots: the process locks that a
// processor holds, the processes whose last handle closed, the processes
// that a revocation touched, the processes that a stop reached. One word
// held each of these sets while the machine had 64 process slots. A table of
// any size needs one bit for each slot, so the set is an array of words
// whose count the compiler fixes from the capacity.
//
// The zero value is the empty set. A slot past the capacity is never in
// the set: `add` refuses it and `has` says false, so a caller that passes a
// wrong slot changes nothing.
//
// The kernel holds the locks: this package reads and writes plain words,
// except add_atomic and copy_atomic, for a set that several processors
// write with no common lock.
//
// This package allocates no memory and calls no kernel operation.
package slot_set

import "base:intrinsics"

// A set of the slots 0 to capacity - 1.
Slot_Set :: struct($capacity: int) where capacity > 0 {
	words: [(capacity + 63) / 64]u64,
}

// word_of gives the index of the word that holds the bit of a slot.
word_of :: #force_inline proc "contextless" (slot: u32) -> u32 {
	return slot / 64
}

// bit_of gives the bit of a slot in its word.
bit_of :: #force_inline proc "contextless" (slot: u32) -> u64 {
	return u64(1) << (slot % 64)
}

// add puts a slot in the set. false: the slot is past the capacity, and
// the set does not change.
add :: proc "contextless" (set: ^Slot_Set($N), slot: u32) -> bool {
	if u64(slot) >= u64(N) {
		return false
	}
	set.words[word_of(slot)] |= bit_of(slot)
	return true
}

// remove takes a slot out of the set. A slot past the capacity changes
// nothing.
remove :: proc "contextless" (set: ^Slot_Set($N), slot: u32) {
	if u64(slot) >= u64(N) {
		return
	}
	set.words[word_of(slot)] &~= bit_of(slot)
}

// has says if a slot is in the set. A slot past the capacity is not.
has :: proc "contextless" (set: ^Slot_Set($N), slot: u32) -> bool {
	if u64(slot) >= u64(N) {
		return false
	}
	return set.words[word_of(slot)] & bit_of(slot) != 0
}

// empty says if the set holds no slot.
empty :: proc "contextless" (set: ^Slot_Set($N)) -> bool {
	for word in set.words {
		if word != 0 {
			return false
		}
	}
	return true
}

// first gives the lowest slot of the set. found is false for an empty set.
first :: proc "contextless" (set: ^Slot_Set($N)) -> (slot: u32, found: bool) {
	for word, index in set.words {
		if word != 0 {
			return u32(index) * 64 + u32(intrinsics.count_trailing_zeros(word)), true
		}
	}
	return 0, false
}

// take gives the lowest slot of the set and takes it out. found is false
// for an empty set.
take :: proc "contextless" (set: ^Slot_Set($N)) -> (slot: u32, found: bool) {
	slot, found = first(set)
	if found {
		remove(set, slot)
	}
	return
}

// add_atomic puts a slot in a set that other processors write at the same
// time, with one atomic or. false: the slot is past the capacity.
add_atomic :: proc "contextless" (set: ^Slot_Set($N), slot: u32) -> bool {
	if u64(slot) >= u64(N) {
		return false
	}
	intrinsics.atomic_or(&set.words[word_of(slot)], bit_of(slot))
	return true
}

// remove_atomic takes a slot out of a set that other processors read at
// the same time, with one atomic and. A slot past the capacity changes
// nothing.
remove_atomic :: proc "contextless" (set: ^Slot_Set($N), slot: u32) {
	if u64(slot) >= u64(N) {
		return
	}
	intrinsics.atomic_and(&set.words[word_of(slot)], ~bit_of(slot))
}

// copy_atomic gives a copy of a set that other processors write, each word
// read whole. A slot that a writer adds during the copy can be missing.
copy_atomic :: proc "contextless" (set: ^Slot_Set($N)) -> (copied: Slot_Set(N)) {
	for &word, index in set.words {
		copied.words[index] = intrinsics.atomic_load(&word)
	}
	return
}

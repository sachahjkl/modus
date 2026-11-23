package kernel

import "base:intrinsics"
import "modulus:slot_set"

// The sets of slots that several processors write with no common lock: the
// holders of a process (handle_insert, which holds the lock of the process
// that holds the handle, not of the process that it names) and the Ports
// handles of a process. The kernel part slot_set keeps no atomics, as it
// reaches no machine; these give the word and the bit of a slot to the
// atomics of the kernel.

// slot_set_add_shared puts a slot in a set that other processors write at
// the same time, with one atomic or. false: the slot is past the capacity.
slot_set_add_shared :: proc "contextless" (set: ^slot_set.Slot_Set($N), slot: u32) -> bool {
	word, bit := slot_set.word_place(set, slot) or_return
	intrinsics.atomic_or(word, bit)
	return true
}

// slot_set_remove_shared takes a slot out of a set that other processors
// read at the same time, with one atomic and. A slot past the capacity
// changes nothing.
slot_set_remove_shared :: proc "contextless" (set: ^slot_set.Slot_Set($N), slot: u32) {
	if word, bit, ok := slot_set.word_place(set, slot); ok {
		intrinsics.atomic_and(word, ~bit)
	}
}

// slot_set_copy_shared gives a copy of a set that other processors write,
// each word read whole. A slot that a writer adds during the copy can be
// missing.
slot_set_copy_shared :: proc "contextless" (set: ^slot_set.Slot_Set($N)) -> (copied: slot_set.Slot_Set(N)) {
	for &word, index in set.words {
		copied.words[index] = intrinsics.atomic_load(&word)
	}
	return
}

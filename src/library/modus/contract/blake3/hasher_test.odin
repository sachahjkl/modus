#+build !freestanding
package blake3

import "core:testing"

// The incremental hash gives the hash of the whole input for each size at
// an edge of a block, of a chunk and of a subtree, whatever the cut of the
// pieces: one byte at a time, a cut at each block, and pieces of a size
// that crosses the blocks and the chunks.
@(test)
the_hash_in_pieces_is_the_hash_of_the_whole :: proc(t: ^testing.T) {
	input := make([]u8, 1024 * 1024 + 1)
	defer delete(input)
	for &b, i in input {
		b = u8(i % 251)
	}
	// The pieces of the writers of the system come after the edges of the
	// hash: 32 KiB (a piece of module_files), 64 KiB and 1 MiB (a step of
	// its commits), each with one byte less and one more.
	sizes := [?]int{0, 1, 63, 64, 65, 1023, 1024, 1025, 2047, 2048, 2049, 3072, 3073, 4096, 4097, 8192, 8193, 9 * CHUNK_SIZE + 3, 32 * 1024 - 1, 32 * 1024, 32 * 1024 + 1, 64 * 1024, 1024 * 1024, 1024 * 1024 + 1}
	pieces := [?]int{1, 7, 64, 65, 1000, 1024, 5000, 32 * 1024}
	for size in sizes {
		whole := hash(input[:size])
		for piece in pieces {
			hasher := hasher_make()
			for at := 0; at < size; at += piece {
				hasher_update(&hasher, input[at:min(at + piece, size)])
			}
			testing.expectf(t, hasher_finish(&hasher) == whole, "a size of %d in pieces of %d", size, piece)
		}
		derived := hasher_make_derive_key("modus test context")
		hasher_update(&derived, input[:size / 2])
		hasher_update(&derived, input[size / 2:size])
		testing.expectf(t, hasher_finish(&derived) == derive_key("modus test context", input[:size]), "derive_key of %d", size)
		key := hash(input[:3])
		keyed := hasher_make_keyed(key)
		hasher_update(&keyed, input[:size])
		testing.expectf(t, hasher_finish(&keyed) == keyed_hash(key, input[:size]), "keyed_hash of %d", size)
	}
	// An empty piece changes nothing, and a finish keeps the state.
	hasher := hasher_make()
	hasher_update(&hasher, input[:100])
	hasher_update(&hasher, nil)
	testing.expect(t, hasher_finish(&hasher) == hash(input[:100]))
	hasher_update(&hasher, input[100:2000])
	testing.expect(t, hasher_finish(&hasher) == hash(input[:2000]))
}

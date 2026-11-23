package blake3

// The incremental form of the hash: an input that comes in pieces gives the
// same hash as the whole input given to `hash`, `derive_key` or
// `keyed_hash`. A reader of a module file of 64 MiB, or of a
// canonical record of any size, then holds a piece of memory and not the
// whole input.
//
// It follows the incremental algorithm of the BLAKE3 specification
// (section 5.1.2): the chaining values of the whole subtrees wait on a
// stack, and a new chunk joins each subtree that it completes. It allocates
// no memory: the hasher is about 1.9 KiB, in the memory of the caller.
//
// Example:
//
// ```odin
// hasher := blake3.hasher_make()
// blake3.hasher_update(&hasher, first_piece)
// blake3.hasher_update(&hasher, second_piece)
// digest := blake3.hasher_finish(&hasher)
// ```

// The chaining values that wait: one for each bit of a count of chunks of
// 64 bits, less the 10 bits of a chunk.
@(private)
HASHER_STACK_CAPACITY :: 54

// The state of one hash of an input that comes in pieces. The zero value is
// not a hasher: make one with hasher_make, hasher_make_derive_key or
// hasher_make_keyed.
Hasher :: struct {
	key:               [8]u32,
	domain_flags:      Flags,
	chunk_value:       [8]u32, // The chaining value of the chunk so far.
	chunk_counter:     u64,
	block:             [BLOCK_SIZE]u8,
	block_length:      int,
	blocks_compressed: int, // The whole blocks of the chunk that were compressed.
	stack:             [HASHER_STACK_CAPACITY][8]u32,
	stack_length:      int,
}

// hasher_make gives a hasher of the plain hash: the hash of its input is
// hash(input).
hasher_make :: proc "contextless" () -> Hasher {
	return hasher_with_key(INITIAL_VALUE, {})
}

// hasher_make_derive_key gives a hasher of derive_key(context_string, input).
hasher_make_derive_key :: proc "contextless" (context_string: string) -> Hasher {
	context_key := root_words_with_key(transmute([]u8)context_string, INITIAL_VALUE, {.Derive_Key_Context})
	return hasher_with_key(context_key, {.Derive_Key_Material})
}

// hasher_make_keyed gives a hasher of keyed_hash(key, input).
hasher_make_keyed :: proc "contextless" (key: Hash) -> Hasher {
	key_words: [8]u32
	for index in 0 ..< 8 {
		key_words[index] = u32(key[index * 4]) | u32(key[index * 4 + 1]) << 8 | u32(key[index * 4 + 2]) << 16 | u32(key[index * 4 + 3]) << 24
	}
	return hasher_with_key(key_words, {.Keyed_Hash})
}

@(private)
hasher_with_key :: proc "contextless" (key: [8]u32, domain_flags: Flags) -> Hasher {
	return {key = key, domain_flags = domain_flags, chunk_value = key}
}

// hasher_update adds the bytes of input after the bytes that came before.
hasher_update :: proc "contextless" (hasher: ^Hasher, input: []u8) {
	rest := input
	for len(rest) > 0 {
		// A whole chunk is closed only when a byte follows it: the last
		// chunk of the input is the root when it is the only one.
		if hasher_chunk_length(hasher) == CHUNK_SIZE {
			value := first_half(hasher_chunk_compress(hasher, {}))
			hasher_chunk_value_add(hasher, value)
			hasher.chunk_counter += 1
			hasher.chunk_value = hasher.key
			hasher.block_length = 0
			hasher.blocks_compressed = 0
		}
		// A whole block is compressed only when a byte follows it: the
		// last block of a chunk takes the flag of its end.
		if hasher.block_length == BLOCK_SIZE {
			hasher.chunk_value = first_half(compress(hasher.chunk_value, block_words(&hasher.block), hasher.chunk_counter, BLOCK_SIZE, hasher_block_flags(hasher)))
			hasher.blocks_compressed += 1
			hasher.block_length = 0
		}
		taken := min(BLOCK_SIZE - hasher.block_length, len(rest))
		copy(hasher.block[hasher.block_length:][:taken], rest[:taken])
		hasher.block_length += taken
		rest = rest[taken:]
	}
}

// hasher_finish gives the hash of each byte that hasher_update took. The
// hasher keeps its state: more bytes can follow, and a later finish gives
// the hash of the longer input.
hasher_finish :: proc "contextless" (hasher: ^Hasher) -> Hash {
	if hasher.stack_length == 0 {
		return words_to_hash(first_half(hasher_chunk_compress(hasher, {.Root})))
	}
	value := first_half(hasher_chunk_compress(hasher, {}))
	for index := hasher.stack_length - 1; index > 0; index -= 1 {
		value = first_half(compress(hasher.key, parent_block(hasher.stack[index], value), 0, BLOCK_SIZE, hasher.domain_flags + {.Parent}))
	}
	return words_to_hash(first_half(compress(hasher.key, parent_block(hasher.stack[0], value), 0, BLOCK_SIZE, hasher.domain_flags + {.Parent, .Root})))
}

@(private)
hasher_chunk_length :: proc "contextless" (hasher: ^Hasher) -> int {
	return hasher.blocks_compressed * BLOCK_SIZE + hasher.block_length
}

@(private)
hasher_block_flags :: proc "contextless" (hasher: ^Hasher) -> Flags {
	return hasher.blocks_compressed == 0 ? hasher.domain_flags + {.Chunk_Start} : hasher.domain_flags
}

// hasher_chunk_compress compresses the last block of the chunk, with the
// flag of the end of a chunk and last_flags.
@(private)
hasher_chunk_compress :: proc "contextless" (hasher: ^Hasher, last_flags: Flags) -> [16]u32 {
	padded: [BLOCK_SIZE]u8
	copy(padded[:hasher.block_length], hasher.block[:hasher.block_length])
	return compress(hasher.chunk_value, block_words(&padded), hasher.chunk_counter, u32(hasher.block_length), hasher_block_flags(hasher) + {.Chunk_End} + last_flags)
}

// hasher_chunk_value_add pushes the chaining value of a whole chunk, and
// joins each subtree that it completes: the count of the chunks says how
// many, by its zero bits at the end.
@(private)
hasher_chunk_value_add :: proc "contextless" (hasher: ^Hasher, chunk_value: [8]u32) {
	value := chunk_value
	total := hasher.chunk_counter + 1
	for total & 1 == 0 {
		hasher.stack_length -= 1
		value = first_half(compress(hasher.key, parent_block(hasher.stack[hasher.stack_length], value), 0, BLOCK_SIZE, hasher.domain_flags + {.Parent}))
		total >>= 1
	}
	hasher.stack[hasher.stack_length] = value
	hasher.stack_length += 1
}

@(private)
block_words :: proc "contextless" (bytes: ^[BLOCK_SIZE]u8) -> (block: [16]u32) {
	for index in 0 ..< 16 {
		block[index] = u32(bytes[index * 4]) | u32(bytes[index * 4 + 1]) << 8 | u32(bytes[index * 4 + 2]) << 16 | u32(bytes[index * 4 + 3]) << 24
	}
	return
}

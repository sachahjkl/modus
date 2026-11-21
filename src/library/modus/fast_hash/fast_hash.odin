// A fast hash of short keys for the tables in memory: rapidhash V3, the
// form `rapidhash_withSeed` with its default build choices (compact,
// fast), rewritten in Odin from its published algorithm
// (src/md/data/swiss_table.md, "The hash"). It gives the bytes of the
// reference for every input, so the test vectors of the reference check it.
//
// It is not a hash of identity or of security: BLAKE3 stays for those. A
// table whose keys another party chooses takes a seed that the party does
// not know.
package fast_hash

import "base:intrinsics"

// The default secret words of rapidhash.
SECRET :: [8]u64 {
	0x2d35_8dcc_aa6c_78a5,
	0x8bb8_4b93_962e_acc9,
	0x4b33_a62e_d433_d4a3,
	0x4d5a_2da5_1de1_aa47,
	0xa076_1d64_78bd_642f,
	0xe703_7ed1_a0b4_28db,
	0x90ed_1765_281c_388c,
	0xaaaa_aaaa_aaaa_aaaa,
}

// multiply_wide gives the 128-bit product of two words in two halves.
multiply_wide :: #force_inline proc "contextless" (a, b: u64) -> (low, high: u64) {
	product := u128(a) * u128(b)
	return u64(product), u64(product >> 64)
}

// multiply_and_fold gives the two halves of the product, joined by xor.
multiply_and_fold :: #force_inline proc "contextless" (a, b: u64) -> u64 {
	low, high := multiply_wide(a, b)
	return low ~ high
}

@(private)
read_u64 :: #force_inline proc "contextless" (data: [^]u8, place: int) -> u64 {
	return u64(intrinsics.unaligned_load((^u64le)(&data[place])))
}

@(private)
read_u32 :: #force_inline proc "contextless" (data: [^]u8, place: int) -> u64 {
	return u64(intrinsics.unaligned_load((^u32le)(&data[place])))
}

// seed_prepare gives the prepared seed of a seed: the first step of the
// hash, which depends on the seed only. A table computes it once.
seed_prepare :: #force_inline proc "contextless" (seed: u64) -> u64 {
	secret := SECRET
	return seed ~ multiply_and_fold(seed ~ secret[2], secret[1])
}

// hash_bytes gives the hash of bytes with a seed: rapidhash_withSeed.
hash_bytes :: proc "contextless" (bytes: []u8, seed: u64) -> u64 {
	return hash_bytes_with_prepared_seed(bytes, seed_prepare(seed))
}

// hash_bytes_with_prepared_seed gives the hash of bytes with a seed that
// seed_prepare gave. Any word is a valid prepared seed: a table whose
// memory starts at zero hashes with the prepared seed 0.
hash_bytes_with_prepared_seed :: #force_inline proc "contextless" (bytes: []u8, prepared_seed: u64) -> u64 #no_bounds_check {
	secret := SECRET
	data := raw_data(bytes)
	length := len(bytes)
	seed := prepared_seed
	a, b: u64
	remaining := length
	if length <= 16 {
		if length >= 8 {
			seed ~= u64(length)
			a = read_u64(data, 0)
			b = read_u64(data, length - 8)
		} else if length >= 4 {
			seed ~= u64(length)
			a = read_u32(data, 0)
			b = read_u32(data, length - 4)
		} else if length > 0 {
			a = u64(data[0]) << 45 | u64(data[length - 1])
			b = u64(data[length >> 1])
		}
	} else {
		place := 0
		if length > 112 {
			see1, see2, see3, see4, see5, see6 := seed, seed, seed, seed, seed, seed
			for {
				seed = multiply_and_fold(read_u64(data, place) ~ secret[0], read_u64(data, place + 8) ~ seed)
				see1 = multiply_and_fold(read_u64(data, place + 16) ~ secret[1], read_u64(data, place + 24) ~ see1)
				see2 = multiply_and_fold(read_u64(data, place + 32) ~ secret[2], read_u64(data, place + 40) ~ see2)
				see3 = multiply_and_fold(read_u64(data, place + 48) ~ secret[3], read_u64(data, place + 56) ~ see3)
				see4 = multiply_and_fold(read_u64(data, place + 64) ~ secret[4], read_u64(data, place + 72) ~ see4)
				see5 = multiply_and_fold(read_u64(data, place + 80) ~ secret[5], read_u64(data, place + 88) ~ see5)
				see6 = multiply_and_fold(read_u64(data, place + 96) ~ secret[6], read_u64(data, place + 104) ~ see6)
				place += 112
				remaining -= 112
				if remaining <= 112 {
					break
				}
			}
			seed ~= see1
			see2 ~= see3
			see4 ~= see5
			seed ~= see6
			see2 ~= see4
			seed ~= see2
		}
		if remaining > 16 {
			seed = multiply_and_fold(read_u64(data, place) ~ secret[2], read_u64(data, place + 8) ~ seed)
			if remaining > 32 {
				seed = multiply_and_fold(read_u64(data, place + 16) ~ secret[2], read_u64(data, place + 24) ~ seed)
				if remaining > 48 {
					seed = multiply_and_fold(read_u64(data, place + 32) ~ secret[1], read_u64(data, place + 40) ~ seed)
					if remaining > 64 {
						seed = multiply_and_fold(read_u64(data, place + 48) ~ secret[1], read_u64(data, place + 56) ~ seed)
						if remaining > 80 {
							seed = multiply_and_fold(read_u64(data, place + 64) ~ secret[2], read_u64(data, place + 72) ~ seed)
							if remaining > 96 {
								seed = multiply_and_fold(read_u64(data, place + 80) ~ secret[1], read_u64(data, place + 88) ~ seed)
							}
						}
					}
				}
			}
		}
		// After the loop of 112 bytes, fewer than 16 bytes can remain: the
		// last 16 bytes then start before the place, inside the input.
		a = read_u64(data, place + remaining - 16) ~ u64(remaining)
		b = read_u64(data, place + remaining - 8)
	}
	a ~= secret[1]
	b ~= seed
	a, b = multiply_wide(a, b)
	return multiply_and_fold(a ~ secret[7], b ~ secret[1] ~ u64(remaining))
}

// mix_word_with_prepared_seed gives a hash of one word with one folded
// multiply, the mix of an integer key in Abseil: the word with the seed,
// times an odd secret word, the two halves of the product joined. Each bit
// of the word moves the high half, so the tag and the group of a table
// both depend on each bit. Half the cost of hash_word_with_prepared_seed,
// and not rapidhash: its value is not the hash of the 8 bytes.
mix_word_with_prepared_seed :: #force_inline proc "contextless" (word: u64, prepared_seed: u64) -> u64 {
	secret := SECRET
	return multiply_and_fold(word ~ prepared_seed, secret[0])
}

// hash_word_with_prepared_seed gives the hash of the 8 bytes of a word in little-endian order
// with a prepared seed: hash_bytes_with_prepared_seed of those bytes, with
// no read from memory.
hash_word_with_prepared_seed :: #force_inline proc "contextless" (word: u64, prepared_seed: u64) -> u64 {
	secret := SECRET
	a := word ~ secret[1]
	b := word ~ prepared_seed ~ 8
	a, b = multiply_wide(a, b)
	return multiply_and_fold(a ~ secret[7], b ~ secret[1] ~ 8)
}

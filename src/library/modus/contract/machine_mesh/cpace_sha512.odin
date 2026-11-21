// Pure freestanding FIPS 180-4 SHA-512 used by CPaceRistretto255
// (IRTF draft-irtf-cfrg-cpace).
//
// Zero allocations, no core: imports, and explicit volatile erasure of hash
// state after finalization because CPace hashes secret pairing codes and
// shared curve points.
package machine_mesh

import "modus:contract/byte_order"

// Fixed SHA-512 block and digest sizes in bytes.
SHA512_BLOCK_SIZE :: 128
SHA512_DIGEST_SIZE :: 64

// Incremental SHA-512 hashing state.
Sha512_State :: struct {
	chain:         [8]u64,
	block:         [SHA512_BLOCK_SIZE]u8,
	block_used:    int,
	total_low:     u64,
	total_high:    u64,
}

@(private = "file", rodata)
SHA512_INITIAL_VALUE := [8]u64 {
	0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
	0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
}

@(private = "file", rodata)
SHA512_ROUND_CONSTANTS := [80]u64 {
	0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
	0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
	0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
	0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
	0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
	0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
	0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
	0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
	0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
	0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
	0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
	0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
	0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
	0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
	0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
	0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
	0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
	0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
	0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
	0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
}

@(private = "file")
rotate_right_64 :: #force_inline proc "contextless" (value: u64, amount: u64) -> u64 {
	return (value >> amount) | (value << (64 - amount))
}

@(private = "file")
sha512_compress :: proc "contextless" (chain: ^[8]u64, block: []u8) {
	words: [80]u64
	for index in 0 ..< 16 {
		words[index] = byte_order.read_u64_big_endian(block, index * 8)
	}
	for index in 16 ..< 80 {
		w15 := words[index - 15]
		w2 := words[index - 2]
		s0 := rotate_right_64(w15, 1) ~ rotate_right_64(w15, 8) ~ (w15 >> 7)
		s1 := rotate_right_64(w2, 19) ~ rotate_right_64(w2, 61) ~ (w2 >> 6)
		words[index] = words[index - 16] + s0 + words[index - 7] + s1
	}

	a := chain[0]
	b := chain[1]
	c := chain[2]
	d := chain[3]
	e := chain[4]
	f := chain[5]
	g := chain[6]
	h := chain[7]

	constants := SHA512_ROUND_CONSTANTS
	for round in 0 ..< 80 {
		sum1 := rotate_right_64(e, 14) ~ rotate_right_64(e, 18) ~ rotate_right_64(e, 41)
		choose := (e & f) ~ ((~e) & g)
		temp1 := h + sum1 + choose + constants[round] + words[round]
		sum0 := rotate_right_64(a, 28) ~ rotate_right_64(a, 34) ~ rotate_right_64(a, 39)
		majority := (a & b) ~ (a & c) ~ (b & c)
		temp2 := sum0 + majority

		h = g
		g = f
		f = e
		e = d + temp1
		d = c
		c = b
		b = a
		a = temp1 + temp2
	}

	chain[0] += a
	chain[1] += b
	chain[2] += c
	chain[3] += d
	chain[4] += e
	chain[5] += f
	chain[6] += g
	chain[7] += h

	clear_bytes_explicitly(([^]u8)(&words[0])[:size_of(words)])
}

// sha512_init initializes a fresh SHA-512 state.
sha512_init :: proc "contextless" (state: ^Sha512_State) {
	state.chain = SHA512_INITIAL_VALUE
	state.block = {}
	state.block_used = 0
	state.total_low = 0
	state.total_high = 0
}

// sha512_clear erases all internal SHA-512 state bytes.
sha512_clear :: proc "contextless" (state: ^Sha512_State) {
	clear_bytes_explicitly(([^]u8)(state)[:size_of(Sha512_State)])
}

// sha512_update absorbs input bytes into state.
sha512_update :: proc "contextless" (state: ^Sha512_State, input: []u8) {
	if len(input) == 0 {
		return
	}
	add_len := u64(len(input))
	prev_low := state.total_low
	state.total_low += add_len
	if state.total_low < prev_low {
		state.total_high += 1
	}

	rest := input
	if state.block_used > 0 {
		take := min(len(rest), SHA512_BLOCK_SIZE - state.block_used)
		copy(state.block[state.block_used:state.block_used + take], rest[:take])
		state.block_used += take
		rest = rest[take:]
		if state.block_used == SHA512_BLOCK_SIZE {
			sha512_compress(&state.chain, state.block[:])
			state.block_used = 0
		}
	}

	for len(rest) >= SHA512_BLOCK_SIZE {
		sha512_compress(&state.chain, rest[:SHA512_BLOCK_SIZE])
		rest = rest[SHA512_BLOCK_SIZE:]
	}

	if len(rest) > 0 {
		copy(state.block[:len(rest)], rest)
		state.block_used = len(rest)
	}
}

// sha512_final finalizes state, returns the 64-byte digest, and erases state.
sha512_final :: proc "contextless" (state: ^Sha512_State) -> (digest: [SHA512_DIGEST_SIZE]u8) {
	bits_high := (state.total_high << 3) | (state.total_low >> 61)
	bits_low := state.total_low << 3

	state.block[state.block_used] = 0x80
	state.block_used += 1

	if state.block_used > SHA512_BLOCK_SIZE - 16 {
		for index in state.block_used ..< SHA512_BLOCK_SIZE {
			state.block[index] = 0
		}
		sha512_compress(&state.chain, state.block[:])
		state.block_used = 0
	}

	for index in state.block_used ..< SHA512_BLOCK_SIZE - 16 {
		state.block[index] = 0
	}
	byte_order.write_u64_big_endian(state.block[:], SHA512_BLOCK_SIZE - 16, bits_high)
	byte_order.write_u64_big_endian(state.block[:], SHA512_BLOCK_SIZE - 8, bits_low)
	sha512_compress(&state.chain, state.block[:])

	for index in 0 ..< 8 {
		byte_order.write_u64_big_endian(digest[:], index * 8, state.chain[index])
	}
	sha512_clear(state)
	return digest
}

// sha512_sum computes the SHA-512 digest of a single contiguous slice.
sha512_sum :: proc "contextless" (input: []u8) -> [SHA512_DIGEST_SIZE]u8 {
	state: Sha512_State
	sha512_init(&state)
	sha512_update(&state, input)
	return sha512_final(&state)
}

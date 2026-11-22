// Self-contained SHA-256, HMAC-SHA-256, constant-time equality, and
// constant-time AES-128-CFB primitives for TPM 2.0 salted sessions, remote
// attestation quote verification, and policy authorization
// (src/md/features/tpm_sealed_machine_key.md).
//
// Contract packages import only base: and modus:contract/* so they remain
// freestanding and zero-allocation across the boot program, kernel, and
// services. AES-128 computes the S-box algebraically in GF(2^8) with no
// secret-indexed lookup tables.
package tpm_attestation

import "modus:contract/byte_order"

SHA256_SIZE :: 32
SHA256_BLOCK_SIZE :: 64
AES128_KEY_SIZE :: 16
AES128_BLOCK_SIZE :: 16
AES128_ROUNDS :: 10

// A 32-byte SHA-256 digest or HMAC-SHA-256 tag.
Digest :: [SHA256_SIZE]u8

// Streaming SHA-256 state with fixed inline block buffer.
Sha256_State :: struct {
	state:       [8]u32,
	block:       [SHA256_BLOCK_SIZE]u8,
	block_len:   int,
	total_bytes: u64,
}

// Streaming HMAC-SHA-256 state built over two Sha256_State instances.
Hmac_Sha256_State :: struct {
	inner:    Sha256_State,
	outer:    Sha256_State,
}

@(private, rodata)
SHA256_INITIAL_STATE := [8]u32 {
	0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
	0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
}

@(private, rodata)
SHA256_ROUND_CONSTANTS := [64]u32 {
	0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5,
	0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
	0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3,
	0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
	0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC,
	0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
	0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7,
	0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
	0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13,
	0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
	0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3,
	0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
	0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5,
	0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
	0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208,
	0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
}

@(private)
rotr32 :: #force_inline proc "contextless" (value: u32, shift: uint) -> u32 {
	return (value >> shift) | (value << (32 - shift))
}

@(private)
rotl8 :: #force_inline proc "contextless" (value: u8, shift: uint) -> u8 {
	return (value << shift) | (value >> (8 - shift))
}

// constant_time_equal compares two byte slices without early exit so timing
// does not leak secret digests, nonces, or HMAC tags.
@(optimization_mode = "none")
constant_time_equal :: proc "contextless" (left, right: []u8) -> bool {
	if len(left) != len(right) {
		return false
	}
	diff: u8 = 0
	for index in 0 ..< len(left) {
		diff |= left[index] ~ right[index]
	}
	return diff == 0
}

// is_all_zero reports whether every byte in data is zero without early exit.
@(optimization_mode = "none")
is_all_zero :: proc "contextless" (data: []u8) -> bool {
	acc: u8 = 0
	for value in data {
		acc |= value
	}
	return acc == 0
}

// zero_bytes overwrites data with zeroes without allowing dead-store elimination.
@(optimization_mode = "none")
zero_bytes :: proc "contextless" (data: []u8) {
	for index in 0 ..< len(data) {
		data[index] = 0
	}
}

// sha256_init resets state to the FIPS 180-4 SHA-256 initial vector.
sha256_init :: proc "contextless" (ctx: ^Sha256_State) {
	ctx.state = SHA256_INITIAL_STATE
	ctx.block = {}
	ctx.block_len = 0
	ctx.total_bytes = 0
}

@(private)
sha256_compress :: proc "contextless" (ctx: ^Sha256_State, block: []u8) {
	w: [64]u32
	for i in 0 ..< 16 {
		w[i] = byte_order.read_u32_big_endian(block, i * 4)
	}
	for i in 16 ..< 64 {
		s0 := rotr32(w[i - 15], 7) ~ rotr32(w[i - 15], 18) ~ (w[i - 15] >> 3)
		s1 := rotr32(w[i - 2], 17) ~ rotr32(w[i - 2], 19) ~ (w[i - 2] >> 10)
		w[i] = w[i - 16] + s0 + w[i - 7] + s1
	}

	a := ctx.state[0]
	b := ctx.state[1]
	c := ctx.state[2]
	d := ctx.state[3]
	e := ctx.state[4]
	f := ctx.state[5]
	g := ctx.state[6]
	h := ctx.state[7]

	for i in 0 ..< 64 {
		s1 := rotr32(e, 6) ~ rotr32(e, 11) ~ rotr32(e, 25)
		ch := (e & f) ~ ((~e) & g)
		temp1 := h + s1 + ch + SHA256_ROUND_CONSTANTS[i] + w[i]
		s0 := rotr32(a, 2) ~ rotr32(a, 13) ~ rotr32(a, 22)
		maj := (a & b) ~ (a & c) ~ (b & c)
		temp2 := s0 + maj

		h = g
		g = f
		f = e
		e = d + temp1
		d = c
		c = b
		b = a
		a = temp1 + temp2
	}

	ctx.state[0] += a
	ctx.state[1] += b
	ctx.state[2] += c
	ctx.state[3] += d
	ctx.state[4] += e
	ctx.state[5] += f
	ctx.state[6] += g
	ctx.state[7] += h
}

// sha256_update absorbs arbitrary bytes into the SHA-256 state.
sha256_update :: proc "contextless" (ctx: ^Sha256_State, data: []u8) {
	if len(data) == 0 {
		return
	}
	ctx.total_bytes += u64(len(data))
	offset := 0
	if ctx.block_len > 0 {
		need := SHA256_BLOCK_SIZE - ctx.block_len
		take := min(need, len(data))
		copy(ctx.block[ctx.block_len:], data[:take])
		ctx.block_len += take
		offset += take
		if ctx.block_len == SHA256_BLOCK_SIZE {
			sha256_compress(ctx, ctx.block[:])
			ctx.block_len = 0
		}
	}
	for offset + SHA256_BLOCK_SIZE <= len(data) {
		sha256_compress(ctx, data[offset:offset + SHA256_BLOCK_SIZE])
		offset += SHA256_BLOCK_SIZE
	}
	if offset < len(data) {
		remaining := len(data) - offset
		copy(ctx.block[:remaining], data[offset:])
		ctx.block_len = remaining
	}
}

// sha256_update_u32_be absorbs a big-endian 32-bit integer into SHA-256.
sha256_update_u32_be :: proc "contextless" (ctx: ^Sha256_State, value: u32) {
	encoded: [4]u8
	byte_order.write_u32_big_endian(encoded[:], 0, value)
	sha256_update(ctx, encoded[:])
}

// sha256_final completes padding and writes the 32-byte digest.
sha256_final :: proc "contextless" (ctx: ^Sha256_State) -> (out: Digest) {
	total_bits := ctx.total_bytes * 8
	ctx.block[ctx.block_len] = 0x80
	ctx.block_len += 1
	if ctx.block_len > SHA256_BLOCK_SIZE - 8 {
		for i in ctx.block_len ..< SHA256_BLOCK_SIZE {
			ctx.block[i] = 0
		}
		sha256_compress(ctx, ctx.block[:])
		ctx.block_len = 0
	}
	for i in ctx.block_len ..< SHA256_BLOCK_SIZE - 8 {
		ctx.block[i] = 0
	}
	byte_order.write_u64_big_endian(ctx.block[:], SHA256_BLOCK_SIZE - 8, total_bits)
	sha256_compress(ctx, ctx.block[:])
	for i in 0 ..< 8 {
		byte_order.write_u32_big_endian(out[:], i * 4, ctx.state[i])
	}
	zero_bytes(ctx.block[:])
	return out
}

// sha256_sum computes the SHA-256 digest of a single contiguous byte slice.
sha256_sum :: proc "contextless" (data: []u8) -> Digest {
	ctx: Sha256_State
	sha256_init(&ctx)
	sha256_update(&ctx, data)
	return sha256_final(&ctx)
}

// hmac_sha256_init prepares a streaming HMAC-SHA-256 state per RFC 2104.
hmac_sha256_init :: proc "contextless" (ctx: ^Hmac_Sha256_State, key: []u8) {
	key_block: [SHA256_BLOCK_SIZE]u8
	if len(key) > SHA256_BLOCK_SIZE {
		hashed := sha256_sum(key)
		copy(key_block[:SHA256_SIZE], hashed[:])
		zero_bytes(hashed[:])
	} else {
		copy(key_block[:len(key)], key)
	}
	ipad: [SHA256_BLOCK_SIZE]u8
	opad: [SHA256_BLOCK_SIZE]u8
	for i in 0 ..< SHA256_BLOCK_SIZE {
		ipad[i] = key_block[i] ~ 0x36
		opad[i] = key_block[i] ~ 0x5C
	}
	sha256_init(&ctx.inner)
	sha256_update(&ctx.inner, ipad[:])
	sha256_init(&ctx.outer)
	sha256_update(&ctx.outer, opad[:])
	zero_bytes(key_block[:])
	zero_bytes(ipad[:])
	zero_bytes(opad[:])
}

// hmac_sha256_update absorbs message bytes into the inner hash.
hmac_sha256_update :: proc "contextless" (ctx: ^Hmac_Sha256_State, data: []u8) {
	sha256_update(&ctx.inner, data)
}

// hmac_sha256_final finishes HMAC-SHA-256 and wipes intermediate digests.
hmac_sha256_final :: proc "contextless" (ctx: ^Hmac_Sha256_State) -> Digest {
	inner_digest := sha256_final(&ctx.inner)
	sha256_update(&ctx.outer, inner_digest[:])
	zero_bytes(inner_digest[:])
	return sha256_final(&ctx.outer)
}

// hmac_sha256 computes HMAC-SHA-256 over a single message slice.
hmac_sha256 :: proc "contextless" (key, message: []u8) -> Digest {
	ctx: Hmac_Sha256_State
	hmac_sha256_init(&ctx, key)
	hmac_sha256_update(&ctx, message)
	return hmac_sha256_final(&ctx)
}

// Constant-time multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x + 1 (0x1B).
@(private)
gf_mul :: proc "contextless" (a_in, b_in: u8) -> u8 {
	a := a_in
	b := b_in
	product: u8 = 0
	for _ in 0 ..< 8 {
		mask := u8(0) - (b & 1)
		product ~= a & mask
		high := u8(0) - ((a >> 7) & 1)
		a = (a << 1) ~ (0x1B & high)
		b >>= 1
	}
	return product
}

// Constant-time xtime (multiply by 2 in GF(2^8)) with no secret branch.
@(private)
gf_xtime :: #force_inline proc "contextless" (a: u8) -> u8 {
	high := u8(0) - ((a >> 7) & 1)
	return (a << 1) ~ (0x1B & high)
}

// Constant-time AES S-box computed via GF(2^8) inversion (a^254) and affine
// map so no secret-indexed cache table exists.
@(private)
aes_sbox :: proc "contextless" (x: u8) -> u8 {
	a2 := gf_mul(x, x)
	a3 := gf_mul(a2, x)
	a6 := gf_mul(a3, a3)
	a12 := gf_mul(a6, a6)
	a15 := gf_mul(a12, a3)
	a30 := gf_mul(a15, a15)
	a60 := gf_mul(a30, a30)
	a120 := gf_mul(a60, a60)
	a240 := gf_mul(a120, a120)
	a252 := gf_mul(a240, a12)
	inv := gf_mul(a252, a2)
	return inv ~ rotl8(inv, 1) ~ rotl8(inv, 2) ~ rotl8(inv, 3) ~ rotl8(inv, 4) ~ 0x63
}

@(private, rodata)
AES_RCON := [10]u8{0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36}

@(private)
aes128_expand_key :: proc "contextless" (key: [AES128_KEY_SIZE]u8) -> (round_keys: [11][AES128_BLOCK_SIZE]u8) {
	round_keys[0] = key
	for round in 1 ..= AES128_ROUNDS {
		prev := round_keys[round - 1]
		cur: [AES128_BLOCK_SIZE]u8
		// RotWord + SubWord + Rcon on the final 4-byte word of the previous key.
		cur[0] = prev[0] ~ aes_sbox(prev[13]) ~ AES_RCON[round - 1]
		cur[1] = prev[1] ~ aes_sbox(prev[14])
		cur[2] = prev[2] ~ aes_sbox(prev[15])
		cur[3] = prev[3] ~ aes_sbox(prev[12])
		for i in 4 ..< 16 {
			cur[i] = prev[i] ~ cur[i - 4]
		}
		round_keys[round] = cur
	}
	return round_keys
}

// aes128_encrypt_block encrypts one 16-byte block under a 128-bit key using
// the constant-time algebraic S-box (FIPS 197).
aes128_encrypt_block :: proc "contextless" (key: [AES128_KEY_SIZE]u8, input: [AES128_BLOCK_SIZE]u8) -> [AES128_BLOCK_SIZE]u8 {
	round_keys := aes128_expand_key(key)
	state: [AES128_BLOCK_SIZE]u8
	for i in 0 ..< 16 {
		state[i] = input[i] ~ round_keys[0][i]
	}

	for round in 1 ..= AES128_ROUNDS {
		// SubBytes
		for i in 0 ..< 16 {
			state[i] = aes_sbox(state[i])
		}
		// ShiftRows (column-major AES state)
		t1 := state[1]
		state[1] = state[5]
		state[5] = state[9]
		state[9] = state[13]
		state[13] = t1

		t2 := state[2]
		t6 := state[6]
		state[2] = state[10]
		state[6] = state[14]
		state[10] = t2
		state[14] = t6

		t15 := state[15]
		state[15] = state[11]
		state[11] = state[7]
		state[7] = state[3]
		state[3] = t15

		// MixColumns (omitted on final round)
		if round < AES128_ROUNDS {
			for col in 0 ..< 4 {
				base := col * 4
				s0 := state[base + 0]
				s1 := state[base + 1]
				s2 := state[base + 2]
				s3 := state[base + 3]
				all := s0 ~ s1 ~ s2 ~ s3
				state[base + 0] = s0 ~ all ~ gf_xtime(s0 ~ s1)
				state[base + 1] = s1 ~ all ~ gf_xtime(s1 ~ s2)
				state[base + 2] = s2 ~ all ~ gf_xtime(s2 ~ s3)
				state[base + 3] = s3 ~ all ~ gf_xtime(s3 ~ s0)
			}
		}
		// AddRoundKey
		for i in 0 ..< 16 {
			state[i] ~= round_keys[round][i]
		}
	}

	for r in 0 ..< 11 {
		zero_bytes(round_keys[r][:])
	}
	return state
}

// aes128_cfb_encrypt encrypts plaintext into ciphertext in 128-bit CFB mode
// (NIST SP 800-38A, TPM 2.0 Part 1 symmetric parameter encryption).
// Caller ensures len(ciphertext) >= len(plaintext).
aes128_cfb_encrypt :: proc "contextless" (key: [AES128_KEY_SIZE]u8, iv: [AES128_BLOCK_SIZE]u8, plaintext: []u8, ciphertext: []u8) {
	feedback := iv
	offset := 0
	for offset < len(plaintext) {
		keystream := aes128_encrypt_block(key, feedback)
		chunk := min(AES128_BLOCK_SIZE, len(plaintext) - offset)
		for i in 0 ..< chunk {
			cipher_byte := plaintext[offset + i] ~ keystream[i]
			ciphertext[offset + i] = cipher_byte
			feedback[i] = cipher_byte
		}
		zero_bytes(keystream[:])
		offset += chunk
	}
	zero_bytes(feedback[:])
}

// aes128_cfb_decrypt decrypts ciphertext into plaintext in 128-bit CFB mode.
// Caller ensures len(plaintext) >= len(ciphertext). Supports in-place operation.
aes128_cfb_decrypt :: proc "contextless" (key: [AES128_KEY_SIZE]u8, iv: [AES128_BLOCK_SIZE]u8, ciphertext: []u8, plaintext: []u8) {
	feedback := iv
	offset := 0
	for offset < len(ciphertext) {
		keystream := aes128_encrypt_block(key, feedback)
		chunk := min(AES128_BLOCK_SIZE, len(ciphertext) - offset)
		for i in 0 ..< chunk {
			cipher_byte := ciphertext[offset + i]
			plaintext[offset + i] = cipher_byte ~ keystream[i]
			feedback[i] = cipher_byte
		}
		zero_bytes(keystream[:])
		offset += chunk
	}
	zero_bytes(feedback[:])
}

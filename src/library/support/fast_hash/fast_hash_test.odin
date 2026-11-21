#+build !freestanding
package fast_hash

import "core:fmt"
import "core:testing"
import "core:time"

// One vector of the reference: rapidhash_withSeed of the first `length`
// bytes of the input of reference_input, from rapidhash.h (rapidhash V3,
// https://github.com/Nicoshev/rapidhash), compiled with its default
// choices. The lengths reach each branch: 0, 1 to 3, 4 to 7, 8 to 16, each
// step of 16 up to 112, the loop of 112 bytes once and more, and a tail of
// fewer than 16 bytes after the loop (113, 225).
Reference_Vector :: struct {
	length: int,
	seed:   u64,
	hash:   u64,
}

// The input of the vectors: byte i is i * 7 + 3, modulo 256.
reference_input :: proc() -> (input: [1000]u8) {
	for &value, place in input {
		value = u8(place * 7 + 3)
	}
	return
}

REFERENCE_VECTORS :: [?]Reference_Vector {
	{length = 0, seed = 0x0000000000000000, hash = 0x0338DC4BE2CECDAE},
	{length = 1, seed = 0x0000000000000000, hash = 0xC6939E8FB00709FF},
	{length = 2, seed = 0x0000000000000000, hash = 0xAD801A47DF89B990},
	{length = 3, seed = 0x0000000000000000, hash = 0x5655E9F764E8FB47},
	{length = 4, seed = 0x0000000000000000, hash = 0x49227FB2F401A8FC},
	{length = 5, seed = 0x0000000000000000, hash = 0x01B87DC529F9AFFE},
	{length = 7, seed = 0x0000000000000000, hash = 0xF8D2BDFE7F388DF8},
	{length = 8, seed = 0x0000000000000000, hash = 0xF5980B646F822E89},
	{length = 9, seed = 0x0000000000000000, hash = 0xFD9787420766DD08},
	{length = 12, seed = 0x0000000000000000, hash = 0x2401514F706BC577},
	{length = 15, seed = 0x0000000000000000, hash = 0x71BB053C322AB7CB},
	{length = 16, seed = 0x0000000000000000, hash = 0xD0E68844CB24A480},
	{length = 17, seed = 0x0000000000000000, hash = 0x7998C836066E171B},
	{length = 24, seed = 0x0000000000000000, hash = 0x961432085CA20B01},
	{length = 31, seed = 0x0000000000000000, hash = 0xED3EEE46CFA04E29},
	{length = 32, seed = 0x0000000000000000, hash = 0x4F6A424C80F09818},
	{length = 33, seed = 0x0000000000000000, hash = 0x50F708A727E0A6F9},
	{length = 47, seed = 0x0000000000000000, hash = 0x5FA1EE593A9D44E5},
	{length = 48, seed = 0x0000000000000000, hash = 0x78E892266D502576},
	{length = 49, seed = 0x0000000000000000, hash = 0x4C6D34CC323274B4},
	{length = 63, seed = 0x0000000000000000, hash = 0x4C285A4E89FF72C0},
	{length = 64, seed = 0x0000000000000000, hash = 0xD5E007F01F191991},
	{length = 65, seed = 0x0000000000000000, hash = 0xFF190630CC567EB0},
	{length = 80, seed = 0x0000000000000000, hash = 0x760884C469B5878A},
	{length = 81, seed = 0x0000000000000000, hash = 0xC076EE2566934DFD},
	{length = 96, seed = 0x0000000000000000, hash = 0x159E3A5CC100D66D},
	{length = 97, seed = 0x0000000000000000, hash = 0x223A2BC11FF709C2},
	{length = 112, seed = 0x0000000000000000, hash = 0xBDE27E659C073097},
	{length = 113, seed = 0x0000000000000000, hash = 0xE7198C47A15DF67F},
	{length = 128, seed = 0x0000000000000000, hash = 0x29165D219DBCA0AE},
	{length = 224, seed = 0x0000000000000000, hash = 0xCC2F57413B929CF1},
	{length = 225, seed = 0x0000000000000000, hash = 0x9FE6788088459D9F},
	{length = 240, seed = 0x0000000000000000, hash = 0xCB449EE161DBB311},
	{length = 300, seed = 0x0000000000000000, hash = 0xC52168BCD6303829},
	{length = 1000, seed = 0x0000000000000000, hash = 0x871E919AEC95C844},
	{length = 0, seed = 0x0123456789ABCDEF, hash = 0x565EF32CD8EFB3DD},
	{length = 1, seed = 0x0123456789ABCDEF, hash = 0x5ED83E2608FC233E},
	{length = 2, seed = 0x0123456789ABCDEF, hash = 0x4051A9439961052B},
	{length = 3, seed = 0x0123456789ABCDEF, hash = 0xC82EB9221B53D004},
	{length = 4, seed = 0x0123456789ABCDEF, hash = 0xD8148F849747EC09},
	{length = 5, seed = 0x0123456789ABCDEF, hash = 0xF9DEA057A2D174FE},
	{length = 7, seed = 0x0123456789ABCDEF, hash = 0x15ED25EF16203477},
	{length = 8, seed = 0x0123456789ABCDEF, hash = 0x18266E9028777FA7},
	{length = 9, seed = 0x0123456789ABCDEF, hash = 0x27DCC8FA30FDA633},
	{length = 12, seed = 0x0123456789ABCDEF, hash = 0x31C1027D3B5B9071},
	{length = 15, seed = 0x0123456789ABCDEF, hash = 0xDE8EE23860E293E6},
	{length = 16, seed = 0x0123456789ABCDEF, hash = 0x020311D9259B9E9E},
	{length = 17, seed = 0x0123456789ABCDEF, hash = 0x0F6DB5ECF711D100},
	{length = 24, seed = 0x0123456789ABCDEF, hash = 0xCA1B7A7125D21F09},
	{length = 31, seed = 0x0123456789ABCDEF, hash = 0x0C4187B2DABC1B54},
	{length = 32, seed = 0x0123456789ABCDEF, hash = 0x4458222399725CC3},
	{length = 33, seed = 0x0123456789ABCDEF, hash = 0x95723EA9A41BF3D7},
	{length = 47, seed = 0x0123456789ABCDEF, hash = 0x836712FF3B012D08},
	{length = 48, seed = 0x0123456789ABCDEF, hash = 0x4D155E31FBF3DDBC},
	{length = 49, seed = 0x0123456789ABCDEF, hash = 0xFBB6BD7D1F736942},
	{length = 63, seed = 0x0123456789ABCDEF, hash = 0xD6576475626CC431},
	{length = 64, seed = 0x0123456789ABCDEF, hash = 0xCB377D5B1382B919},
	{length = 65, seed = 0x0123456789ABCDEF, hash = 0xACC4FB2B0FEC09DA},
	{length = 80, seed = 0x0123456789ABCDEF, hash = 0xD0406A5B102FCC84},
	{length = 81, seed = 0x0123456789ABCDEF, hash = 0x18C6D955DC20F758},
	{length = 96, seed = 0x0123456789ABCDEF, hash = 0xCEB7CAE742993F1F},
	{length = 97, seed = 0x0123456789ABCDEF, hash = 0xD2E68416B0680090},
	{length = 112, seed = 0x0123456789ABCDEF, hash = 0x29ADEA8005B9C81F},
	{length = 113, seed = 0x0123456789ABCDEF, hash = 0xA94EC7588F15B658},
	{length = 128, seed = 0x0123456789ABCDEF, hash = 0x044586432C4522F0},
	{length = 224, seed = 0x0123456789ABCDEF, hash = 0x38CE16A8C700499C},
	{length = 225, seed = 0x0123456789ABCDEF, hash = 0x59A1D28380DF861B},
	{length = 240, seed = 0x0123456789ABCDEF, hash = 0x74FAB3829209D30E},
	{length = 300, seed = 0x0123456789ABCDEF, hash = 0xA268DA899A7C2021},
	{length = 1000, seed = 0x0123456789ABCDEF, hash = 0x648A7E26F404E913},
	{length = 0, seed = 0xFFFFFFFFFFFFFFFF, hash = 0x9A9C59147A213BE8},
	{length = 1, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xC6F59F210C3F6013},
	{length = 2, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xFAA25E856A706FB6},
	{length = 3, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xC189F216CF24B75D},
	{length = 4, seed = 0xFFFFFFFFFFFFFFFF, hash = 0x0A2020858F6BEF41},
	{length = 5, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xEA214F4E453F074B},
	{length = 7, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xB09CEE6C33D85326},
	{length = 8, seed = 0xFFFFFFFFFFFFFFFF, hash = 0x66B8CC341B6082F2},
	{length = 9, seed = 0xFFFFFFFFFFFFFFFF, hash = 0x3450FB356F668496},
	{length = 12, seed = 0xFFFFFFFFFFFFFFFF, hash = 0x14DC5FA863860855},
	{length = 15, seed = 0xFFFFFFFFFFFFFFFF, hash = 0x08E08E403E8A525B},
	{length = 16, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xC825AADF16A74C53},
	{length = 17, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xE1FC33D6FD7E114E},
	{length = 24, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xC7D98EF17CE89DB2},
	{length = 31, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xFC736E872F1D0E97},
	{length = 32, seed = 0xFFFFFFFFFFFFFFFF, hash = 0x37BD9EFC6E2ED6D1},
	{length = 33, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xF03D46D90BBED71C},
	{length = 47, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xE9CF5473A1C0804D},
	{length = 48, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xCE8773AD027DB12F},
	{length = 49, seed = 0xFFFFFFFFFFFFFFFF, hash = 0x8CA796E3CDBD49F3},
	{length = 63, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xE86CCB57EF38F054},
	{length = 64, seed = 0xFFFFFFFFFFFFFFFF, hash = 0x2CBE20309405A8E2},
	{length = 65, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xA4C566797E153B2E},
	{length = 80, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xACF97A60CD896CF3},
	{length = 81, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xA78FD2BF96450299},
	{length = 96, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xBC14977BB44B2017},
	{length = 97, seed = 0xFFFFFFFFFFFFFFFF, hash = 0x2B95D804830F7D6F},
	{length = 112, seed = 0xFFFFFFFFFFFFFFFF, hash = 0x8DE685C85A17ABA7},
	{length = 113, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xA26F76472872DE6D},
	{length = 128, seed = 0xFFFFFFFFFFFFFFFF, hash = 0x9E620357A995039E},
	{length = 224, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xF81FFFCE7DF41D27},
	{length = 225, seed = 0xFFFFFFFFFFFFFFFF, hash = 0x6FE113AAF56A901F},
	{length = 240, seed = 0xFFFFFFFFFFFFFFFF, hash = 0x26562BAE6B20E4C5},
	{length = 300, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xFAFA4C09ADC7E230},
	{length = 1000, seed = 0xFFFFFFFFFFFFFFFF, hash = 0xA99EE2860365DA2A},
}

@(test)
hash_gives_each_vector_of_the_reference :: proc(t: ^testing.T) {
	input := reference_input()
	for vector in REFERENCE_VECTORS {
		got := hash_bytes(input[:vector.length], vector.seed)
		testing.expectf(t, got == vector.hash, "%d bytes with the seed %16x: the hash %16x, the reference %16x", vector.length, vector.seed, got, vector.hash)
	}
}

// A hash reads only the bytes of its slice: the same bytes at another
// place, with other bytes around them, give the same hash.
@(test)
hash_reads_only_its_bytes :: proc(t: ^testing.T) {
	input := reference_input()
	copy_of_input: [1000 + 32]u8
	for &value in copy_of_input {
		value = 0xA5
	}
	for vector in REFERENCE_VECTORS {
		for offset in 0 ..< 16 {
			copy(copy_of_input[offset:][:vector.length], input[:vector.length])
			got := hash_bytes(copy_of_input[offset:][:vector.length], vector.seed)
			testing.expectf(t, got == vector.hash, "%d bytes at the offset %d: the hash %16x, the reference %16x", vector.length, offset, got, vector.hash)
			for &value in copy_of_input {
				value = ~value
			}
		}
	}
}

// The hash of a word is the hash of its 8 bytes, at the edges of a word and
// of a seed.
@(test)
hash_of_a_word_is_the_hash_of_its_bytes :: proc(t: ^testing.T) {
	words := [?]u64{0, 1, 0x80, 0xFF, 0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, 0xFFFF_FFFF_FFFF_FFFE, 0xFFFF_FFFF_FFFF_FFFF, 0x0123_4567_89AB_CDEF}
	seeds := [?]u64{0, 1, 0xFFFF_FFFF_FFFF_FFFF, 0x0123_4567_89AB_CDEF}
	for word in words {
		for seed in seeds {
			bytes := transmute([8]u8)u64le(word)
			from_bytes := hash_bytes(bytes[:], seed)
			from_word := hash_word_with_prepared_seed(word, seed_prepare(seed))
			testing.expectf(t, from_bytes == from_word, "the word %16x with the seed %16x: %16x from the word, %16x from its bytes", word, seed, from_word, from_bytes)
		}
	}
}

// The measures of time of this package run only with -define:MEASURE=true:
// a test that measures time is opt-in, and a normal run prints no time.
MEASURE :: #config(MEASURE, false)

// A nil slice and an empty slice give the same hash.
@(test)
hash_of_nil_slice :: proc(t: ^testing.T) {
	empty: [0]u8
	for seed in ([?]u64{0, 1, 0x0123_4567_89AB_CDEF, max(u64)}) {
		testing.expect_value(t, hash_bytes(nil, seed), hash_bytes(empty[:], seed))
	}
}

// Each bit of a word and of a seed changes both mix_word_with_prepared_seed
// and hash_word_with_prepared_seed.
@(test)
single_bit_changes_word_hashes :: proc(t: ^testing.T) {
	base_word := u64(0x0123_4567_89AB_CDEF)
	base_seed := seed_prepare(0xFEDC_BA98_7654_3210)
	base_mix := mix_word_with_prepared_seed(base_word, base_seed)
	base_hash := hash_word_with_prepared_seed(base_word, base_seed)
	for bit in uint(0) ..< 64 {
		mask := u64(1) << bit
		testing.expectf(t, mix_word_with_prepared_seed(base_word ~ mask, base_seed) != base_mix, "mix_word unchanged on word bit %d", bit)
		testing.expectf(t, mix_word_with_prepared_seed(base_word, base_seed ~ mask) != base_mix, "mix_word unchanged on seed bit %d", bit)
		testing.expectf(t, hash_word_with_prepared_seed(base_word ~ mask, base_seed) != base_hash, "hash_word unchanged on word bit %d", bit)
		testing.expectf(t, hash_word_with_prepared_seed(base_word, base_seed ~ mask) != base_hash, "hash_word unchanged on seed bit %d", bit)
	}
}

// Prints the time of one hash of a short key on the host, as a measure:
// the least of 20 batches. Build with -o:speed -define:MEASURE=true for a
// number that means something (docs/SIMD.md, "8. The 16-tag group match").
@(test)
hash_cost_of_short_keys :: proc(t: ^testing.T) {
	if !MEASURE {
		return
	}
	BATCH :: 100_000
	input := reference_input()
	for length in ([?]int{8, 16, 32, 64}) {
		least := max(i64)
		sum: u64
		for _ in 0 ..< 20 {
			start := time.tick_now()
			for count in 0 ..< BATCH {
				// The seed changes at each hash, so no hash is the same.
				sum += hash_bytes_with_prepared_seed(input[count & 255:][:length], sum)
			}
			least = min(least, time.duration_nanoseconds(time.tick_since(start)))
		}
		fmt.printfln("fast_hash: one hash of %d bytes on the host: %.2f ns (sum %x)", length, f64(least) / BATCH, sum)
	}
	testing.expect(t, true)
}

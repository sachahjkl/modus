package build

import "core:math/bits"
import "core:strings"

// The fact key of a fact type is the typeid that the compiler gives its
// record type: SipHash-2-4, with a key of 16 bytes, over the canonical name
// of the type in UTF-8, "<package name>::<type name>" for a named type of
// the package scope (src/md/features/log_facts.md, "The fact key: why the
// typeid"). The tool computes the same number from the source, so that it
// writes the table of the facts with no compile, and checks the number in
// the code of each module.

// The two words of the key of SipHash that the compiler uses for the hash
// of a canonical name (src/name_canonicalization.cpp of the compiler): the
// words k0 and k1 of SipHash.
FACT_KEY_SEED_FIRST :: u64(0xa659_2ea2_5e04_ac3c)
FACT_KEY_SEED_SECOND :: u64(0xba3c_ba04_ed28_a9ae)

// fact_key gives the fact key of the record type type_name of the package
// package_name: the typeid of that type in each build of each module that
// compiles the package. A new compiler with another seed or another
// canonical name changes it; a host test compares it with typeid_of.
fact_key :: proc(package_name, type_name: string) -> u64 {
	name := strings.concatenate({package_name, "::", type_name}, context.temp_allocator)
	return siphash_2_4(transmute([]u8)name, FACT_KEY_SEED_FIRST, FACT_KEY_SEED_SECOND)
}

// siphash_2_4 is SipHash-2-4 (Aumasson and Bernstein, 2012) with the key
// words k0 and k1. The tool cannot import core:crypto/siphash: that package
// brings core:crypto/_subtle, and the copy of the cryptography of Odin in
// src/library has a package of the same name, which the compiler refuses
// in one build. A host test checks it against the vector of the paper and
// against typeid_of.
siphash_2_4 :: proc(message: []u8, k0, k1: u64) -> u64 {
	v0 := k0 ~ 0x736f_6d65_7073_6575
	v1 := k1 ~ 0x646f_7261_6e64_6f6d
	v2 := k0 ~ 0x6c79_6765_6e65_7261
	v3 := k1 ~ 0x7465_6462_7974_6573
	round :: #force_inline proc(v0, v1, v2, v3: ^u64) {
		v0^ += v1^
		v1^ = bits.rotate_left64(v1^, 13) ~ v0^
		v0^ = bits.rotate_left64(v0^, 32)
		v2^ += v3^
		v3^ = bits.rotate_left64(v3^, 16) ~ v2^
		v0^ += v3^
		v3^ = bits.rotate_left64(v3^, 21) ~ v0^
		v2^ += v1^
		v1^ = bits.rotate_left64(v1^, 17) ~ v2^
		v2^ = bits.rotate_left64(v2^, 32)
	}
	whole := len(message) / 8 * 8
	for place := 0; place < whole; place += 8 {
		word: u64
		for index in 0 ..< 8 {
			word |= u64(message[place + index]) << uint(8 * index)
		}
		v3 ~= word
		round(&v0, &v1, &v2, &v3)
		round(&v0, &v1, &v2, &v3)
		v0 ~= word
	}
	// The last word: the bytes that are left, and the length in its top byte.
	last := u64(len(message) & 0xFF) << 56
	for index in 0 ..< len(message) - whole {
		last |= u64(message[whole + index]) << uint(8 * index)
	}
	v3 ~= last
	round(&v0, &v1, &v2, &v3)
	round(&v0, &v1, &v2, &v3)
	v0 ~= last
	v2 ~= 0xFF
	for _ in 0 ..< 4 {
		round(&v0, &v1, &v2, &v3)
	}
	return v0 ~ v1 ~ v2 ~ v3
}

package build

import "core:crypto/siphash"
import "core:encoding/endian"
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

// siphash_2_4 computes SipHash-2-4 (Aumasson and Bernstein, 2012) from the
// two little-endian key words k0 and k1 through core:crypto/siphash. A host
// test checks it against the vectors of the paper and against typeid_of.
siphash_2_4 :: proc(message: []u8, k0, k1: u64) -> u64 {
	key: [siphash.KEY_SIZE]u8
	endian.put_u64(key[:8], .Little, k0)
	endian.put_u64(key[8:], .Little, k1)
	return siphash.sum_bytes_2_4(message, key[:])
}

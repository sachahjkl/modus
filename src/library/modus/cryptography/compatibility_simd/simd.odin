// The part of `core:simd` that the cryptography of `core:crypto` uses, over
// the SIMD types and intrinsics of the compiler: a compatibility layer, so
// that the vector code taken from Odin compiles in a module of this system
// without importing the host core library (docs/CRYPTOGRAPHY.md). The names
// are the names of the origin.
package compatibility_simd

import "base:intrinsics"

u32x4 :: #simd[4]u32
u64x2 :: #simd[2]u64
u8x16 :: #simd[16]u8

add :: #force_inline proc "contextless" (a, b: $T) -> T where intrinsics.type_is_simd_vector(T) {
	return intrinsics.simd_add(a, b)
}

bit_xor :: #force_inline proc "contextless" (a, b: $T) -> T where intrinsics.type_is_simd_vector(T) {
	return intrinsics.simd_bit_xor(a, b)
}

shl :: #force_inline proc "contextless" (a, b: $T) -> T where intrinsics.type_is_simd_vector(T) {
	return intrinsics.simd_shl(a, b)
}

shr :: #force_inline proc "contextless" (a, b: $T) -> T where intrinsics.type_is_simd_vector(T) {
	return intrinsics.simd_shr(a, b)
}

shuffle :: intrinsics.simd_shuffle

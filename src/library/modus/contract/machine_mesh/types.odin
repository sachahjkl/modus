// Shared types and constant-time primitives for the machine mesh contract
// (src/md/features/several_machines.md).
//
// This package holds no kernel operation call, imports no support package,
// and allocates no memory. All Ed25519 signature checks run through a
// caller-supplied callback so the contract stays independent of the support
// cryptography library.
package machine_mesh

import "base:intrinsics"

// Fixed byte sizes for Ed25519 public keys and signatures.
PUBLIC_KEY_SIZE :: 32
SIGNATURE_SIZE :: 64

// Offline Ed25519 public key that identifies a principal across machines.
Principal_Root_Public_Key :: [PUBLIC_KEY_SIZE]u8

// Caller-supplied Ed25519 signature verifier so this contract package imports
// no support cryptography package.
Signature_Verify_Proc :: #type proc "contextless" (
	public_key: [PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [SIGNATURE_SIZE]u8,
	user_data: rawptr,
) -> bool

// bytes_all_zero returns true when every byte of input is zero, without early
// exit on non-zero bytes.
bytes_all_zero :: proc "contextless" (input: []u8) -> bool {
	accumulated: u8 = 0
	for value in input {
		accumulated |= value
	}
	return accumulated == 0
}

// key_is_zero returns true when all 32 bytes of value are zero.
key_is_zero :: proc "contextless" (value: [PUBLIC_KEY_SIZE]u8) -> bool {
	copy_value := value
	return bytes_all_zero(copy_value[:])
}

// keys_equal_constant_time compares two 32-byte values without early exit.
keys_equal_constant_time :: proc "contextless" (left, right: [PUBLIC_KEY_SIZE]u8) -> bool {
	difference: u8 = 0
	for index in 0 ..< PUBLIC_KEY_SIZE {
		difference |= left[index] ~ right[index]
	}
	return difference == 0
}

// slices_equal_constant_time compares two byte slices of equal length without
// early exit. Slices of different lengths return false immediately.
slices_equal_constant_time :: proc "contextless" (left, right: []u8) -> bool {
	if len(left) != len(right) {
		return false
	}
	difference: u8 = 0
	for index in 0 ..< len(left) {
		difference |= left[index] ~ right[index]
	}
	return difference == 0
}

// clear_bytes_explicitly overwrites every byte of buffer with zero using
// volatile stores so the compiler does not remove the erasure of secret state.
clear_bytes_explicitly :: proc "contextless" (buffer: []u8) {
	for index in 0 ..< len(buffer) {
		intrinsics.volatile_store(&buffer[index], 0)
	}
}

// Not taken from Odin: this file of the system takes the place of
// core/crypto/chacha20/chacha20_impl.odin, which reads processor features
// through core:sys/info (unavailable to freestanding modules). On amd64 and
// arm64, 128-bit SIMD (SSE2 / NEON) is guaranteed by the architecture, so
// _chacha20/simd128 is the default; other architectures use _chacha20/ref.
// The names are the names of the origin (docs/CRYPTOGRAPHY.md).
package modus_chacha20

import "modus:cryptography/_chacha20/ref"
import "modus:cryptography/_chacha20/simd128"

DEFAULT_IMPLEMENTATION :: Implementation.Simd128 when (ODIN_ARCH == .amd64 || ODIN_ARCH == .arm64) else Implementation.Portable

Implementation :: enum {
	Portable,
	Simd128,
}

@(private)
init_impl :: proc(ctx: ^Context, impl: Implementation) {
	switch impl {
	case .Portable:
		ctx._impl = .Portable
	case .Simd128:
		ctx._impl = simd128.is_performant() ? .Simd128 : .Portable
	}
}

@(private)
stream_blocks :: proc(ctx: ^Context, dst, src: []byte, nr_blocks: int) {
	// The implementation increments the counter as a value of 64 bits. In
	// the IETF form the counter has 32 bits, and the increment after the
	// last block carries into the first word of the IV: put that word back,
	// so that a seek after the last block gives the keystream of this IV.
	first_word_of_the_iv := ctx._state._s[13]
	switch ctx._impl {
	case .Portable:
		ref.stream_blocks(&ctx._state, dst, src, nr_blocks)
	case .Simd128:
		simd128.stream_blocks(&ctx._state, dst, src, nr_blocks)
	}
	if ctx._state._is_ietf_flavor {
		ctx._state._s[13] = first_word_of_the_iv
	}
}

@(private)
hchacha20 :: proc "contextless" (dst, key, iv: []byte, impl: Implementation) {
	switch impl {
	case .Portable:
		ref.hchacha20(dst, key, iv)
	case .Simd128:
		simd128.hchacha20(dst, key, iv)
	}
}

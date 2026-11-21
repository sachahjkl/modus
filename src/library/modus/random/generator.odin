// The random generator of a process (docs/RANDOMNESS.md): ChaCha20 with
// fast key erasure (D. J. Bernstein, "Fast-key-erasure random-number
// generators", 2017). Its state is a record of fixed size in the memory of
// the process; a draw makes no kernel entry and no call.
//
// Each refill runs ChaCha20 with the key and the nonce 0 for 13 blocks: the
// first 32 bytes are the next key, the next 800 bytes are served in order.
// The key that made them is erased at once, and each byte is erased when it
// is served: a copy of the state after a draw does not give the bytes
// before it (backtracking resistance).
//
// The ChaCha20 is the code of Odin's core:crypto that the system took
// (src/library/modus/cryptography, docs/CRYPTOGRAPHY.md), checked against RFC 8439.
//
// Who uses it: each process that draws random bytes. A process seeds its
// generator from its context (`generator_from_context`), where its starter
// wrote a seed; the root service gathers its own seed (`entropy_gather`,
// `entropy.odin`). The parts:
//
// - `Generator`, `generator_seed`, `generator_from_context`: the state.
// - `fill`, `fill_for_a_key`: the draws.
// - `seed_for_a_child`, `values_with_seed`: the seed of a process that this
//   one starts, or of another thread.
// - `reseed`: mix fresh bytes into the key.
// - `fresh_bytes_attach`: the fresh bytes page of the process, whose new
//   bytes the generator mixes into its key at a refill and before a key,
//   never at each draw (src/md/features/fresh_bytes.md).
// - `Seed_Strength`, `Entropy_Report`, `entropy_gather`: the gathering of
//   the root service.
//
// ```odin
// generator: random.Generator
// random.generator_from_context(&generator, ctx) or_return
// key: [32]u8
// random.fill_for_a_key(&generator, key[:], .Processor, &error) or_return
// ```
//
// See [random generator](term:random-generator),
// [random seed](term:random-seed) and [seed strength](term:seed-strength).
package random

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/fresh_bytes"
import op "modus:contract/operation"
import "modus:system"
import "modus:cryptography/chacha20"
import crypto "modus:cryptography/compatibility_crypto"

SEED_SIZE :: 32 // The bytes of a seed and of a key of ChaCha20.
REFILL_BLOCKS :: 13 // The blocks of 64 bytes of ChaCha20 of one refill: 832 bytes.
REFILL_SIZE :: REFILL_BLOCKS * 64 // The bytes of one refill.
BUFFER_SIZE :: REFILL_SIZE - SEED_SIZE // The bytes served from one refill: 800, after the next key.

// A zero Generator is not seeded: a draw from it stops the process (a
// check), so that no process draws numbers from a known key.
//
// One generator belongs to one thread. Two threads that draw from one
// generator at once would get the same bytes (two equal nonces, two equal
// seeds): a second thread gets its own generator, seeded with
// seed_for_a_child of the first. A draw that finds the generator in use by
// another draw stops the process with a sentence that says so.
Generator :: struct {
	key:       [SEED_SIZE]u8, // The key of the next refill.
	buffer:    [BUFFER_SIZE]u8, // The bytes of the last refill; a served byte is zero.
	available: int, // Bytes of the buffer not served: they are its last ones.
	seeded:    bool, // A seed was given: a draw is allowed.
	strength:  Seed_Strength, // The strength of the seed of the system from which this seed comes.
	in_use:    bool, // A draw runs: a second draw at the same time is refused.
	refills:   u64, // The refills since the seed.
	served:    u64, // Bytes served since the seed.
	fresh_page:         ^fresh_bytes.Page, // The fresh bytes page of the process; nil: none.
	fresh_change_count: u32, // The change count of the page that the key has: a change is mixed once.
	fresh_mixes:        u64, // The changes of the page mixed into the key since the seed.
}

// generator_seed keys a generator with a seed of 32 bytes, and erases the
// seed of the caller. A seed of 32 zero bytes is refused: it is the value
// of "no seed" (a starter that did not give one).
generator_seed :: proc "contextless" (generator: ^Generator, seed: ^[SEED_SIZE]u8, strength: Seed_Strength) -> bool {
	if crypto.is_zero_constant_time(seed[:]) == 1 {
		return false
	}
	generator^ = {}
	generator.key = seed^
	crypto.zero_explicit(seed, SEED_SIZE)
	generator.seeded = true
	generator.strength = strength
	return true
}

// seed_strength gives the strength of the seed of the system from which the
// seed of this generator comes: weak, processor or entropy. A process that
// makes keys reads it.
seed_strength :: proc "contextless" (generator: ^Generator) -> Seed_Strength {
	return generator.strength
}

// refill makes the next 800 bytes and the next key. Its frame, and those of
// ChaCha20 under it, hold the words of the key: fill erases the stack below
// it after it returns.
@(private)
refill :: #force_no_inline proc "contextless" (generator: ^Generator) {
	// All zero: runtime.default_context() stores the default random
	// generator of the runtime, whose state is thread-local (a module has
	// none). The code of ChaCha20 needs no allocator.
	context = {}
	nonce: [12]u8
	block: [REFILL_SIZE]u8
	cipher: chacha20.Context
	chacha20.init(&cipher, generator.key[:], nonce[:])
	chacha20.keystream_bytes(&cipher, block[:])
	chacha20.reset(&cipher)
	copy(generator.key[:], block[:SEED_SIZE])
	copy(generator.buffer[:], block[SEED_SIZE:])
	crypto.zero_explicit(&block, size_of(block))
	generator.available = BUFFER_SIZE
	generator.refills += 1
}

// fill writes random bytes in output. A generator that is not seeded stops
// the process.
fill :: proc "contextless" (generator: ^Generator, output: []u8) {
	fill_bytes(generator, output, false)
}

// fill_bytes is the one draw. It mixes the new bytes of the fresh bytes page
// at each refill, and before a key or a seed when for_a_key is true, and at
// no other draw: the page changes once in a period, and a mix costs a hash
// and the buffer (src/md/features/fresh_bytes.md).
@(private)
fill_bytes :: proc "contextless" (generator: ^Generator, output: []u8, for_a_key: bool) {
	ensure_contextless(generator.seeded, "random: a draw from a generator with no seed")
	in_use_before := intrinsics.atomic_exchange(&generator.in_use, true)
	ensure_contextless(!in_use_before, "random: two threads drew from one generator at once: each thread needs its own generator, seeded with seed_for_a_child")
	if for_a_key {
		fresh_bytes_take(generator)
	}
	done := 0
	for done < len(output) {
		if generator.available == 0 {
			fresh_bytes_take(generator)
			refill(generator)
			crypto.erase_stack_below_the_caller()
		}
		start := BUFFER_SIZE - generator.available
		count := min(generator.available, len(output) - done)
		copy(output[done:][:count], generator.buffer[start:][:count])
		crypto.zero_explicit(&generator.buffer[start], count)
		generator.available -= count
		done += count
	}
	generator.served += u64(len(output))
	intrinsics.atomic_store(&generator.in_use, false)
}

// fill_for_a_key writes random bytes in output for a key, a nonce or
// another secret, when the seed of this generator has least_strength at
// least. Each process chooses what it accepts; a seed that is weaker gives
// the error Seed_Too_Weak and writes no byte. A plain draw with no
// requirement is fill.
fill_for_a_key :: proc "contextless" (generator: ^Generator, output: []u8, least_strength: Seed_Strength, error: ^errors.Error_Record) -> bool {
	if !generator.seeded || generator.strength < least_strength {
		errors.fail(error, -1, .Seed_Too_Weak, .None, 3, i64(generator.strength), i64(least_strength))
		return false
	}
	fill_bytes(generator, output, true)
	return true
}

// The context of the key derivation of a mix of the fresh bytes page: a
// hash of other bytes never gives this key.
DOMAIN_FRESH_BYTES :: "kernel random: the fresh bytes of a process, version 1"

// fresh_bytes_take mixes the bytes of the fresh bytes page into the key when
// the page has a change that the key does not have: the next key is BLAKE3
// of the domain text, the old key and the bytes, so the bytes only add. It
// drops the buffer, so the next byte comes from the new key. The caller
// holds the generator (in_use).
@(private)
fresh_bytes_take :: proc "contextless" (generator: ^Generator) {
	if generator.fresh_page == nil {
		return
	}
	bytes, change_count, fresh := fresh_bytes.read(generator.fresh_page, generator.fresh_change_count)
	if !fresh {
		return
	}
	generator.key = key_derive(DOMAIN_FRESH_BYTES, generator.key[:], bytes[:])
	crypto.erase_stack_below_the_caller()
	crypto.zero_explicit(&bytes, size_of(bytes))
	crypto.zero_explicit(&generator.buffer, size_of(generator.buffer))
	generator.available = 0
	generator.fresh_change_count = change_count
	generator.fresh_mixes += 1
}

// fresh_bytes_attach gives a generator the fresh bytes page of the process
// (fresh_bytes.page_of); nil gives none. generator_from_context attaches the
// page of the context. A process that gives another thread its own
// generator attaches the page to it too: each generator mixes the bytes
// into its own key.
fresh_bytes_attach :: proc "contextless" (generator: ^Generator, page: ^fresh_bytes.Page) {
	generator.fresh_page = page
}

// fresh_bytes_mixes gives the changes of the fresh bytes page that the
// generator mixed into its key, and the change count of the last one (0:
// none yet). The process `randomness` shows them.
fresh_bytes_mixes :: proc "contextless" (generator: ^Generator) -> (mixes: u64, change_count: u32) {
	return generator.fresh_mixes, generator.fresh_change_count
}

// next_u64 gives a random number of 64 bits.
next_u64 :: proc "contextless" (generator: ^Generator) -> u64 {
	value: u64
	fill(generator, ([^]u8)(&value)[:8])
	return value
}

// seed_for_a_child gives the seed of a process that this process starts:
// 32 bytes of its own stream, which it never serves again. The starter
// knows the seed of its child: a child has no secret from the process that
// starts it, which already chooses its code and its grants.
seed_for_a_child :: proc "contextless" (generator: ^Generator) -> (seed: [SEED_SIZE]u8) {
	fill_bytes(generator, seed[:], true)
	return
}

// reseed mixes new bytes (of the processor, or of a device) into the key:
// the next key is BLAKE3 of the old key and the bytes (see entropy.odin),
// and the buffer is dropped.
reseed :: proc "contextless" (generator: ^Generator, fresh: []u8) {
	ensure_contextless(generator.seeded, "random: a reseed of a generator with no seed")
	in_use_before := intrinsics.atomic_exchange(&generator.in_use, true)
	ensure_contextless(!in_use_before, "random: a reseed during a draw of another thread: each thread needs its own generator")
	generator.key = key_derive(DOMAIN_RESEED, generator.key[:], fresh)
	crypto.erase_stack_below_the_caller()
	crypto.zero_explicit(&generator.buffer, size_of(generator.buffer))
	generator.available = 0
	intrinsics.atomic_store(&generator.in_use, false)
}

// generator_from_context seeds the generator of a process with the seed of
// its context (the values 9 to 12) and its strength (the value 16), and
// erases the seed there. It attaches the fresh bytes page of the context,
// when the starter mapped one. false: the context has no seed (the root
// service), or its strength names no member of Seed_Strength; the caller
// then has no generator, and each key that it asks for is refused.
generator_from_context :: proc "contextless" (generator: ^Generator, ctx: ^system.Context) -> bool {
	seed: [SEED_SIZE]u8
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		value := ctx.values[op.CONTEXT_VALUE_SEED + index]
		for byte in 0 ..< 8 {
			seed[index * 8 + byte] = u8(value >> (8 * uint(byte)))
		}
	}
	crypto.zero_explicit(&ctx.values[op.CONTEXT_VALUE_SEED], op.CONTEXT_VALUE_SEED_COUNT * 8)
	// A strength that names no member refuses the seed: taken for the
	// strongest, it would let a key come from a seed that nothing measured.
	strength, strength_ok := op.seed_strength_of_word(ctx.values[op.CONTEXT_VALUE_SEED_STRENGTH])
	if !strength_ok {
		crypto.zero_explicit(&seed, SEED_SIZE)
		return false
	}
	if !generator_seed(generator, &seed, strength) {
		return false
	}
	fresh_bytes_attach(generator, fresh_bytes.page_of(ctx))
	return true
}

// values_with_seed gives the values of a process to start with a seed for
// it from the generator of this process (system.process_start refuses a
// start with no seed).
values_with_seed :: proc "contextless" (generator: ^Generator, values: [op.CONTEXT_VALUES]u64) -> (with_seed: [op.CONTEXT_VALUES]u64) {
	with_seed = values
	seed := seed_for_a_child(generator)
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		value: u64
		for byte in 0 ..< 8 {
			value |= u64(seed[index * 8 + byte]) << (8 * uint(byte))
		}
		with_seed[op.CONTEXT_VALUE_SEED + index] = value
	}
	// The child's seed comes from this stream: it has the strength of the
	// seed of the system, as this one has.
	with_seed[op.CONTEXT_VALUE_SEED_STRENGTH] = u64(generator.strength)
	crypto.zero_explicit(&seed, SEED_SIZE)
	return
}

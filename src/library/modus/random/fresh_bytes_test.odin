#+build !freestanding
#+build !modus
package random

import "modus:contract/errors"
import "modus:contract/fixed_addresses"
import "modus:contract/fresh_bytes"
import op "modus:contract/operation"
import "modus:cryptography/chacha20"
import "core:testing"

page_bytes_of :: proc(first: u8) -> (bytes: [fresh_bytes.BYTES]u8) {
	for &byte, index in bytes {
		byte = first + u8(index * 3)
	}
	return
}

// The generator mixes a change of its page at its next refill, and not at a
// draw from its buffer; a change is mixed once.
@(test)
a_change_is_mixed_at_the_next_refill_and_once :: proc(t: ^testing.T) {
	page := new(fresh_bytes.Page)
	defer free(page)
	seed := seed_of(21)
	generator: Generator
	testing.expect(t, generator_seed(&generator, &seed, .Entropy))
	fresh_bytes_attach(&generator, page)
	drawn: [100]u8
	// A page with no change: no mix.
	fill(&generator, drawn[:])
	mixes, change_count := fresh_bytes_mixes(&generator)
	testing.expect_value(t, mixes, 0)
	testing.expect_value(t, change_count, u32(0))
	bytes := page_bytes_of(5)
	fresh_bytes.write(page, &bytes)
	// A draw from the buffer: no mix, and the key stays.
	key_before := generator.key
	fill(&generator, drawn[:])
	mixes, _ = fresh_bytes_mixes(&generator)
	testing.expect_value(t, mixes, 0)
	testing.expect(t, generator.key == key_before)
	// The draw that empties the buffer refills: the change is mixed.
	rest: [BUFFER_SIZE]u8
	fill(&generator, rest[:])
	mixes, change_count = fresh_bytes_mixes(&generator)
	testing.expect_value(t, mixes, 1)
	testing.expect_value(t, change_count, u32(fresh_bytes.CHANGE_STEP))
	// The next refill finds no new change: no second mix.
	fill(&generator, rest[:])
	mixes, _ = fresh_bytes_mixes(&generator)
	testing.expect_value(t, mixes, 1)
}

// A key draw mixes a change at once: its bytes are the ChaCha20 stream of
// BLAKE3 of the domain text, the key before and the bytes of the page,
// after the first 32 bytes, so the bytes of the page only add to the key.
@(test)
a_key_draw_mixes_at_once :: proc(t: ^testing.T) {
	page := new(fresh_bytes.Page)
	defer free(page)
	seed := seed_of(33)
	generator: Generator
	testing.expect(t, generator_seed(&generator, &seed, .Entropy))
	fresh_bytes_attach(&generator, page)
	drawn: [10]u8
	fill(&generator, drawn[:])
	bytes := page_bytes_of(40)
	page_copy := bytes
	fresh_bytes.write(page, &bytes)
	key_before := generator.key
	key: [32]u8
	error: errors.Error_Record
	testing.expect(t, fill_for_a_key(&generator, key[:], .Weak, &error))
	mixes, _ := fresh_bytes_mixes(&generator)
	testing.expect_value(t, mixes, 1)
	mixed_key := key_derive(DOMAIN_FRESH_BYTES, key_before[:], page_copy[:])
	nonce: [12]u8
	block: [REFILL_SIZE]u8
	cipher: chacha20.Context
	chacha20.init(&cipher, mixed_key[:], nonce[:])
	chacha20.keystream_bytes(&cipher, block[:])
	testing.expect(t, string(key[:]) == string(block[SEED_SIZE:][:len(key)]))
	testing.expect_value(t, generator.available, BUFFER_SIZE - len(key))
}

// A key that is refused for its strength reads no page: it mixes nothing,
// and the change waits for the next refill or key.
@(test)
a_refused_key_mixes_nothing :: proc(t: ^testing.T) {
	page := new(fresh_bytes.Page)
	defer free(page)
	seed := seed_of(44)
	generator: Generator
	testing.expect(t, generator_seed(&generator, &seed, .Weak))
	fresh_bytes_attach(&generator, page)
	bytes := page_bytes_of(80)
	fresh_bytes.write(page, &bytes)
	key: [32]u8
	error: errors.Error_Record
	testing.expect(t, !fill_for_a_key(&generator, key[:], .Processor, &error))
	mixes, _ := fresh_bytes_mixes(&generator)
	testing.expect_value(t, mixes, 0)
	testing.expect(t, fill_for_a_key(&generator, key[:], .Weak, &error))
	mixes, _ = fresh_bytes_mixes(&generator)
	testing.expect_value(t, mixes, 1)
}

// The seed of a child mixes a change at once, as a key does.
@(test)
a_child_seed_mixes_at_once :: proc(t: ^testing.T) {
	page := new(fresh_bytes.Page)
	defer free(page)
	seed := seed_of(55)
	generator: Generator
	testing.expect(t, generator_seed(&generator, &seed, .Entropy))
	fresh_bytes_attach(&generator, page)
	drawn: [10]u8
	fill(&generator, drawn[:])
	bytes := page_bytes_of(60)
	fresh_bytes.write(page, &bytes)
	_ = seed_for_a_child(&generator)
	mixes, _ := fresh_bytes_mixes(&generator)
	testing.expect_value(t, mixes, 1)
}

// A page in the middle of a change gives no mix; the change is mixed when
// the writer ends it.
@(test)
a_change_in_progress_is_not_mixed :: proc(t: ^testing.T) {
	page := new(fresh_bytes.Page)
	defer free(page)
	seed := seed_of(70)
	generator: Generator
	testing.expect(t, generator_seed(&generator, &seed, .Entropy))
	fresh_bytes_attach(&generator, page)
	bytes := page_bytes_of(90)
	fresh_bytes.write(page, &bytes)
	page.change_count += 1
	key_before := generator.key
	key: [32]u8
	error: errors.Error_Record
	testing.expect(t, fill_for_a_key(&generator, key[:], .Weak, &error))
	mixes, _ := fresh_bytes_mixes(&generator)
	testing.expect_value(t, mixes, 0)
	// No mix: the key draw came from the stream of the key before.
	nonce: [12]u8
	block: [REFILL_SIZE]u8
	cipher: chacha20.Context
	chacha20.init(&cipher, key_before[:], nonce[:])
	chacha20.keystream_bytes(&cipher, block[:])
	testing.expect(t, string(key[:]) == string(block[SEED_SIZE:][:len(key)]))
	page.change_count += 1
	testing.expect(t, fill_for_a_key(&generator, key[:], .Weak, &error))
	mixes, _ = fresh_bytes_mixes(&generator)
	testing.expect_value(t, mixes, 1)
}

// Two generators with one seed draw different bytes after one of them mixed
// its page: the stream depends on the fresh bytes.
@(test)
the_stream_depends_on_the_fresh_bytes :: proc(t: ^testing.T) {
	page := new(fresh_bytes.Page)
	defer free(page)
	first_seed, second_seed := seed_of(99), seed_of(99)
	with_page, without_page: Generator
	testing.expect(t, generator_seed(&with_page, &first_seed, .Entropy))
	testing.expect(t, generator_seed(&without_page, &second_seed, .Entropy))
	fresh_bytes_attach(&with_page, page)
	bytes := page_bytes_of(1)
	fresh_bytes.write(page, &bytes)
	first, second: [64]u8
	fill(&with_page, first[:])
	fill(&without_page, second[:])
	testing.expect(t, first != second)
}

// generator_from_context attaches the page only when the starter mapped it.
@(test)
the_page_of_the_context_is_attached :: proc(t: ^testing.T) {
	ctx: op.Context
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		ctx.values[op.CONTEXT_VALUE_SEED + index] = u64(index + 1)
	}
	generator: Generator
	testing.expect(t, generator_from_context(&generator, &ctx))
	testing.expect(t, generator.fresh_page == nil)
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		ctx.values[op.CONTEXT_VALUE_SEED + index] = u64(index + 1)
	}
	fixed_addresses.range_mapped_add(&ctx.values, .Fresh_Bytes_Page)
	testing.expect(t, generator_from_context(&generator, &ctx))
	testing.expect(t, uintptr(generator.fresh_page) == uintptr(fresh_bytes.PAGE_ADDRESS))
}

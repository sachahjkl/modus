#+build !freestanding
#+build !modus
package lz4

import "core:fmt"
import "core:slice"
import "core:testing"
import "core:time"

MEASURE :: #config(MEASURE, false)

@(private = "file")
splitmix64_next :: proc(state: ^u64) -> u64 {
	state^ += 0x9E37_79B9_7F4A_7C15
	z := state^
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

@(private = "file")
fill_repetitive_text :: proc(buffer: []u8) {
	sample := "modus kernel ring record storage commit tree hash draw table surface compositor window frame "
	for index in 0 ..< len(buffer) {
		buffer[index] = sample[index % len(sample)]
		if index > 0 && index % 173 == 0 {
			buffer[index] = u8('0' + (index / 173) % 10)
		}
	}
}

@(private = "file")
fill_structured_binary :: proc(buffer: []u8) {
	for index in 0 ..< len(buffer) {
		record := index / 32
		field := index % 32
		switch {
		case field < 4:
			buffer[index] = u8(field + 1)
		case field < 8:
			buffer[index] = u8((record >> uint((field - 4) * 8)) & 0xFF)
		case field < 24:
			buffer[index] = u8((record / 7 + field * 3) & 0xFF)
		case:
			buffer[index] = 0
		}
	}
}

@(private = "file")
fill_incompressible :: proc(buffer: []u8, seed: u64) {
	state := seed
	index := 0
	for index + 8 <= len(buffer) {
		word := splitmix64_next(&state)
		for lane in 0 ..< 8 {
			buffer[index + lane] = u8(word >> uint(lane * 8))
		}
		index += 8
	}
	if index < len(buffer) {
		word := splitmix64_next(&state)
		for lane in 0 ..< len(buffer) - index {
			buffer[index + lane] = u8(word >> uint(lane * 8))
		}
	}
}

@(test)
edges_and_bounds_refusals :: proc(t: ^testing.T) {
	testing.expect_value(t, compress_bound(0), 0)
	testing.expect_value(t, compress_bound(-1), 0)
	testing.expect_value(t, compress_bound(min(int)), 0)
	testing.expect_value(t, compress_bound(MAXIMUM_BLOCK_BYTES + 1), 0)
	testing.expect(t, compress_bound(1) >= 2)
	testing.expect(t, compress_bound(MAXIMUM_BLOCK_BYTES) > MAXIMUM_BLOCK_BYTES)

	// Nil hash table refused even on empty input.
	out: [32]u8
	written_nil, ref_nil := compress_block(nil, out[:], nil)
	testing.expect_value(t, written_nil, 0)
	testing.expect_value(t, ref_nil, Refusal.Hash_Table_Nil)

	// Empty input roundtrip.
	table: Hash_Table
	written_empty, ref_empty := compress_block(nil, nil, &table)
	testing.expect_value(t, written_empty, 0)
	testing.expect_value(t, ref_empty, Refusal.None)

	dec_empty, dec_ref_empty := decompress_block(nil, nil)
	testing.expect_value(t, dec_empty, 0)
	testing.expect_value(t, dec_ref_empty, Refusal.None)

	dec_empty_ref, dec_ref_empty_ref := decompress_block_reference(nil, nil)
	testing.expect_value(t, dec_empty_ref, 0)
	testing.expect_value(t, dec_ref_empty_ref, Refusal.None)

	// Edge lengths from 1 byte past 64 KiB (including hash-table u16 wraparound).
	edge_lengths := [?]int{1, 2, 3, 4, 5, 11, 12, 13, 14, 15, 16, 17, 255, 256, 270, 1024, 65534, 65535, 65536, 70000}
	for length in edge_lengths {
		source := make([]u8, length)
		defer delete(source)
		fill_repetitive_text(source)

		compressed := make([]u8, compress_bound(length))
		defer delete(compressed)
		comp_len, comp_ref := compress_block(source, compressed, &table)
		testing.expect_value(t, comp_ref, Refusal.None)
		testing.expect(t, comp_len > 0)

		// Dirty hash table must yield byte-for-byte identical compressed output.
		dirty_table: Hash_Table
		for &entry in dirty_table {
			entry = 0xABCD
		}
		compressed_dirty := make([]u8, compress_bound(length))
		defer delete(compressed_dirty)
		comp_len_dirty, comp_ref_dirty := compress_block(source, compressed_dirty, &dirty_table)
		testing.expect_value(t, comp_ref_dirty, Refusal.None)
		testing.expect_value(t, comp_len_dirty, comp_len)
		testing.expect(t, slice.equal(compressed[:comp_len], compressed_dirty[:comp_len_dirty]))

		// Compress into 1 byte too small must fail cleanly with Destination_Too_Small.
		if comp_len > 0 {
			too_small := make([]u8, comp_len - 1)
			defer delete(too_small)
			w_small, r_small := compress_block(source, too_small, &table)
			testing.expect_value(t, w_small, 0)
			testing.expect_value(t, r_small, Refusal.Destination_Too_Small)
		}

		// Decompress with both fast and reference decoders into exact-size buffer with trailing guard.
		fast_buf := make([]u8, length + 8)
		ref_buf := make([]u8, length + 8)
		defer delete(fast_buf)
		defer delete(ref_buf)
		for index in length ..< length + 8 {
			fast_buf[index] = 0xEE
			ref_buf[index] = 0xEE
		}
		fast_len, fast_ref := decompress_block(compressed[:comp_len], fast_buf[:length])
		ref_len, ref_ref := decompress_block_reference(compressed[:comp_len], ref_buf[:length])
		testing.expect_value(t, fast_ref, Refusal.None)
		testing.expect_value(t, ref_ref, Refusal.None)
		testing.expect_value(t, fast_len, length)
		testing.expect_value(t, ref_len, length)
		testing.expect(t, slice.equal(fast_buf[:length], source))
		testing.expect(t, slice.equal(ref_buf[:length], source))
		for index in length ..< length + 8 {
			testing.expect_value(t, fast_buf[index], u8(0xEE))
			testing.expect_value(t, ref_buf[index], u8(0xEE))
		}

		// Destination 1 byte short fails on both decoders.
		if length > 0 {
			w_f, r_f := decompress_block(compressed[:comp_len], fast_buf[:length - 1])
			w_r, r_r := decompress_block_reference(compressed[:comp_len], ref_buf[:length - 1])
			testing.expect_value(t, w_f, 0)
			testing.expect_value(t, w_r, 0)
			testing.expect_value(t, r_f, Refusal.Destination_Too_Small)
			testing.expect_value(t, r_r, Refusal.Destination_Too_Small)
		}
	}
}

@(test)
standard_lz4_wire_vectors_and_overlapping_offsets :: proc(t: ^testing.T) {
	// Known raw LZ4 block:
	//   token 0x45: 4 literals ("abcd"), match length = 5 + 4 = 9
	//   offset 0x0004 (4): repeats "abcd" -> "abcdabcdabcd" + 'a' (13 bytes)
	//   final token 0x50: 5 literals ("12345")
	//   total: "abcdabcdabcda12345" (18 bytes)
	vector := [?]u8{0x45, 'a', 'b', 'c', 'd', 0x04, 0x00, 0x50, '1', '2', '3', '4', '5'}
	expected := "abcdabcdabcda12345"
	out_fast: [32]u8
	out_ref: [32]u8
	len_fast, ref_fast := decompress_block(vector[:], out_fast[:])
	len_ref, ref_ref := decompress_block_reference(vector[:], out_ref[:])
	testing.expect_value(t, ref_fast, Refusal.None)
	testing.expect_value(t, ref_ref, Refusal.None)
	testing.expect_value(t, len_fast, len(expected))
	testing.expect_value(t, len_ref, len(expected))
	testing.expect_value(t, string(out_fast[:len_fast]), expected)
	testing.expect_value(t, string(out_ref[:len_ref]), expected)

	// Explicitly exercise every small overlapping match offset 1..16 across multiple match lengths.
	for offset in 1 ..= 16 {
		for extra_len in ([?]int{0, 1, 3, 7, 14, 15, 31, 255, 270}) {
			match_len := MINIMUM_MATCH_LENGTH + extra_len
			// Construct a raw LZ4 block:
			//   sequence 1: `offset` literals (values 0x41 + i), then match at `offset` of length `match_len`
			//   sequence 2: 1 final literal '!'
			stream := make([dynamic]u8)
			defer delete(stream)
			lit_nib := u8(min(offset, 15))
			mat_nib := u8(min(extra_len, 15))
			append(&stream, (lit_nib << 4) | mat_nib)
			if offset >= 15 {
				rem := offset - 15
				for rem >= 255 {
					append(&stream, 255)
					rem -= 255
				}
				append(&stream, u8(rem))
			}
			for i in 0 ..< offset {
				append(&stream, u8('A' + i))
			}
			append(&stream, u8(offset & 0xFF), u8((offset >> 8) & 0xFF))
			if extra_len >= 15 {
				rem := extra_len - 15
				for rem >= 255 {
					append(&stream, 255)
					rem -= 255
				}
				append(&stream, u8(rem))
			}
			append(&stream, 0x10, '!')

			total_expected := offset + match_len + 1
			fast_out := make([]u8, total_expected)
			ref_out := make([]u8, total_expected)
			defer delete(fast_out)
			defer delete(ref_out)

			w_f, r_f := decompress_block(stream[:], fast_out)
			w_r, r_r := decompress_block_reference(stream[:], ref_out)
			testing.expect_value(t, r_f, Refusal.None)
			testing.expect_value(t, r_r, Refusal.None)
			testing.expect_value(t, w_f, total_expected)
			testing.expect_value(t, w_r, total_expected)
			testing.expect(t, slice.equal(fast_out, ref_out))
			for i in 0 ..< offset + match_len {
				testing.expect_value(t, fast_out[i], u8('A' + (i % offset)))
			}
			testing.expect_value(t, fast_out[total_expected - 1], u8('!'))
		}
	}
}

@(test)
hostile_compressed_streams_refused :: proc(t: ^testing.T) {
	Case :: struct {
		name:     string,
		stream:   []u8,
		out_size: int,
		want:     Refusal,
	}
	cases := [?]Case {
		{"truncated literal extension (no byte after 0xF0)", {0xF0}, 64, .Truncated},
		{"truncated literal extension (255 at end)", {0xF0, 0xFF}, 512, .Truncated},
		{"truncated literals (claims 4, has 3)", {0x40, 'a', 'b', 'c'}, 64, .Truncated},
		{"literal destination too small", {0x40, 'a', 'b', 'c', 'd'}, 3, .Destination_Too_Small},
		{"truncated match offset (1 byte only)", {0x10, 'a', 0x01}, 64, .Truncated},
		{"zero match offset", {0x10, 'a', 0x00, 0x00, 0x00}, 64, .Zero_Match_Offset},
		{"offset past output start (at output 0)", {0x00, 0x01, 0x00, 0x00}, 64, .Match_Offset_Too_Large},
		{"offset past output start (offset 5 at output 4)", {0x40, 'a', 'b', 'c', 'd', 0x05, 0x00, 0x00}, 64, .Match_Offset_Too_Large},
		{"offset 65535 at output 4", {0x40, 'a', 'b', 'c', 'd', 0xFF, 0xFF, 0x00}, 64, .Match_Offset_Too_Large},
		{"truncated match length extension", {0x1F, 'a', 0x01, 0x00}, 64, .Truncated},
		{"truncated match length extension after 255", {0x1F, 'a', 0x01, 0x00, 0xFF}, 512, .Truncated},
		{"match destination too small", {0x10, 'a', 0x01, 0x00, 0x00}, 4, .Destination_Too_Small},
		{"missing final literal-only sequence", {0x10, 'a', 0x01, 0x00}, 64, .Truncated},
		{"trailing garbage byte after valid final literal token is parsed as offset and refused", {0x10, 'a', 0xFF}, 64, .Truncated},
	}

	for item in cases {
		buf_fast := make([]u8, item.out_size)
		buf_ref := make([]u8, item.out_size)
		defer delete(buf_fast)
		defer delete(buf_ref)
		w_f, r_f := decompress_block(item.stream, buf_fast)
		w_r, r_r := decompress_block_reference(item.stream, buf_ref)
		testing.expectf(t, w_f == 0 && r_f == item.want, "%s: fast got (%d, %v), want (0, %v)", item.name, w_f, r_f, item.want)
		testing.expectf(t, w_r == 0 && r_r == item.want, "%s: reference got (%d, %v), want (0, %v)", item.name, w_r, r_r, item.want)
	}
}

@(test)
deterministic_fuzz_roundtrip_and_mutated_streams :: proc(t: ^testing.T) {
	rng := u64(0x1234_5678_9ABC_DEF0)
	table: Hash_Table

	// 1. Roundtrip fuzz across mixed lengths (0 .. 65536) and data distributions.
	for round in 0 ..< 160 {
		length := int(splitmix64_next(&rng) % 65537)
		if round < 20 {
			length = round
		}
		source := make([]u8, length)
		defer delete(source)

		switch round % 4 {
		case 0:
			fill_repetitive_text(source)
		case 1:
			fill_structured_binary(source)
		case 2:
			fill_incompressible(source, splitmix64_next(&rng))
		case 3:
			// Periodic runs with small random periods 1..19 plus random noise patches.
			period := int(splitmix64_next(&rng) % 19) + 1
			for i in 0 ..< length {
				source[i] = u8((i % period) * 13 + 7)
			}
			if length > 16 {
				patch := int(splitmix64_next(&rng) % u64(length - 8))
				fill_incompressible(source[patch:patch + 8], splitmix64_next(&rng))
			}
		}

		bound := max(compress_bound(length), 1)
		compressed := make([]u8, bound)
		defer delete(compressed)
		comp_len, comp_ref := compress_block(source, compressed, &table)
		testing.expect_value(t, comp_ref, Refusal.None)

		out_fast := make([]u8, length)
		out_ref := make([]u8, length)
		defer delete(out_fast)
		defer delete(out_ref)
		w_f, r_f := decompress_block(compressed[:comp_len], out_fast)
		w_r, r_r := decompress_block_reference(compressed[:comp_len], out_ref)
		testing.expect_value(t, r_f, Refusal.None)
		testing.expect_value(t, r_r, Refusal.None)
		testing.expect_value(t, w_f, length)
		testing.expect_value(t, w_r, length)
		testing.expect(t, slice.equal(out_fast, source))
		testing.expect(t, slice.equal(out_ref, source))
	}

	// 2. Hostile mutation fuzz: mutate valid compressed blocks and pure random bytes,
	// asserting fast and reference decoders agree on every outcome without crashing.
	base_source := make([]u8, 4096)
	defer delete(base_source)
	fill_repetitive_text(base_source)
	base_compressed := make([]u8, compress_bound(len(base_source)))
	defer delete(base_compressed)
	base_comp_len, _ := compress_block(base_source, base_compressed, &table)

	mutated := make([]u8, len(base_compressed))
	defer delete(mutated)
	fast_out := make([]u8, 8192)
	ref_out := make([]u8, 8192)
	defer delete(fast_out)
	defer delete(ref_out)

	for round in 0 ..< 1000 {
		stream_len: int
		if round % 3 == 0 {
			// Pure hostile random bytes.
			stream_len = int(splitmix64_next(&rng) % 256)
			fill_incompressible(mutated[:stream_len], splitmix64_next(&rng))
		} else {
			stream_len = base_comp_len
			copy(mutated[:stream_len], base_compressed[:stream_len])
			mutations := int(splitmix64_next(&rng) % 4) + 1
			for _ in 0 ..< mutations {
				if stream_len == 0 {
					break
				}
				kind := splitmix64_next(&rng) % 4
				pos := int(splitmix64_next(&rng) % u64(stream_len))
				switch kind {
				case 0:
					mutated[pos] ~= u8(1 << (splitmix64_next(&rng) & 7))
				case 1:
					mutated[pos] = 0xFF
				case 2:
					mutated[pos] = 0x00
				case 3:
					stream_len = pos
				}
			}
		}
		cap_out := int(splitmix64_next(&rng) % 8193)
		w_f, r_f := decompress_block(mutated[:stream_len], fast_out[:cap_out])
		w_r, r_r := decompress_block_reference(mutated[:stream_len], ref_out[:cap_out])
		testing.expectf(t, w_f == w_r && r_f == r_r, "mutation %d: fast=(%d,%v) ref=(%d,%v)", round, w_f, r_f, w_r, r_r)
		if r_f == .None {
			testing.expect(t, slice.equal(fast_out[:w_f], ref_out[:w_r]))
		}
	}
}

@(test)
measure_lz4_throughput :: proc(t: ^testing.T) {
	if !MEASURE {
		return
	}
	BLOCK_SIZE :: 65536
	ROUNDS :: 15
	ITERATIONS :: 256

	source := make([]u8, BLOCK_SIZE)
	compressed := make([]u8, compress_bound(BLOCK_SIZE))
	decompressed := make([]u8, BLOCK_SIZE)
	defer delete(source)
	defer delete(compressed)
	defer delete(decompressed)

	table: Hash_Table
	Dataset :: enum {
		Repetitive_Text,
		Structured_Binary,
		Incompressible,
	}
	for kind in Dataset {
		switch kind {
		case .Repetitive_Text:
			fill_repetitive_text(source)
		case .Structured_Binary:
			fill_structured_binary(source)
		case .Incompressible:
			fill_incompressible(source, 0xCAFE_BABE_1234_5678)
		}

		comp_len := 0
		best_comp_ns := max(i64)
		for _ in 0 ..< ROUNDS {
			start := time.tick_now()
			for _ in 0 ..< ITERATIONS {
				n, ref := compress_block(source, compressed, &table)
				testing.expect_value(t, ref, Refusal.None)
				comp_len = n
			}
			best_comp_ns = min(best_comp_ns, time.duration_nanoseconds(time.tick_since(start)))
		}

		best_decomp_ns := max(i64)
		for _ in 0 ..< ROUNDS {
			start := time.tick_now()
			for _ in 0 ..< ITERATIONS {
				n, ref := decompress_block(compressed[:comp_len], decompressed)
				testing.expect_value(t, ref, Refusal.None)
				testing.expect_value(t, n, BLOCK_SIZE)
			}
			best_decomp_ns = min(best_decomp_ns, time.duration_nanoseconds(time.tick_since(start)))
		}

		testing.expect(t, slice.equal(decompressed, source))
		total_mib := f64(BLOCK_SIZE * ITERATIONS) / (1024.0 * 1024.0)
		comp_mib_s := total_mib / (f64(best_comp_ns) / 1e9)
		decomp_mib_s := total_mib / (f64(best_decomp_ns) / 1e9)
		ratio := f64(BLOCK_SIZE) / f64(comp_len)
		fmt.printfln(
			"lz4: %-18v 64 KiB -> %5d B (%.2fx): compress %.1f MiB/s, decompress %.1f MiB/s",
			kind,
			comp_len,
			ratio,
			comp_mib_s,
			decomp_mib_s,
		)
	}
}

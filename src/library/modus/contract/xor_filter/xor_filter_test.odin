#+build !freestanding
package xor_filter

import "core:fmt"
import "core:slice"
import "core:testing"
import "core:time"
import "modus:contract/blake3"
import "modus:contract/byte_order"

MEASURE :: #config(MEASURE, false)

@(private = "file")
Test_Buffers :: struct {
	fingerprints:  []u8,
	t2count:       []u8,
	t2hash:        []u64,
	alone:         []u32,
	reverse_order: []u64,
	reverse_h:     []u8,
}

@(private = "file")
allocate_test_buffers :: proc(key_count: int) -> (buffers: Test_Buffers, layout: Filter_Layout, ok: bool) {
	refusal: Refusal
	layout, refusal = layout_for_key_count(key_count)
	if refusal != .None {
		return {}, {}, false
	}
	array_len := int(layout.array_length)
	buffers.fingerprints = make([]u8, array_len)
	buffers.t2count = make([]u8, array_len)
	buffers.t2hash = make([]u64, array_len)
	buffers.alone = make([]u32, array_len)
	buffers.reverse_order = make([]u64, max(key_count, 1))
	buffers.reverse_h = make([]u8, max(key_count, 1))
	return buffers, layout, true
}

@(private = "file")
destroy_test_buffers :: proc(buffers: ^Test_Buffers) {
	delete(buffers.fingerprints)
	delete(buffers.t2count)
	delete(buffers.t2hash)
	delete(buffers.alone)
	delete(buffers.reverse_order)
	delete(buffers.reverse_h)
}

@(private = "file")
scratch_of :: proc(buffers: ^Test_Buffers) -> Build_Scratch {
	return Build_Scratch {
		t2count = buffers.t2count,
		t2hash = buffers.t2hash,
		alone = buffers.alone,
		reverse_order = buffers.reverse_order,
		reverse_h = buffers.reverse_h,
	}
}

@(test)
empty_and_small_to_large_sets_zero_false_negatives :: proc(t: ^testing.T) {
	// Nil filter always returns false.
	testing.expect(t, !contains(nil, 0))
	testing.expect(t, !contains(nil, max(u64)))

	// 0 keys: valid empty filter returns false for every key and roundtrips cleanly.
	{
		buffers, _, ok := allocate_test_buffers(0)
		testing.expect(t, ok)
		defer destroy_test_buffers(&buffers)

		filter, refusal := filter_build(nil, buffers.fingerprints, scratch_of(&buffers))
		testing.expect_value(t, refusal, Refusal.None)
		testing.expect_value(t, filter.key_count, u32(0))
		for probe in u64(0) ..< 1000 {
			testing.expect(t, !contains(&filter, probe))
		}
		testing.expect(t, !contains(&filter, max(u64)))

		wire_size, size_ref := filter_encoded_size(&filter)
		testing.expect_value(t, size_ref, Refusal.None)
		wire := make([]u8, wire_size)
		defer delete(wire)
		written, enc_ref := filter_encode(&filter, wire)
		testing.expect_value(t, enc_ref, Refusal.None)
		testing.expect_value(t, written, wire_size)

		decoded, dec_ref := filter_decode(wire[:written])
		testing.expect_value(t, dec_ref, Refusal.None)
		testing.expect_value(t, decoded.key_count, u32(0))
		for probe in u64(0) ..< 256 {
			testing.expect(t, !contains(&decoded, probe))
		}
	}

	// Sizes 1, 2, 3, 10, 100, 1000, 10000: 100% inserted keys must be found,
	// wire roundtrip preserves every query, and false positive rate stays near 1/256.
	sizes := [?]int{1, 2, 3, 10, 100, 1_000, 10_000}
	for count in sizes {
		keys := make([]u64, count)
		defer delete(keys)
		state := u64(0x517C_C1B7_2722_0A95) + u64(count)
		for index in 0 ..< count {
			keys[index] = splitmix64_next(&state)
		}
		if count >= 2 {
			// Include extreme boundary key values 0 and max(u64).
			keys[0] = 0
			keys[1] = max(u64)
		}

		buffers, _, ok := allocate_test_buffers(count)
		testing.expect(t, ok)
		defer destroy_test_buffers(&buffers)

		filter, refusal := filter_build(keys, buffers.fingerprints, scratch_of(&buffers))
		testing.expectf(t, refusal == .None, "count=%d failed with %v", count, refusal)
		testing.expect_value(t, filter.key_count, u32(count))

		for key in keys {
			testing.expectf(t, contains(&filter, key), "false negative for count=%d key=%x", count, key)
		}

		// Wire roundtrip must match identically.
		wire_size, size_ref := filter_encoded_size(&filter)
		testing.expect_value(t, size_ref, Refusal.None)
		wire := make([]u8, wire_size)
		defer delete(wire)
		written, enc_ref := filter_encode(&filter, wire)
		testing.expect_value(t, enc_ref, Refusal.None)
		testing.expect_value(t, written, wire_size)

		decoded, dec_ref := filter_decode(wire[:written])
		testing.expect_value(t, dec_ref, Refusal.None)
		for key in keys {
			testing.expect(t, contains(&decoded, key))
		}

		if count == 10_000 {
			// Measure false positive rate over 50,000 absent keys (expected ~195 / 50000 = 0.39%).
			false_positives := 0
			probe_state := u64(0xD6E8_FEB8_6659_FD93)
			for _ in 0 ..< 50_000 {
				probe := splitmix64_next(&probe_state)
				if contains(&decoded, probe) {
					false_positives += 1
				}
			}
			// Must be well within statistical range of 1/256 (~0.39%): < 1.0%.
			testing.expectf(t, false_positives < 500, "unexpectedly high false positives: %d / 50000", false_positives)
		}
	}
}

@(test)
duplicate_keys_and_blake3_keys_handled_without_mutating_input :: proc(t: ^testing.T) {
	// 1. All keys identical (200 copies of one key).
	{
		keys := make([]u64, 200)
		defer delete(keys)
		for &k in keys {
			k = 0xDEAD_BEEF_CAFE_BABE
		}
		buffers, _, ok := allocate_test_buffers(len(keys))
		testing.expect(t, ok)
		defer destroy_test_buffers(&buffers)

		filter, refusal := filter_build(keys, buffers.fingerprints, scratch_of(&buffers))
		testing.expect_value(t, refusal, Refusal.None)
		testing.expect_value(t, filter.key_count, u32(1))
		testing.expect(t, contains(&filter, 0xDEAD_BEEF_CAFE_BABE))
	}

	// 2. Mixed duplicate BLAKE3-derived keys; caller's slice must remain untouched.
	{
		keys := make([]u64, 1000)
		original := make([]u64, 1000)
		defer delete(keys)
		defer delete(original)
		for index in 0 ..< 1000 {
			// 250 distinct objects, each repeated 4 times in scrambled order.
			id := u32((index * 73) % 250)
			payload: [8]u8
			byte_order.write_u32_little_endian(payload[:], 0, id)
			byte_order.write_u32_little_endian(payload[:], 4, id ~ 0xA5A5_5A5A)
			digest := blake3.hash(payload[:])
			keys[index] = key_from_blake3_hash(digest)
		}
		copy(original, keys)

		buffers, _, ok := allocate_test_buffers(len(keys))
		testing.expect(t, ok)
		defer destroy_test_buffers(&buffers)

		filter, refusal := filter_build(keys, buffers.fingerprints, scratch_of(&buffers))
		testing.expect_value(t, refusal, Refusal.None)
		testing.expect_value(t, filter.key_count, u32(250))
		testing.expect(t, slice.equal(keys, original))
		for key in original {
			testing.expect(t, contains(&filter, key))
		}
	}
}

@(test)
sizing_scratch_and_wire_border_refusals :: proc(t: ^testing.T) {
	// Layout bounds.
	_, r_neg := layout_for_key_count(-1)
	testing.expect_value(t, r_neg, Refusal.Too_Many_Keys)
	_, r_over := layout_for_key_count(int(MAXIMUM_KEYS) + 1)
	testing.expect_value(t, r_over, Refusal.Too_Many_Keys)

	keys := [4]u64{10, 20, 30, 40}
	buffers, layout, ok := allocate_test_buffers(len(keys))
	testing.expect(t, ok)
	defer destroy_test_buffers(&buffers)
	array_len := int(layout.array_length)

	// Fingerprints buffer 1 byte short -> Buffer_Too_Small.
	_, r_fp := filter_build(keys[:], buffers.fingerprints[:array_len - 1], scratch_of(&buffers))
	testing.expect_value(t, r_fp, Refusal.Buffer_Too_Small)

	// Each scratch slice 1 element short -> Scratch_Too_Small.
	s := scratch_of(&buffers)
	s_t2c := s
	s_t2c.t2count = s.t2count[:array_len - 1]
	_, r1 := filter_build(keys[:], buffers.fingerprints, s_t2c)
	testing.expect_value(t, r1, Refusal.Scratch_Too_Small)

	s_t2h := s
	s_t2h.t2hash = s.t2hash[:array_len - 1]
	_, r2 := filter_build(keys[:], buffers.fingerprints, s_t2h)
	testing.expect_value(t, r2, Refusal.Scratch_Too_Small)

	s_al := s
	s_al.alone = s.alone[:array_len - 1]
	_, r3 := filter_build(keys[:], buffers.fingerprints, s_al)
	testing.expect_value(t, r3, Refusal.Scratch_Too_Small)

	s_ro := s
	s_ro.reverse_order = s.reverse_order[:len(keys) - 1]
	_, r4 := filter_build(keys[:], buffers.fingerprints, s_ro)
	testing.expect_value(t, r4, Refusal.Scratch_Too_Small)

	s_rh := s
	s_rh.reverse_h = s.reverse_h[:len(keys) - 1]
	_, r5 := filter_build(keys[:], buffers.fingerprints, s_rh)
	testing.expect_value(t, r5, Refusal.Scratch_Too_Small)

	// Valid filter for wire refusal mutations.
	valid, valid_ref := filter_build(keys[:], buffers.fingerprints, s)
	testing.expect_value(t, valid_ref, Refusal.None)
	wire_size, _ := filter_encoded_size(&valid)
	wire := make([]u8, wire_size + 4)
	defer delete(wire)
	written, enc_ref := filter_encode(&valid, wire[:wire_size])
	testing.expect_value(t, enc_ref, Refusal.None)
	testing.expect_value(t, written, wire_size)

	// Encode into 1-byte-short buffer must leave sentinel untouched.
	small := make([]u8, wire_size - 1)
	defer delete(small)
	for &b in small {
		b = 0x77
	}
	w_small, r_small := filter_encode(&valid, small)
	testing.expect_value(t, w_small, 0)
	testing.expect_value(t, r_small, Refusal.Buffer_Too_Small)
	testing.expect_value(t, small[0], u8(0x77))

	// Truncated headers and body.
	for cut in ([?]int{0, 1, HEADER_SIZE - 1, HEADER_SIZE, wire_size - 1}) {
		_, r_cut := filter_decode(wire[:cut])
		testing.expect_value(t, r_cut, Refusal.Truncated)
	}

	// Trailing garbage.
	wire[wire_size] = 0x00
	_, r_trail_1 := filter_decode(wire[:wire_size + 1])
	testing.expect_value(t, r_trail_1, Refusal.Trailing_Bytes)
	_, r_trail_4 := filter_decode(wire[:wire_size + 4])
	testing.expect_value(t, r_trail_4, Refusal.Trailing_Bytes)

	// Corrupt header magic.
	bad_magic := make([]u8, wire_size)
	defer delete(bad_magic)
	copy(bad_magic, wire[:wire_size])
	bad_magic[7] = '2'
	_, r_magic := filter_decode(bad_magic)
	testing.expect_value(t, r_magic, Refusal.Bad_Header)

	// Non-zero reserved word.
	bad_reserved := make([]u8, wire_size)
	defer delete(bad_reserved)
	copy(bad_reserved, wire[:wire_size])
	byte_order.write_u32_little_endian(bad_reserved, 28, 1)
	_, r_res := filter_decode(bad_reserved)
	testing.expect_value(t, r_res, Refusal.Reserved_Nonzero)

	// Zero, non-power-of-two, below-min, and above-max segment lengths refused.
	for bad_seg_len in ([?]u32{0, 1, 2, 3, 5, 6, 12, MAXIMUM_SEGMENT_LENGTH * 2, max(u32)}) {
		mut := make([]u8, wire_size)
		defer delete(mut)
		copy(mut, wire[:wire_size])
		byte_order.write_u32_little_endian(mut, 20, bad_seg_len)
		_, r_seg := filter_decode(mut)
		testing.expectf(t, r_seg == .Bad_Segment_Length, "segment_length=%d got %v", bad_seg_len, r_seg)
	}

	// Zero segment count refused.
	bad_seg_cnt := make([]u8, wire_size)
	defer delete(bad_seg_cnt)
	copy(bad_seg_cnt, wire[:wire_size])
	byte_order.write_u32_little_endian(bad_seg_cnt, 24, 0)
	_, r_sc := filter_decode(bad_seg_cnt)
	testing.expect_value(t, r_sc, Refusal.Bad_Segment_Count)

	// Oversized key_count and oversized fingerprint count (including u32 multiplication overflow).
	bad_keys := make([]u8, wire_size)
	defer delete(bad_keys)
	copy(bad_keys, wire[:wire_size])
	byte_order.write_u32_little_endian(bad_keys, 16, MAXIMUM_KEYS + 1)
	_, r_over_k := filter_decode(bad_keys)
	testing.expect_value(t, r_over_k, Refusal.Oversized_Filter)

	bad_fp_count := make([]u8, wire_size)
	defer delete(bad_fp_count)
	copy(bad_fp_count, wire[:wire_size])
	byte_order.write_u32_little_endian(bad_fp_count, 20, MAXIMUM_SEGMENT_LENGTH)
	byte_order.write_u32_little_endian(bad_fp_count, 24, max(u32))
	_, r_over_fp := filter_decode(bad_fp_count)
	testing.expect_value(t, r_over_fp, Refusal.Oversized_Filter)
}

@(test)
measure_xor_filter_latency_and_density :: proc(t: ^testing.T) {
	if !MEASURE {
		return
	}
	ROUNDS :: 15
	PROBES :: 200_000

	for count in ([?]int{1_000, 10_000, 100_000}) {
		keys := make([]u64, count)
		absent := make([]u64, PROBES)
		defer delete(keys)
		defer delete(absent)
		state := u64(0x9E37_79B9_7F4A_7C15) + u64(count)
		for index in 0 ..< count {
			keys[index] = splitmix64_next(&state)
		}
		for index in 0 ..< PROBES {
			absent[index] = splitmix64_next(&state)
		}

		buffers, layout, ok := allocate_test_buffers(count)
		testing.expect(t, ok)
		defer destroy_test_buffers(&buffers)

		build_start := time.tick_now()
		filter, refusal := filter_build(keys, buffers.fingerprints, scratch_of(&buffers))
		build_ms := time.duration_milliseconds(time.tick_since(build_start))
		testing.expect_value(t, refusal, Refusal.None)

		best_hit_ns := max(i64)
		for _ in 0 ..< ROUNDS {
			hits := 0
			start := time.tick_now()
			for index in 0 ..< PROBES {
				if contains(&filter, keys[index % count]) {
					hits += 1
				}
			}
			best_hit_ns = min(best_hit_ns, time.duration_nanoseconds(time.tick_since(start)))
			testing.expect_value(t, hits, PROBES)
		}

		best_miss_ns := max(i64)
		false_positives := 0
		for _ in 0 ..< ROUNDS {
			fp := 0
			start := time.tick_now()
			for key in absent {
				if contains(&filter, key) {
					fp += 1
				}
			}
			best_miss_ns = min(best_miss_ns, time.duration_nanoseconds(time.tick_since(start)))
			false_positives = fp
		}

		bits_per_key := f64(layout.array_length * 8) / f64(count)
		hit_ns := f64(best_hit_ns) / f64(PROBES)
		miss_ns := f64(best_miss_ns) / f64(PROBES)
		fp_percent := 100.0 * f64(false_positives) / f64(PROBES)
		fmt.printfln(
			"xor_filter: %6d keys -> %7d B (%.2f bits/key), build %.2f ms, hit %.2f ns, miss %.2f ns, FP %.3f%% (%d/%d)",
			count,
			layout.array_length,
			bits_per_key,
			build_ms,
			hit_ns,
			miss_ns,
			fp_percent,
			false_positives,
			PROBES,
		)
	}
}

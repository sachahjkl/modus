// Freestanding, zero-allocation Binary Fuse 8-bit compact set filter
// (src/md/data/performance_primitives.md).
//
// Implements the 3-wise 8-bit Binary Fuse filter (Graf & Lemire, ACM JEA 2022)
// over 64-bit keys such as truncated BLAKE3 digests for object_cache and
// module_gc. Achieves 0% false negatives, ~0.39% (1/256) false positive rate,
// O(1) lookup with three array reads, and ~9 to 10 bits per key.
//
// Binary wire format (32-byte little-endian header + fingerprints):
//   [0..8]   magic          "MODBF8V1"
//   [8..16]  seed           u64
//   [16..20] key_count      u32 (0 ..= MAXIMUM_KEYS)
//   [20..24] segment_length u32 (power of two in [4, 262144])
//   [24..28] segment_count  u32 (>= 1)
//   [28..32] reserved       u32 (must be 0)
//   [32..]   fingerprints   (segment_count + 2) * segment_length bytes
package xor_filter

import "modus:contract/blake3"
import "modus:contract/byte_order"

// Magic bytes identifying version 1 of the modus Binary Fuse8 wire format.
HEADER_MAGIC :: [8]u8{'M', 'O', 'D', 'B', 'F', '8', 'V', '1'}

// Fixed byte length of the serialized filter header.
HEADER_SIZE :: 32

// Power-of-two bounds for segment_length.
MINIMUM_SEGMENT_LENGTH :: u32(4)
MAXIMUM_SEGMENT_LENGTH :: u32(262144)

// Hard capacity bounds enforced at both construction and wire decode.
MAXIMUM_KEYS :: u32(16_000_000)
MAXIMUM_FINGERPRINTS :: u32(24_000_000)

// Maximum seed retries during graph peeling before returning Build_Failed.
MAXIMUM_BUILD_ATTEMPTS :: 100

// Default deterministic starting seed for filter_build.
DEFAULT_INITIAL_SEED :: u64(0x726b_2b9d_438b_9d4d)

// Closed set of refusals returned by filter sizing, construction, and wire coding.
Refusal :: enum u8 {
	None               = 0,
	Too_Many_Keys      = 1,
	Scratch_Too_Small  = 2,
	Buffer_Too_Small   = 3,
	Build_Failed       = 4,
	Truncated          = 5,
	Trailing_Bytes     = 6,
	Bad_Header         = 7,
	Reserved_Nonzero   = 8,
	Bad_Segment_Length = 9,
	Bad_Segment_Count  = 10,
	Oversized_Filter   = 11,
	Invalid_Filter     = 12,
}

// Computed array and segment dimensions for a filter of a given key count.
Filter_Layout :: struct {
	segment_length:       u32,
	segment_count:        u32,
	segment_count_length: u32,
	array_length:         u32,
}

// Caller-supplied scratch slices used during filter_build (zero heap allocation).
// Required lengths:
//   t2count, t2hash, alone: >= layout.array_length
//   reverse_order, reverse_h: >= len(keys)
Build_Scratch :: struct {
	t2count:       []u8,
	t2hash:        []u64,
	alone:         []u32,
	reverse_order: []u64,
	reverse_h:     []u8,
}

// Immutable Binary Fuse 8-bit filter over 64-bit keys.
Filter :: struct {
	seed:                 u64,
	key_count:            u32,
	segment_length:       u32,
	segment_length_mask:  u32,
	segment_count:        u32,
	segment_count_length: u32,
	array_length:         u32,
	fingerprints:         []u8,
}

// key_from_blake3_hash derives a 64-bit filter key from the first 8 bytes of a
// BLAKE3 hash in little-endian order.
key_from_blake3_hash :: #force_inline proc "contextless" (hash: blake3.Hash) -> u64 {
	copy_hash := hash
	return byte_order.read_u64_little_endian(copy_hash[:], 0)
}

@(private)
is_power_of_two_u32 :: #force_inline proc "contextless" (value: u32) -> bool {
	return value != 0 && (value & (value - 1)) == 0
}

@(private)
mix_split :: #force_inline proc "contextless" (key: u64, seed: u64) -> u64 {
	hash := key + seed
	hash ~= hash >> 33
	hash *= 0xff51afd7ed558ccd
	hash ~= hash >> 33
	hash *= 0xc4ceb9fe1a85ec53
	hash ~= hash >> 33
	return hash
}

@(private)
splitmix64_next :: #force_inline proc "contextless" (state: ^u64) -> u64 {
	state^ += 0x9E37_79B9_7F4A_7C15
	z := state^
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

@(private)
mulhi64 :: #force_inline proc "contextless" (left, right: u64) -> u64 {
	return u64((u128(left) * u128(right)) >> 64)
}

@(private)
fingerprint_of :: #force_inline proc "contextless" (hash: u64) -> u8 {
	return u8(hash ~ (hash >> 32))
}

@(private)
hash_positions_from_params :: #force_inline proc "contextless" (
	hash: u64,
	segment_length: u32,
	segment_length_mask: u32,
	segment_count_length: u32,
) -> (h0, h1, h2: u32) {
	hi := mulhi64(hash, u64(segment_count_length))
	h0 = u32(hi)
	h1 = h0 + segment_length
	h2 = h1 + segment_length
	h1 ~= u32(hash >> 18) & segment_length_mask
	h2 ~= u32(hash) & segment_length_mask
	return
}

// Integer threshold table for 1 << floor(log(size) / log(3.33) + 2.25) so
// freestanding contract code needs no floating-point logarithm.
@(private)
segment_length_for_key_count :: proc "contextless" (size: u32) -> u32 {
	switch {
	case size >= 15_275_006:
		return 65536
	case size >= 4_587_089:
		return 32768
	case size >= 1_377_505:
		return 16384
	case size >= 413_666:
		return 8192
	case size >= 124_224:
		return 4096
	case size >= 37_305:
		return 2048
	case size >= 11_203:
		return 1024
	case size >= 3_365:
		return 512
	case size >= 1_011:
		return 256
	case size >= 304:
		return 128
	case size >= 92:
		return 64
	case size >= 28:
		return 32
	case size >= 9:
		return 16
	case size >= 3:
		return 8
	case:
		return 4
	}
}

// Fixed-point (per-mille) overhead factor approximating
// max(1.125, 0.875 + 0.25 * max(1, log(1e6) / log(size))).
@(private)
size_factor_per_mille :: proc "contextless" (size: u32) -> u32 {
	switch {
	case size >= 1_000_000:
		return 1125
	case size >= 300_000:
		return 1150
	case size >= 100_000:
		return 1175
	case size >= 30_000:
		return 1210
	case size >= 10_000:
		return 1250
	case size >= 3_000:
		return 1310
	case size >= 1_000:
		return 1380
	case size >= 300:
		return 1480
	case size >= 100:
		return 1625
	case size >= 30:
		return 1900
	case size >= 10:
		return 2375
	case:
		return 3000
	}
}

// layout_for_key_count computes the exact segment geometry and fingerprint byte
// count required to construct a Binary Fuse8 filter for key_count keys.
layout_for_key_count :: proc "contextless" (key_count: int) -> (layout: Filter_Layout, refusal: Refusal) {
	if key_count < 0 || u64(key_count) > u64(MAXIMUM_KEYS) {
		return {}, .Too_Many_Keys
	}
	if key_count == 0 {
		return Filter_Layout {
			segment_length = MINIMUM_SEGMENT_LENGTH,
			segment_count = 1,
			segment_count_length = MINIMUM_SEGMENT_LENGTH,
			array_length = 3 * MINIMUM_SEGMENT_LENGTH,
		}, .None
	}
	size := u32(key_count)
	segment_length := segment_length_for_key_count(size)
	factor := size_factor_per_mille(size)
	capacity := u64(size) * u64(factor)
	capacity = (capacity + 999) / 1000
	initial_segments := (capacity + u64(segment_length) - 1) / u64(segment_length)
	segment_count: u64 = initial_segments <= 2 ? 1 : initial_segments - 2
	array_length := (segment_count + 2) * u64(segment_length)
	if array_length > u64(MAXIMUM_FINGERPRINTS) {
		return {}, .Oversized_Filter
	}
	return Filter_Layout {
		segment_length = segment_length,
		segment_count = u32(segment_count),
		segment_count_length = u32(segment_count * u64(segment_length)),
		array_length = u32(array_length),
	}, .None
}

// In-place O(N log N) heapsort used only when a build retry must deduplicate
// keys without heap allocation or mutating the caller's key slice.
@(private)
heapsort_u64 :: proc "contextless" (values: []u64) {
	count := len(values)
	if count <= 1 {
		return
	}
	sift_down :: proc "contextless" (data: []u64, start, end: int) {
		root := start
		for {
			child := root * 2 + 1
			if child > end {
				return
			}
			swap := root
			if data[swap] < data[child] {
				swap = child
			}
			if child + 1 <= end && data[swap] < data[child + 1] {
				swap = child + 1
			}
			if swap == root {
				return
			}
			data[root], data[swap] = data[swap], data[root]
			root = swap
		}
	}
	for start := (count - 2) / 2; start >= 0; start -= 1 {
		sift_down(values, start, count - 1)
	}
	for end := count - 1; end > 0; end -= 1 {
		values[end], values[0] = values[0], values[end]
		sift_down(values, 0, end - 1)
	}
}

// filter_build constructs a Binary Fuse 8-bit filter for keys into the
// caller-supplied fingerprints buffer using scratch memory. Handles empty
// key sets and arbitrary duplicate keys without mutating keys.
filter_build :: proc "contextless" (
	keys: []u64,
	fingerprints: []u8,
	scratch: Build_Scratch,
	initial_seed: u64 = DEFAULT_INITIAL_SEED,
) -> (filter: Filter, refusal: Refusal) {
	layout, layout_refusal := layout_for_key_count(len(keys))
	if layout_refusal != .None {
		return {}, layout_refusal
	}
	array_len := int(layout.array_length)
	if len(fingerprints) < array_len {
		return {}, .Buffer_Too_Small
	}
	if len(keys) == 0 {
		for index in 0 ..< array_len {
			fingerprints[index] = 0
		}
		return Filter {
			seed = initial_seed,
			key_count = 0,
			segment_length = layout.segment_length,
			segment_length_mask = layout.segment_length - 1,
			segment_count = layout.segment_count,
			segment_count_length = layout.segment_count_length,
			array_length = layout.array_length,
			fingerprints = fingerprints[:array_len],
		}, .None
	}
	if len(scratch.t2count) < array_len ||
		len(scratch.t2hash) < array_len ||
		len(scratch.alone) < array_len ||
		len(scratch.reverse_order) < len(keys) ||
		len(scratch.reverse_h) < len(keys) {
		return {}, .Scratch_Too_Small
	}

	segment_length := layout.segment_length
	segment_length_mask := segment_length - 1
	segment_count_length := layout.segment_count_length
	t2count := scratch.t2count[:array_len]
	t2hash := scratch.t2hash[:array_len]
	alone := scratch.alone[:array_len]
	reverse_order := scratch.reverse_order[:len(keys)]
	reverse_h := scratch.reverse_h[:len(keys)]

	seed_state := initial_seed
	for attempt in 0 ..< MAXIMUM_BUILD_ATTEMPTS {
		seed := splitmix64_next(&seed_state)
		for index in 0 ..< array_len {
			t2count[index] = 0
			t2hash[index] = 0
		}

		overflow := false
		unique_count := 0

		if attempt == 0 {
			// Fast path: assume keys are unique on the first attempt.
			unique_count = len(keys)
			for key in keys {
				hash := mix_split(key, seed)
				h0, h1, h2 := hash_positions_from_params(hash, segment_length, segment_length_mask, segment_count_length)
				if t2count[h0] >= 252 || t2count[h1] >= 252 || t2count[h2] >= 252 {
					overflow = true
					break
				}
				t2count[h0] += 4
				t2hash[h0] ~= hash
				t2count[h1] += 4
				t2count[h1] ~= 1
				t2hash[h1] ~= hash
				t2count[h2] += 4
				t2count[h2] ~= 2
				t2hash[h2] ~= hash
			}
		} else {
			// Retry path: sort a copy of keys inside reverse_order and skip
			// duplicates so duplicate keys never stall peeling.
			copy(reverse_order, keys)
			heapsort_u64(reverse_order)
			for index in 0 ..< len(keys) {
				key := reverse_order[index]
				if index > 0 && key == reverse_order[index - 1] {
					continue
				}
				unique_count += 1
				hash := mix_split(key, seed)
				h0, h1, h2 := hash_positions_from_params(hash, segment_length, segment_length_mask, segment_count_length)
				if t2count[h0] >= 252 || t2count[h1] >= 252 || t2count[h2] >= 252 {
					overflow = true
					break
				}
				t2count[h0] += 4
				t2hash[h0] ~= hash
				t2count[h1] += 4
				t2count[h1] ~= 1
				t2hash[h1] ~= hash
				t2count[h2] += 4
				t2count[h2] ~= 2
				t2hash[h2] ~= hash
			}
		}

		if overflow {
			continue
		}

		alone_size := 0
		for index in 0 ..< array_len {
			if (t2count[index] >> 2) == 1 {
				alone[alone_size] = u32(index)
				alone_size += 1
			}
		}

		stack_size := 0
		for alone_size > 0 {
			alone_size -= 1
			index := alone[alone_size]
			if (t2count[index] >> 2) != 1 {
				continue
			}
			hash := t2hash[index]
			found := t2count[index] & 3
			reverse_h[stack_size] = found
			reverse_order[stack_size] = hash
			stack_size += 1

			h0, h1, h2 := hash_positions_from_params(hash, segment_length, segment_length_mask, segment_count_length)
			t2count[h0] -= 4
			t2hash[h0] ~= hash
			if (t2count[h0] >> 2) == 1 && alone_size < array_len {
				alone[alone_size] = h0
				alone_size += 1
			}
			t2count[h1] -= 4
			t2count[h1] ~= 1
			t2hash[h1] ~= hash
			if (t2count[h1] >> 2) == 1 && alone_size < array_len {
				alone[alone_size] = h1
				alone_size += 1
			}
			t2count[h2] -= 4
			t2count[h2] ~= 2
			t2hash[h2] ~= hash
			if (t2count[h2] >> 2) == 1 && alone_size < array_len {
				alone[alone_size] = h2
				alone_size += 1
			}
		}

		if stack_size != unique_count {
			continue
		}

		// Peeling succeeded: assign fingerprints in reverse peeling order.
		target_fingerprints := fingerprints[:array_len]
		for index in 0 ..< array_len {
			target_fingerprints[index] = 0
		}
		for index := stack_size - 1; index >= 0; index -= 1 {
			hash := reverse_order[index]
			found := reverse_h[index]
			h0, h1, h2 := hash_positions_from_params(hash, segment_length, segment_length_mask, segment_count_length)
			fp := fingerprint_of(hash)
			switch found {
			case 0:
				target_fingerprints[h0] = fp ~ target_fingerprints[h1] ~ target_fingerprints[h2]
			case 1:
				target_fingerprints[h1] = fp ~ target_fingerprints[h0] ~ target_fingerprints[h2]
			case 2:
				target_fingerprints[h2] = fp ~ target_fingerprints[h0] ~ target_fingerprints[h1]
			}
		}

		return Filter {
			seed = seed,
			key_count = u32(unique_count),
			segment_length = segment_length,
			segment_length_mask = segment_length_mask,
			segment_count = layout.segment_count,
			segment_count_length = segment_count_length,
			array_length = layout.array_length,
			fingerprints = target_fingerprints,
		}, .None
	}

	return {}, .Build_Failed
}

// contains tests whether key may be a member of filter in O(1) time.
// Guarantees 0% false negatives for all keys inserted into filter and returns
// false for every key on an empty filter.
contains :: #force_inline proc "contextless" (filter: ^Filter, key: u64) -> bool {
	if filter == nil || filter.key_count == 0 || filter.segment_length == 0 || filter.segment_count_length == 0 {
		return false
	}
	if len(filter.fingerprints) < int(filter.array_length) {
		return false
	}
	hash := mix_split(key, filter.seed)
	fp := fingerprint_of(hash)
	h0, h1, h2 := hash_positions_from_params(hash, filter.segment_length, filter.segment_length_mask, filter.segment_count_length)
	combined := filter.fingerprints[h0] ~ filter.fingerprints[h1] ~ filter.fingerprints[h2]
	return fp == combined
}

// validate_filter_fields checks internal consistency of a Filter struct before
// encoding it to wire bytes.
@(private)
validate_filter_fields :: proc "contextless" (filter: ^Filter) -> Refusal {
	if filter == nil {
		return .Invalid_Filter
	}
	if filter.key_count > MAXIMUM_KEYS {
		return .Oversized_Filter
	}
	if !is_power_of_two_u32(filter.segment_length) ||
		filter.segment_length < MINIMUM_SEGMENT_LENGTH ||
		filter.segment_length > MAXIMUM_SEGMENT_LENGTH {
		return .Bad_Segment_Length
	}
	if filter.segment_length_mask != filter.segment_length - 1 {
		return .Invalid_Filter
	}
	if filter.segment_count == 0 {
		return .Bad_Segment_Count
	}
	expected_segment_count_length := u64(filter.segment_count) * u64(filter.segment_length)
	expected_array_length := (u64(filter.segment_count) + 2) * u64(filter.segment_length)
	if expected_array_length > u64(MAXIMUM_FINGERPRINTS) {
		return .Oversized_Filter
	}
	if u64(filter.segment_count_length) != expected_segment_count_length ||
		u64(filter.array_length) != expected_array_length {
		return .Invalid_Filter
	}
	if len(filter.fingerprints) < int(filter.array_length) {
		return .Invalid_Filter
	}
	return .None
}

// filter_encoded_size returns the exact wire byte size of filter, or 0 with
// the refusal when filter is invalid.
filter_encoded_size :: proc "contextless" (filter: ^Filter) -> (size: int, refusal: Refusal) {
	if check := validate_filter_fields(filter); check != .None {
		return 0, check
	}
	return HEADER_SIZE + int(filter.array_length), .None
}

// filter_encode validates filter and writes its canonical binary encoding into
// output. Refused calls leave output untouched.
filter_encode :: proc "contextless" (filter: ^Filter, output: []u8) -> (written: int, refusal: Refusal) {
	total_size, check := filter_encoded_size(filter)
	if check != .None {
		return 0, check
	}
	if len(output) < total_size {
		return 0, .Buffer_Too_Small
	}
	magic := HEADER_MAGIC
	copy(output[0:8], magic[:])
	byte_order.write_u64_little_endian(output, 8, filter.seed)
	byte_order.write_u32_little_endian(output, 16, filter.key_count)
	byte_order.write_u32_little_endian(output, 20, filter.segment_length)
	byte_order.write_u32_little_endian(output, 24, filter.segment_count)
	byte_order.write_u32_little_endian(output, 28, 0)
	copy(output[HEADER_SIZE:total_size], filter.fingerprints[:filter.array_length])
	return total_size, .None
}

// filter_decode strictly validates a serialized Binary Fuse8 filter border and
// returns a Filter borrowing its fingerprint bytes directly from encoded.
// Refuses corrupt magic, non-zero reserved words, zero or non-power-of-two
// segment lengths, zero segment counts, oversized filters, truncation, and
// trailing garbage.
filter_decode :: proc "contextless" (encoded: []u8) -> (filter: Filter, refusal: Refusal) {
	if len(encoded) < HEADER_SIZE {
		return {}, .Truncated
	}
	magic := HEADER_MAGIC
	for index in 0 ..< len(magic) {
		if encoded[index] != magic[index] {
			return {}, .Bad_Header
		}
	}
	reserved := byte_order.read_u32_little_endian(encoded, 28)
	if reserved != 0 {
		return {}, .Reserved_Nonzero
	}
	seed := byte_order.read_u64_little_endian(encoded, 8)
	key_count := byte_order.read_u32_little_endian(encoded, 16)
	segment_length := byte_order.read_u32_little_endian(encoded, 20)
	segment_count := byte_order.read_u32_little_endian(encoded, 24)

	if key_count > MAXIMUM_KEYS {
		return {}, .Oversized_Filter
	}
	if !is_power_of_two_u32(segment_length) ||
		segment_length < MINIMUM_SEGMENT_LENGTH ||
		segment_length > MAXIMUM_SEGMENT_LENGTH {
		return {}, .Bad_Segment_Length
	}
	if segment_count == 0 {
		return {}, .Bad_Segment_Count
	}
	expected_array_length := (u64(segment_count) + 2) * u64(segment_length)
	if expected_array_length > u64(MAXIMUM_FINGERPRINTS) {
		return {}, .Oversized_Filter
	}
	expected_total := HEADER_SIZE + int(expected_array_length)
	if len(encoded) < expected_total {
		return {}, .Truncated
	}
	if len(encoded) > expected_total {
		return {}, .Trailing_Bytes
	}
	return Filter {
		seed = seed,
		key_count = key_count,
		segment_length = segment_length,
		segment_length_mask = segment_length - 1,
		segment_count = segment_count,
		segment_count_length = segment_count * segment_length,
		array_length = u32(expected_array_length),
		fingerprints = encoded[HEADER_SIZE:expected_total],
	}, .None
}

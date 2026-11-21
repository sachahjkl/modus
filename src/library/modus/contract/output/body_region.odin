package output

import "base:intrinsics"
import "modus:contract/errors"

// The body region of a record output (src/md/features/module_outputs.md,
// "A large body"): a ring-buffered memory region owned by the writer and
// mapped read-only by each reader, carrying payloads that exceed the fixed
// 256-byte record compartment of an output ring.
//
// Memory layout of a body region:
//   offset 0..63   Body_Region_Header (64 bytes, one cache line)
//   offset 64..    Contiguous circular data area of header.data_capacity bytes
//
// Each body is placed contiguously at an aligned offset inside the data area.
// When a payload does not fit between write_offset and data_capacity, the
// writer records previous_wrap_offset = write_offset, increments generation
// (from 1), and resets write_offset to 0. A reader copies the header once,
// validates all bounds and wrap invariants, checks that the referenced range
// has not been overwritten by the current generation, and copies the payload
// once into caller-owned memory.
//
// Contract package: no allocator, no kernel call, no global state.

// Magic word ("BODY" in little-endian) identifying a Body_Region_Header.
BODY_REGION_MAGIC :: u32(0x59444F42)

// Wire format version of Body_Region_Header.
BODY_REGION_VERSION :: u32(1)

// Fixed byte size of Body_Region_Header.
BODY_REGION_HEADER_SIZE :: 64

// Allowed alignment bounds for records inside a body region (power of two).
BODY_REGION_ALIGNMENT_LEAST :: u32(8)
BODY_REGION_ALIGNMENT_DEFAULT :: u32(8)
BODY_REGION_ALIGNMENT_MOST :: u32(64)

// Maximum data area capacity of one body region (64 MiB).
BODY_REGION_CAPACITY_LIMIT :: u32(64 * 1024 * 1024)

// Fixed-layout header at offset 0 of a body region (64 bytes, zero padding).
Body_Region_Header :: struct {
	magic:                u32, // BODY_REGION_MAGIC.
	version:              u32, // BODY_REGION_VERSION.
	alignment:            u32, // Power of two in BODY_REGION_ALIGNMENT_LEAST ..= BODY_REGION_ALIGNMENT_MOST.
	data_capacity:        u32, // Bytes in the data area; must equal len(region) - BODY_REGION_HEADER_SIZE.
	generation:           u32, // Wrap generation counter, starting at 1; 0 is refused.
	write_offset:         u32, // Next write offset in 0 ..= data_capacity, aligned to alignment.
	previous_wrap_offset: u32, // End offset written in generation - 1 before wrapping; 0 when generation == 1.
	next_serial:          u32, // Next serial assigned by the writer.
	total_written:        u64, // Monotonic count of bodies written into this region.
	reserved:             [6]u32, // Must be 0.
}
#assert(size_of(Body_Region_Header) == BODY_REGION_HEADER_SIZE)

// Fixed-layout reference carried inside a record of a record output (16 bytes).
Body_Reference :: struct {
	offset:     u32, // Aligned byte offset in the data area (0 ..< data_capacity).
	length:     u32, // Exact payload length in bytes.
	generation: u32, // Wrap generation in which this payload was written (from 1).
	serial:     u32, // Serial of the record that owns this payload.
}
#assert(size_of(Body_Reference) == 16)

// Closed policy controlling whether zero-length payloads are accepted.
Body_Length_Rule :: enum u8 {
	Non_Empty_Required = 0, // Refuse length == 0 with Zero_Length.
	Allow_Empty        = 1, // Accept length == 0.
}

// Closed set of faults returned by body region border validation, writes, and reads.
Body_Region_Fault :: enum u8 {
	None                  = 0,
	Region_Too_Small      = 1,
	Region_Too_Large      = 2,
	Bad_Header            = 3,
	Bad_Alignment         = 4,
	Misaligned            = 5,
	Zero_Length           = 6,
	Payload_Too_Large     = 7,
	Out_Of_Bounds         = 8,
	Wrap_Corruption       = 9,
	Stale_Generation      = 10,
	Future_Generation     = 11,
	Generation_Exhausted  = 12,
	Serial_Mismatch       = 13,
	Destination_Too_Small = 14,
}

// body_region_alignment_valid reports whether alignment is a power of two
// within BODY_REGION_ALIGNMENT_LEAST ..= BODY_REGION_ALIGNMENT_MOST.
body_region_alignment_valid :: proc "contextless" (alignment: u32) -> bool {
	return alignment >= BODY_REGION_ALIGNMENT_LEAST &&
		alignment <= BODY_REGION_ALIGNMENT_MOST &&
		(alignment & (alignment - 1)) == 0
}

// align_up_u64 rounds value up to a multiple of alignment (a non-zero power of two).
@(private = "file")
align_up_u64 :: proc "contextless" (value, alignment: u64) -> u64 {
	mask := alignment - 1
	return (value + mask) & ~mask
}

// body_region_init initializes a caller-owned region slice with a valid
// Body_Region_Header at generation 1 and zeroes the data area. Refuses a
// region too small, too large, with an invalid alignment, or whose data area
// size is not a multiple of alignment. On refusal, region is untouched.
body_region_init :: proc "contextless" (region: []u8, alignment: u32 = BODY_REGION_ALIGNMENT_DEFAULT) -> Body_Region_Fault {
	if !body_region_alignment_valid(alignment) {
		return .Bad_Alignment
	}
	if len(region) < BODY_REGION_HEADER_SIZE + int(alignment) {
		return .Region_Too_Small
	}
	data_size := len(region) - BODY_REGION_HEADER_SIZE
	if data_size > int(BODY_REGION_CAPACITY_LIMIT) {
		return .Region_Too_Large
	}
	if u32(data_size) % alignment != 0 {
		return .Misaligned
	}
	intrinsics.mem_zero(raw_data(region), len(region))
	header := Body_Region_Header {
		magic                = BODY_REGION_MAGIC,
		version              = BODY_REGION_VERSION,
		alignment            = alignment,
		data_capacity        = u32(data_size),
		generation           = 1,
		write_offset         = 0,
		previous_wrap_offset = 0,
		next_serial          = 0,
		total_written        = 0,
	}
	intrinsics.mem_copy_non_overlapping(raw_data(region), &header, BODY_REGION_HEADER_SIZE)
	return .None
}

// body_region_header_read copies the header once out of region and validates
// all header, capacity, alignment, and wrap-state invariants at the border.
body_region_header_read :: proc "contextless" (region: []u8) -> (header: Body_Region_Header, fault: Body_Region_Fault) {
	if len(region) < BODY_REGION_HEADER_SIZE {
		return {}, .Region_Too_Small
	}
	actual_data_size := len(region) - BODY_REGION_HEADER_SIZE
	if actual_data_size > int(BODY_REGION_CAPACITY_LIMIT) {
		return {}, .Region_Too_Large
	}
	copied: Body_Region_Header
	intrinsics.mem_copy_non_overlapping(&copied, raw_data(region), BODY_REGION_HEADER_SIZE)
	if copied.magic != BODY_REGION_MAGIC || copied.version != BODY_REGION_VERSION || copied.reserved != ([6]u32{}) {
		return {}, .Bad_Header
	}
	if !body_region_alignment_valid(copied.alignment) {
		return {}, .Bad_Alignment
	}
	if copied.data_capacity < copied.alignment || u64(copied.data_capacity) != u64(actual_data_size) {
		return {}, .Bad_Header
	}
	if copied.data_capacity % copied.alignment != 0 {
		return {}, .Misaligned
	}
	if copied.generation == 0 {
		return {}, .Wrap_Corruption
	}
	if copied.write_offset > copied.data_capacity || copied.previous_wrap_offset > copied.data_capacity {
		return {}, .Wrap_Corruption
	}
	if copied.write_offset % copied.alignment != 0 || copied.previous_wrap_offset % copied.alignment != 0 {
		return {}, .Misaligned
	}
	if copied.generation == 1 && copied.previous_wrap_offset != 0 {
		return {}, .Wrap_Corruption
	}
	if copied.generation > 1 && (copied.previous_wrap_offset == 0 || copied.total_written == 0) {
		return {}, .Wrap_Corruption
	}
	if copied.total_written == 0 && copied.write_offset != 0 {
		return {}, .Wrap_Corruption
	}
	return copied, .None
}

// body_region_reference_check validates a Body_Reference against a validated
// Body_Region_Header snapshot. Refuses zero length when required, misaligned
// offsets, out-of-bounds offset + length (using 64-bit arithmetic to prevent
// wrap overflow), stale or future generations, overwritten pre-wrap ranges,
// wrap bound corruption, and optional serial mismatch.
body_region_reference_check :: proc "contextless" (
	header: Body_Region_Header,
	ref: Body_Reference,
	length_rule: Body_Length_Rule = .Non_Empty_Required,
	verify_serial: bool = false,
	expected_serial: u32 = 0,
) -> Body_Region_Fault {
	if !body_region_alignment_valid(header.alignment) || header.generation == 0 || header.data_capacity == 0 {
		return .Bad_Header
	}
	if ref.length == 0 && length_rule == .Non_Empty_Required {
		return .Zero_Length
	}
	if ref.offset % header.alignment != 0 {
		return .Misaligned
	}
	if ref.generation == 0 {
		return .Stale_Generation
	}
	if ref.generation > header.generation {
		return .Future_Generation
	}
	if header.total_written == 0 {
		return .Out_Of_Bounds
	}

	offset64 := u64(ref.offset)
	length64 := u64(ref.length)
	capacity64 := u64(header.data_capacity)
	aligned_length64 := align_up_u64(length64, u64(header.alignment))
	if offset64 > capacity64 || length64 > capacity64 - offset64 || aligned_length64 > capacity64 - offset64 {
		return .Out_Of_Bounds
	}
	aligned_end := offset64 + aligned_length64

	if ref.generation == header.generation {
		if aligned_end > u64(header.write_offset) {
			return .Out_Of_Bounds
		}
	} else if ref.generation + 1 == header.generation {
		// Once write_offset reaches or passes previous_wrap_offset, every byte
		// of the previous generation has been overwritten.
		if header.write_offset >= header.previous_wrap_offset {
			return .Stale_Generation
		}
		if offset64 < u64(header.write_offset) {
			return .Stale_Generation
		}
		if aligned_end > u64(header.previous_wrap_offset) {
			return .Wrap_Corruption
		}
	} else {
		return .Stale_Generation
	}

	if verify_serial && ref.serial != expected_serial {
		return .Serial_Mismatch
	}
	return .None
}

// body_region_write appends payload into region with zero dynamic allocation,
// wrapping contiguously to offset 0 and advancing generation when payload does
// not fit in the remaining tail. Zeroes any alignment padding bytes after
// payload. On refusal, region is untouched.
body_region_write :: proc "contextless" (
	region: []u8,
	payload: []u8,
	length_rule: Body_Length_Rule = .Non_Empty_Required,
) -> (ref: Body_Reference, fault: Body_Region_Fault) {
	header, header_fault := body_region_header_read(region)
	if header_fault != .None {
		return {}, header_fault
	}
	if len(payload) == 0 && length_rule == .Non_Empty_Required {
		return {}, .Zero_Length
	}
	payload_len64 := u64(len(payload))
	capacity64 := u64(header.data_capacity)
	if payload_len64 > capacity64 {
		return {}, .Payload_Too_Large
	}
	aligned_len64 := align_up_u64(payload_len64, u64(header.alignment))
	if aligned_len64 > capacity64 {
		return {}, .Payload_Too_Large
	}

	target_offset := u64(header.write_offset)
	next_generation := header.generation
	next_previous_wrap := header.previous_wrap_offset
	if target_offset + aligned_len64 > capacity64 {
		if header.generation == max(u32) {
			return {}, .Generation_Exhausted
		}
		// Never wrap before writing anything (impossible since aligned_len64 <= capacity64
		// and target_offset == 0 would satisfy target_offset + aligned_len64 <= capacity64).
		next_previous_wrap = header.write_offset
		next_generation = header.generation + 1
		target_offset = 0
	}

	data_start := BODY_REGION_HEADER_SIZE + int(target_offset)
	if len(payload) > 0 {
		copy(region[data_start:][:len(payload)], payload)
	}
	pad_len := int(aligned_len64 - payload_len64)
	if pad_len > 0 {
		intrinsics.mem_zero(&region[data_start + len(payload)], pad_len)
	}

	ref = Body_Reference {
		offset     = u32(target_offset),
		length     = u32(len(payload)),
		generation = next_generation,
		serial     = header.next_serial,
	}

	header.generation = next_generation
	header.previous_wrap_offset = next_previous_wrap
	header.write_offset = u32(target_offset + aligned_len64)
	header.next_serial = header.next_serial + 1
	header.total_written = header.total_written + 1
	intrinsics.mem_copy_non_overlapping(raw_data(region), &header, BODY_REGION_HEADER_SIZE)
	return ref, .None
}

// body_region_read validates the header and reference once and copies the
// payload bytes once into destination. On refusal, destination is untouched.
body_region_read :: proc "contextless" (
	region: []u8,
	ref: Body_Reference,
	destination: []u8,
	length_rule: Body_Length_Rule = .Non_Empty_Required,
	verify_serial: bool = false,
	expected_serial: u32 = 0,
) -> (written: int, fault: Body_Region_Fault) {
	header, header_fault := body_region_header_read(region)
	if header_fault != .None {
		return 0, header_fault
	}
	ref_fault := body_region_reference_check(header, ref, length_rule, verify_serial, expected_serial)
	if ref_fault != .None {
		return 0, ref_fault
	}
	if len(destination) < int(ref.length) {
		return 0, .Destination_Too_Small
	}
	if ref.length > 0 {
		data_start := BODY_REGION_HEADER_SIZE + int(ref.offset)
		copy(destination[:int(ref.length)], region[data_start:][:int(ref.length)])
	}
	return int(ref.length), .None
}

// body_region_error converts a Body_Region_Fault into a typed errors.Error_Record.
body_region_error :: proc "contextless" (fault: Body_Region_Fault, value: i64 = 0, limit: i64 = 0) -> errors.Error_Record {
	switch fault {
	case .None:
		return {}
	case .Region_Too_Small, .Destination_Too_Small:
		return errors.error_make(.Too_Small, .Bytes, 0, value, limit)
	case .Region_Too_Large, .Payload_Too_Large:
		return errors.error_make(.Too_Long, .Bytes, 0, value, limit)
	case .Bad_Header, .Wrap_Corruption:
		return errors.error_make(.Damaged, .Region, 0, value, limit)
	case .Bad_Alignment, .Misaligned:
		return errors.error_make(.Not_Multiple, .Bytes, 0, value, limit)
	case .Zero_Length:
		return errors.error_make(.Empty, .Bytes, 0, value, limit)
	case .Out_Of_Bounds:
		return errors.error_make(.Out_Of_Range, .Bytes, 0, value, limit)
	case .Stale_Generation, .Future_Generation, .Generation_Exhausted:
		return errors.error_make(.State, .Region, 0, value, limit)
	case .Serial_Mismatch:
		return errors.error_make(.Bad_Value, .Records, 0, value, limit)
	}
	return errors.error_make(.Bad_Value, .Region, 0, value, limit)
}

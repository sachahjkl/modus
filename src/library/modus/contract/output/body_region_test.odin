#+build !freestanding
package output

import "base:intrinsics"
import "core:slice"
import "core:testing"
import "modus:contract/errors"

@(private = "file")
sentinel_fill :: proc(buf: []u8, marker: u8) {
	for &b in buf {
		b = marker
	}
}

@(private = "file")
is_all :: proc(buf: []u8, marker: u8) -> bool {
	for b in buf {
		if b != marker {
			return false
		}
	}
	return true
}

@(private = "file")
read_raw_header :: proc(region: []u8) -> (h: Body_Region_Header) {
	intrinsics.mem_copy_non_overlapping(&h, raw_data(region), BODY_REGION_HEADER_SIZE)
	return h
}

@(private = "file")
write_raw_header :: proc(region: []u8, h: Body_Region_Header) {
	local := h
	intrinsics.mem_copy_non_overlapping(raw_data(region), &local, BODY_REGION_HEADER_SIZE)
}

// Initialization refuses invalid alignments, regions below header + alignment,
// and data areas that are not multiples of alignment, leaving bytes untouched.
@(test)
body_region_init_refuses_bad_alignment_and_size :: proc(t: ^testing.T) {
	buf: [BODY_REGION_HEADER_SIZE + 128]u8
	sentinel_fill(buf[:], 0xCC)

	for bad_align in ([?]u32{0, 1, 2, 4, 7, 9, 12, 24, 63, 65, 128, max(u32)}) {
		testing.expect_value(t, body_region_init(buf[:], bad_align), Body_Region_Fault.Bad_Alignment)
	}
	for small in ([?]int{0, 1, BODY_REGION_HEADER_SIZE - 1, BODY_REGION_HEADER_SIZE, BODY_REGION_HEADER_SIZE + 7}) {
		testing.expect_value(t, body_region_init(buf[:small], 8), Body_Region_Fault.Region_Too_Small)
	}
	for misaligned in ([?]int{BODY_REGION_HEADER_SIZE + 9, BODY_REGION_HEADER_SIZE + 15, BODY_REGION_HEADER_SIZE + 63}) {
		testing.expect_value(t, body_region_init(buf[:misaligned], 8), Body_Region_Fault.Misaligned)
	}
	testing.expect(t, is_all(buf[:], 0xCC))

	// Valid alignments: 8, 16, 32, 64.
	for valid_align in ([?]u32{8, 16, 32, 64}) {
		testing.expect_value(t, body_region_init(buf[:], valid_align), Body_Region_Fault.None)
		header, fault := body_region_header_read(buf[:])
		testing.expect_value(t, fault, Body_Region_Fault.None)
		testing.expect_value(t, header.alignment, valid_align)
		testing.expect_value(t, header.data_capacity, u32(128))
		testing.expect_value(t, header.generation, u32(1))
		testing.expect_value(t, header.write_offset, u32(0))
		testing.expect_value(t, header.previous_wrap_offset, u32(0))
		testing.expect(t, is_all(buf[BODY_REGION_HEADER_SIZE:], 0))
	}
}

// Hostile headers with bad magic, version, reserved words, mismatched capacity,
// misaligned cursors, or broken wrap invariants are all refused at the border.
@(test)
body_region_header_border_refuses_corrupt_headers :: proc(t: ^testing.T) {
	region: [BODY_REGION_HEADER_SIZE + 64]u8
	testing.expect_value(t, body_region_init(region[:], 8), Body_Region_Fault.None)
	valid := read_raw_header(region[:])

	// Too small region slice.
	_, fault := body_region_header_read(region[:0])
	testing.expect_value(t, fault, Body_Region_Fault.Region_Too_Small)
	_, fault = body_region_header_read(region[:BODY_REGION_HEADER_SIZE - 1])
	testing.expect_value(t, fault, Body_Region_Fault.Region_Too_Small)

	// Bad magic & version.
	h := valid
	h.magic = 0
	write_raw_header(region[:], h)
	_, fault = body_region_header_read(region[:])
	testing.expect_value(t, fault, Body_Region_Fault.Bad_Header)

	for bad_ver in ([?]u32{0, 2, max(u32)}) {
		h = valid
		h.version = bad_ver
		write_raw_header(region[:], h)
		_, fault = body_region_header_read(region[:])
		testing.expect_value(t, fault, Body_Region_Fault.Bad_Header)
	}

	// Nonzero reserved words.
	for slot in 0 ..< len(valid.reserved) {
		h = valid
		h.reserved[slot] = 1
		write_raw_header(region[:], h)
		_, fault = body_region_header_read(region[:])
		testing.expect_value(t, fault, Body_Region_Fault.Bad_Header)
	}

	// Bad alignment.
	h = valid
	h.alignment = 12
	write_raw_header(region[:], h)
	_, fault = body_region_header_read(region[:])
	testing.expect_value(t, fault, Body_Region_Fault.Bad_Alignment)

	// Capacity mismatch against slice size.
	for bad_cap in ([?]u32{0, 56, 72, max(u32)}) {
		h = valid
		h.data_capacity = bad_cap
		write_raw_header(region[:], h)
		_, fault = body_region_header_read(region[:])
		testing.expect_value(t, fault, Body_Region_Fault.Bad_Header)
	}

	// Generation 0.
	h = valid
	h.generation = 0
	write_raw_header(region[:], h)
	_, fault = body_region_header_read(region[:])
	testing.expect_value(t, fault, Body_Region_Fault.Wrap_Corruption)

	// Write offset or previous_wrap_offset past capacity.
	h = valid
	h.write_offset = 72
	h.total_written = 1
	write_raw_header(region[:], h)
	_, fault = body_region_header_read(region[:])
	testing.expect_value(t, fault, Body_Region_Fault.Wrap_Corruption)

	h = valid
	h.generation = 2
	h.previous_wrap_offset = 72
	h.total_written = 2
	write_raw_header(region[:], h)
	_, fault = body_region_header_read(region[:])
	testing.expect_value(t, fault, Body_Region_Fault.Wrap_Corruption)

	// Misaligned write_offset or previous_wrap_offset.
	h = valid
	h.write_offset = 4
	h.total_written = 1
	write_raw_header(region[:], h)
	_, fault = body_region_header_read(region[:])
	testing.expect_value(t, fault, Body_Region_Fault.Misaligned)

	h = valid
	h.generation = 2
	h.previous_wrap_offset = 12
	h.total_written = 2
	write_raw_header(region[:], h)
	_, fault = body_region_header_read(region[:])
	testing.expect_value(t, fault, Body_Region_Fault.Misaligned)

	// Generation 1 with nonzero previous_wrap_offset.
	h = valid
	h.previous_wrap_offset = 16
	write_raw_header(region[:], h)
	_, fault = body_region_header_read(region[:])
	testing.expect_value(t, fault, Body_Region_Fault.Wrap_Corruption)

	// Generation > 1 with zero previous_wrap_offset or zero total_written.
	h = valid
	h.generation = 2
	h.previous_wrap_offset = 0
	h.total_written = 1
	write_raw_header(region[:], h)
	_, fault = body_region_header_read(region[:])
	testing.expect_value(t, fault, Body_Region_Fault.Wrap_Corruption)

	h = valid
	h.generation = 2
	h.previous_wrap_offset = 32
	h.total_written = 0
	write_raw_header(region[:], h)
	_, fault = body_region_header_read(region[:])
	testing.expect_value(t, fault, Body_Region_Fault.Wrap_Corruption)

	// total_written == 0 with write_offset != 0.
	h = valid
	h.write_offset = 8
	h.total_written = 0
	write_raw_header(region[:], h)
	_, fault = body_region_header_read(region[:])
	testing.expect_value(t, fault, Body_Region_Fault.Wrap_Corruption)
}

// Reference checks refuse zero length when required, misaligned offsets, u32
// overflow, out-of-bounds ranges, stale/future generations, and serial mismatch,
// leaving destination untouched on every refusal.
@(test)
body_region_read_refuses_invalid_references_without_touching_destination :: proc(t: ^testing.T) {
	region: [BODY_REGION_HEADER_SIZE + 64]u8
	testing.expect_value(t, body_region_init(region[:], 8), Body_Region_Fault.None)

	dst: [64]u8
	sentinel_fill(dst[:], 0xA5)

	// Reading from an empty region (total_written == 0).
	_, fault := body_region_read(region[:], {offset = 0, length = 8, generation = 1, serial = 0}, dst[:])
	testing.expect_value(t, fault, Body_Region_Fault.Out_Of_Bounds)

	// Write one 13-byte payload (occupies offsets 0..15 with 3 zero padding bytes).
	payload := [13]u8{'h', 'e', 'l', 'l', 'o', '_', 'm', 'o', 'd', 'u', 's', '!', '!'}
	ref, wfault := body_region_write(region[:], payload[:])
	testing.expect_value(t, wfault, Body_Region_Fault.None)
	testing.expect_value(t, ref.offset, u32(0))
	testing.expect_value(t, ref.length, u32(13))
	testing.expect_value(t, ref.generation, u32(1))
	testing.expect_value(t, ref.serial, u32(0))

	// Zero length refused when Non_Empty_Required.
	_, fault = body_region_read(region[:], {offset = 0, length = 0, generation = 1, serial = 0}, dst[:], .Non_Empty_Required)
	testing.expect_value(t, fault, Body_Region_Fault.Zero_Length)

	// Misaligned offsets.
	for bad_off in ([?]u32{1, 4, 7, 9, max(u32)}) {
		_, fault = body_region_read(region[:], {offset = bad_off, length = 4, generation = 1, serial = 0}, dst[:])
		testing.expect_value(t, fault, Body_Region_Fault.Misaligned)
	}

	// u32 offset + length overflow (aligned max(u32) & ~7 = 0xFFFFFFF8).
	_, fault = body_region_read(region[:], {offset = 0xFFFFFFF8, length = 16, generation = 1, serial = 0}, dst[:])
	testing.expect_value(t, fault, Body_Region_Fault.Out_Of_Bounds)
	_, fault = body_region_read(region[:], {offset = 0, length = max(u32), generation = 1, serial = 0}, dst[:])
	testing.expect_value(t, fault, Body_Region_Fault.Out_Of_Bounds)

	// Past capacity and past write_offset within generation 1.
	_, fault = body_region_read(region[:], {offset = 64, length = 8, generation = 1, serial = 0}, dst[:])
	testing.expect_value(t, fault, Body_Region_Fault.Out_Of_Bounds)
	_, fault = body_region_read(region[:], {offset = 8, length = 16, generation = 1, serial = 0}, dst[:])
	testing.expect_value(t, fault, Body_Region_Fault.Out_Of_Bounds)
	_, fault = body_region_read(region[:], {offset = 16, length = 1, generation = 1, serial = 0}, dst[:])
	testing.expect_value(t, fault, Body_Region_Fault.Out_Of_Bounds)

	// Stale generation 0 and future generations.
	_, fault = body_region_read(region[:], {offset = 0, length = 13, generation = 0, serial = 0}, dst[:])
	testing.expect_value(t, fault, Body_Region_Fault.Stale_Generation)
	for future in ([?]u32{2, max(u32)}) {
		_, fault = body_region_read(region[:], {offset = 0, length = 13, generation = future, serial = 0}, dst[:])
		testing.expect_value(t, fault, Body_Region_Fault.Future_Generation)
	}

	// Serial mismatch.
	_, fault = body_region_read(region[:], ref, dst[:], .Non_Empty_Required, true, 1)
	testing.expect_value(t, fault, Body_Region_Fault.Serial_Mismatch)

	// Destination too small (0 and length - 1).
	_, fault = body_region_read(region[:], ref, dst[:0])
	testing.expect_value(t, fault, Body_Region_Fault.Destination_Too_Small)
	_, fault = body_region_read(region[:], ref, dst[:12])
	testing.expect_value(t, fault, Body_Region_Fault.Destination_Too_Small)

	// Destination was never modified by any refused read.
	testing.expect(t, is_all(dst[:], 0xA5))

	// Valid read succeeds with exact bytes and serial match.
	n, ok_fault := body_region_read(region[:], ref, dst[:13], .Non_Empty_Required, true, 0)
	testing.expect_value(t, ok_fault, Body_Region_Fault.None)
	testing.expect_value(t, n, 13)
	testing.expect(t, slice.equal(dst[:13], payload[:]))
}

// Ring-buffer wraps advance generation, keep unoverwritten tail records from
// generation - 1 readable, refuse overwritten and past-wrap records, and refuse
// generation exhaustion at max(u32) without mutating the region.
@(test)
body_region_wrap_lifecycle_and_stale_eviction :: proc(t: ^testing.T) {
	region: [BODY_REGION_HEADER_SIZE + 64]u8
	testing.expect_value(t, body_region_init(region[:], 8), Body_Region_Fault.None)

	// Write A (20 bytes -> aligned 24, offsets 0..23) and B (21 bytes -> aligned 24, offsets 24..47).
	a_data := [20]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}
	b_data := [21]u8{21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41}
	c_data := [24]u8{50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73}
	d_data := [16]u8{80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95}

	ref_a, fa := body_region_write(region[:], a_data[:])
	ref_b, fb := body_region_write(region[:], b_data[:])
	testing.expect(t, fa == .None && fb == .None)
	testing.expect(t, ref_a.offset == 0 && ref_a.generation == 1 && ref_a.serial == 0)
	testing.expect(t, ref_b.offset == 24 && ref_b.generation == 1 && ref_b.serial == 1)
	// Alignment padding bytes after A (offsets 20..23) and B (offsets 45..47) are zero.
	testing.expect(t, is_all(region[BODY_REGION_HEADER_SIZE + 20:BODY_REGION_HEADER_SIZE + 24], 0))
	testing.expect(t, is_all(region[BODY_REGION_HEADER_SIZE + 45:BODY_REGION_HEADER_SIZE + 48], 0))

	// Write C (24 bytes): 48 + 24 > 64, so it wraps to offset 0 in generation 2.
	ref_c, fc := body_region_write(region[:], c_data[:])
	testing.expect_value(t, fc, Body_Region_Fault.None)
	testing.expect(t, ref_c.offset == 0 && ref_c.generation == 2 && ref_c.serial == 2)

	header, hf := body_region_header_read(region[:])
	testing.expect_value(t, hf, Body_Region_Fault.None)
	testing.expect_value(t, header.generation, u32(2))
	testing.expect_value(t, header.write_offset, u32(24))
	testing.expect_value(t, header.previous_wrap_offset, u32(48))

	dst: [64]u8
	// A (gen 1, offset 0) was overwritten by C (gen 2, offsets 0..23) -> Stale_Generation.
	_, fault := body_region_read(region[:], ref_a, dst[:])
	testing.expect_value(t, fault, Body_Region_Fault.Stale_Generation)

	// B (gen 1, offset 24..47) is still intact -> readable!
	n, bf := body_region_read(region[:], ref_b, dst[:], .Non_Empty_Required, true, 1)
	testing.expect_value(t, bf, Body_Region_Fault.None)
	testing.expect_value(t, n, len(b_data))
	testing.expect(t, slice.equal(dst[:n], b_data[:]))

	// Fabricated gen 1 ref past previous_wrap_offset (offset 48..55) -> Wrap_Corruption.
	_, fault = body_region_read(region[:], {offset = 48, length = 8, generation = 1, serial = 99}, dst[:])
	testing.expect_value(t, fault, Body_Region_Fault.Wrap_Corruption)

	// C (gen 2, offset 0..23) -> readable!
	nc, cf := body_region_read(region[:], ref_c, dst[:], .Non_Empty_Required, true, 2)
	testing.expect_value(t, cf, Body_Region_Fault.None)
	testing.expect(t, slice.equal(dst[:nc], c_data[:]))

	// Write D (16 bytes -> offsets 24..39 in gen 2): now overwrites start of B.
	ref_d, fd := body_region_write(region[:], d_data[:])
	testing.expect_value(t, fd, Body_Region_Fault.None)
	testing.expect(t, ref_d.offset == 24 && ref_d.generation == 2 && ref_d.serial == 3)
	_, fault = body_region_read(region[:], ref_b, dst[:])
	testing.expect_value(t, fault, Body_Region_Fault.Stale_Generation)

	// Write full-capacity payload (64 bytes): forces wrap to generation 3.
	full: [64]u8
	for &b, idx in full {
		b = u8(idx + 1)
	}
	ref_full, ff := body_region_write(region[:], full[:])
	testing.expect_value(t, ff, Body_Region_Fault.None)
	testing.expect(t, ref_full.offset == 0 && ref_full.length == 64 && ref_full.generation == 3 && ref_full.serial == 4)
	// Gen 1 (two generations behind) and gen 2 (write_offset == capacity >= previous_wrap) are stale.
	_, fault = body_region_read(region[:], ref_a, dst[:])
	testing.expect_value(t, fault, Body_Region_Fault.Stale_Generation)
	_, fault = body_region_read(region[:], ref_c, dst[:])
	testing.expect_value(t, fault, Body_Region_Fault.Stale_Generation)
	_, fault = body_region_read(region[:], ref_d, dst[:])
	testing.expect_value(t, fault, Body_Region_Fault.Stale_Generation)
	n_full, read_full := body_region_read(region[:], ref_full, dst[:], .Non_Empty_Required, true, 4)
	testing.expect_value(t, read_full, Body_Region_Fault.None)
	testing.expect(t, n_full == 64 && slice.equal(dst[:64], full[:]))

	// Payload one byte past capacity is refused without changing region.
	too_big: [65]u8
	before := region
	_, big_fault := body_region_write(region[:], too_big[:])
	testing.expect_value(t, big_fault, Body_Region_Fault.Payload_Too_Large)
	testing.expect(t, slice.equal(region[:], before[:]))

	// Generation exhaustion at max(u32) on wrap is refused without mutating region.
	h := read_raw_header(region[:])
	h.generation = max(u32)
	write_raw_header(region[:], h)
	before_exhaust := region
	_, exhaust_fault := body_region_write(region[:], d_data[:])
	testing.expect_value(t, exhaust_fault, Body_Region_Fault.Generation_Exhausted)
	testing.expect(t, slice.equal(region[:], before_exhaust[:]))
}

// Zero-length payloads are refused under Non_Empty_Required and accepted under
// Allow_Empty, and every non-None fault maps to a non-zero Error_Record.
@(test)
body_region_zero_length_policy_and_error_records :: proc(t: ^testing.T) {
	region: [BODY_REGION_HEADER_SIZE + 32]u8
	testing.expect_value(t, body_region_init(region[:], 8), Body_Region_Fault.None)

	_, zfault := body_region_write(region[:], nil, .Non_Empty_Required)
	testing.expect_value(t, zfault, Body_Region_Fault.Zero_Length)

	ref, ok_fault := body_region_write(region[:], nil, .Allow_Empty)
	testing.expect_value(t, ok_fault, Body_Region_Fault.None)
	testing.expect(t, ref.offset == 0 && ref.length == 0 && ref.generation == 1 && ref.serial == 0)

	dst: [8]u8
	n, rf := body_region_read(region[:], ref, dst[:], .Allow_Empty, true, 0)
	testing.expect_value(t, rf, Body_Region_Fault.None)
	testing.expect_value(t, n, 0)
	_, rf = body_region_read(region[:], ref, dst[:], .Non_Empty_Required)
	testing.expect_value(t, rf, Body_Region_Fault.Zero_Length)

	testing.expect_value(t, body_region_error(.None), errors.Error_Record{})
	for member in Body_Region_Fault {
		if member == .None {
			continue
		}
		rec := body_region_error(member, 1, 2)
		testing.expectf(t, rec.kind != 0, "fault %v gave zero Error_Record", member)
	}
}

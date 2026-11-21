// Deterministic block disk image format (MODGBD1) for packing read-only input
// trees and extracting guest-written output trees into canonical MODTREE1
// bytes plus their exact domain-separated tree_hash.
//
// Binary layout (all integers little-endian):
//
//   Header (64 bytes, offset 0):
//     [0..7]   magic                 "MODGBD1"
//     [7]      format_version        1
//     [8..12]  role_word             Guest_Disk_Role (1..3)
//     [12..16] flags                 bit 0 = DISK_FLAG_READ_ONLY; other bits 0
//     [16..20] entry_count           0 ..= MAX_DISK_ENTRIES
//     [20..24] reserved              0
//     [24..32] frozen_epoch_seconds  u64
//     [32..40] total_image_bytes     u64 (header + directory + payloads)
//     [40..64] reserved_padding      all zero bytes
//
//   Directory entries (176 bytes each, starting at offset 64, strictly sorted
//   by UTF-8 byte order of path with no duplicate and no file/directory prefix
//   conflict):
//     [0..2]     path_length   u16 (1 ..= MAX_MOUNT_PATH_BYTES)
//     [2..4]     reserved      u16 (must be 0)
//     [4..128]   path          [124]u8, zero-padded past path_length
//     [128..136] data_offset   u64 (monotonic, non-overlapping, >= directory end)
//     [136..144] data_size     u64
//     [144..176] content_hash  32-byte BLAKE3 hash of payload bytes
//
//   Payload area (starting at offset 64 + entry_count * 176):
//     Packed file payload bytes for entries 0 ..< entry_count in entry order.
//     Any remaining bytes in a fixed-size block device past total_image_bytes
//     must be zero.
package guest_builder

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/tree_hash"

// Magic bytes identifying the deterministic guest builder disk image format.
DISK_MAGIC :: [7]u8{'M', 'O', 'D', 'G', 'B', 'D', '1'}

// Current version byte immediately following DISK_MAGIC.
DISK_FORMAT_VERSION :: u8(1)

// Fixed byte size of the MODGBD1 header.
DISK_HEADER_SIZE :: 64

// Logical sector size of virtual block disks.
DISK_SECTOR_SIZE :: 512

// Maximum number of file entries stored in one MODGBD1 disk image.
MAX_DISK_ENTRIES :: 64

// Fixed byte size of one MODGBD1 directory entry.
DISK_ENTRY_SIZE :: 2 + 2 + MAX_MOUNT_PATH_BYTES + 8 + 8 + blake3.HASH_SIZE

// Flag bit indicating a read-only disk image (Root_Image or Inputs_Read_Only).
DISK_FLAG_READ_ONLY :: u32(1)

// Maximum encoded byte length of one intermediate directory node during unpack.
UNPACK_NODE_BUFFER_BYTES :: tree_hash.HEADER_SIZE + MAX_DISK_ENTRIES * tree_hash.ENTRY_SIZE

#assert(DISK_ENTRY_SIZE == 176)
#assert(DISK_HEADER_SIZE == 64)

// One file supplied when packing a MODGBD1 disk image.
Disk_File_Input :: struct {
	path:    string,
	content: []u8,
}

// Decoded MODGBD1 header returned by validate_disk_image.
Disk_Header :: struct {
	role:                 Guest_Disk_Role,
	read_only:            bool,
	entry_count:          u32,
	frozen_epoch_seconds: u64,
	total_image_bytes:    u64,
}

// Decoded view of one MODGBD1 directory entry.
Disk_Entry_View :: struct {
	path:         string,
	data_offset:  u64,
	data_size:    u64,
	content_hash: blake3.Hash,
}

// Caller-supplied zero-allocation scratch workspace for unpack_output_disk.
// Keeps recursive directory tree construction off the freestanding thread stack.
Disk_Unpack_Workspace :: struct {
	level_entries: [MAX_PATH_DEPTH][MAX_DISK_ENTRIES]tree_hash.Tree_Entry,
	node_buffer:   [UNPACK_NODE_BUFFER_BYTES]u8,
}

// disk_image_required_size computes the exact byte count needed to pack files
// into a MODGBD1 image. Returns (0, false) on overflow or entry count past bound.
disk_image_required_size :: proc "contextless" (files: []Disk_File_Input) -> (size: u64, ok: bool) {
	if len(files) > MAX_DISK_ENTRIES {
		return 0, false
	}
	total := u64(DISK_HEADER_SIZE) + u64(len(files)) * u64(DISK_ENTRY_SIZE)
	for file in files {
		payload_size := u64(len(file.content))
		if payload_size > max(u64) - total {
			return 0, false
		}
		total += payload_size
	}
	return total, true
}

// pack_disk_image validates files and writes a canonical MODGBD1 image with
// the requested role into disk_buffer. All checks run before any byte of
// disk_buffer is modified so a refused call leaves disk_buffer untouched.
pack_disk_image :: proc "contextless" (
	role: Guest_Disk_Role,
	files: []Disk_File_Input,
	frozen_epoch_seconds: u64,
	disk_buffer: []u8,
) -> (written_bytes: int, refusal: Guest_Builder_Refusal) {
	checked_role, role_ok := guest_disk_role_of_word(u64(role))
	if !role_ok {
		return 0, .Malformed_Disk_Image
	}
	if len(files) > MAX_DISK_ENTRIES {
		return 0, .Too_Many_Inputs
	}
	required, size_ok := disk_image_required_size(files)
	if !size_ok || required > u64(len(disk_buffer)) {
		return 0, .Output_Too_Large
	}

	// Pass 1: validate every path, strict UTF-8 sort order, uniqueness, and
	// absence of file/directory prefix conflicts before writing any byte.
	for file, index in files {
		path_bytes := transmute([]u8)file.path
		if !validate_relative_path(path_bytes) {
			return 0, .Invalid_Mount_Path
		}
		if index > 0 {
			previous_path := transmute([]u8)files[index - 1].path
			order := compare_path_bytes(previous_path, path_bytes)
			if order == 0 {
				return 0, .Duplicate_Input_Mount
			}
			if order > 0 {
				return 0, .Malformed_Disk_Image
			}
		}
		// Check all earlier entries because characters below '/' (such as '-'
		// and '.') can sort between "a" and "a/file".
		for earlier in 0 ..< index {
			earlier_path := transmute([]u8)files[earlier].path
			if paths_conflict_as_file_and_directory(earlier_path, path_bytes) {
				return 0, .Duplicate_Input_Mount
			}
		}
	}

	// Pass 2: write canonical header, sorted directory table, and packed payloads.
	for &value in disk_buffer[:required] {
		value = 0
	}
	magic := DISK_MAGIC
	copy(disk_buffer[0:7], magic[:])
	disk_buffer[7] = DISK_FORMAT_VERSION
	byte_order.write_u32_little_endian(disk_buffer, 8, u32(checked_role))
	flags := u32(0)
	switch checked_role {
	case .Root_Image, .Inputs_Read_Only:
		flags = DISK_FLAG_READ_ONLY
	case .Output_Writable:
		flags = 0
	}
	byte_order.write_u32_little_endian(disk_buffer, 12, flags)
	byte_order.write_u32_little_endian(disk_buffer, 16, u32(len(files)))
	byte_order.write_u32_little_endian(disk_buffer, 20, 0)
	byte_order.write_u64_little_endian(disk_buffer, 24, frozen_epoch_seconds)
	byte_order.write_u64_little_endian(disk_buffer, 32, required)

	data_cursor := u64(DISK_HEADER_SIZE) + u64(len(files)) * u64(DISK_ENTRY_SIZE)
	for file, index in files {
		entry_offset := DISK_HEADER_SIZE + index * DISK_ENTRY_SIZE
		path_bytes := transmute([]u8)file.path
		byte_order.write_u16_little_endian(disk_buffer, entry_offset, u16(len(path_bytes)))
		byte_order.write_u16_little_endian(disk_buffer, entry_offset + 2, 0)
		copy(disk_buffer[entry_offset + 4:][:len(path_bytes)], path_bytes)
		payload_size := u64(len(file.content))
		byte_order.write_u64_little_endian(disk_buffer, entry_offset + 128, data_cursor)
		byte_order.write_u64_little_endian(disk_buffer, entry_offset + 136, payload_size)
		content_hash := blake3.hash(file.content)
		copy(disk_buffer[entry_offset + 144:][:blake3.HASH_SIZE], content_hash[:])
		if payload_size > 0 {
			copy(disk_buffer[data_cursor:][:payload_size], file.content)
			data_cursor += payload_size
		}
	}
	return int(required), .None
}

// pack_input_disk packs a sorted hierarchy of immutable input files into a
// read-only MODGBD1 input disk image.
pack_input_disk :: proc "contextless" (
	files: []Disk_File_Input,
	frozen_epoch_seconds: u64,
	disk_buffer: []u8,
) -> (written_bytes: int, refusal: Guest_Builder_Refusal) {
	return pack_disk_image(.Inputs_Read_Only, files, frozen_epoch_seconds, disk_buffer)
}

// validate_disk_image strictly checks every byte of a MODGBD1 disk image:
// header magic/version, role border, flags consistency, reserved zeros, entry
// count, size bound, trailing zeros, strict path validation/sorting/uniqueness,
// non-overlapping in-bounds extents, and per-entry BLAKE3 payload hashes.
validate_disk_image :: proc "contextless" (
	image: []u8,
	expected_role: Guest_Disk_Role,
	size_bound: u64,
) -> (header: Disk_Header, refusal: Guest_Builder_Refusal) {
	checked_expected, expected_ok := guest_disk_role_of_word(u64(expected_role))
	if !expected_ok {
		return {}, .Malformed_Disk_Image
	}
	if len(image) < DISK_HEADER_SIZE {
		return {}, .Malformed_Disk_Image
	}
	magic := DISK_MAGIC
	for index in 0 ..< len(magic) {
		if image[index] != magic[index] {
			return {}, .Malformed_Disk_Image
		}
	}
	if image[7] != DISK_FORMAT_VERSION {
		return {}, .Malformed_Disk_Image
	}
	role_word := byte_order.read_u32_little_endian(image, 8)
	role, role_ok := guest_disk_role_of_word(u64(role_word))
	if !role_ok || role != checked_expected {
		return {}, .Malformed_Disk_Image
	}
	flags := byte_order.read_u32_little_endian(image, 12)
	if flags & ~DISK_FLAG_READ_ONLY != 0 {
		return {}, .Malformed_Disk_Image
	}
	read_only := (flags & DISK_FLAG_READ_ONLY) != 0
	switch role {
	case .Root_Image, .Inputs_Read_Only:
		if !read_only {
			return {}, .Malformed_Disk_Image
		}
	case .Output_Writable:
		if read_only {
			return {}, .Malformed_Disk_Image
		}
	}
	entry_count := byte_order.read_u32_little_endian(image, 16)
	if entry_count > MAX_DISK_ENTRIES {
		return {}, .Malformed_Disk_Image
	}
	if byte_order.read_u32_little_endian(image, 20) != 0 {
		return {}, .Malformed_Disk_Image
	}
	frozen_epoch_seconds := byte_order.read_u64_little_endian(image, 24)
	total_image_bytes := byte_order.read_u64_little_endian(image, 32)
	for pad in image[40:DISK_HEADER_SIZE] {
		if pad != 0 {
			return {}, .Malformed_Disk_Image
		}
	}
	if size_bound > 0 && total_image_bytes > size_bound {
		return {}, .Output_Too_Large
	}
	directory_end := u64(DISK_HEADER_SIZE) + u64(entry_count) * u64(DISK_ENTRY_SIZE)
	if total_image_bytes < directory_end || total_image_bytes > u64(len(image)) {
		return {}, .Malformed_Disk_Image
	}
	// Trailing bytes past total_image_bytes in a fixed-size block device must
	// remain zero so no unverified side-channel data survives in the image.
	for trailing in image[total_image_bytes:] {
		if trailing != 0 {
			return {}, .Malformed_Disk_Image
		}
	}

	previous_path: []u8
	extent_floor := directory_end
	for index in 0 ..< int(entry_count) {
		entry_offset := DISK_HEADER_SIZE + index * DISK_ENTRY_SIZE
		path_length := int(byte_order.read_u16_little_endian(image, entry_offset))
		if path_length == 0 || path_length > MAX_MOUNT_PATH_BYTES {
			return {}, .Malformed_Disk_Image
		}
		if byte_order.read_u16_little_endian(image, entry_offset + 2) != 0 {
			return {}, .Malformed_Disk_Image
		}
		path_slice := image[entry_offset + 4:][:path_length]
		if !validate_relative_path(path_slice) {
			return {}, .Malformed_Disk_Image
		}
		for pad in image[entry_offset + 4 + path_length:entry_offset + 4 + MAX_MOUNT_PATH_BYTES] {
			if pad != 0 {
				return {}, .Malformed_Disk_Image
			}
		}
		if index > 0 {
			order := compare_path_bytes(previous_path, path_slice)
			if order >= 0 {
				return {}, .Malformed_Disk_Image
			}
		}
		// Check all earlier entries because characters below '/' (such as '-'
		// and '.') can sort between "a" and "a/file".
		for earlier in 0 ..< index {
			earlier_offset := DISK_HEADER_SIZE + earlier * DISK_ENTRY_SIZE
			earlier_length := int(byte_order.read_u16_little_endian(image, earlier_offset))
			earlier_path := image[earlier_offset + 4:][:earlier_length]
			if paths_conflict_as_file_and_directory(earlier_path, path_slice) {
				return {}, .Malformed_Disk_Image
			}
		}
		data_offset := byte_order.read_u64_little_endian(image, entry_offset + 128)
		data_size := byte_order.read_u64_little_endian(image, entry_offset + 136)
		if data_offset < extent_floor || data_offset > total_image_bytes {
			return {}, .Malformed_Disk_Image
		}
		if data_size > total_image_bytes - data_offset {
			return {}, .Malformed_Disk_Image
		}
		extent_floor = data_offset + data_size
		expected_hash: blake3.Hash
		copy(expected_hash[:], image[entry_offset + 144:][:blake3.HASH_SIZE])
		actual_hash := blake3.hash(image[data_offset:][:data_size])
		if actual_hash != expected_hash {
			return {}, .Malformed_Disk_Image
		}
		previous_path = path_slice
	}
	if extent_floor != total_image_bytes {
		return {}, .Malformed_Disk_Image
	}

	return Disk_Header {
		role                 = role,
		read_only            = read_only,
		entry_count          = entry_count,
		frozen_epoch_seconds = frozen_epoch_seconds,
		total_image_bytes    = total_image_bytes,
	}, .None
}

// disk_image_entry_at returns entry number index from an already-validated
// MODGBD1 image.
disk_image_entry_at :: proc "contextless" (image: []u8, index: int) -> (entry: Disk_Entry_View, ok: bool) {
	if index < 0 || len(image) < DISK_HEADER_SIZE {
		return {}, false
	}
	entry_count := int(byte_order.read_u32_little_endian(image, 16))
	if index >= entry_count || entry_count > MAX_DISK_ENTRIES {
		return {}, false
	}
	entry_offset := DISK_HEADER_SIZE + index * DISK_ENTRY_SIZE
	if entry_offset + DISK_ENTRY_SIZE > len(image) {
		return {}, false
	}
	path_length := int(byte_order.read_u16_little_endian(image, entry_offset))
	if path_length == 0 || path_length > MAX_MOUNT_PATH_BYTES {
		return {}, false
	}
	entry.path = string(image[entry_offset + 4:][:path_length])
	entry.data_offset = byte_order.read_u64_little_endian(image, entry_offset + 128)
	entry.data_size = byte_order.read_u64_little_endian(image, entry_offset + 136)
	copy(entry.content_hash[:], image[entry_offset + 144:][:blake3.HASH_SIZE])
	return entry, true
}

// path_first_segment splits remainder into its leading segment before '/' and
// the suffix after '/', or returns has_slash = false when remainder is a leaf.
@(private = "file")
path_first_segment :: proc "contextless" (remainder: []u8) -> (segment: []u8, has_slash: bool) {
	for index in 0 ..< len(remainder) {
		if remainder[index] == '/' {
			return remainder[:index], true
		}
	}
	return remainder, false
}

// bytes_equal compares two byte slices for exact equality.
@(private = "file")
bytes_equal :: proc "contextless" (left, right: []u8) -> bool {
	if len(left) != len(right) {
		return false
	}
	for index in 0 ..< len(left) {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

// build_tree_level recursively encodes entries[start ..< end) after stripping
// prefix_length bytes into canonical MODTREE1 bytes and returns its domain-
// separated tree_hash. At depth 0, the canonical bytes are copied into
// root_output if root_output has sufficient capacity.
@(private = "file")
build_tree_level :: proc "contextless" (
	image: []u8,
	start: int,
	end: int,
	prefix_length: int,
	depth: int,
	workspace: ^Disk_Unpack_Workspace,
	root_output: []u8,
) -> (written_root: int, node_hash: blake3.Hash, refusal: Guest_Builder_Refusal) {
	if depth < 0 || depth >= MAX_PATH_DEPTH {
		return 0, {}, .Output_Extraction_Failed
	}
	level_entries := &workspace.level_entries[depth]
	node_count := 0
	cursor := start
	for cursor < end {
		entry_view, entry_ok := disk_image_entry_at(image, cursor)
		if !entry_ok || prefix_length >= len(entry_view.path) {
			return 0, {}, .Output_Extraction_Failed
		}
		path_bytes := transmute([]u8)entry_view.path
		remainder := path_bytes[prefix_length:]
		segment, has_slash := path_first_segment(remainder)
		if node_count >= MAX_DISK_ENTRIES {
			return 0, {}, .Output_Extraction_Failed
		}
		if !has_slash {
			made, make_refusal := tree_hash.tree_entry_make(.Object, string(segment), entry_view.content_hash)
			if make_refusal != .None {
				return 0, {}, .Output_Extraction_Failed
			}
			level_entries[node_count] = made
			node_count += 1
			cursor += 1
		} else {
			// Gather the contiguous range of entries sharing this subdirectory segment.
			group_end := cursor + 1
			for group_end < end {
				next_view, next_ok := disk_image_entry_at(image, group_end)
				if !next_ok || prefix_length >= len(next_view.path) {
					return 0, {}, .Output_Extraction_Failed
				}
				next_bytes := transmute([]u8)next_view.path
				next_segment, next_has_slash := path_first_segment(next_bytes[prefix_length:])
				if !next_has_slash || !bytes_equal(segment, next_segment) {
					break
				}
				group_end += 1
			}
			_, child_hash, child_refusal := build_tree_level(
				image,
				cursor,
				group_end,
				prefix_length + len(segment) + 1,
				depth + 1,
				workspace,
				nil,
			)
			if child_refusal != .None {
				return 0, {}, child_refusal
			}
			made, make_refusal := tree_hash.tree_entry_make(.Tree, string(segment), child_hash)
			if make_refusal != .None {
				return 0, {}, .Output_Extraction_Failed
			}
			level_entries[node_count] = made
			node_count += 1
			cursor = group_end
		}
	}

	// Sort node entries by canonical UTF-8 name order: directory "a" sorts
	// after "a-b" in full-path order ('/' > '-') but before "a-b" as a tree name.
	for i := 1; i < node_count; i += 1 {
		current := level_entries[i]
		current_name := current.name[:current.name_length]
		j := i - 1
		for j >= 0 {
			other_name := level_entries[j].name[:level_entries[j].name_length]
			if tree_hash.compare_name_bytes(other_name, current_name) <= 0 {
				break
			}
			level_entries[j + 1] = level_entries[j]
			j -= 1
		}
		level_entries[j + 1] = current
	}

	encoded_length, encode_refusal := tree_hash.tree_encode(level_entries[:node_count], workspace.node_buffer[:])
	if encode_refusal != .None {
		return 0, {}, .Output_Extraction_Failed
	}
	computed_hash, hash_refusal := tree_hash.tree_hash(workspace.node_buffer[:encoded_length])
	if hash_refusal != .None {
		return 0, {}, .Output_Extraction_Failed
	}
	if depth == 0 {
		if len(root_output) < encoded_length {
			return 0, {}, .Output_Extraction_Failed
		}
		copy(root_output[:encoded_length], workspace.node_buffer[:encoded_length])
		return encoded_length, computed_hash, .None
	}
	return 0, computed_hash, .None
}

// unpack_output_disk validates a guest-written MODGBD1 output disk image,
// encodes its root directory as canonical MODTREE1 bytes into
// canonical_tree_output, and returns the exact domain-separated tree_hash.
// Any refusal leaves canonical_tree_output unchanged and returns a zero hash.
unpack_output_disk :: proc "contextless" (
	image: []u8,
	output_size_bound: u64,
	workspace: ^Disk_Unpack_Workspace,
	canonical_tree_output: []u8,
) -> (written_tree_bytes: int, output_tree_hash: blake3.Hash, refusal: Guest_Builder_Refusal) {
	if workspace == nil {
		return 0, {}, .Output_Extraction_Failed
	}
	if output_size_bound == 0 || output_size_bound > MAX_OUTPUT_DISK_BYTES {
		return 0, {}, .Output_Too_Large
	}
	header, validation_refusal := validate_disk_image(image, .Output_Writable, output_size_bound)
	if validation_refusal != .None {
		return 0, {}, validation_refusal
	}
	return build_tree_level(
		image[:header.total_image_bytes],
		0,
		int(header.entry_count),
		0,
		0,
		workspace,
		canonical_tree_output,
	)
}

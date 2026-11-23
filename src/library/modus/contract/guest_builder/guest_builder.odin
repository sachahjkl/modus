// The contract of the sandboxed guest builder (src/md/features/recipes.md,
// "The three kinds of builder"; src/md/features/guest.md).
//
// A guest build runs a foreign Linux toolchain inside a deterministic,
// zero-network modus virtual machine guest. The guest receives:
//   - a content-addressed Linux kernel and root image (read-only);
//   - a read-only input disk packed in the canonical MODGBD1 format from
//     validated relative mounts of immutable tree_hash inputs;
//   - a blank writable output disk capped at output_size_bound;
//   - a frozen epoch timestamp (default 0, never the wall clock);
//   - an optional content-addressed initial archive (cpio newc), placed in
//     the memory of the guest beside the kernel.
//
// Every integer crossing a binary border is little-endian. Every enum crosses
// a border through one procedure calling enum_word.member_of_word that refuses
// any value naming no member. This package holds no kernel operation call,
// imports no support package, and allocates no memory.
package guest_builder

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/text_encoding"
import "modus:contract/tree_hash"

// Maximum number of read-only input tree mounts in one guest build spec.
MAX_INPUT_MOUNTS :: 64

// Maximum length in bytes of a relative mount path or disk entry path.
MAX_MOUNT_PATH_BYTES :: 124

// Maximum number of slash-separated segments in a validated relative path.
MAX_PATH_DEPTH :: 8

// Maximum length in bytes of the deterministic guest build command line.
MAX_COMMAND_BYTES :: 512

// Minimum and maximum guest memory caps in 4 KiB pages (64 KiB ..= 16 GiB).
// At runtime the caller's process budget and available machine RAM bound the
// actual allocation.
MIN_GUEST_MEMORY_PAGES :: u64(16)
MAX_GUEST_MEMORY_PAGES :: u64(4_194_304)

// Maximum size in bytes of the read-only input disk and blank writable output
// disk (1 GiB each; bounded at runtime by memory and storage budgets).
MAX_INPUT_DISK_BYTES :: u64(1024 * 1024 * 1024)
MAX_OUTPUT_DISK_BYTES :: u64(1024 * 1024 * 1024)

// Maximum size in bytes of the initial archive (1 GiB). The archive lives in
// the memory of the guest, so the memory of the spec bounds it too.
MAX_INITIAL_ARCHIVE_BYTES :: u64(1024 * 1024 * 1024)

// Size in bytes of one page of Guest_Build_Spec.memory_pages.
GUEST_PAGE_BYTES :: u64(4096)

// Default bound on guest exits when spec.max_guest_exits is left zero.
DEFAULT_MAX_GUEST_EXITS :: u64(1_000_000)

// The time of the system that one build may take, in seconds, when
// spec.time_bound_seconds is left zero, and the most that a spec may ask.
// The bound of the exits counts what the guest does; this one ends a guest
// that does nothing that exits, as a loop with its interrupts off, which
// only the timer of the host interrupts. It is a deadline of the contract
// of a build, not the hang bound of a test.
DEFAULT_BUILD_TIME_BOUND_SECONDS :: u32(3_600)
MAX_BUILD_TIME_BOUND_SECONDS :: u32(86_400)

// Wire magic and version for canonical serialized Guest_Build_Spec records.
// Version 4 holds the time bound of the build in the word after the
// version, and the compact canonical mount encoding: only input_count
// mounts appear on the wire, followed immediately by command and initial
// archive.
SPEC_WIRE_MAGIC :: [8]u8{'M', 'O', 'D', 'G', 'B', 'S', 'P', '1'}
SPEC_WIRE_VERSION :: u32(4)

// Domain separation string for hashing a canonical Guest_Build_Spec.
BUILD_SPEC_HASH_DOMAIN :: "modus guest build spec v1"

// Fixed wire size of one serialized Guest_Input_Mount:
//   [0..32]   tree_hash
//   [32..34]  path_length (u16 LE)
//   [34..36]  reserved    (u16 LE, must be 0)
//   [36..160] path        ([124]u8, zero-padded)
INPUT_MOUNT_WIRE_SIZE :: blake3.HASH_SIZE + 2 + 2 + MAX_MOUNT_PATH_BYTES

// Compact canonical wire layout of a serialized Guest_Build_Spec (version 4):
//   [0..8]               magic                 "MODGBSP1"
//   [8..12]              version               u32 LE (4)
//   [12..16]             time_bound_seconds    u32 LE (0: the default)
//   [16..48]             kernel_hash           [32]u8
//   [48..80]             root_image_hash       [32]u8
//   [80..88]             frozen_epoch_seconds  u64 LE
//   [88..96]             memory_pages          u64 LE
//   [96..104]            output_size_bound     u64 LE
//   [104..112]           max_guest_exits       u64 LE
//   [112]                allow_network         u8 (0 or 1; 1 refused)
//   [113]                allow_real_clock      u8 (0 or 1; 1 refused)
//   [114]                allow_writable_inputs u8 (0 or 1; 1 refused)
//   [115]                reserved_flag         u8 (must be 0)
//   [116..120]           input_count           u32 LE (0 ..= MAX_INPUT_MOUNTS)
//   [120..120+N*160]     inputs                [input_count]Guest_Input_Mount
//   [+0..+4]             command_length        u32 LE
//   [+4..+8]             reserved_command      u32 LE (must be 0)
//   [+8..+520]           command               [512]u8 (zero-padded)
//   [+520..+552]         initial_archive_hash  [32]u8 (all zero: none)
//   [+552..+560]         initial_archive_size  u64 LE
SPEC_WIRE_HEADER_SIZE :: 120
SPEC_WIRE_TRAILER_SIZE :: 4 + 4 + MAX_COMMAND_BYTES + blake3.HASH_SIZE + 8
SPEC_WIRE_MIN_SIZE :: SPEC_WIRE_HEADER_SIZE + SPEC_WIRE_TRAILER_SIZE
SPEC_WIRE_SIZE :: SPEC_WIRE_MIN_SIZE + MAX_INPUT_MOUNTS * INPUT_MOUNT_WIRE_SIZE

#assert(INPUT_MOUNT_WIRE_SIZE == 160)
#assert(SPEC_WIRE_TRAILER_SIZE == 560)
#assert(SPEC_WIRE_MIN_SIZE == 680)
#assert(SPEC_WIRE_SIZE == 10920)

// build_time_bound_nanoseconds gives the time of the system that a build of
// spec may take.
build_time_bound_nanoseconds :: proc "contextless" (spec: ^Guest_Build_Spec) -> u64 {
	seconds := spec.time_bound_seconds
	if seconds == 0 {
		seconds = DEFAULT_BUILD_TIME_BOUND_SECONDS
	}
	return u64(min(seconds, MAX_BUILD_TIME_BOUND_SECONDS)) * 1_000_000_000
}

// spec_wire_size gives the exact canonical wire length for input_count mounts.
spec_wire_size :: proc "contextless" (input_count: u32) -> int {
	return SPEC_WIRE_MIN_SIZE + int(input_count) * INPUT_MOUNT_WIRE_SIZE
}

// spec_wire_initial_archive_offset gives the byte offset of
// initial_archive_hash in a compact encoded spec with input_count mounts.
spec_wire_initial_archive_offset :: proc "contextless" (input_count: u32) -> int {
	return SPEC_WIRE_HEADER_SIZE + int(input_count) * INPUT_MOUNT_WIRE_SIZE + 4 + 4 + MAX_COMMAND_BYTES
}

// Closed lifecycle state of a sandboxed guest build.
Guest_Build_State :: enum u8 {
	Prepared  = 1,
	Running   = 2,
	Succeeded = 3,
	Failed    = 4,
	Refused   = 5,
	Timed_Out = 6,
}

// Closed set of virtual block disk roles attached to a guest builder VM.
Guest_Disk_Role :: enum u8 {
	Root_Image       = 1,
	Inputs_Read_Only = 2,
	Output_Writable  = 3,
}

// Closed set of refusals returned by spec validation, disk image verification,
// and sandbox execution.
Guest_Builder_Refusal :: enum u8 {
	None                     = 0,
	Zero_Kernel_Hash         = 1,
	Zero_Root_Image_Hash     = 2,
	Empty_Command            = 3,
	Command_Too_Long         = 4,
	Invalid_Command_Text     = 5,
	Too_Many_Inputs          = 6,
	Duplicate_Input_Mount    = 7,
	Invalid_Mount_Path       = 8,
	Network_Forbidden        = 9,
	Real_Clock_Forbidden     = 10,
	Writable_Input_Forbidden = 11,
	Memory_Too_Small         = 12,
	Memory_Past_Bound        = 13,
	Output_Too_Large         = 14,
	Malformed_Disk_Image     = 15,
	Nonzero_Guest_Exit       = 16,
	Output_Extraction_Failed = 17,
	Initial_Archive_Too_Large    = 18, // Past MAX_INITIAL_ARCHIVE_BYTES, the memory of the guest, or the place that the kernel leaves.
	Initial_Archive_Size_Invalid = 19, // A size with no hash, a hash with no size, or bytes whose count is not the size.
	Initial_Archive_Mismatch     = 20, // The bytes do not have the hash of the spec.
	Time_Bound_Past_Most         = 21, // time_bound_seconds is past MAX_BUILD_TIME_BOUND_SECONDS.
}

// Closed set of block device operations dispatched by the sandbox controller.
Guest_Block_Operation :: enum u8 {
	Read  = 1,
	Write = 2,
	Flush = 3,
}

// Closed set of virtio-blk style status responses returned to the guest.
Guest_Block_Status :: enum u8 {
	Ok          = 0,
	Io_Error    = 1,
	Unsupported = 2,
}

// Closed set of sandbox violations recorded during a guest build run.
Sandbox_Violation_Kind :: enum u8 {
	None                   = 0,
	Read_Only_Disk_Write   = 1,
	Network_Access_Attempt = 2,
	Output_Size_Exceeded   = 3,
}

// Closed set of deterministic I/O ports handled by the guest builder VMM.
Guest_Io_Port :: enum u16 {
	Rtc_Index            = 0x0070,
	Rtc_Data             = 0x0071,
	Debug_Console_Data   = 0x03F8,
	Debug_Console_Status = 0x03FD,
	Frozen_Clock_Low     = 0x0500,
	Frozen_Clock_High    = 0x0504,
	Build_Exit_Status    = 0x0508,
	Block_Disk_Select    = 0x0510,
	Block_Offset_Low     = 0x0514,
	Block_Length         = 0x0518,
	Block_Command        = 0x051C,
	Network_Device_Trap  = 0x0520,
}

// Closed set of legacy CMOS/RTC register indices answered from frozen time.
Guest_Rtc_Register :: enum u8 {
	Seconds      = 0x00,
	Minutes      = 0x02,
	Hours        = 0x04,
	Weekday      = 0x06,
	Day_Of_Month = 0x07,
	Month        = 0x08,
	Year         = 0x09,
	Status_A     = 0x0A,
	Status_B     = 0x0B,
	Century      = 0x32,
}

// One read-only input tree mount declared inside a Guest_Build_Spec.
Guest_Input_Mount :: struct {
	tree_hash:   blake3.Hash,
	path_length: u16,
	reserved:    u16,
	path:        [MAX_MOUNT_PATH_BYTES]u8,
}
#assert(size_of(Guest_Input_Mount) == 160)

// Fixed-layout specification of one deterministic guest build.
// Contains no handles, pointers, or slices so it crosses module borders and
// hashes deterministically.
Guest_Build_Spec :: struct {
	kernel_hash:           blake3.Hash,
	root_image_hash:       blake3.Hash,
	frozen_epoch_seconds:  u64,
	memory_pages:          u64,
	output_size_bound:     u64,
	max_guest_exits:       u64,
	time_bound_seconds:    u32, // The time of the system that the build may take; 0: DEFAULT_BUILD_TIME_BOUND_SECONDS.
	allow_network:         bool,
	allow_real_clock:      bool,
	allow_writable_inputs: bool,
	reserved_flag:         u8,
	input_count:           u32,
	inputs:                [MAX_INPUT_MOUNTS]Guest_Input_Mount,
	command_length:        u32,
	reserved_command:      u32,
	command:               [MAX_COMMAND_BYTES]u8,
	initial_archive_hash:  blake3.Hash, // All zero: the build has no initial archive.
	initial_archive_size:  u64,
}

// Border conversions: every raw transport word becomes its enum member here
// only, refusing any value that names no member.

guest_build_state_of_word :: proc "contextless" (word: u64) -> (state: Guest_Build_State, ok: bool) {
	return enum_word.member_of_word(Guest_Build_State, word)
}

guest_disk_role_of_word :: proc "contextless" (word: u64) -> (role: Guest_Disk_Role, ok: bool) {
	return enum_word.member_of_word(Guest_Disk_Role, word)
}

guest_builder_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Guest_Builder_Refusal, ok: bool) {
	return enum_word.member_of_word(Guest_Builder_Refusal, word)
}

guest_block_operation_of_word :: proc "contextless" (word: u64) -> (operation: Guest_Block_Operation, ok: bool) {
	return enum_word.member_of_word(Guest_Block_Operation, word)
}

guest_io_port_of_word :: proc "contextless" (word: u64) -> (port: Guest_Io_Port, ok: bool) {
	return enum_word.member_of_word(Guest_Io_Port, word)
}

guest_rtc_register_of_word :: proc "contextless" (word: u64) -> (register: Guest_Rtc_Register, ok: bool) {
	return enum_word.member_of_word(Guest_Rtc_Register, word)
}

// hash_is_zero reports whether every byte of hash is zero.
hash_is_zero :: proc "contextless" (hash: blake3.Hash) -> bool {
	for value in hash {
		if value != 0 {
			return false
		}
	}
	return true
}

// compare_path_bytes compares two UTF-8 path byte slices lexicographically:
// -1 if left < right, 0 if equal, 1 if left > right.
compare_path_bytes :: proc "contextless" (left, right: []u8) -> int {
	limit := min(len(left), len(right))
	for index in 0 ..< limit {
		if left[index] != right[index] {
			return left[index] < right[index] ? -1 : 1
		}
	}
	if len(left) < len(right) {
		return -1
	}
	if len(left) > len(right) {
		return 1
	}
	return 0
}

// paths_conflict_as_file_and_directory reports whether either path is a strict
// directory prefix of the other (for example "src" and "src/main.odin").
paths_conflict_as_file_and_directory :: proc "contextless" (left, right: []u8) -> bool {
	if len(left) < len(right) {
		if right[len(left)] != '/' {
			return false
		}
		for index in 0 ..< len(left) {
			if left[index] != right[index] {
				return false
			}
		}
		return true
	}
	if len(right) < len(left) {
		if left[len(right)] != '/' {
			return false
		}
		for index in 0 ..< len(right) {
			if right[index] != left[index] {
				return false
			}
		}
		return true
	}
	return false
}

// validate_relative_path verifies that path_bytes is a canonical relative
// POSIX-style path:
//   - length 1 ..= MAX_MOUNT_PATH_BYTES;
//   - valid non-control UTF-8;
//   - no leading '/', no trailing '/', no empty "//" segment, no '\' byte;
//   - 1 ..= MAX_PATH_DEPTH segments, each passing tree_hash.tree_name_validate
//     (refusing ".", "..", NUL, and segments longer than 64 bytes).
validate_relative_path :: proc "contextless" (path_bytes: []u8) -> bool {
	if len(path_bytes) == 0 || len(path_bytes) > MAX_MOUNT_PATH_BYTES {
		return false
	}
	if path_bytes[0] == '/' || path_bytes[len(path_bytes) - 1] == '/' {
		return false
	}
	if !text_encoding.text_valid(path_bytes) {
		return false
	}
	segment_start := 0
	depth := 0
	for index := 0; index <= len(path_bytes); index += 1 {
		at_end := index == len(path_bytes)
		if !at_end && path_bytes[index] == '\\' {
			return false
		}
		if at_end || path_bytes[index] == '/' {
			segment := path_bytes[segment_start:index]
			if tree_hash.tree_name_validate(segment) != .None {
				return false
			}
			depth += 1
			if depth > MAX_PATH_DEPTH {
				return false
			}
			segment_start = index + 1
		}
	}
	return depth > 0
}

// build_spec_set_command validates and stores command_text into spec, leaving
// spec unchanged when refused.
build_spec_set_command :: proc "contextless" (spec: ^Guest_Build_Spec, command_text: string) -> Guest_Builder_Refusal {
	if spec == nil {
		return .Invalid_Command_Text
	}
	command_bytes := transmute([]u8)command_text
	if len(command_bytes) == 0 {
		return .Empty_Command
	}
	if len(command_bytes) > MAX_COMMAND_BYTES {
		return .Command_Too_Long
	}
	if !text_encoding.text_valid(command_bytes) {
		return .Invalid_Command_Text
	}
	spec.command = {}
	copy(spec.command[:], command_bytes)
	spec.command_length = u32(len(command_bytes))
	spec.reserved_command = 0
	return .None
}

// build_spec_add_input validates and appends one read-only input tree mount to
// spec, leaving spec unchanged when refused.
build_spec_add_input :: proc "contextless" (spec: ^Guest_Build_Spec, mount_path: string, input_tree_hash: blake3.Hash) -> Guest_Builder_Refusal {
	if spec == nil {
		return .Invalid_Mount_Path
	}
	if spec.input_count >= MAX_INPUT_MOUNTS {
		return .Too_Many_Inputs
	}
	path_bytes := transmute([]u8)mount_path
	if !validate_relative_path(path_bytes) {
		return .Invalid_Mount_Path
	}
	if hash_is_zero(input_tree_hash) {
		return .Malformed_Disk_Image
	}
	for index in 0 ..< int(spec.input_count) {
		existing_length := min(int(spec.inputs[index].path_length), MAX_MOUNT_PATH_BYTES)
		existing_path := spec.inputs[index].path[:existing_length]
		if compare_path_bytes(existing_path, path_bytes) == 0 || paths_conflict_as_file_and_directory(existing_path, path_bytes) {
			return .Duplicate_Input_Mount
		}
	}
	slot := &spec.inputs[spec.input_count]
	slot^ = {}
	slot.tree_hash = input_tree_hash
	slot.path_length = u16(len(path_bytes))
	copy(slot.path[:], path_bytes)
	spec.input_count += 1
	return .None
}

// build_spec_set_initial_archive names archive as the initial archive of
// spec by its hash and its size, leaving spec unchanged when refused.
build_spec_set_initial_archive :: proc "contextless" (spec: ^Guest_Build_Spec, archive: []u8) -> Guest_Builder_Refusal {
	if spec == nil || len(archive) == 0 {
		return .Initial_Archive_Size_Invalid
	}
	if u64(len(archive)) > MAX_INITIAL_ARCHIVE_BYTES {
		return .Initial_Archive_Too_Large
	}
	spec.initial_archive_hash = blake3.hash(archive)
	spec.initial_archive_size = u64(len(archive))
	return .None
}

// initial_archive_check checks the size and the hash of the spec against the
// bytes that a caller gave as its initial archive. The caller copies the
// bytes first, so that no other process can change them after the check.
initial_archive_check :: proc "contextless" (spec: ^Guest_Build_Spec, archive: []u8) -> Guest_Builder_Refusal {
	if spec == nil {
		return .Initial_Archive_Size_Invalid
	}
	if hash_is_zero(spec.initial_archive_hash) {
		return len(archive) == 0 && spec.initial_archive_size == 0 ? .None : .Initial_Archive_Size_Invalid
	}
	if u64(len(archive)) > MAX_INITIAL_ARCHIVE_BYTES {
		return .Initial_Archive_Too_Large
	}
	if u64(len(archive)) != spec.initial_archive_size {
		return .Initial_Archive_Size_Invalid
	}
	if blake3.hash(archive) != spec.initial_archive_hash {
		return .Initial_Archive_Mismatch
	}
	return .None
}

// validate_build_spec checks every sandbox and determinism invariant of spec.
// Any violation is refused before a guest processor is created or entered.
validate_build_spec :: proc "contextless" (spec: ^Guest_Build_Spec) -> Guest_Builder_Refusal {
	if spec == nil {
		return .Zero_Kernel_Hash
	}
	if spec.allow_network {
		return .Network_Forbidden
	}
	if spec.allow_real_clock {
		return .Real_Clock_Forbidden
	}
	if spec.allow_writable_inputs {
		return .Writable_Input_Forbidden
	}
	if spec.reserved_flag != 0 || spec.reserved_command != 0 {
		return .Invalid_Command_Text
	}
	if hash_is_zero(spec.kernel_hash) {
		return .Zero_Kernel_Hash
	}
	if hash_is_zero(spec.root_image_hash) {
		return .Zero_Root_Image_Hash
	}
	if spec.memory_pages < MIN_GUEST_MEMORY_PAGES {
		return .Memory_Too_Small
	}
	if spec.memory_pages > MAX_GUEST_MEMORY_PAGES {
		return .Memory_Past_Bound
	}
	if spec.time_bound_seconds > MAX_BUILD_TIME_BOUND_SECONDS {
		return .Time_Bound_Past_Most
	}
	if spec.output_size_bound == 0 || spec.output_size_bound > MAX_OUTPUT_DISK_BYTES {
		return .Output_Too_Large
	}
	if hash_is_zero(spec.initial_archive_hash) {
		if spec.initial_archive_size != 0 {
			return .Initial_Archive_Size_Invalid
		}
	} else {
		if spec.initial_archive_size == 0 {
			return .Initial_Archive_Size_Invalid
		}
		// The archive and the kernel share the memory of the guest: an
		// archive as large as that memory leaves no room for the kernel.
		if spec.initial_archive_size > MAX_INITIAL_ARCHIVE_BYTES || spec.initial_archive_size >= spec.memory_pages * GUEST_PAGE_BYTES {
			return .Initial_Archive_Too_Large
		}
	}
	if spec.command_length == 0 {
		return .Empty_Command
	}
	if spec.command_length > MAX_COMMAND_BYTES {
		return .Command_Too_Long
	}
	command_length := int(spec.command_length)
	if !text_encoding.text_valid(spec.command[:command_length]) {
		return .Invalid_Command_Text
	}
	for pad in spec.command[command_length:MAX_COMMAND_BYTES] {
		if pad != 0 {
			return .Invalid_Command_Text
		}
	}
	if spec.input_count > MAX_INPUT_MOUNTS {
		return .Too_Many_Inputs
	}
	input_count := int(spec.input_count)
	for index in 0 ..< input_count {
		mount := &spec.inputs[index]
		if mount.reserved != 0 {
			return .Invalid_Mount_Path
		}
		if hash_is_zero(mount.tree_hash) {
			return .Malformed_Disk_Image
		}
		path_length := int(mount.path_length)
		if path_length == 0 || path_length > MAX_MOUNT_PATH_BYTES {
			return .Invalid_Mount_Path
		}
		path_slice := mount.path[:path_length]
		if !validate_relative_path(path_slice) {
			return .Invalid_Mount_Path
		}
		for pad in mount.path[path_length:MAX_MOUNT_PATH_BYTES] {
			if pad != 0 {
				return .Invalid_Mount_Path
			}
		}
		for earlier in 0 ..< index {
			earlier_length := int(spec.inputs[earlier].path_length)
			earlier_path := spec.inputs[earlier].path[:earlier_length]
			if compare_path_bytes(earlier_path, path_slice) == 0 || paths_conflict_as_file_and_directory(earlier_path, path_slice) {
				return .Duplicate_Input_Mount
			}
		}
	}
	// Unused input slots must be zero so canonical hashing has no hidden bytes.
	for index in input_count ..< MAX_INPUT_MOUNTS {
		mount := &spec.inputs[index]
		if mount.path_length != 0 || mount.reserved != 0 || !hash_is_zero(mount.tree_hash) {
			return .Invalid_Mount_Path
		}
		for value in mount.path {
			if value != 0 {
				return .Invalid_Mount_Path
			}
		}
	}
	return .None
}

// encode_build_spec validates spec and writes its canonical little-endian wire
// representation into output_buffer. Refused calls leave output_buffer unchanged.
encode_build_spec :: proc "contextless" (spec: ^Guest_Build_Spec, output_buffer: []u8) -> (written: int, refusal: Guest_Builder_Refusal) {
	if validation := validate_build_spec(spec); validation != .None {
		return 0, validation
	}
	required := spec_wire_size(spec.input_count)
	if len(output_buffer) < required {
		return 0, .Output_Too_Large
	}
	magic := SPEC_WIRE_MAGIC
	copy(output_buffer[0:8], magic[:])
	byte_order.write_u32_little_endian(output_buffer, 8, SPEC_WIRE_VERSION)
	byte_order.write_u32_little_endian(output_buffer, 12, spec.time_bound_seconds)
	copy(output_buffer[16:48], spec.kernel_hash[:])
	copy(output_buffer[48:80], spec.root_image_hash[:])
	byte_order.write_u64_little_endian(output_buffer, 80, spec.frozen_epoch_seconds)
	byte_order.write_u64_little_endian(output_buffer, 88, spec.memory_pages)
	byte_order.write_u64_little_endian(output_buffer, 96, spec.output_size_bound)
	byte_order.write_u64_little_endian(output_buffer, 104, spec.max_guest_exits)
	output_buffer[112] = spec.allow_network ? 1 : 0
	output_buffer[113] = spec.allow_real_clock ? 1 : 0
	output_buffer[114] = spec.allow_writable_inputs ? 1 : 0
	output_buffer[115] = 0
	byte_order.write_u32_little_endian(output_buffer, 116, spec.input_count)
	offset := SPEC_WIRE_HEADER_SIZE
	for index in u32(0) ..< spec.input_count {
		mount := &spec.inputs[index]
		copy(output_buffer[offset:offset + blake3.HASH_SIZE], mount.tree_hash[:])
		byte_order.write_u16_little_endian(output_buffer, offset + 32, mount.path_length)
		byte_order.write_u16_little_endian(output_buffer, offset + 34, 0)
		copy(output_buffer[offset + 36:offset + INPUT_MOUNT_WIRE_SIZE], mount.path[:])
		offset += INPUT_MOUNT_WIRE_SIZE
	}
	byte_order.write_u32_little_endian(output_buffer, offset, spec.command_length)
	byte_order.write_u32_little_endian(output_buffer, offset + 4, 0)
	copy(output_buffer[offset + 8:offset + 8 + MAX_COMMAND_BYTES], spec.command[:])
	archive_offset := offset + 8 + MAX_COMMAND_BYTES
	copy(output_buffer[archive_offset:archive_offset + blake3.HASH_SIZE], spec.initial_archive_hash[:])
	byte_order.write_u64_little_endian(output_buffer, archive_offset + blake3.HASH_SIZE, spec.initial_archive_size)
	return required, .None
}

// decode_build_spec strictly decodes and validates a wire-encoded
// Guest_Build_Spec. Any structural error or sandbox violation returns a zero
// spec and the exact refusal.
decode_build_spec :: proc "contextless" (wire_bytes: []u8) -> (spec: Guest_Build_Spec, refusal: Guest_Builder_Refusal) {
	if len(wire_bytes) < SPEC_WIRE_MIN_SIZE || len(wire_bytes) > SPEC_WIRE_SIZE {
		return {}, .Malformed_Disk_Image
	}
	magic := SPEC_WIRE_MAGIC
	for index in 0 ..< len(magic) {
		if wire_bytes[index] != magic[index] {
			return {}, .Malformed_Disk_Image
		}
	}
	if byte_order.read_u32_little_endian(wire_bytes, 8) != SPEC_WIRE_VERSION {
		return {}, .Malformed_Disk_Image
	}
	if wire_bytes[112] > 1 {
		return {}, .Network_Forbidden
	}
	if wire_bytes[113] > 1 {
		return {}, .Real_Clock_Forbidden
	}
	if wire_bytes[114] > 1 {
		return {}, .Writable_Input_Forbidden
	}
	input_count := byte_order.read_u32_little_endian(wire_bytes, 116)
	if input_count > MAX_INPUT_MOUNTS {
		return {}, .Too_Many_Inputs
	}
	if len(wire_bytes) != spec_wire_size(input_count) {
		return {}, .Malformed_Disk_Image
	}
	decoded: Guest_Build_Spec
	copy(decoded.kernel_hash[:], wire_bytes[16:48])
	copy(decoded.root_image_hash[:], wire_bytes[48:80])
	decoded.frozen_epoch_seconds = byte_order.read_u64_little_endian(wire_bytes, 80)
	decoded.memory_pages = byte_order.read_u64_little_endian(wire_bytes, 88)
	decoded.output_size_bound = byte_order.read_u64_little_endian(wire_bytes, 96)
	decoded.max_guest_exits = byte_order.read_u64_little_endian(wire_bytes, 104)
	decoded.time_bound_seconds = byte_order.read_u32_little_endian(wire_bytes, 12)
	decoded.allow_network = wire_bytes[112] != 0
	decoded.allow_real_clock = wire_bytes[113] != 0
	decoded.allow_writable_inputs = wire_bytes[114] != 0
	decoded.reserved_flag = wire_bytes[115]
	decoded.input_count = input_count
	offset := SPEC_WIRE_HEADER_SIZE
	for index in u32(0) ..< input_count {
		mount := &decoded.inputs[index]
		copy(mount.tree_hash[:], wire_bytes[offset:offset + blake3.HASH_SIZE])
		mount.path_length = byte_order.read_u16_little_endian(wire_bytes, offset + 32)
		mount.reserved = byte_order.read_u16_little_endian(wire_bytes, offset + 34)
		copy(mount.path[:], wire_bytes[offset + 36:offset + INPUT_MOUNT_WIRE_SIZE])
		offset += INPUT_MOUNT_WIRE_SIZE
	}
	decoded.command_length = byte_order.read_u32_little_endian(wire_bytes, offset)
	decoded.reserved_command = byte_order.read_u32_little_endian(wire_bytes, offset + 4)
	copy(decoded.command[:], wire_bytes[offset + 8:offset + 8 + MAX_COMMAND_BYTES])
	archive_offset := offset + 8 + MAX_COMMAND_BYTES
	copy(decoded.initial_archive_hash[:], wire_bytes[archive_offset:archive_offset + blake3.HASH_SIZE])
	decoded.initial_archive_size = byte_order.read_u64_little_endian(wire_bytes, archive_offset + blake3.HASH_SIZE)
	if validation := validate_build_spec(&decoded); validation != .None {
		return {}, validation
	}
	return decoded, .None
}

// build_spec_hash computes the domain-separated BLAKE3 identity hash of a
// validated Guest_Build_Spec. Refused specs return a zero hash.
build_spec_hash :: proc "contextless" (spec: ^Guest_Build_Spec) -> (hash: blake3.Hash, refusal: Guest_Builder_Refusal) {
	encoded: [SPEC_WIRE_SIZE]u8
	written, encode_refusal := encode_build_spec(spec, encoded[:])
	if encode_refusal != .None {
		return {}, encode_refusal
	}
	return blake3.derive_key(BUILD_SPEC_HASH_DOMAIN, encoded[:written]), .None
}

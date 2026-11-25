// Versioned export boundary contract for shared network library modules
// (`tcp`, `quic`, and `cryptography`; src/md/api/library_modules.md).
//
// One shared library module loads once and serves every networking process
// through caller-supplied session workspaces, holding zero mutable module-global
// session state or per-base writable relocation segments. This contract defines
// the closed library kinds, ABI versions, required capability feature sets,
// caller workspace sizing and alignment checks, replacement compatibility
// checks, and canonical wire descriptor encoding.
//
// This is a contract package: it imports base and contract packages only,
// calls no kernel operation, and allocates no memory.
package network_library

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Format property: canonical 8-byte header magic for an encoded descriptor.
NETWORK_LIBRARY_WIRE_MAGIC :: [8]u8{'M', 'O', 'D', 'N', 'L', 'I', 'B', '1'}

// Format property: exact canonical byte length of an encoded Network_Library_Descriptor:
//   [0..8]   magic "MODNLIB1"
//   [8..10]  abi_version (u16 LE)
//   [10]     kind (u8)
//   [11]     reserved (0)
//   [12..16] features (u32 LE)
//   [16..20] export_count (u32 LE)
//   [20..24] reserved (0)
//   [24..32] min_workspace_bytes (u64 LE)
//   [32..40] workspace_alignment (u64 LE)
//   [40..48] max_record_bytes (u64 LE)
//   [48..56] reserved (0)
//   [56..88] module_hash (32 bytes)
NETWORK_LIBRARY_DESCRIPTOR_WIRE_SIZE :: 88

// Format property: workspace alignment bounds (64-bit word floor to 4 KiB page ceiling).
NETWORK_LIBRARY_MIN_ALIGNMENT :: u64(8)
NETWORK_LIBRARY_DEFAULT_ALIGNMENT :: u64(64)
NETWORK_LIBRARY_MAX_ALIGNMENT :: u64(4096)

// Format property: upper bound on coarse exports exposed by one shared network library.
NETWORK_LIBRARY_MAX_EXPORT_COUNT :: u32(64)

// Plan value: minimum caller-supplied session workspace bytes for each library kind,
// sized for zero-allocation protocol state (TLS 1.3 transcript + cipher keys, QUIC
// transport/stream state, and stateless AEAD/Ed25519/X25519 scratch).
TCP_SESSION_WORKSPACE_MIN_BYTES :: u64(32 * 1024)
QUIC_SESSION_WORKSPACE_MIN_BYTES :: u64(64 * 1024)
CRYPTOGRAPHY_SESSION_WORKSPACE_MIN_BYTES :: u64(4 * 1024)

// Format property: mask of every valid Network_Library_Feature bit (bits 0..7).
NETWORK_LIBRARY_ALL_FEATURES_MASK :: u32((1 << 8) - 1)

// Closed set of shared network library module kinds.
Network_Library_Kind :: enum u8 {
	Tcp          = 1, // TLS 1.3 over TCP record protection and handshake state.
	Quic         = 2, // QUIC packet protection, framing, and transport state.
	Cryptography = 3, // AEAD, Ed25519, X25519, and key derivation primitives.
}

// Closed set of ABI versions for the coarse network library export boundary.
Network_Library_Abi_Version :: enum u16 {
	V1 = 1,
}

// Closed set of capability bits advertised by a shared network library module.
Network_Library_Feature :: enum u8 {
	Tls13_Record_Protection = 0,
	Tls13_Handshake         = 1,
	Quic_Packet_Protection  = 2,
	Quic_Transport_State    = 3,
	Aead_Chacha20_Poly1305  = 4,
	Aead_Aes256_Gcm         = 5,
	Ed25519_Verify_Sign     = 6,
	X25519_Key_Exchange     = 7,
}

Network_Library_Features :: bit_set[Network_Library_Feature;u32]

// Closed set of refusals returned by boundary validation, workspace checks,
// replacement compatibility checks, and descriptor wire encoding/decoding.
Network_Library_Refusal :: enum u8 {
	None                     = 0,
	Bad_Descriptor           = 1,
	Bad_Kind                 = 2,
	Bad_Abi_Version          = 3,
	Bad_Features             = 4,
	Bad_Export_Count         = 5,
	Zero_Module_Hash         = 6,
	Bad_Workspace_Spec       = 7,
	Bad_Max_Record_Bytes     = 8,
	Workspace_Nil            = 9,
	Workspace_Misaligned     = 10,
	Workspace_Too_Small      = 11,
	Workspace_Address_Wrap   = 12,
	Incompatible_Replacement = 13,
	Buffer_Too_Small         = 14,
	Malformed_Wire           = 15,
}

// Immutable boundary descriptor published by one shared network library module.
Network_Library_Descriptor :: struct {
	kind:                Network_Library_Kind,
	abi_version:         Network_Library_Abi_Version,
	features:            Network_Library_Features,
	export_count:        u32,
	min_workspace_bytes: u64,
	workspace_alignment: u64,
	max_record_bytes:    u64,
	module_hash:         blake3.Hash,
}

// Caller-owned memory span supplied to a shared network library session call.
Session_Workspace_Span :: struct {
	address:    uintptr,
	size_bytes: u64,
}

// Single borders converting raw words into closed enum and bitset values.

network_library_kind_of_word :: proc "contextless" (word: u64) -> (kind: Network_Library_Kind, ok: bool) {
	return enum_word.member_of_word(Network_Library_Kind, word)
}

network_library_abi_version_of_word :: proc "contextless" (word: u64) -> (version: Network_Library_Abi_Version, ok: bool) {
	return enum_word.member_of_word(Network_Library_Abi_Version, word)
}

network_library_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Network_Library_Refusal, ok: bool) {
	return enum_word.member_of_word(Network_Library_Refusal, word)
}

// network_library_features_of_word converts a raw 32-bit word into
// Network_Library_Features, refusing any unknown bit outside bits 0..7.
network_library_features_of_word :: proc "contextless" (word: u32) -> (features: Network_Library_Features, ok: bool) {
	if (word & ~NETWORK_LIBRARY_ALL_FEATURES_MASK) != 0 {
		return {}, false
	}
	return transmute(Network_Library_Features)word, true
}

network_library_features_word :: proc "contextless" (features: Network_Library_Features) -> u32 {
	return transmute(u32)features
}

// network_library_required_features returns the mandatory capability subset
// that a module of kind must expose to satisfy its shared-library contract.
network_library_required_features :: proc "contextless" (kind: Network_Library_Kind) -> Network_Library_Features {
	switch kind {
	case .Tcp:
		return {.Tls13_Record_Protection, .Tls13_Handshake}
	case .Quic:
		return {.Quic_Packet_Protection, .Quic_Transport_State}
	case .Cryptography:
		return {.Aead_Chacha20_Poly1305, .Ed25519_Verify_Sign, .X25519_Key_Exchange}
	}
	return {}
}

// network_library_default_min_workspace returns the baseline session workspace
// floor in bytes for kind.
network_library_default_min_workspace :: proc "contextless" (kind: Network_Library_Kind) -> u64 {
	switch kind {
	case .Tcp:
		return TCP_SESSION_WORKSPACE_MIN_BYTES
	case .Quic:
		return QUIC_SESSION_WORKSPACE_MIN_BYTES
	case .Cryptography:
		return CRYPTOGRAPHY_SESSION_WORKSPACE_MIN_BYTES
	}
	return 0
}

@(private = "file")
hash_is_zero :: proc "contextless" (value: blake3.Hash) -> bool {
	accum: u8 = 0
	for item in value {
		accum |= item
	}
	return accum == 0
}

@(private = "file")
is_power_of_two :: proc "contextless" (value: u64) -> bool {
	return value != 0 && (value & (value - 1)) == 0
}

// network_library_descriptor_validate checks every structural, version,
// feature, alignment, and sizing invariant of desc.
network_library_descriptor_validate :: proc "contextless" (desc: ^Network_Library_Descriptor) -> Network_Library_Refusal {
	if desc == nil {
		return .Bad_Descriptor
	}
	checked_kind, kind_ok := network_library_kind_of_word(u64(desc.kind))
	if !kind_ok {
		return .Bad_Kind
	}
	if _, abi_ok := network_library_abi_version_of_word(u64(desc.abi_version)); !abi_ok {
		return .Bad_Abi_Version
	}
	checked_features, feat_ok := network_library_features_of_word(network_library_features_word(desc.features))
	if !feat_ok {
		return .Bad_Features
	}
	required := network_library_required_features(checked_kind)
	if (checked_features & required) != required {
		return .Bad_Features
	}
	if desc.export_count == 0 || desc.export_count > NETWORK_LIBRARY_MAX_EXPORT_COUNT {
		return .Bad_Export_Count
	}
	if hash_is_zero(desc.module_hash) {
		return .Zero_Module_Hash
	}
	if !is_power_of_two(desc.workspace_alignment) ||
	   desc.workspace_alignment < NETWORK_LIBRARY_MIN_ALIGNMENT ||
	   desc.workspace_alignment > NETWORK_LIBRARY_MAX_ALIGNMENT {
		return .Bad_Workspace_Spec
	}
	floor := network_library_default_min_workspace(checked_kind)
	if desc.min_workspace_bytes < floor || (desc.min_workspace_bytes % desc.workspace_alignment) != 0 {
		return .Bad_Workspace_Spec
	}
	if desc.max_record_bytes == 0 {
		return .Bad_Max_Record_Bytes
	}
	return .None
}

// session_workspace_check verifies that a caller-supplied workspace meets
// desc's alignment and minimum size requirements without address wraparound.
session_workspace_check :: proc "contextless" (
	desc: ^Network_Library_Descriptor,
	workspace: Session_Workspace_Span,
) -> Network_Library_Refusal {
	if desc_ref := network_library_descriptor_validate(desc); desc_ref != .None {
		return desc_ref
	}
	addr := u64(workspace.address)
	if addr == 0 {
		return .Workspace_Nil
	}
	if (addr % desc.workspace_alignment) != 0 {
		return .Workspace_Misaligned
	}
	if workspace.size_bytes < desc.min_workspace_bytes {
		return .Workspace_Too_Small
	}
	if max(u64) - addr < workspace.size_bytes {
		return .Workspace_Address_Wrap
	}
	return .None
}

// network_library_replacement_compatible checks whether replacement can replace
// current without breaking existing importers: kind and ABI version must match,
// every feature of current must remain present, workspace size and alignment
// requirements must not grow, and max_record_bytes must not shrink.
network_library_replacement_compatible :: proc "contextless" (
	current: ^Network_Library_Descriptor,
	replacement: ^Network_Library_Descriptor,
) -> Network_Library_Refusal {
	if cur_ref := network_library_descriptor_validate(current); cur_ref != .None {
		return cur_ref
	}
	if rep_ref := network_library_descriptor_validate(replacement); rep_ref != .None {
		return rep_ref
	}
	if replacement.kind != current.kind || replacement.abi_version != current.abi_version {
		return .Incompatible_Replacement
	}
	if (replacement.features & current.features) != current.features {
		return .Incompatible_Replacement
	}
	if replacement.export_count < current.export_count {
		return .Incompatible_Replacement
	}
	if replacement.min_workspace_bytes > current.min_workspace_bytes ||
	   replacement.workspace_alignment > current.workspace_alignment {
		return .Incompatible_Replacement
	}
	if replacement.max_record_bytes < current.max_record_bytes {
		return .Incompatible_Replacement
	}
	return .None
}

// network_library_descriptor_encode serializes a validated descriptor into its
// exact 88-byte canonical little-endian wire format. Refused calls write nothing.
network_library_descriptor_encode :: proc "contextless" (
	desc: ^Network_Library_Descriptor,
	output: []u8,
) -> (written: int, refusal: Network_Library_Refusal) {
	if val_ref := network_library_descriptor_validate(desc); val_ref != .None {
		return 0, val_ref
	}
	if len(output) < NETWORK_LIBRARY_DESCRIPTOR_WIRE_SIZE {
		return 0, .Buffer_Too_Small
	}
	magic := NETWORK_LIBRARY_WIRE_MAGIC
	copy(output[0:8], magic[:])
	byte_order.write_u16_little_endian(output, 8, u16(desc.abi_version))
	output[10] = u8(desc.kind)
	output[11] = 0
	byte_order.write_u32_little_endian(output, 12, network_library_features_word(desc.features))
	byte_order.write_u32_little_endian(output, 16, desc.export_count)
	byte_order.write_u32_little_endian(output, 20, 0)
	byte_order.write_u64_little_endian(output, 24, desc.min_workspace_bytes)
	byte_order.write_u64_little_endian(output, 32, desc.workspace_alignment)
	byte_order.write_u64_little_endian(output, 40, desc.max_record_bytes)
	byte_order.write_u64_little_endian(output, 48, 0)
	copy(output[56:88], desc.module_hash[:])
	return NETWORK_LIBRARY_DESCRIPTOR_WIRE_SIZE, .None
}

// network_library_descriptor_decode strictly parses an exact 88-byte wire
// descriptor, refusing bad magic, non-zero reserved bytes, unknown enum or
// feature words, truncation, trailing bytes, and invalid workspace specs.
network_library_descriptor_decode :: proc "contextless" (
	input: []u8,
) -> (desc: Network_Library_Descriptor, refusal: Network_Library_Refusal) {
	if len(input) != NETWORK_LIBRARY_DESCRIPTOR_WIRE_SIZE {
		return {}, .Malformed_Wire
	}
	magic := NETWORK_LIBRARY_WIRE_MAGIC
	for index in 0 ..< len(magic) {
		if input[index] != magic[index] {
			return {}, .Malformed_Wire
		}
	}
	if input[11] != 0 ||
	   byte_order.read_u32_little_endian(input, 20) != 0 ||
	   byte_order.read_u64_little_endian(input, 48) != 0 {
		return {}, .Malformed_Wire
	}
	abi_version, abi_ok := network_library_abi_version_of_word(u64(byte_order.read_u16_little_endian(input, 8)))
	if !abi_ok {
		return {}, .Bad_Abi_Version
	}
	kind, kind_ok := network_library_kind_of_word(u64(input[10]))
	if !kind_ok {
		return {}, .Bad_Kind
	}
	features, feat_ok := network_library_features_of_word(byte_order.read_u32_little_endian(input, 12))
	if !feat_ok {
		return {}, .Bad_Features
	}
	candidate := Network_Library_Descriptor {
		kind                = kind,
		abi_version         = abi_version,
		features            = features,
		export_count        = byte_order.read_u32_little_endian(input, 16),
		min_workspace_bytes = byte_order.read_u64_little_endian(input, 24),
		workspace_alignment = byte_order.read_u64_little_endian(input, 32),
		max_record_bytes    = byte_order.read_u64_little_endian(input, 40),
	}
	copy(candidate.module_hash[:], input[56:88])
	if val_ref := network_library_descriptor_validate(&candidate); val_ref != .None {
		return {}, val_ref
	}
	return candidate, .None
}

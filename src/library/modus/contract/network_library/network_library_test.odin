#+build !freestanding
package network_library

import "core:testing"
import "modus:contract/blake3"

@(private = "file")
make_valid_descriptor :: proc(kind: Network_Library_Kind) -> Network_Library_Descriptor {
	return Network_Library_Descriptor {
		kind                = kind,
		abi_version         = .V1,
		features            = network_library_required_features(kind),
		export_count        = 8,
		min_workspace_bytes = network_library_default_min_workspace(kind),
		workspace_alignment = NETWORK_LIBRARY_DEFAULT_ALIGNMENT,
		max_record_bytes    = 16_640,
		module_hash         = blake3.hash(transmute([]u8)string("network-library-module-v1")),
	}
}

@(test)
network_library_enum_and_feature_borders_refuse_unknown_words :: proc(t: ^testing.T) {
	for member in Network_Library_Kind {
		got, ok := network_library_kind_of_word(u64(member))
		testing.expect(t, ok && got == member)
	}
	_, bad_k0 := network_library_kind_of_word(0)
	_, bad_k4 := network_library_kind_of_word(4)
	_, bad_kmax := network_library_kind_of_word(max(u64))
	testing.expect(t, !bad_k0 && !bad_k4 && !bad_kmax)

	for member in Network_Library_Abi_Version {
		got, ok := network_library_abi_version_of_word(u64(member))
		testing.expect(t, ok && got == member)
	}
	_, bad_a0 := network_library_abi_version_of_word(0)
	_, bad_a2 := network_library_abi_version_of_word(2)
	testing.expect(t, !bad_a0 && !bad_a2)

	for member in Network_Library_Refusal {
		got, ok := network_library_refusal_of_word(u64(member))
		testing.expect(t, ok && got == member)
	}
	_, bad_r := network_library_refusal_of_word(16)
	testing.expect(t, !bad_r)

	all_valid, ok_all := network_library_features_of_word(NETWORK_LIBRARY_ALL_FEATURES_MASK)
	testing.expect(t, ok_all && network_library_features_word(all_valid) == NETWORK_LIBRARY_ALL_FEATURES_MASK)
	_, ok_high := network_library_features_of_word(u32(1) << 8)
	_, ok_max := network_library_features_of_word(max(u32))
	testing.expect(t, !ok_high && !ok_max)
}

@(test)
network_library_descriptor_validate_and_wire_roundtrip :: proc(t: ^testing.T) {
	testing.expect_value(t, network_library_descriptor_validate(nil), Network_Library_Refusal.Bad_Descriptor)

	for kind in Network_Library_Kind {
		desc := make_valid_descriptor(kind)
		testing.expect_value(t, network_library_descriptor_validate(&desc), Network_Library_Refusal.None)

		wire: [NETWORK_LIBRARY_DESCRIPTOR_WIRE_SIZE]u8
		written, enc_ref := network_library_descriptor_encode(&desc, wire[:])
		testing.expect_value(t, enc_ref, Network_Library_Refusal.None)
		testing.expect_value(t, written, NETWORK_LIBRARY_DESCRIPTOR_WIRE_SIZE)

		decoded, dec_ref := network_library_descriptor_decode(wire[:])
		testing.expect_value(t, dec_ref, Network_Library_Refusal.None)
		testing.expect_value(t, decoded, desc)
	}

	base := make_valid_descriptor(.Quic)

	bad_kind := base
	bad_kind.kind = Network_Library_Kind(9)
	testing.expect_value(t, network_library_descriptor_validate(&bad_kind), Network_Library_Refusal.Bad_Kind)

	bad_abi := base
	bad_abi.abi_version = Network_Library_Abi_Version(2)
	testing.expect_value(t, network_library_descriptor_validate(&bad_abi), Network_Library_Refusal.Bad_Abi_Version)

	missing_feat := base
	missing_feat.features = {.Quic_Packet_Protection}
	testing.expect_value(t, network_library_descriptor_validate(&missing_feat), Network_Library_Refusal.Bad_Features)

	zero_exp := base
	zero_exp.export_count = 0
	testing.expect_value(t, network_library_descriptor_validate(&zero_exp), Network_Library_Refusal.Bad_Export_Count)

	over_exp := base
	over_exp.export_count = NETWORK_LIBRARY_MAX_EXPORT_COUNT + 1
	testing.expect_value(t, network_library_descriptor_validate(&over_exp), Network_Library_Refusal.Bad_Export_Count)

	zero_hash := base
	zero_hash.module_hash = {}
	testing.expect_value(t, network_library_descriptor_validate(&zero_hash), Network_Library_Refusal.Zero_Module_Hash)

	bad_align := base
	bad_align.workspace_alignment = 48
	testing.expect_value(t, network_library_descriptor_validate(&bad_align), Network_Library_Refusal.Bad_Workspace_Spec)

	small_ws := base
	small_ws.min_workspace_bytes = QUIC_SESSION_WORKSPACE_MIN_BYTES - NETWORK_LIBRARY_DEFAULT_ALIGNMENT
	testing.expect_value(t, network_library_descriptor_validate(&small_ws), Network_Library_Refusal.Bad_Workspace_Spec)

	unaligned_ws := base
	unaligned_ws.min_workspace_bytes = QUIC_SESSION_WORKSPACE_MIN_BYTES + 1
	testing.expect_value(t, network_library_descriptor_validate(&unaligned_ws), Network_Library_Refusal.Bad_Workspace_Spec)

	zero_rec := base
	zero_rec.max_record_bytes = 0
	testing.expect_value(t, network_library_descriptor_validate(&zero_rec), Network_Library_Refusal.Bad_Max_Record_Bytes)

	// Encode into short buffer refuses without writing any byte.
	short_buf: [NETWORK_LIBRARY_DESCRIPTOR_WIRE_SIZE - 1]u8
	short_buf[0] = 0xEE
	w_short, r_short := network_library_descriptor_encode(&base, short_buf[:])
	testing.expect_value(t, r_short, Network_Library_Refusal.Buffer_Too_Small)
	testing.expect_value(t, w_short, 0)
	testing.expect_value(t, short_buf[0], u8(0xEE))

	// Decode refusals: truncated, trailing, bad magic, non-zero reserved bytes, unknown feature bit.
	wire: [NETWORK_LIBRARY_DESCRIPTOR_WIRE_SIZE]u8
	_, _ = network_library_descriptor_encode(&base, wire[:])
	_, dec_trunc := network_library_descriptor_decode(wire[:NETWORK_LIBRARY_DESCRIPTOR_WIRE_SIZE - 1])
	testing.expect_value(t, dec_trunc, Network_Library_Refusal.Malformed_Wire)

	long_wire: [NETWORK_LIBRARY_DESCRIPTOR_WIRE_SIZE + 1]u8
	copy(long_wire[:], wire[:])
	_, dec_trail := network_library_descriptor_decode(long_wire[:])
	testing.expect_value(t, dec_trail, Network_Library_Refusal.Malformed_Wire)

	bad_magic := wire
	bad_magic[7] = '2'
	_, dec_magic := network_library_descriptor_decode(bad_magic[:])
	testing.expect_value(t, dec_magic, Network_Library_Refusal.Malformed_Wire)

	for res_off in ([?]int{11, 20, 48}) {
		bad_res := wire
		bad_res[res_off] = 1
		_, dec_res := network_library_descriptor_decode(bad_res[:])
		testing.expect_value(t, dec_res, Network_Library_Refusal.Malformed_Wire)
	}

	bad_feat_wire := wire
	bad_feat_wire[13] = 0x01 // bit 8 set
	_, dec_feat := network_library_descriptor_decode(bad_feat_wire[:])
	testing.expect_value(t, dec_feat, Network_Library_Refusal.Bad_Features)
}

@(test)
session_workspace_check_alignment_size_and_wrap_refusals :: proc(t: ^testing.T) {
	desc := make_valid_descriptor(.Tcp)

	testing.expect_value(t, session_workspace_check(&desc, {address = 0, size_bytes = TCP_SESSION_WORKSPACE_MIN_BYTES}), Network_Library_Refusal.Workspace_Nil)
	testing.expect_value(t, session_workspace_check(&desc, {address = 0x1004, size_bytes = TCP_SESSION_WORKSPACE_MIN_BYTES}), Network_Library_Refusal.Workspace_Misaligned)
	testing.expect_value(t, session_workspace_check(&desc, {address = 0x1000, size_bytes = TCP_SESSION_WORKSPACE_MIN_BYTES - 1}), Network_Library_Refusal.Workspace_Too_Small)
	testing.expect_value(t, session_workspace_check(&desc, {address = uintptr(max(u64) - 63), size_bytes = TCP_SESSION_WORKSPACE_MIN_BYTES}), Network_Library_Refusal.Workspace_Address_Wrap)

	// Exact aligned boundary workspace succeeds.
	testing.expect_value(t, session_workspace_check(&desc, {address = 0x10000, size_bytes = TCP_SESSION_WORKSPACE_MIN_BYTES}), Network_Library_Refusal.None)
}

@(test)
network_library_replacement_compatibility_rules :: proc(t: ^testing.T) {
	cur := make_valid_descriptor(.Cryptography)
	cur.min_workspace_bytes = 8192
	cur.workspace_alignment = 64

	// Compatible replacement adds AES-GCM, adds exports, and needs equal or smaller workspace.
	rep := cur
	rep.module_hash = blake3.hash(transmute([]u8)string("network-library-module-v2"))
	rep.features |= {.Aead_Aes256_Gcm}
	rep.export_count = 12
	rep.min_workspace_bytes = 4096
	rep.workspace_alignment = 32
	rep.max_record_bytes = 32_768
	testing.expect_value(t, network_library_replacement_compatible(&cur, &rep), Network_Library_Refusal.None)

	// Incompatible: kind mismatch.
	wrong_kind := make_valid_descriptor(.Tcp)
	testing.expect_value(t, network_library_replacement_compatible(&cur, &wrong_kind), Network_Library_Refusal.Incompatible_Replacement)

	// Incompatible: drops a feature that current advertised.
	cur_with_aes := cur
	cur_with_aes.features |= {.Aead_Aes256_Gcm}
	dropped_feat := rep
	dropped_feat.features = network_library_required_features(.Cryptography)
	testing.expect_value(t, network_library_replacement_compatible(&cur_with_aes, &dropped_feat), Network_Library_Refusal.Incompatible_Replacement)

	// Incompatible: shrinks export count.
	shrunk_exp := rep
	shrunk_exp.export_count = cur.export_count - 1
	testing.expect_value(t, network_library_replacement_compatible(&cur, &shrunk_exp), Network_Library_Refusal.Incompatible_Replacement)

	// Incompatible: grows min_workspace_bytes or workspace_alignment.
	bigger_ws := rep
	bigger_ws.min_workspace_bytes = cur.min_workspace_bytes + 64
	testing.expect_value(t, network_library_replacement_compatible(&cur, &bigger_ws), Network_Library_Refusal.Incompatible_Replacement)

	stricter_align := rep
	stricter_align.workspace_alignment = 128
	testing.expect_value(t, network_library_replacement_compatible(&cur, &stricter_align), Network_Library_Refusal.Incompatible_Replacement)

	// Incompatible: shrinks max_record_bytes.
	smaller_rec := rep
	smaller_rec.max_record_bytes = cur.max_record_bytes - 1
	testing.expect_value(t, network_library_replacement_compatible(&cur, &smaller_rec), Network_Library_Refusal.Incompatible_Replacement)
}

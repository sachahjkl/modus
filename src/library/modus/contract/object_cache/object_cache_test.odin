#+build !freestanding
package object_cache

import "base:runtime"
import "core:crypto/ed25519"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/tree_hash"

@(private = "file")
make_sample_hash :: proc(seed: u8) -> blake3.Hash {
	input := [4]u8{seed, seed ~ 0x5A, seed + 17, 0xA5}
	return blake3.hash(input[:])
}

@(private = "file")
make_keypair :: proc(seed_byte: u8) -> (private_key: ed25519.Private_Key, public_bytes: [PUBLIC_KEY_SIZE]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for index in 0 ..< len(seed) {
		seed[index] = seed_byte + u8(index * 7)
	}
	ok := ed25519.private_key_set_bytes(&private_key, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&private_key, public_bytes[:])
	return private_key, public_bytes
}

@(private = "file")
ed25519_verify_callback :: proc "contextless" (
	public_key: [PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [SIGNATURE_SIZE]u8,
	_: rawptr,
) -> bool {
	context = runtime.default_context()
	pub_copy := public_key
	sig_copy := signature
	parsed: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&parsed, pub_copy[:]) {
		return false
	}
	return ed25519.verify(&parsed, message, sig_copy[:])
}

@(private = "file")
make_signed_realisation :: proc(
	recipe_hash: blake3.Hash,
	output_hash: blake3.Hash,
	output_kind: Cache_Object_Kind,
	private_key: ^ed25519.Private_Key,
	public_bytes: [PUBLIC_KEY_SIZE]u8,
) -> Realisation_Record {
	record := Realisation_Record {
		recipe_hash       = recipe_hash,
		output_hash       = output_hash,
		output_kind       = output_kind,
		signer_public_key = public_bytes,
	}
	signing_bytes, ok := realisation_signing_bytes(&record)
	assert(ok)
	ed25519.sign(private_key, signing_bytes[:], record.signature[:])
	return record
}

@(private = "file")
make_sample_tree :: proc(buffer: []u8) -> (encoded: []u8, computed_hash: blake3.Hash) {
	e1, ref1 := tree_hash.tree_entry_make(.Object, "alpha.module", make_sample_hash(11))
	e2, ref2 := tree_hash.tree_entry_make(.Tree, "sub", make_sample_hash(22))
	assert(ref1 == .None && ref2 == .None)
	entries := [2]tree_hash.Tree_Entry{e1, e2}
	written, enc_ref := tree_hash.tree_encode(entries[:], buffer)
	assert(enc_ref == .None)
	encoded = buffer[:written]
	h, h_ref := tree_hash.tree_hash(encoded)
	assert(h_ref == .None)
	return encoded, h
}

@(test)
signing_bytes_domain_separation_and_edges :: proc(t: ^testing.T) {
	_, pub_a := make_keypair(0x41)
	_, pub_b := make_keypair(0x42)
	rec := Realisation_Record {
		recipe_hash       = make_sample_hash(1),
		output_hash       = make_sample_hash(2),
		output_kind       = .Tree,
		signer_public_key = pub_a,
	}
	bytes_a, ok_a := realisation_signing_bytes(&rec)
	testing.expect(t, ok_a)
	testing.expect_value(t, string(bytes_a[:len(REALISATION_SIGNING_DOMAIN)]), REALISATION_SIGNING_DOMAIN)

	// Changing any semantic field changes the signable payload.
	rec_other_kind := rec
	rec_other_kind.output_kind = .Blob
	bytes_kind, ok_kind := realisation_signing_bytes(&rec_other_kind)
	testing.expect(t, ok_kind)
	testing.expect(t, bytes_kind != bytes_a)

	rec_other_key := rec
	rec_other_key.signer_public_key = pub_b
	bytes_key, ok_key := realisation_signing_bytes(&rec_other_key)
	testing.expect(t, ok_key)
	testing.expect(t, bytes_key != bytes_a)

	// Refusals: nil, zero recipe_hash, zero output_hash, bad output_kind.
	_, ok_nil := realisation_signing_bytes(nil)
	testing.expect(t, !ok_nil)
	bad_zero_recipe := rec
	bad_zero_recipe.recipe_hash = {}
	_, ok_zr := realisation_signing_bytes(&bad_zero_recipe)
	testing.expect(t, !ok_zr)
	bad_zero_out := rec
	bad_zero_out.output_hash = {}
	_, ok_zo := realisation_signing_bytes(&bad_zero_out)
	testing.expect(t, !ok_zo)
	bad_kind := rec
	bad_kind.output_kind = Cache_Object_Kind(0)
	_, ok_bk := realisation_signing_bytes(&bad_kind)
	testing.expect(t, !ok_bk)

	// Put_Object signing bytes domain and edges.
	put_bytes, ok_put := put_object_signing_bytes(.Blob, make_sample_hash(5), 1024, pub_a)
	testing.expect(t, ok_put)
	testing.expect_value(t, string(put_bytes[:len(PUT_OBJECT_SIGNING_DOMAIN)]), PUT_OBJECT_SIGNING_DOMAIN)
	_, ok_put_zero := put_object_signing_bytes(.Blob, {}, 10, pub_a)
	testing.expect(t, !ok_put_zero)
	_, ok_put_big_tree := put_object_signing_bytes(.Tree, make_sample_hash(5), u64(MAX_TREE_PAYLOAD_BYTES) + 1, pub_a)
	testing.expect(t, !ok_put_big_tree)
	// Large blob past the old 16 MiB limit is accepted up to MAX_OBJECT_BYTES; one byte past is refused.
	_, ok_put_100m := put_object_signing_bytes(.Blob, make_sample_hash(5), 100 * 1024 * 1024, pub_a)
	testing.expect(t, ok_put_100m)
	_, ok_put_max := put_object_signing_bytes(.Blob, make_sample_hash(5), MAX_OBJECT_BYTES, pub_a)
	testing.expect(t, ok_put_max)
	_, ok_put_big_blob := put_object_signing_bytes(.Blob, make_sample_hash(5), MAX_OBJECT_BYTES + 1, pub_a)
	testing.expect(t, !ok_put_big_blob)
}

@(test)
enum_borders_refuse_unknown_words :: proc(t: ^testing.T) {
	// Edges: 0, valid members, one past max, 255, max u64.
	for bad in ([]u64{0, 7, 8, 255, max(u64)}) {
		_, ok := cache_request_kind_of_word(bad)
		testing.expect(t, !ok)
	}
	for member in Cache_Request_Kind {
		got, ok := cache_request_kind_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}

	for bad in ([]u64{0, 9, 10, 255, max(u64)}) {
		_, ok := cache_response_status_of_word(bad)
		testing.expect(t, !ok)
	}
	for member in Cache_Response_Status {
		got, ok := cache_response_status_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}

	for bad in ([]u64{0, 3, 255, max(u64)}) {
		_, ok := put_object_state_of_word(bad)
		testing.expect(t, !ok)
	}
	for member in Put_Object_State {
		got, ok := put_object_state_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}

	for bad in ([]u64{0, 3, 255, max(u64)}) {
		_, ok := cache_object_kind_of_word(bad)
		testing.expect(t, !ok)
	}
	for member in Cache_Object_Kind {
		got, ok := cache_object_kind_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}

	for bad in ([]u64{0, 5, 255, max(u64)}) {
		_, ok := substitution_mode_of_word(bad)
		testing.expect(t, !ok)
	}
	for member in Substitution_Mode {
		got, ok := substitution_mode_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}
}

@(test)
request_and_response_roundtrips :: proc(t: ^testing.T) {
	buffer: [4096]u8
	private_key, public_bytes := make_keypair(0x31)

	// 1. Has with 1 hash and with MAX_HAS_HASHES (64) hashes.
	has_req := Cache_Request {
		kind       = .Has,
		hash_count = MAX_HAS_HASHES,
	}
	for index in 0 ..< MAX_HAS_HASHES {
		has_req.hashes[index] = make_sample_hash(u8(index + 1))
	}
	expected_size, size_ref := encoded_request_size(&has_req)
	testing.expect_value(t, size_ref, Wire_Refusal.None)
	written, enc_ref := encode_request(&has_req, buffer[:])
	testing.expect_value(t, enc_ref, Wire_Refusal.None)
	testing.expect_value(t, written, expected_size)

	decoded_has, dec_ref := decode_request(buffer[:written])
	testing.expect_value(t, dec_ref, Wire_Refusal.None)
	testing.expect_value(t, decoded_has.kind, Cache_Request_Kind.Has)
	testing.expect_value(t, decoded_has.hash_count, u8(MAX_HAS_HASHES))
	for index in 0 ..< MAX_HAS_HASHES {
		testing.expect_value(t, decoded_has.hashes[index], has_req.hashes[index])
	}

	// Has Ok response with full bitset pattern.
	has_resp := Cache_Response {
		request_kind   = .Has,
		status         = .Ok,
		present_bitset = 0x8000_0000_0000_0001 | 0x0000_0000_00F0_0A00,
	}
	resp_written, resp_ref := encode_response(&has_resp, buffer[:])
	testing.expect_value(t, resp_ref, Wire_Refusal.None)
	dec_has_resp, dec_has_resp_ref := decode_response(buffer[:resp_written])
	testing.expect_value(t, dec_has_resp_ref, Wire_Refusal.None)
	testing.expect_value(t, dec_has_resp.request_kind, Cache_Request_Kind.Has)
	testing.expect_value(t, dec_has_resp.status, Cache_Response_Status.Ok)
	testing.expect_value(t, dec_has_resp.present_bitset, has_resp.present_bitset)

	// 2. Get_Object (Blob at offset 0 and aligned non-zero offset, and Tree at offset 0).
	for kind in Cache_Object_Kind {
		get_obj := Cache_Request {
			kind        = .Get_Object,
			object_hash = make_sample_hash(u8(kind) + 40),
			object_kind = kind,
			offset      = kind == .Blob ? 2 * FRAME_PAYLOAD_BYTES : 0,
		}
		n, r := encode_request(&get_obj, buffer[:])
		testing.expect_value(t, r, Wire_Refusal.None)
		got, dr := decode_request(buffer[:n])
		testing.expect_value(t, dr, Wire_Refusal.None)
		testing.expect_value(t, got.kind, Cache_Request_Kind.Get_Object)
		testing.expect_value(t, got.object_hash, get_obj.object_hash)
		testing.expect_value(t, got.object_kind, kind)
		testing.expect_value(t, got.offset, get_obj.offset)
	}

	// Get_Object Ok response (including 0-byte empty blob and 1-byte blob).
	blob_bytes := transmute([]u8)string("modus object payload")
	one_byte := [1]u8{0x5A}
	for payload in ([][]u8{nil, one_byte[:], blob_bytes}) {
		resp := Cache_Response {
			request_kind = .Get_Object,
			status       = .Ok,
			object_kind  = .Blob,
			object_size  = u64(len(payload)),
			offset       = 0,
			payload      = payload,
		}
		n, r := encode_response(&resp, buffer[:])
		testing.expect_value(t, r, Wire_Refusal.None)
		got, dr := decode_response(buffer[:n])
		testing.expect_value(t, dr, Wire_Refusal.None)
		testing.expect_value(t, got.status, Cache_Response_Status.Ok)
		testing.expect_value(t, got.object_kind, Cache_Object_Kind.Blob)
		testing.expect_value(t, got.object_size, u64(len(payload)))
		testing.expect_value(t, got.offset, u64(0))
		testing.expect_value(t, len(got.proof), 0)
		testing.expect_value(t, len(got.payload), len(payload))
		for i in 0 ..< len(payload) {
			testing.expect_value(t, got.payload[i], payload[i])
		}
	}

	// Get_Object Ok response for a 2-frame blob (final 1-byte frame with 1-level proof).
	proof_one: [PROOF_ENTRY_SIZE]u8
	for i in 0 ..< len(proof_one) {
		proof_one[i] = u8(i + 1)
	}
	ranged_resp := Cache_Response {
		request_kind = .Get_Object,
		status       = .Ok,
		object_kind  = .Blob,
		object_size  = FRAME_PAYLOAD_BYTES + 1,
		offset       = FRAME_PAYLOAD_BYTES,
		proof        = proof_one[:],
		payload      = one_byte[:],
	}
	n_rr, r_rr := encode_response(&ranged_resp, buffer[:])
	testing.expect_value(t, r_rr, Wire_Refusal.None)
	got_rr, d_rr := decode_response(buffer[:n_rr])
	testing.expect_value(t, d_rr, Wire_Refusal.None)
	testing.expect_value(t, got_rr.object_size, u64(FRAME_PAYLOAD_BYTES + 1))
	testing.expect_value(t, got_rr.offset, u64(FRAME_PAYLOAD_BYTES))
	testing.expect_value(t, len(got_rr.proof), PROOF_ENTRY_SIZE)
	testing.expect_value(t, len(got_rr.payload), 1)

	// 3. Get_Realisation request + Ok response.
	recipe_h := make_sample_hash(77)
	output_h := make_sample_hash(88)
	get_real := Cache_Request {
		kind        = .Get_Realisation,
		recipe_hash = recipe_h,
	}
	n_gr, r_gr := encode_request(&get_real, buffer[:])
	testing.expect_value(t, r_gr, Wire_Refusal.None)
	got_gr, d_gr := decode_request(buffer[:n_gr])
	testing.expect_value(t, d_gr, Wire_Refusal.None)
	testing.expect_value(t, got_gr.kind, Cache_Request_Kind.Get_Realisation)
	testing.expect_value(t, got_gr.recipe_hash, recipe_h)

	realisation := make_signed_realisation(recipe_h, output_h, .Tree, &private_key, public_bytes)
	gr_resp := Cache_Response {
		request_kind = .Get_Realisation,
		status       = .Ok,
		realisation  = realisation,
	}
	n_gr_resp, r_gr_resp := encode_response(&gr_resp, buffer[:])
	testing.expect_value(t, r_gr_resp, Wire_Refusal.None)
	got_gr_resp, d_gr_resp := decode_response(buffer[:n_gr_resp])
	testing.expect_value(t, d_gr_resp, Wire_Refusal.None)
	testing.expect_value(t, got_gr_resp.realisation, realisation)

	// 4. Put_Object head request + Ok responses (Accept_Frames and Already_Present) + Put_Object_Frame.
	put_obj := Cache_Request {
		kind                = .Put_Object,
		object_hash         = blake3.hash(blob_bytes),
		object_kind         = .Blob,
		object_size         = u64(len(blob_bytes)),
		uploader_public_key = public_bytes,
	}
	put_sign_bytes, put_sign_ok := put_object_signing_bytes(.Blob, put_obj.object_hash, u64(len(blob_bytes)), public_bytes)
	testing.expect(t, put_sign_ok)
	ed25519.sign(&private_key, put_sign_bytes[:], put_obj.uploader_signature[:])
	n_po, r_po := encode_request(&put_obj, buffer[:])
	testing.expect_value(t, r_po, Wire_Refusal.None)
	got_po, d_po := decode_request(buffer[:n_po])
	testing.expect_value(t, d_po, Wire_Refusal.None)
	testing.expect_value(t, got_po.kind, Cache_Request_Kind.Put_Object)
	testing.expect_value(t, got_po.object_hash, put_obj.object_hash)
	testing.expect_value(t, got_po.object_kind, Cache_Object_Kind.Blob)
	testing.expect_value(t, got_po.object_size, u64(len(blob_bytes)))
	testing.expect_value(t, got_po.uploader_public_key, public_bytes)
	testing.expect_value(t, got_po.uploader_signature, put_obj.uploader_signature)

	for state in Put_Object_State {
		po_resp := Cache_Response {
			request_kind = .Put_Object,
			status       = .Ok,
			put_state    = state,
			offset       = state == .Accept_Frames ? FRAME_PAYLOAD_BYTES : 0,
		}
		n_por, r_por := encode_response(&po_resp, buffer[:])
		testing.expect_value(t, r_por, Wire_Refusal.None)
		got_por, d_por := decode_response(buffer[:n_por])
		testing.expect_value(t, d_por, Wire_Refusal.None)
		testing.expect_value(t, got_por.put_state, state)
		testing.expect_value(t, got_por.offset, po_resp.offset)
	}

	put_frame := Cache_Request {
		kind        = .Put_Object_Frame,
		object_hash = put_obj.object_hash,
		offset      = 0,
		payload     = blob_bytes,
	}
	n_pf, r_pf := encode_request(&put_frame, buffer[:])
	testing.expect_value(t, r_pf, Wire_Refusal.None)
	got_pf, d_pf := decode_request(buffer[:n_pf])
	testing.expect_value(t, d_pf, Wire_Refusal.None)
	testing.expect_value(t, got_pf.kind, Cache_Request_Kind.Put_Object_Frame)
	testing.expect_value(t, got_pf.object_hash, put_obj.object_hash)
	testing.expect_value(t, got_pf.offset, u64(0))
	testing.expect_value(t, string(got_pf.payload), string(blob_bytes))

	pfr := Cache_Response{request_kind = .Put_Object_Frame, status = .Ok}
	n_pfr, r_pfr := encode_response(&pfr, buffer[:])
	testing.expect_value(t, r_pfr, Wire_Refusal.None)
	got_pfr, d_pfr := decode_response(buffer[:n_pfr])
	testing.expect_value(t, d_pfr, Wire_Refusal.None)
	testing.expect_value(t, got_pfr.request_kind, Cache_Request_Kind.Put_Object_Frame)
	testing.expect_value(t, got_pfr.status, Cache_Response_Status.Ok)

	// 5. Put_Realisation request + every non-Ok status response.
	put_real := Cache_Request {
		kind        = .Put_Realisation,
		realisation = realisation,
	}
	n_pr, r_pr := encode_request(&put_real, buffer[:])
	testing.expect_value(t, r_pr, Wire_Refusal.None)
	got_pr, d_pr := decode_request(buffer[:n_pr])
	testing.expect_value(t, d_pr, Wire_Refusal.None)
	testing.expect_value(t, got_pr.kind, Cache_Request_Kind.Put_Realisation)
	testing.expect_value(t, got_pr.realisation, realisation)

	for status in Cache_Response_Status {
		if status == .Ok {
			continue
		}
		err_resp := Cache_Response {
			request_kind = .Put_Realisation,
			status       = status,
		}
		n_err, r_err := encode_response(&err_resp, buffer[:])
		testing.expect_value(t, r_err, Wire_Refusal.None)
		testing.expect_value(t, n_err, FRAME_HEADER_SIZE)
		got_err, d_err := decode_response(buffer[:n_err])
		testing.expect_value(t, d_err, Wire_Refusal.None)
		testing.expect_value(t, got_err.status, status)
	}
}

@(test)
wire_decoder_refuses_hostile_and_malformed_frames :: proc(t: ^testing.T) {
	buffer: [512]u8
	valid_req := Cache_Request {
		kind        = .Get_Object,
		object_hash = make_sample_hash(9),
		object_kind = .Blob,
		offset      = 0,
	}
	n, r := encode_request(&valid_req, buffer[:])
	testing.expect_value(t, r, Wire_Refusal.None)

	// Truncation at every byte offset 0 ..< n.
	for cut in 0 ..< n {
		_, dec_ref := decode_request(buffer[:cut])
		testing.expect_value(t, dec_ref, Wire_Refusal.Truncated)
	}

	// Trailing byte refused.
	buffer[n] = 0x42
	_, trail_ref := decode_request(buffer[:n + 1])
	testing.expect_value(t, trail_ref, Wire_Refusal.Trailing_Bytes)

	// Bad magic (including swapping request/response magic).
	bad_magic := buffer[:n]
	saved_magic := bad_magic[3]
	bad_magic[3] = 'R'
	_, magic_ref := decode_request(bad_magic)
	testing.expect_value(t, magic_ref, Wire_Refusal.Bad_Magic)
	bad_magic[3] = saved_magic

	// Unsupported version: 0, 1, 3, 255.
	for bad_ver in ([]u8{0, 1, 3, 255}) {
		bad_magic[4] = bad_ver
		_, ver_ref := decode_request(bad_magic)
		testing.expect_value(t, ver_ref, Wire_Refusal.Unsupported_Version)
	}
	bad_magic[4] = WIRE_VERSION

	// Unknown request kind words: 0, 7, 255.
	for bad_kind in ([]u8{0, 7, 255}) {
		bad_magic[5] = bad_kind
		_, kind_ref := decode_request(bad_magic)
		testing.expect_value(t, kind_ref, Wire_Refusal.Bad_Request_Kind)
	}
	bad_magic[5] = u8(Cache_Request_Kind.Get_Object)

	// Non-zero reserved header bytes.
	bad_magic[6] = 1
	_, res6_ref := decode_request(bad_magic)
	testing.expect_value(t, res6_ref, Wire_Refusal.Reserved_Nonzero)
	bad_magic[6] = 0
	bad_magic[7] = 0xFF
	_, res7_ref := decode_request(bad_magic)
	testing.expect_value(t, res7_ref, Wire_Refusal.Reserved_Nonzero)
	bad_magic[7] = 0

	// Oversized request header body_length (MAX_REQUEST_BODY_BYTES + 1 and max u32).
	for bad_len in ([]u32{u32(MAX_REQUEST_BODY_BYTES) + 1, max(u32)}) {
		byte_order.write_u32_little_endian(bad_magic, 8, bad_len)
		_, big_ref := decode_request(bad_magic)
		testing.expect_value(t, big_ref, Wire_Refusal.Too_Large)
	}
	byte_order.write_u32_little_endian(bad_magic, 8, u32(GET_OBJECT_BODY_SIZE))

	// Unknown object kind inside Get_Object body: 0, 3, 255.
	for bad_obj in ([]u8{0, 3, 255}) {
		bad_magic[FRAME_HEADER_SIZE + 32] = bad_obj
		_, obj_ref := decode_request(bad_magic)
		testing.expect_value(t, obj_ref, Wire_Refusal.Bad_Object_Kind)
	}
	bad_magic[FRAME_HEADER_SIZE + 32] = u8(Cache_Object_Kind.Blob)

	// Non-zero reserved byte inside Get_Object body.
	bad_magic[FRAME_HEADER_SIZE + 35] = 1
	_, body_res_ref := decode_request(bad_magic)
	testing.expect_value(t, body_res_ref, Wire_Refusal.Reserved_Nonzero)
	bad_magic[FRAME_HEADER_SIZE + 35] = 0

	// Zero hash in Get_Object refused.
	zero_hash_frame: [FRAME_HEADER_SIZE + GET_OBJECT_BODY_SIZE]u8
	copy(zero_hash_frame[:], bad_magic)
	for i in 0 ..< blake3.HASH_SIZE {
		zero_hash_frame[FRAME_HEADER_SIZE + i] = 0
	}
	_, zh_ref := decode_request(zero_hash_frame[:])
	testing.expect_value(t, zh_ref, Wire_Refusal.Zero_Hash)

	// Has count edges: 0, 65, 255 refused on both encode and decode.
	for bad_count in ([]u8{0, MAX_HAS_HASHES + 1, 255}) {
		bad_has := Cache_Request {
			kind       = .Has,
			hash_count = bad_count,
		}
		_, enc_count_ref := encode_request(&bad_has, buffer[:])
		testing.expect_value(t, enc_count_ref, Wire_Refusal.Bad_Count)

		raw_has: [FRAME_HEADER_SIZE + HAS_HEADER_SIZE]u8
		magic := REQUEST_MAGIC
		copy(raw_has[0:4], magic[:])
		raw_has[4] = WIRE_VERSION
		raw_has[5] = u8(Cache_Request_Kind.Has)
		byte_order.write_u32_little_endian(raw_has[:], 8, HAS_HEADER_SIZE)
		raw_has[FRAME_HEADER_SIZE] = bad_count
		_, dec_count_ref := decode_request(raw_has[:])
		testing.expect_value(t, dec_count_ref, Wire_Refusal.Bad_Count)
	}

	// An unaligned offset in Get_Object is refused on encode and decode.
	for bad_off in ([]u64{1, 1024, FRAME_PAYLOAD_BYTES - 1, FRAME_PAYLOAD_BYTES + 1}) {
		unaligned_get := valid_req
		unaligned_get.offset = bad_off
		_, u_enc := encode_request(&unaligned_get, buffer[:])
		testing.expect_value(t, u_enc, Wire_Refusal.Unaligned_Offset)

		byte_order.write_u64_little_endian(bad_magic, FRAME_HEADER_SIZE + 36, bad_off)
		_, u_dec := decode_request(bad_magic)
		testing.expect_value(t, u_dec, Wire_Refusal.Unaligned_Offset)
	}
	byte_order.write_u64_little_endian(bad_magic, FRAME_HEADER_SIZE + 36, 0)
	// Get_Object offset at MAX_OBJECT_BYTES refused as Bad_Range.
	byte_order.write_u64_little_endian(bad_magic, FRAME_HEADER_SIZE + 36, MAX_OBJECT_BYTES)
	_, max_off_ref := decode_request(bad_magic)
	testing.expect_value(t, max_off_ref, Wire_Refusal.Bad_Range)
	byte_order.write_u64_little_endian(bad_magic, FRAME_HEADER_SIZE + 36, 0)
	// The largest offset of the last frame passes.
	byte_order.write_u64_little_endian(bad_magic, FRAME_HEADER_SIZE + 36, MAX_OBJECT_BYTES - FRAME_PAYLOAD_BYTES)
	last_offset_request, last_offset_ref := decode_request(bad_magic)
	testing.expect_value(t, last_offset_ref, Wire_Refusal.None)
	testing.expect_value(t, last_offset_request.offset, MAX_OBJECT_BYTES - FRAME_PAYLOAD_BYTES)
	byte_order.write_u64_little_endian(bad_magic, FRAME_HEADER_SIZE + 36, 0)
	// Get_Object for Tree with non-zero aligned offset refused as Bad_Range.
	tree_off_req := Cache_Request {
		kind        = .Get_Object,
		object_hash = make_sample_hash(9),
		object_kind = .Tree,
		offset      = FRAME_PAYLOAD_BYTES,
	}
	_, tree_off_ref := encode_request(&tree_off_req, buffer[:])
	testing.expect_value(t, tree_off_ref, Wire_Refusal.Bad_Range)

	// Put_Object claiming Tree size past MAX_TREE_PAYLOAD_BYTES or Blob size past MAX_OBJECT_BYTES refused as Too_Large.
	raw_put_tree: [FRAME_HEADER_SIZE + PUT_OBJECT_BODY_SIZE]u8
	magic := REQUEST_MAGIC
	copy(raw_put_tree[0:4], magic[:])
	raw_put_tree[4] = WIRE_VERSION
	raw_put_tree[5] = u8(Cache_Request_Kind.Put_Object)
	byte_order.write_u32_little_endian(raw_put_tree[:], 8, PUT_OBJECT_BODY_SIZE)
	sample_h := make_sample_hash(12)
	copy(raw_put_tree[FRAME_HEADER_SIZE:FRAME_HEADER_SIZE + 32], sample_h[:])
	raw_put_tree[FRAME_HEADER_SIZE + 32] = u8(Cache_Object_Kind.Tree)
	byte_order.write_u64_little_endian(raw_put_tree[:], FRAME_HEADER_SIZE + 36, u64(MAX_TREE_PAYLOAD_BYTES) + 1)
	_, tree_big_ref := decode_request(raw_put_tree[:])
	testing.expect_value(t, tree_big_ref, Wire_Refusal.Too_Large)
	raw_put_tree[FRAME_HEADER_SIZE + 32] = u8(Cache_Object_Kind.Blob)
	byte_order.write_u64_little_endian(raw_put_tree[:], FRAME_HEADER_SIZE + 36, MAX_OBJECT_BYTES + 1)
	_, blob_big_ref := decode_request(raw_put_tree[:])
	testing.expect_value(t, blob_big_ref, Wire_Refusal.Too_Large)

	// Put_Object_Frame with unaligned offset refused as Unaligned_Offset.
	bad_put_frame := Cache_Request {
		kind        = .Put_Object_Frame,
		object_hash = sample_h,
		offset      = 4096,
		payload     = nil,
	}
	_, pf_unaligned := encode_request(&bad_put_frame, buffer[:])
	testing.expect_value(t, pf_unaligned, Wire_Refusal.Unaligned_Offset)

	// Encode refusal must leave output buffer untouched.
	sentinel: [64]u8
	for i in 0 ..< len(sentinel) {
		sentinel[i] = 0xCC
	}
	_, small_ref := encode_request(&valid_req, sentinel[:FRAME_HEADER_SIZE + GET_OBJECT_BODY_SIZE - 1])
	testing.expect_value(t, small_ref, Wire_Refusal.Buffer_Too_Small)
	for value in sentinel {
		testing.expect_value(t, value, u8(0xCC))
	}

	// Response decoder refusals: bad magic, bad status (0, 8, 255), non-empty body on Not_Found, oversized body.
	resp_ok := Cache_Response {
		request_kind = .Get_Realisation,
		status       = .Not_Found,
	}
	rn, rr := encode_response(&resp_ok, buffer[:])
	testing.expect_value(t, rr, Wire_Refusal.None)
	for bad_status in ([]u8{0, 9, 255}) {
		buffer[6] = bad_status
		_, st_ref := decode_response(buffer[:rn])
		testing.expect_value(t, st_ref, Wire_Refusal.Bad_Response_Status)
	}
	// Put_Object Ok response refuses unknown state, non-zero offset for Already_Present, and unaligned offset for Accept_Frames.
	for bad_state in ([]u8{0, 3, 255}) {
		raw_po_resp: [FRAME_HEADER_SIZE + PUT_OBJECT_RESPONSE_BODY_SIZE]u8
		rmagic := RESPONSE_MAGIC
		copy(raw_po_resp[0:4], rmagic[:])
		raw_po_resp[4] = WIRE_VERSION
		raw_po_resp[5] = u8(Cache_Request_Kind.Put_Object)
		raw_po_resp[6] = u8(Cache_Response_Status.Ok)
		byte_order.write_u32_little_endian(raw_po_resp[:], 8, PUT_OBJECT_RESPONSE_BODY_SIZE)
		raw_po_resp[FRAME_HEADER_SIZE] = bad_state
		_, ps_ref := decode_response(raw_po_resp[:])
		testing.expect_value(t, ps_ref, Wire_Refusal.Bad_Put_State)
	}
	bad_present := Cache_Response{request_kind = .Put_Object, status = .Ok, put_state = .Already_Present, offset = FRAME_PAYLOAD_BYTES}
	_, bp_ref := encode_response(&bad_present, buffer[:])
	testing.expect_value(t, bp_ref, Wire_Refusal.Reserved_Nonzero)
	bad_accept := Cache_Response{request_kind = .Put_Object, status = .Ok, put_state = .Accept_Frames, offset = 512}
	_, ba_ref := encode_response(&bad_accept, buffer[:])
	testing.expect_value(t, ba_ref, Wire_Refusal.Unaligned_Offset)

	// Get_Object Ok response refuses short proof (proof cut short) and mismatched frame length.
	short_proof_resp := Cache_Response {
		request_kind = .Get_Object,
		status       = .Ok,
		object_kind  = .Blob,
		object_size  = FRAME_PAYLOAD_BYTES + 1,
		offset       = FRAME_PAYLOAD_BYTES,
		proof        = nil,
		payload      = []u8{0x42},
	}
	_, sp_ref := encode_response(&short_proof_resp, buffer[:])
	testing.expect_value(t, sp_ref, Wire_Refusal.Bad_Range)
	buffer[6] = u8(Cache_Response_Status.Not_Found)
	// Non-zero body on non-Ok status refused as Trailing_Bytes.
	byte_order.write_u32_little_endian(buffer[:], 8, 1)
	buffer[FRAME_HEADER_SIZE] = 0xAA
	_, err_body_ref := decode_response(buffer[:FRAME_HEADER_SIZE + 1])
	testing.expect_value(t, err_body_ref, Wire_Refusal.Trailing_Bytes)
	// Oversized response header refused as Too_Large.
	byte_order.write_u32_little_endian(buffer[:], 8, u32(MAX_RESPONSE_BODY_BYTES) + 1)
	_, resp_big_ref := decode_response(buffer[:rn])
	testing.expect_value(t, resp_big_ref, Wire_Refusal.Too_Large)
}

@(test)
substitution_policy_verifies_blobs_and_trees_by_hash_without_signer :: proc(t: ^testing.T) {
	// Empty policy (no trusted signers, nil verifier): objects still trust by hash!
	empty_policy := Substitution_Policy {
		mode            = .Prefer_Cache,
		trusted_signers = nil,
	}

	// Valid blob passes with zero signers and nil verifier.
	blob := make([]u8, 128)
	defer delete(blob)
	for index in 0 ..< len(blob) {
		blob[index] = u8(index * 3 + 5)
	}
	blob_hash := blake3.hash(blob)
	testing.expect_value(
		t,
		substitution_check(empty_policy, Substitution_Object_Subject{expected_hash = blob_hash, object_kind = .Blob, payload = blob}, nil),
		Substitution_Decision.Trust_By_Hash,
	)

	// Single tampered bit in blob (first, middle, last byte) -> Refuse_Hash_Mismatch.
	for pos in ([]int{0, len(blob) / 2, len(blob) - 1}) {
		blob[pos] ~= 0x01
		testing.expect_value(
			t,
			substitution_check(empty_policy, Substitution_Object_Subject{expected_hash = blob_hash, object_kind = .Blob, payload = blob}, nil),
			Substitution_Decision.Refuse_Hash_Mismatch,
		)
		blob[pos] ~= 0x01
	}

	// Valid canonical tree passes with zero signers and nil verifier.
	tree_buf: [tree_hash.HEADER_SIZE + 2 * tree_hash.ENTRY_SIZE]u8
	tree_bytes, expected_tree_hash := make_sample_tree(tree_buf[:])
	testing.expect_value(
		t,
		substitution_check(empty_policy, Substitution_Object_Subject{expected_hash = expected_tree_hash, object_kind = .Tree, payload = tree_bytes}, nil),
		Substitution_Decision.Trust_By_Hash,
	)

	// Single tampered bit in tree entry hash -> Refuse_Hash_Mismatch.
	hash_byte_offset := tree_hash.HEADER_SIZE + tree_hash.ENTRY_SIZE - 1
	tree_bytes[hash_byte_offset] ~= 0x80
	testing.expect_value(
		t,
		substitution_check(empty_policy, Substitution_Object_Subject{expected_hash = expected_tree_hash, object_kind = .Tree, payload = tree_bytes}, nil),
		Substitution_Decision.Refuse_Hash_Mismatch,
	)
	tree_bytes[hash_byte_offset] ~= 0x80

	// Single tampered bit in tree header magic -> Refuse_Malformed.
	tree_bytes[0] ~= 0x01
	testing.expect_value(
		t,
		substitution_check(empty_policy, Substitution_Object_Subject{expected_hash = expected_tree_hash, object_kind = .Tree, payload = tree_bytes}, nil),
		Substitution_Decision.Refuse_Malformed,
	)
	tree_bytes[0] ~= 0x01

	// Plain blob masquerading as a Tree -> Refuse_Malformed.
	testing.expect_value(
		t,
		substitution_check(empty_policy, Substitution_Object_Subject{expected_hash = blob_hash, object_kind = .Tree, payload = blob}, nil),
		Substitution_Decision.Refuse_Malformed,
	)

	// Domain separation: valid tree bytes checked as Tree against plain blake3.hash(tree_bytes) -> Refuse_Hash_Mismatch.
	plain_hash_of_tree := blake3.hash(tree_bytes)
	testing.expect_value(
		t,
		substitution_check(empty_policy, Substitution_Object_Subject{expected_hash = plain_hash_of_tree, object_kind = .Tree, payload = tree_bytes}, nil),
		Substitution_Decision.Refuse_Hash_Mismatch,
	)

	// Domain separation: valid tree bytes checked as Blob against tree_hash(tree_bytes) -> Refuse_Hash_Mismatch.
	testing.expect_value(
		t,
		substitution_check(empty_policy, Substitution_Object_Subject{expected_hash = expected_tree_hash, object_kind = .Blob, payload = tree_bytes}, nil),
		Substitution_Decision.Refuse_Hash_Mismatch,
	)

	// Zero expected hash or unknown object_kind -> Refuse_Malformed.
	testing.expect_value(
		t,
		substitution_check(empty_policy, Substitution_Object_Subject{expected_hash = {}, object_kind = .Blob, payload = blob}, nil),
		Substitution_Decision.Refuse_Malformed,
	)
	testing.expect_value(
		t,
		substitution_check(empty_policy, Substitution_Object_Subject{expected_hash = blob_hash, object_kind = Cache_Object_Kind(0), payload = blob}, nil),
		Substitution_Decision.Refuse_Malformed,
	)
}

@(test)
substitution_policy_enforces_trusted_signers_and_signatures_for_realisations :: proc(t: ^testing.T) {
	trusted_priv, trusted_pub := make_keypair(0x10)
	second_priv, second_pub := make_keypair(0x20)
	untrusted_priv, untrusted_pub := make_keypair(0x90)
	_ = second_priv

	trusted_list := [2][PUBLIC_KEY_SIZE]u8{trusted_pub, second_pub}
	policy := Substitution_Policy {
		mode            = .Prefer_Cache,
		trusted_signers = trusted_list[:],
	}

	recipe_h := make_sample_hash(101)
	other_recipe_h := make_sample_hash(102)
	output_h := make_sample_hash(202)
	valid_rec := make_signed_realisation(recipe_h, output_h, .Tree, &trusted_priv, trusted_pub)

	// Valid realisation trusted in Prefer_Cache, Cache_Only, and Verify modes.
	for mode in ([]Substitution_Mode{.Prefer_Cache, .Cache_Only, .Verify}) {
		mode_policy := policy
		mode_policy.mode = mode
		testing.expect_value(
			t,
			substitution_check(mode_policy, Substitution_Realisation_Subject{expected_recipe_hash = recipe_h, realisation = valid_rec}, ed25519_verify_callback),
			Substitution_Decision.Trust_By_Signer,
		)
	}

	// Build_Only mode refuses every remote realisation even from a trusted signer.
	build_only_policy := policy
	build_only_policy.mode = .Build_Only
	testing.expect_value(
		t,
		substitution_check(build_only_policy, Substitution_Realisation_Subject{expected_recipe_hash = recipe_h, realisation = valid_rec}, ed25519_verify_callback),
		Substitution_Decision.Refuse_Untrusted_Signer,
	)

	// Untrusted signer key (even with a cryptographically valid Ed25519 signature) -> Refuse_Untrusted_Signer.
	untrusted_rec := make_signed_realisation(recipe_h, output_h, .Tree, &untrusted_priv, untrusted_pub)
	testing.expect_value(
		t,
		substitution_check(policy, Substitution_Realisation_Subject{expected_recipe_hash = recipe_h, realisation = untrusted_rec}, ed25519_verify_callback),
		Substitution_Decision.Refuse_Untrusted_Signer,
	)

	// Flipped signature bit at first, middle, and last byte -> Refuse_Bad_Signature.
	for pos in ([]int{0, 31, 63}) {
		bad_sig_rec := valid_rec
		bad_sig_rec.signature[pos] ~= 0x01
		testing.expect_value(
			t,
			substitution_check(policy, Substitution_Realisation_Subject{expected_recipe_hash = recipe_h, realisation = bad_sig_rec}, ed25519_verify_callback),
			Substitution_Decision.Refuse_Bad_Signature,
		)
	}

	// Tampered output_hash or output_kind after signing -> Refuse_Bad_Signature.
	tampered_output := valid_rec
	tampered_output.output_hash[0] ~= 0x01
	testing.expect_value(
		t,
		substitution_check(policy, Substitution_Realisation_Subject{expected_recipe_hash = recipe_h, realisation = tampered_output}, ed25519_verify_callback),
		Substitution_Decision.Refuse_Bad_Signature,
	)
	tampered_kind := valid_rec
	tampered_kind.output_kind = .Blob
	testing.expect_value(
		t,
		substitution_check(policy, Substitution_Realisation_Subject{expected_recipe_hash = recipe_h, realisation = tampered_kind}, ed25519_verify_callback),
		Substitution_Decision.Refuse_Bad_Signature,
	)

	// Wrong recipe_hash (does not match expected_recipe_hash) -> Refuse_Malformed.
	testing.expect_value(
		t,
		substitution_check(policy, Substitution_Realisation_Subject{expected_recipe_hash = other_recipe_h, realisation = valid_rec}, ed25519_verify_callback),
		Substitution_Decision.Refuse_Malformed,
	)

	// Nil verifier callback refuses with Refuse_Bad_Signature (never silently trusts!).
	testing.expect_value(
		t,
		substitution_check(policy, Substitution_Realisation_Subject{expected_recipe_hash = recipe_h, realisation = valid_rec}, nil),
		Substitution_Decision.Refuse_Bad_Signature,
	)

	// Malformed inputs: zero hashes, zero signer key, bad mode, nil subject.
	zero_signer := valid_rec
	zero_signer.signer_public_key = {}
	testing.expect_value(
		t,
		substitution_check(policy, Substitution_Realisation_Subject{expected_recipe_hash = recipe_h, realisation = zero_signer}, ed25519_verify_callback),
		Substitution_Decision.Refuse_Malformed,
	)
	bad_mode_policy := policy
	bad_mode_policy.mode = Substitution_Mode(0)
	testing.expect_value(
		t,
		substitution_check(bad_mode_policy, Substitution_Realisation_Subject{expected_recipe_hash = recipe_h, realisation = valid_rec}, ed25519_verify_callback),
		Substitution_Decision.Refuse_Malformed,
	)
	testing.expect_value(
		t,
		substitution_check(policy, nil, ed25519_verify_callback),
		Substitution_Decision.Refuse_Malformed,
	)
}

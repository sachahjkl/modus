package cache_server

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/object_cache"
import "modus:contract/tree_hash"
import "modus:cryptography/ed25519"
import "modustool:foundation"

@(private)
make_test_keypair :: proc(seed_byte: u8) -> (private_key: ed25519.Private_Key, public_bytes: [object_cache.PUBLIC_KEY_SIZE]u8, seed: [ed25519.PRIVATE_KEY_SIZE]u8) {
	for index in 0 ..< len(seed) {
		seed[index] = seed_byte + u8(index * 11)
	}
	ok := ed25519.private_key_set_bytes(&private_key, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&private_key, public_bytes[:])
	return private_key, public_bytes, seed
}

@(private)
make_temp_store_dir :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "modus_cache_test_*", context.allocator)
	testing.expect_value(t, err, nil)
	return dir
}

@(private)
encode_req_alloc :: proc(t: ^testing.T, req: ^object_cache.Cache_Request) -> []u8 {
	size, size_ref := object_cache.encoded_request_size(req)
	testing.expect_value(t, size_ref, object_cache.Wire_Refusal.None)
	frame := make([]u8, size)
	written, enc_ref := object_cache.encode_request(req, frame)
	testing.expect_value(t, enc_ref, object_cache.Wire_Refusal.None)
	testing.expect_value(t, written, size)
	return frame
}

@(private)
make_signed_put_object_request :: proc(
	kind: object_cache.Cache_Object_Kind,
	object_hash: blake3.Hash,
	object_size: u64,
	private_key: ^ed25519.Private_Key,
	public_bytes: [object_cache.PUBLIC_KEY_SIZE]u8,
) -> object_cache.Cache_Request {
	req := object_cache.Cache_Request {
		kind                = .Put_Object,
		object_hash         = object_hash,
		object_kind         = kind,
		object_size         = object_size,
		uploader_public_key = public_bytes,
	}
	sign_bytes, ok := object_cache.put_object_signing_bytes(kind, object_hash, object_size, public_bytes)
	assert(ok)
	ed25519.sign(private_key, sign_bytes[:], req.uploader_signature[:])
	return req
}

// test_put_object_on_server runs the full Put_Object + Put_Object_Frame
// exchange over one Cache_Connection and returns the final status.
@(private)
test_put_object_on_server :: proc(
	server: ^Cache_Server,
	head_req: ^object_cache.Cache_Request,
	payload: []u8,
) -> object_cache.Cache_Response_Status {
	conn: Cache_Connection
	cache_connection_init(&conn)
	defer cache_connection_destroy(&conn)

	head_written, head_ref := object_cache.encode_request(head_req, conn.request_buffer)
	if head_ref != .None {
		return .Refused
	}
	resp_bytes, status := cache_server_handle_connection_frame(server, &conn, conn.request_buffer[:head_written])
	if status != .Ok {
		return status
	}
	head_resp, dec_ref := object_cache.decode_response(resp_bytes)
	if dec_ref != .None {
		return .Refused
	}
	if head_resp.put_state == .Already_Present {
		return .Ok
	}
	frame_count, count_ok := object_cache.object_frame_count(u64(len(payload)))
	if !count_ok {
		return .Too_Large
	}
	for frame_index in u64(0) ..< frame_count {
		frame_len, len_ok := object_cache.object_frame_length(u64(len(payload)), frame_index)
		if !len_ok {
			return .Refused
		}
		offset := frame_index * object_cache.FRAME_PAYLOAD_BYTES
		frame_req := object_cache.Cache_Request {
			kind        = .Put_Object_Frame,
			object_hash = head_req.object_hash,
			offset      = offset,
			payload     = payload[int(offset):int(offset) + int(frame_len)],
		}
		fw, fref := object_cache.encode_request(&frame_req, conn.request_buffer)
		if fref != .None {
			return .Refused
		}
		_, fstatus := cache_server_handle_connection_frame(server, &conn, conn.request_buffer[:fw])
		if fstatus != .Ok {
			return fstatus
		}
	}
	return .Ok
}

@(private)
make_signed_realisation_record :: proc(
	recipe_hash: blake3.Hash,
	output_hash: blake3.Hash,
	output_kind: object_cache.Cache_Object_Kind,
	private_key: ^ed25519.Private_Key,
	public_bytes: [object_cache.PUBLIC_KEY_SIZE]u8,
) -> object_cache.Realisation_Record {
	record := object_cache.Realisation_Record {
		recipe_hash       = recipe_hash,
		output_hash       = output_hash,
		output_kind       = output_kind,
		signer_public_key = public_bytes,
	}
	sign_bytes, ok := object_cache.realisation_signing_bytes(&record)
	assert(ok)
	ed25519.sign(private_key, sign_bytes[:], record.signature[:])
	return record
}

@(private)
modus_ed25519_verify_cb :: proc "contextless" (
	public_key: [object_cache.PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [object_cache.SIGNATURE_SIZE]u8,
	_: rawptr,
) -> bool {
	context = runtime.default_context()
	return cache_server_verify_ed25519(public_key, message, signature)
}

@(private)
make_test_tree :: proc(buffer: []u8) -> (encoded: []u8, h: blake3.Hash) {
	e1, r1 := tree_hash.tree_entry_make(.Object, "kernel.module", blake3.hash(transmute([]u8)string("k")))
	e2, r2 := tree_hash.tree_entry_make(.Object, "root.module", blake3.hash(transmute([]u8)string("r")))
	assert(r1 == .None && r2 == .None)
	entries := [2]tree_hash.Tree_Entry{e1, e2}
	written, enc_ref := tree_hash.tree_encode(entries[:], buffer)
	assert(enc_ref == .None)
	encoded = buffer[:written]
	computed, h_ref := tree_hash.tree_hash(encoded)
	assert(h_ref == .None)
	return encoded, computed
}

@(test)
put_and_get_blob_and_tree :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	priv, pub, _ := make_test_keypair(0x11)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{pub}
	server, ok := cache_server_open(dir, authorized[:])
	testing.expect(t, ok)
	defer cache_server_destroy(&server)

	// 1. Put + Get non-empty Blob.
	blob_bytes := transmute([]u8)string("hello modus object cache blob")
	blob_hash := blake3.hash(blob_bytes)
	put_blob_req := make_signed_put_object_request(.Blob, blob_hash, u64(len(blob_bytes)), &priv, pub)
	put_status := test_put_object_on_server(&server, &put_blob_req, blob_bytes)
	testing.expect_value(t, put_status, object_cache.Cache_Response_Status.Ok)

	// Verify tmp/ is clean after atomic rename.
	tmp_entries, tmp_err := os.read_all_directory_by_path(fmt.tprintf("%s/tmp", dir), context.temp_allocator)
	testing.expect_value(t, tmp_err, nil)
	testing.expect_value(t, len(tmp_entries), 0)

	// Get Blob back.
	get_blob_req := object_cache.Cache_Request {
		kind        = .Get_Object,
		object_hash = blob_hash,
		object_kind = .Blob,
		offset      = 0,
	}
	get_blob_frame := encode_req_alloc(t, &get_blob_req)
	defer delete(get_blob_frame)
	get_resp_frame, get_status := cache_server_handle_frame(&server, get_blob_frame)
	defer delete(get_resp_frame)
	testing.expect_value(t, get_status, object_cache.Cache_Response_Status.Ok)
	get_resp, get_dec_ref := object_cache.decode_response(get_resp_frame)
	testing.expect_value(t, get_dec_ref, object_cache.Wire_Refusal.None)
	testing.expect_value(t, get_resp.object_kind, object_cache.Cache_Object_Kind.Blob)
	testing.expect_value(t, get_resp.object_size, u64(len(blob_bytes)))
	testing.expect_value(t, string(get_resp.payload), string(blob_bytes))

	// Requesting stored Blob as Tree must not succeed (Not_Found).
	get_as_tree := object_cache.Cache_Request {
		kind        = .Get_Object,
		object_hash = blob_hash,
		object_kind = .Tree,
		offset      = 0,
	}
	get_as_tree_frame := encode_req_alloc(t, &get_as_tree)
	defer delete(get_as_tree_frame)
	wrong_kind_frame, wrong_kind_status := cache_server_handle_frame(&server, get_as_tree_frame)
	defer delete(wrong_kind_frame)
	testing.expect_value(t, wrong_kind_status, object_cache.Cache_Response_Status.Not_Found)

	// 2. Put + Get canonical Tree.
	tree_buf: [tree_hash.HEADER_SIZE + 2 * tree_hash.ENTRY_SIZE_MOST]u8
	tree_bytes, t_hash := make_test_tree(tree_buf[:])
	put_tree_req := make_signed_put_object_request(.Tree, t_hash, u64(len(tree_bytes)), &priv, pub)
	put_tree_status := test_put_object_on_server(&server, &put_tree_req, tree_bytes)
	testing.expect_value(t, put_tree_status, object_cache.Cache_Response_Status.Ok)

	get_tree_req := object_cache.Cache_Request {
		kind        = .Get_Object,
		object_hash = t_hash,
		object_kind = .Tree,
		offset      = 0,
	}
	get_tree_frame := encode_req_alloc(t, &get_tree_req)
	defer delete(get_tree_frame)
	get_tree_resp_frame, get_tree_status := cache_server_handle_frame(&server, get_tree_frame)
	defer delete(get_tree_resp_frame)
	testing.expect_value(t, get_tree_status, object_cache.Cache_Response_Status.Ok)
	get_tree_resp, get_tree_dec_ref := object_cache.decode_response(get_tree_resp_frame)
	testing.expect_value(t, get_tree_dec_ref, object_cache.Wire_Refusal.None)
	testing.expect_value(t, get_tree_resp.object_kind, object_cache.Cache_Object_Kind.Tree)
	testing.expect_value(t, len(get_tree_resp.payload), len(tree_bytes))
	for i in 0 ..< len(tree_bytes) {
		testing.expect_value(t, get_tree_resp.payload[i], tree_bytes[i])
	}
}

@(test)
put_and_get_signed_realisation_and_has_batch :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	priv, pub, _ := make_test_keypair(0x22)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{pub}
	server, ok := cache_server_open(dir, authorized[:])
	testing.expect(t, ok)
	defer cache_server_destroy(&server)

	recipe_hash := blake3.hash(transmute([]u8)string("recipe-kernel-v1"))
	tree_buf: [tree_hash.HEADER_SIZE + 2 * tree_hash.ENTRY_SIZE_MOST]u8
	tree_bytes, output_tree_hash := make_test_tree(tree_buf[:])

	// Store the output tree and its signed realisation.
	put_tree := make_signed_put_object_request(.Tree, output_tree_hash, u64(len(tree_bytes)), &priv, pub)
	put_tree_status := test_put_object_on_server(&server, &put_tree, tree_bytes)
	testing.expect_value(t, put_tree_status, object_cache.Cache_Response_Status.Ok)

	realisation := make_signed_realisation_record(recipe_hash, output_tree_hash, .Tree, &priv, pub)
	put_real := object_cache.Cache_Request {
		kind        = .Put_Realisation,
		realisation = realisation,
	}
	put_real_frame := encode_req_alloc(t, &put_real)
	defer delete(put_real_frame)
	put_real_resp, put_real_status := cache_server_handle_frame(&server, put_real_frame)
	defer delete(put_real_resp)
	testing.expect_value(t, put_real_status, object_cache.Cache_Response_Status.Ok)

	// Fetch realisation back and validate via Substitution_Policy.
	get_real := object_cache.Cache_Request {
		kind        = .Get_Realisation,
		recipe_hash = recipe_hash,
	}
	get_real_frame := encode_req_alloc(t, &get_real)
	defer delete(get_real_frame)
	get_real_resp_frame, get_real_status := cache_server_handle_frame(&server, get_real_frame)
	defer delete(get_real_resp_frame)
	testing.expect_value(t, get_real_status, object_cache.Cache_Response_Status.Ok)

	decoded_resp, dec_ref := object_cache.decode_response(get_real_resp_frame)
	testing.expect_value(t, dec_ref, object_cache.Wire_Refusal.None)
	testing.expect_value(t, decoded_resp.realisation, realisation)

	policy := object_cache.Substitution_Policy {
		mode            = .Prefer_Cache,
		trusted_signers = authorized[:],
	}
	decision := object_cache.substitution_check(
		policy,
		object_cache.Substitution_Realisation_Subject{expected_recipe_hash = recipe_hash, realisation = decoded_resp.realisation},
		modus_ed25519_verify_cb,
	)
	testing.expect_value(t, decision, object_cache.Substitution_Decision.Trust_By_Signer)

	// Has batch query with 64 hashes: present at slots 0 (tree), 31 (realisation), 63 (tree), absent elsewhere.
	has_req := object_cache.Cache_Request {
		kind       = .Has,
		hash_count = object_cache.MAX_HAS_HASHES,
	}
	for i in 0 ..< object_cache.MAX_HAS_HASHES {
		label := fmt.tprintf("absent-%d", i)
		has_req.hashes[i] = blake3.hash(transmute([]u8)label)
	}
	has_req.hashes[0] = output_tree_hash
	has_req.hashes[31] = recipe_hash
	has_req.hashes[63] = output_tree_hash
	has_frame := encode_req_alloc(t, &has_req)
	defer delete(has_frame)
	has_resp_frame, has_status := cache_server_handle_frame(&server, has_frame)
	defer delete(has_resp_frame)
	testing.expect_value(t, has_status, object_cache.Cache_Response_Status.Ok)
	has_resp, has_dec_ref := object_cache.decode_response(has_resp_frame)
	testing.expect_value(t, has_dec_ref, object_cache.Wire_Refusal.None)
	expected_bitset := (u64(1) << 0) | (u64(1) << 31) | (u64(1) << 63)
	testing.expect_value(t, has_resp.present_bitset, expected_bitset)
}

@(test)
tampered_and_unauthorized_puts_rejected :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	auth_priv, auth_pub, _ := make_test_keypair(0x33)
	rogue_priv, rogue_pub, _ := make_test_keypair(0x77)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{auth_pub}
	server, ok := cache_server_open(dir, authorized[:])
	testing.expect(t, ok)
	defer cache_server_destroy(&server)

	// 1. Tampered blob (authorized signature over claimed hash, payload bit flipped) -> Bad_Hash, nothing written.
	payload := make([]u8, 64)
	defer delete(payload)
	for i in 0 ..< len(payload) {
		payload[i] = u8(i + 1)
	}
	claimed_hash := blake3.hash(payload)
	tampered_req := make_signed_put_object_request(.Blob, claimed_hash, u64(len(payload)), &auth_priv, auth_pub)
	payload[10] ~= 0x01
	st_tampered := test_put_object_on_server(&server, &tampered_req, payload)
	testing.expect_value(t, st_tampered, object_cache.Cache_Response_Status.Bad_Hash)
	testing.expect(t, !cache_server_has(&server, claimed_hash))
	payload[10] ~= 0x01

	// 2. Blob masquerading as Tree -> Bad_Hash, nothing written.
	fake_tree_req := make_signed_put_object_request(.Tree, claimed_hash, u64(len(payload)), &auth_priv, auth_pub)
	st_fake_tree := test_put_object_on_server(&server, &fake_tree_req, payload)
	testing.expect_value(t, st_fake_tree, object_cache.Cache_Response_Status.Bad_Hash)
	testing.expect(t, !cache_server_has(&server, claimed_hash))

	// 3. Tampered signature on Put_Object -> Bad_Signature, nothing written.
	bad_sig_put := make_signed_put_object_request(.Blob, claimed_hash, u64(len(payload)), &auth_priv, auth_pub)
	bad_sig_put.uploader_signature[0] ~= 0x80
	st_bad_sig := test_put_object_on_server(&server, &bad_sig_put, payload)
	testing.expect_value(t, st_bad_sig, object_cache.Cache_Response_Status.Bad_Signature)
	testing.expect(t, !cache_server_has(&server, claimed_hash))

	// 4. Unauthorized Put_Object (valid signature from rogue key) -> Unauthorized, nothing written.
	unauth_put := make_signed_put_object_request(.Blob, claimed_hash, u64(len(payload)), &rogue_priv, rogue_pub)
	st_unauth := test_put_object_on_server(&server, &unauth_put, payload)
	testing.expect_value(t, st_unauth, object_cache.Cache_Response_Status.Unauthorized)
	testing.expect(t, !cache_server_has(&server, claimed_hash))

	// 5. Tampered signature on Put_Realisation -> Bad_Signature, nothing written.
	recipe_h := blake3.hash(transmute([]u8)string("recipe-a"))
	output_h := blake3.hash(transmute([]u8)string("output-a"))
	bad_real := make_signed_realisation_record(recipe_h, output_h, .Tree, &auth_priv, auth_pub)
	bad_real.signature[63] ~= 0x01
	bad_real_req := object_cache.Cache_Request {
		kind        = .Put_Realisation,
		realisation = bad_real,
	}
	bad_real_frame := encode_req_alloc(t, &bad_real_req)
	defer delete(bad_real_frame)
	resp_bad_real, st_bad_real := cache_server_handle_frame(&server, bad_real_frame)
	defer delete(resp_bad_real)
	testing.expect_value(t, st_bad_real, object_cache.Cache_Response_Status.Bad_Signature)
	testing.expect(t, !cache_server_has(&server, recipe_h))

	// 6. Unauthorized Put_Realisation (valid signature from rogue key) -> Unauthorized, nothing written.
	rogue_real := make_signed_realisation_record(recipe_h, output_h, .Tree, &rogue_priv, rogue_pub)
	rogue_real_req := object_cache.Cache_Request {
		kind        = .Put_Realisation,
		realisation = rogue_real,
	}
	rogue_real_frame := encode_req_alloc(t, &rogue_real_req)
	defer delete(rogue_real_frame)
	resp_rogue_real, st_rogue_real := cache_server_handle_frame(&server, rogue_real_frame)
	defer delete(resp_rogue_real)
	testing.expect_value(t, st_rogue_real, object_cache.Cache_Response_Status.Unauthorized)
	testing.expect(t, !cache_server_has(&server, recipe_h))
}

@(test)
unknown_hash_not_found_and_on_disk_corruption_detected :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	priv, pub, _ := make_test_keypair(0x44)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{pub}
	server, ok := cache_server_open(dir, authorized[:])
	testing.expect(t, ok)
	defer cache_server_destroy(&server)

	// Unknown object and realisation return Not_Found.
	missing_h := blake3.hash(transmute([]u8)string("does-not-exist"))
	get_missing_obj := object_cache.Cache_Request {
		kind        = .Get_Object,
		object_hash = missing_h,
		object_kind = .Blob,
		offset      = 0,
	}
	f1 := encode_req_alloc(t, &get_missing_obj)
	defer delete(f1)
	r1, s1 := cache_server_handle_frame(&server, f1)
	defer delete(r1)
	testing.expect_value(t, s1, object_cache.Cache_Response_Status.Not_Found)

	get_missing_real := object_cache.Cache_Request {
		kind        = .Get_Realisation,
		recipe_hash = missing_h,
	}
	f2 := encode_req_alloc(t, &get_missing_real)
	defer delete(f2)
	r2, s2 := cache_server_handle_frame(&server, f2)
	defer delete(r2)
	testing.expect_value(t, s2, object_cache.Cache_Response_Status.Not_Found)

	// Store valid blob, then simulate on-disk bitrot: Get_Object must detect Bad_Hash!
	blob := transmute([]u8)string("intact bytes")
	blob_h := blake3.hash(blob)
	put_req := make_signed_put_object_request(.Blob, blob_h, u64(len(blob)), &priv, pub)
	ps := test_put_object_on_server(&server, &put_req, blob)
	testing.expect_value(t, ps, object_cache.Cache_Response_Status.Ok)

	hex_h := hash_to_hex(blob_h)
	obj_path, path_ok := store_path_for_hex(dir, .Objects, string(hex_h[:]), context.temp_allocator)
	testing.expect(t, path_ok)
	corrupt := transmute([]u8)string("corrupt byte")
	testing.expect_value(t, os.write_entire_file(obj_path, corrupt), nil)

	get_corrupt := object_cache.Cache_Request {
		kind        = .Get_Object,
		object_hash = blob_h,
		object_kind = .Blob,
		offset      = 0,
	}
	cf := encode_req_alloc(t, &get_corrupt)
	defer delete(cf)
	cr, cs := cache_server_handle_frame(&server, cf)
	defer delete(cr)
	testing.expect_value(t, cs, object_cache.Cache_Response_Status.Bad_Hash)
}

@(test)
path_traversal_and_corrupt_wire_frames_rejected :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	server, ok := cache_server_open(dir, nil)
	testing.expect(t, ok)
	defer cache_server_destroy(&server)

	// Adversarial path traversal and invalid hex names must be rejected before any filesystem access.
	bad_names := [?]string {
		"",
		"../etc/passwd",
		"../../secret",
		".",
		"..",
		strings.repeat("a", 63, context.temp_allocator),
		strings.repeat("a", 65, context.temp_allocator),
		strings.repeat("A", 64, context.temp_allocator),
		strings.concatenate({strings.repeat("a", 31, context.temp_allocator), "/", strings.repeat("a", 32, context.temp_allocator)}, context.temp_allocator),
		strings.concatenate({"../", strings.repeat("a", 61, context.temp_allocator)}, context.temp_allocator),
		strings.concatenate({strings.repeat("a", 31, context.temp_allocator), "\x00", strings.repeat("a", 32, context.temp_allocator)}, context.temp_allocator),
		strings.concatenate({strings.repeat("a", 63, context.temp_allocator), "g"}, context.temp_allocator),
	}
	for bad in bad_names {
		testing.expect(t, !hex_hash_valid(bad))
		_, path_ok := store_path_for_hex(dir, .Objects, bad, context.temp_allocator)
		testing.expect(t, !path_ok)
		_, _, read_ok := store_read_by_hex(&server, .Objects, bad)
		testing.expect(t, !read_ok)
		written, added := store_write_atomic(&server, .Objects, bad, transmute([]u8)string("x"))
		testing.expect(t, !written && !added)
	}

	// Corrupt wire frames passed to cache_server_handle_frame produce clean Refused / Too_Large responses.
	corrupt_cases := [?][]u8 {
		nil,
		{0x00, 0x01, 0x02},
		{'B', 'A', 'D', '!', 1, 1, 0, 0, 0, 0, 0, 0},
		{'M', 'O', 'C', 'Q', 99, 1, 0, 0, 0, 0, 0, 0},
		{'M', 'O', 'C', 'Q', 1, 0, 0, 0, 0, 0, 0, 0},
		{'M', 'O', 'C', 'Q', 1, 255, 0, 0, 0, 0, 0, 0},
	}
	for raw in corrupt_cases {
		resp_frame, st := cache_server_handle_frame(&server, raw)
		defer delete(resp_frame)
		testing.expect_value(t, st, object_cache.Cache_Response_Status.Refused)
		decoded, dec_ref := object_cache.decode_response(resp_frame)
		testing.expect_value(t, dec_ref, object_cache.Wire_Refusal.None)
		testing.expect_value(t, decoded.status, object_cache.Cache_Response_Status.Refused)
	}

	// Oversized request frame header yields Too_Large response.
	oversized: [object_cache.FRAME_HEADER_SIZE]u8
	magic := object_cache.REQUEST_MAGIC
	copy(oversized[0:4], magic[:])
	oversized[4] = object_cache.WIRE_VERSION
	oversized[5] = u8(object_cache.Cache_Request_Kind.Put_Object)
	byte_order.write_u32_little_endian(oversized[:], 8, u32(object_cache.MAX_REQUEST_BODY_BYTES) + 1)
	big_resp, big_status := cache_server_handle_frame(&server, oversized[:])
	defer delete(big_resp)
	testing.expect_value(t, big_status, object_cache.Cache_Response_Status.Too_Large)
}

@(test)
loopback_tcp_server_end_to_end :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	priv, pub, _ := make_test_keypair(0x55)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{pub}
	server, open_ok := cache_server_open(dir, authorized[:])
	testing.expect(t, open_ok)
	defer cache_server_destroy(&server)

	listener, listen_err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect_value(t, listen_err, nil)
	bound, bound_err := net.bound_endpoint(listener)
	testing.expect_value(t, bound_err, nil)

	Server_Thread_Args :: struct {
		server:   ^Cache_Server,
		listener: net.TCP_Socket,
	}
	args := Server_Thread_Args{server = &server, listener = listener}
	worker := thread.create_and_start_with_poly_data(&args, proc(a: ^Server_Thread_Args) {
		cache_server_serve_listener(a.server, a.listener)
	})
	defer {
		sync.atomic_store(&server.stop, true)
		_ = net.shutdown(listener, .Both)
		net.close(listener)
		thread.join(worker)
		thread.destroy(worker)
	}

	// Put_Object, then Get_Object, then Has over one TCP stream, through the
	// client of the commands.
	client, connect_outcome := cache_client_connect(net.endpoint_to_string(bound, context.temp_allocator))
	testing.expect_value(t, connect_outcome, Cache_Client_Outcome.Done)
	defer cache_client_close(&client)

	payload := transmute([]u8)string("tcp framed blob payload")
	blob_h, put_outcome := cache_client_put_object(&client, &priv, .Blob, payload)
	testing.expect_value(t, put_outcome, Cache_Client_Outcome.Done)
	testing.expect_value(t, blob_h, blake3.hash(payload))

	got, get_outcome := cache_client_get_object(&client, .Blob, blob_h)
	defer delete(got)
	testing.expect_value(t, get_outcome, Cache_Client_Outcome.Done)
	testing.expect_value(t, string(got), string(payload))

	hashes := [2]blake3.Hash{blob_h, blake3.hash(transmute([]u8)string("absent"))}
	present, has_outcome := cache_client_has(&client, hashes[:])
	testing.expect_value(t, has_outcome, Cache_Client_Outcome.Done)
	testing.expect_value(t, present, u64(1))
}

@(test)
key_file_loaders_and_cli_validation :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	_, pub, seed := make_test_keypair(0x66)
	seed_hex := hash_to_hex(seed)
	pub_hex := hash_to_hex(pub)

	priv_path := fmt.tprintf("%s/signer.key", dir)
	pub_path := fmt.tprintf("%s/signer.key.public", dir)
	bad_path := fmt.tprintf("%s/bad.key", dir)
	testing.expect_value(t, os.write_entire_file(priv_path, transmute([]u8)fmt.tprintf("%s\n", string(seed_hex[:]))), nil)
	testing.expect_value(t, os.write_entire_file(pub_path, transmute([]u8)fmt.tprintf("%s\n", string(pub_hex[:]))), nil)
	testing.expect_value(t, os.write_entire_file(bad_path, transmute([]u8)string("not-a-key\n")), nil)

	derived_pub, priv_ok := read_signer_public_key_from_private_key_file(priv_path)
	testing.expect(t, priv_ok)
	testing.expect_value(t, derived_pub, pub)

	loaded_pub, pub_ok := read_public_key_file("cache-serve", pub_path)
	testing.expect(t, pub_ok)
	testing.expect_value(t, loaded_pub, pub)

	_, bad_priv_ok := read_signer_public_key_from_private_key_file(bad_path)
	testing.expect(t, !bad_priv_ok)
	_, bad_pub_ok := read_public_key_file("cache-serve", bad_path)
	testing.expect(t, !bad_pub_ok)

	// CLI refuses missing --dir and unknown options.
	testing.expect_value(t, run_cache_serve(nil), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_serve([]string{"--bogus"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_serve([]string{"--dir"}), foundation.EXIT_USAGE)
}

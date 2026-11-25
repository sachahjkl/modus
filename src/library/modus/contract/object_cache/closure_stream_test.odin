#+build !freestanding
package object_cache

import "base:runtime"
import "core:crypto/ed25519"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/tree_hash"

@(private = "file")
closure_test_hash :: proc(tag: u8) -> blake3.Hash {
	data := [4]u8{'c', 'l', 's', tag}
	return blake3.hash(data[:])
}

@(private = "file")
closure_test_keypair :: proc(seed_byte: u8) -> (priv: ed25519.Private_Key, pub: [PUBLIC_KEY_SIZE]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for i in 0 ..< len(seed) {
		seed[i] = seed_byte + u8(i * 13)
	}
	ok := ed25519.private_key_set_bytes(&priv, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&priv, pub[:])
	return priv, pub
}

@(private = "file")
closure_test_verify_ed25519 :: proc "contextless" (
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

@(test)
closure_stream_refusal_border_refuses_unknown_words :: proc(t: ^testing.T) {
	for member in Closure_Stream_Refusal {
		got, ok := closure_stream_refusal_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}
	for bad in ([?]u64{16, 255, max(u64)}) {
		_, ok := closure_stream_refusal_of_word(bad)
		testing.expectf(t, !ok, "word %d must not map to Closure_Stream_Refusal", bad)
	}
}

@(test)
closure_header_and_record_headers_refuse_every_edge_and_corruption :: proc(t: ^testing.T) {
	hdr_buf: [CLOSURE_STREAM_HEADER_SIZE]u8
	valid_hdr := Closure_Stream_Header {
		version         = CLOSURE_STREAM_VERSION,
		has_realisation = true,
		root_kind       = .Tree,
		root_hash       = closure_test_hash(1),
		object_count    = 3,
	}

	// Write refusals leave output unchanged.
	_, ref := closure_header_write(nil, hdr_buf[:])
	testing.expect_value(t, ref, Closure_Stream_Refusal.Buffer_Too_Small)
	_, ref = closure_header_write(&valid_hdr, hdr_buf[:CLOSURE_STREAM_HEADER_SIZE - 1])
	testing.expect_value(t, ref, Closure_Stream_Refusal.Buffer_Too_Small)

	bad_ver := valid_hdr
	bad_ver.version = 2
	_, ref = closure_header_write(&bad_ver, hdr_buf[:])
	testing.expect_value(t, ref, Closure_Stream_Refusal.Unsupported_Version)

	bad_kind := valid_hdr
	bad_kind.root_kind = Cache_Object_Kind(9)
	_, ref = closure_header_write(&bad_kind, hdr_buf[:])
	testing.expect_value(t, ref, Closure_Stream_Refusal.Bad_Object_Kind)

	zero_root := valid_hdr
	zero_root.root_hash = {}
	_, ref = closure_header_write(&zero_root, hdr_buf[:])
	testing.expect_value(t, ref, Closure_Stream_Refusal.Zero_Hash)

	zero_count := valid_hdr
	zero_count.object_count = 0
	_, ref = closure_header_write(&zero_count, hdr_buf[:])
	testing.expect_value(t, ref, Closure_Stream_Refusal.Bad_Count)

	over_count := valid_hdr
	over_count.object_count = CLOSURE_STREAM_MAX_OBJECTS + 1
	_, ref = closure_header_write(&over_count, hdr_buf[:])
	testing.expect_value(t, ref, Closure_Stream_Refusal.Bad_Count)

	// Valid write + read round-trip.
	n, wref := closure_header_write(&valid_hdr, hdr_buf[:])
	testing.expect_value(t, wref, Closure_Stream_Refusal.None)
	testing.expect_value(t, n, CLOSURE_STREAM_HEADER_SIZE)

	got_hdr, rref := closure_header_read(hdr_buf[:])
	testing.expect_value(t, rref, Closure_Stream_Refusal.None)
	testing.expect_value(t, got_hdr, valid_hdr)

	// Read refusals: truncated, bad magic, bad version, unknown flags, nonzero reserved, bad kind, zero hash, bad count.
	_, rref = closure_header_read(hdr_buf[:CLOSURE_STREAM_HEADER_SIZE - 1])
	testing.expect_value(t, rref, Closure_Stream_Refusal.Truncated)

	bad_magic := hdr_buf
	bad_magic[7] = '2'
	_, rref = closure_header_read(bad_magic[:])
	testing.expect_value(t, rref, Closure_Stream_Refusal.Bad_Magic)

	bad_ver_bytes := hdr_buf
	byte_order.write_u32_little_endian(bad_ver_bytes[:], 8, 99)
	_, rref = closure_header_read(bad_ver_bytes[:])
	testing.expect_value(t, rref, Closure_Stream_Refusal.Unsupported_Version)

	bad_flags := hdr_buf
	byte_order.write_u32_little_endian(bad_flags[:], 12, 2)
	_, rref = closure_header_read(bad_flags[:])
	testing.expect_value(t, rref, Closure_Stream_Refusal.Reserved_Nonzero)

	bad_res := hdr_buf
	bad_res[63] = 1
	_, rref = closure_header_read(bad_res[:])
	testing.expect_value(t, rref, Closure_Stream_Refusal.Reserved_Nonzero)

	bad_kind_bytes := hdr_buf
	bad_kind_bytes[56] = 0
	_, rref = closure_header_read(bad_kind_bytes[:])
	testing.expect_value(t, rref, Closure_Stream_Refusal.Bad_Object_Kind)

	// Record header write & read refusals.
	rec_buf: [CLOSURE_RECORD_HEADER_SIZE]u8
	valid_rec := Closure_Record_Header{kind = .Blob, size = 12, hash = closure_test_hash(2)}
	_, rref = closure_record_header_write(&valid_rec, rec_buf[:CLOSURE_RECORD_HEADER_SIZE - 1])
	testing.expect_value(t, rref, Closure_Stream_Refusal.Buffer_Too_Small)

	oversized_tree := Closure_Record_Header{kind = .Tree, size = u64(MAX_TREE_PAYLOAD_BYTES) + 1, hash = closure_test_hash(2)}
	_, rref = closure_record_header_write(&oversized_tree, rec_buf[:])
	testing.expect_value(t, rref, Closure_Stream_Refusal.Too_Large)

	rn, rwref := closure_record_header_write(&valid_rec, rec_buf[:])
	testing.expect_value(t, rwref, Closure_Stream_Refusal.None)
	testing.expect_value(t, rn, CLOSURE_RECORD_HEADER_SIZE)

	got_rec, rrref := closure_record_header_read(rec_buf[:])
	testing.expect_value(t, rrref, Closure_Stream_Refusal.None)
	testing.expect_value(t, got_rec, valid_rec)

	_, rrref = closure_record_header_read(rec_buf[:CLOSURE_RECORD_HEADER_SIZE - 1])
	testing.expect_value(t, rrref, Closure_Stream_Refusal.Truncated)

	bad_rec_res := rec_buf
	bad_rec_res[2] = 0x80
	_, rrref = closure_record_header_read(bad_rec_res[:])
	testing.expect_value(t, rrref, Closure_Stream_Refusal.Reserved_Nonzero)

	bad_rec_zero := rec_buf
	for i in 12 ..< 44 {
		bad_rec_zero[i] = 0
	}
	_, rrref = closure_record_header_read(bad_rec_zero[:])
	testing.expect_value(t, rrref, Closure_Stream_Refusal.Zero_Hash)
}

@(test)
closure_stream_roundtrip_blob_nested_tree_signed_realisation_and_tamper_refusals :: proc(t: ^testing.T) {
	priv, pub := closure_test_keypair(0x51)
	_, untrusted_pub := closure_test_keypair(0x99)

	// Build leaf blob -> child tree -> root tree.
	leaf := transmute([]u8)string("program-binary-bytes-v1")
	leaf_hash := blake3.hash(leaf)

	sub_buf: [256]u8
	e_leaf, _ := tree_hash.tree_entry_make(.Object, "helper", leaf_hash)
	sub_len, _ := tree_hash.tree_encode([]tree_hash.Tree_Entry{e_leaf}, sub_buf[:])
	sub_bytes := sub_buf[:sub_len]
	sub_hash, _ := tree_hash.tree_hash(sub_bytes)

	root_buf: [256]u8
	e_mod, _ := tree_hash.tree_entry_make(.Object, "module", leaf_hash)
	e_mods, _ := tree_hash.tree_entry_make(.Tree, "modules", sub_hash)
	root_len, _ := tree_hash.tree_encode([]tree_hash.Tree_Entry{e_mod, e_mods}, root_buf[:])
	root_bytes := root_buf[:root_len]
	root_hash, _ := tree_hash.tree_hash(root_bytes)

	recipe_hash := closure_test_hash(77)
	real := Realisation_Record {
		recipe_hash       = recipe_hash,
		output_hash       = root_hash,
		output_kind       = .Tree,
		signer_public_key = pub,
	}
	sign_bytes, sign_ok := realisation_signing_bytes(&real)
	testing.expect(t, sign_ok)
	ed25519.sign(&priv, sign_bytes[:], real.signature[:])

	// Assemble complete bottom-up MODCLOS1 stream in memory: [leaf, sub_tree, root_tree] + realisation.
	stream := make([dynamic]u8, context.temp_allocator)
	append_bytes :: proc(dst: ^[dynamic]u8, src: []u8) {
		for b in src {
			append(dst, b)
		}
	}

	hdr := Closure_Stream_Header {
		version         = CLOSURE_STREAM_VERSION,
		has_realisation = true,
		root_kind       = .Tree,
		root_hash       = root_hash,
		object_count    = 3,
	}
	hdr_raw: [CLOSURE_STREAM_HEADER_SIZE]u8
	_, href := closure_header_write(&hdr, hdr_raw[:])
	testing.expect_value(t, href, Closure_Stream_Refusal.None)
	append_bytes(&stream, hdr_raw[:])

	records := [3]struct {
		kind:    Cache_Object_Kind,
		hash:    blake3.Hash,
		payload: []u8,
	}{
		{.Blob, leaf_hash, leaf},
		{.Tree, sub_hash, sub_bytes},
		{.Tree, root_hash, root_bytes},
	}
	for r in records {
		rec_hdr := Closure_Record_Header{kind = r.kind, size = u64(len(r.payload)), hash = r.hash}
		rec_raw: [CLOSURE_RECORD_HEADER_SIZE]u8
		_, rref := closure_record_header_write(&rec_hdr, rec_raw[:])
		testing.expect_value(t, rref, Closure_Stream_Refusal.None)
		append_bytes(&stream, rec_raw[:])
		append_bytes(&stream, r.payload)
	}

	real_raw: [REALISATION_WIRE_SIZE]u8
	_, enc_ref := encode_realisation_record(&real, real_raw[:])
	testing.expect_value(t, enc_ref, Wire_Refusal.None)
	append_bytes(&stream, real_raw[:])

	trusted := [1][PUBLIC_KEY_SIZE]u8{pub}
	got_hdr, got_real, vref := closure_stream_verify_buffer(stream[:], trusted[:], closure_test_verify_ed25519)
	testing.expect_value(t, vref, Closure_Stream_Refusal.None)
	testing.expect_value(t, got_hdr, hdr)
	testing.expect_value(t, got_real, real)

	// Untrusted signer refused.
	untrusted := [1][PUBLIC_KEY_SIZE]u8{untrusted_pub}
	_, _, vref = closure_stream_verify_buffer(stream[:], untrusted[:], closure_test_verify_ed25519)
	testing.expect_value(t, vref, Closure_Stream_Refusal.Untrusted_Signer)

	// Tampered signature refused.
	bad_sig := make([]u8, len(stream), context.temp_allocator)
	copy(bad_sig, stream[:])
	bad_sig[len(bad_sig) - 1] ~= 0x01
	_, _, vref = closure_stream_verify_buffer(bad_sig, trusted[:], closure_test_verify_ed25519)
	testing.expect_value(t, vref, Closure_Stream_Refusal.Bad_Signature)

	// Tampered blob payload byte refused with Hash_Mismatch.
	tampered := make([]u8, len(stream), context.temp_allocator)
	copy(tampered, stream[:])
	tampered[CLOSURE_STREAM_HEADER_SIZE + CLOSURE_RECORD_HEADER_SIZE] ~= 0xFF
	_, _, vref = closure_stream_verify_buffer(tampered, trusted[:], closure_test_verify_ed25519)
	testing.expect_value(t, vref, Closure_Stream_Refusal.Hash_Mismatch)

	// Truncated stream refused.
	_, _, vref = closure_stream_verify_buffer(stream[:len(stream) - 1], trusted[:], closure_test_verify_ed25519)
	testing.expect_value(t, vref, Closure_Stream_Refusal.Truncated)

	// Trailing garbage byte refused.
	trailing := make([dynamic]u8, context.temp_allocator)
	append_bytes(&trailing, stream[:])
	append(&trailing, 0x00)
	_, _, vref = closure_stream_verify_buffer(trailing[:], trusted[:], closure_test_verify_ed25519)
	testing.expect_value(t, vref, Closure_Stream_Refusal.Trailing_Bytes)
}

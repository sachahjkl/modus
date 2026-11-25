package cache_server

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/object_cache"
import "modus:contract/program_tree"
import "modus:contract/tree_hash"
import "modus:cryptography/ed25519"
import "modustool:foundation"

@(private = "file")
write_hex_key_file :: proc(t: ^testing.T, path: string, key: [object_cache.PUBLIC_KEY_SIZE]u8) {
	hex := hash_to_hex(key)
	err := os.write_entire_file(path, hex[:])
	testing.expect_value(t, err, nil)
}

@(test)
closure_cli_roundtrip_program_tree_determinism_and_idempotency :: proc(t: ^testing.T) {
	src_dir := make_temp_store_dir(t)
	dst_dir := make_temp_store_dir(t)
	usb_dir := make_temp_store_dir(t)
	defer {
		os.remove_all(src_dir)
		os.remove_all(dst_dir)
		os.remove_all(usb_dir)
		delete(src_dir)
		delete(dst_dir)
		delete(usb_dir)
	}

	priv, pub, seed := make_test_keypair(0x33)
	src_server, opened := cache_server_open(src_dir, [][object_cache.PUBLIC_KEY_SIZE]u8{pub})
	testing.expect(t, opened)
	defer cache_server_destroy(&src_server)

	// Build a canonical MODTREE2 program tree:
	//   module -> entry_blob
	//   modules/codec -> helper_blob
	//   assets/icon.bin -> asset_blob
	entry_blob := transmute([]u8)string("entry-module-binary-v1")
	helper_blob := transmute([]u8)string("helper-codec-binary-v1")
	asset_blob := transmute([]u8)string("immutable-icon-bytes-v1")

	entry_hash, ok1 := cache_server_seed_object(&src_server, .Blob, entry_blob, seed)
	helper_hash, ok2 := cache_server_seed_object(&src_server, .Blob, helper_blob, seed)
	asset_hash, ok3 := cache_server_seed_object(&src_server, .Blob, asset_blob, seed)
	testing.expect(t, ok1 && ok2 && ok3)

	mods_buf: [256]u8
	e_helper, _ := tree_hash.tree_entry_make(.Object, "codec", helper_hash)
	mods_len, _ := tree_hash.tree_encode([]tree_hash.Tree_Entry{e_helper}, mods_buf[:])
	mods_hash, ok4 := cache_server_seed_object(&src_server, .Tree, mods_buf[:mods_len], seed)
	testing.expect(t, ok4)

	assets_buf: [256]u8
	e_icon, _ := tree_hash.tree_entry_make(.Object, "icon.bin", asset_hash)
	assets_len, _ := tree_hash.tree_encode([]tree_hash.Tree_Entry{e_icon}, assets_buf[:])
	assets_hash, ok5 := cache_server_seed_object(&src_server, .Tree, assets_buf[:assets_len], seed)
	testing.expect(t, ok5)

	root_buf: [512]u8
	e_assets, _ := tree_hash.tree_entry_make(.Tree, "assets", assets_hash)
	e_mod, _ := tree_hash.tree_entry_make(.Object, "module", entry_hash)
	e_mods, _ := tree_hash.tree_entry_make(.Tree, "modules", mods_hash)
	root_len, _ := tree_hash.tree_encode([]tree_hash.Tree_Entry{e_assets, e_mod, e_mods}, root_buf[:])
	root_bytes := root_buf[:root_len]

	// Confirm the root conforms to modus:contract/program_tree.
	pt_summary, pt_ref := program_tree.program_tree_validate(root_bytes)
	testing.expect_value(t, pt_ref, program_tree.Program_Tree_Refusal.None)
	testing.expect_value(t, pt_summary.entry_module_hash, entry_hash)
	testing.expect(t, pt_summary.has_modules && pt_summary.has_assets)

	root_hash, ok6 := cache_server_seed_object(&src_server, .Tree, root_bytes, seed)
	testing.expect(t, ok6)

	// Store a signed Realisation_Record in src_dir.
	recipe_hash := blake3.hash(transmute([]u8)string("program-tree-recipe-v1"))
	real_rec := object_cache.Realisation_Record {
		recipe_hash       = recipe_hash,
		output_hash       = root_hash,
		output_kind       = .Tree,
		signer_public_key = pub,
	}
	sign_bytes, sign_ok := object_cache.realisation_signing_bytes(&real_rec)
	testing.expect(t, sign_ok)
	ed25519.sign(&priv, sign_bytes[:], real_rec.signature[:])
	real_wire: [object_cache.REALISATION_WIRE_SIZE]u8
	_, enc_ref := object_cache.encode_realisation_record(&real_rec, real_wire[:])
	testing.expect_value(t, enc_ref, object_cache.Wire_Refusal.None)
	recipe_hex := hash_to_hex(recipe_hash)
	real_written, _ := store_write_atomic(&src_server, .Realisations, string(recipe_hex[:]), real_wire[:])
	testing.expect(t, real_written)

	root_hex := hash_to_hex(root_hash)
	out1 := fmt.tprintf("%s/bundle1.modclos", usb_dir)
	out2 := fmt.tprintf("%s/bundle2.modclos", usb_dir)
	signer_path := fmt.tprintf("%s/signer.pub", usb_dir)
	write_hex_key_file(t, signer_path, pub)

	// Export twice through CLI and verify byte-for-byte determinism.
	rc1 := run_cache_export([]string{"--dir", src_dir, string(root_hex[:]), out1, "--realisation", string(recipe_hex[:])})
	testing.expect_value(t, rc1, 0)
	rc2 := run_cache_export([]string{"--dir", src_dir, string(root_hex[:]), out2, "--realisation", string(recipe_hex[:])})
	testing.expect_value(t, rc2, 0)

	raw1, err1 := os.read_entire_file(out1, context.allocator)
	defer delete(raw1)
	raw2, err2 := os.read_entire_file(out2, context.allocator)
	defer delete(raw2)
	testing.expect_value(t, err1, nil)
	testing.expect_value(t, err2, nil)
	testing.expect(t, slice.equal(raw1, raw2), "two offline closure exports of the same tree must be byte-for-byte identical")

	// Import into empty air-gapped destination cache with --signer verification.
	rc_imp := run_cache_import([]string{"--dir", dst_dir, out1, "--signer", signer_path})
	testing.expect_value(t, rc_imp, 0)

	// Verify all 6 objects and the realisation exist on disk in dst_dir.
	dst_server, dst_opened := cache_server_open(dst_dir, [][object_cache.PUBLIC_KEY_SIZE]u8{pub})
	testing.expect(t, dst_opened)
	defer cache_server_destroy(&dst_server)
	for h in ([?]blake3.Hash{entry_hash, helper_hash, asset_hash, mods_hash, assets_hash, root_hash, recipe_hash}) {
		testing.expect(t, cache_server_has(&dst_server, h))
	}

	// Re-importing the exact same bundle is idempotent: 0 newly imported, 6 existing.
	stats2, prob2 := cache_closure_import(dst_dir, out1, [][object_cache.PUBLIC_KEY_SIZE]u8{pub})
	testing.expect_value(t, prob2, "")
	testing.expect_value(t, stats2.objects_imported, u64(0))
	testing.expect_value(t, stats2.objects_existing, u64(6))
	testing.expect(t, stats2.has_realisation)
	testing.expect_value(t, stats2.recipe_hash, recipe_hash)
}

@(test)
closure_cli_streams_multiframe_blob_and_refuses_tamper_untrusted_and_bad_args :: proc(t: ^testing.T) {
	src_dir := make_temp_store_dir(t)
	dst_dir := make_temp_store_dir(t)
	usb_dir := make_temp_store_dir(t)
	defer {
		os.remove_all(src_dir)
		os.remove_all(dst_dir)
		os.remove_all(usb_dir)
		delete(src_dir)
		delete(dst_dir)
		delete(usb_dir)
	}

	priv, pub, seed := make_test_keypair(0x44)
	_, other_pub, _ := make_test_keypair(0x88)

	src_server, opened := cache_server_open(src_dir, [][object_cache.PUBLIC_KEY_SIZE]u8{pub})
	testing.expect(t, opened)
	defer cache_server_destroy(&src_server)

	// > 1 MiB blob exercises streaming import path.
	big_size := int(object_cache.FRAME_PAYLOAD_BYTES) + 33_333
	big_blob := make([]u8, big_size)
	defer delete(big_blob)
	for i in 0 ..< big_size {
		big_blob[i] = u8((i * 59 + 3) & 0xFF)
	}
	big_hash, seeded := cache_server_seed_object(&src_server, .Blob, big_blob, seed)
	testing.expect(t, seeded)

	recipe_hash := blake3.hash(transmute([]u8)string("big-blob-recipe"))
	real_rec := object_cache.Realisation_Record {
		recipe_hash       = recipe_hash,
		output_hash       = big_hash,
		output_kind       = .Blob,
		signer_public_key = pub,
	}
	sb, _ := object_cache.realisation_signing_bytes(&real_rec)
	ed25519.sign(&priv, sb[:], real_rec.signature[:])
	real_wire: [object_cache.REALISATION_WIRE_SIZE]u8
	_, _ = object_cache.encode_realisation_record(&real_rec, real_wire[:])
	recipe_hex := hash_to_hex(recipe_hash)
	_, _ = store_write_atomic(&src_server, .Realisations, string(recipe_hex[:]), real_wire[:])

	big_path := fmt.tprintf("%s/big.modclos", usb_dir)
	exp_stats, exp_prob := cache_closure_export(src_dir, big_hash, big_path, recipe_hash, true)
	testing.expect_value(t, exp_prob, "")
	testing.expect_value(t, exp_stats.object_count, u64(1))

	// 1. Untrusted signer refused and writes neither objects nor realisation.
	_, prob_untrusted := cache_closure_import(dst_dir, big_path, [][object_cache.PUBLIC_KEY_SIZE]u8{other_pub})
	testing.expect(t, prob_untrusted != "")
	{
		dst_untrusted_server, u_open := cache_server_open(dst_dir, nil)
		testing.expect(t, u_open)
		defer cache_server_destroy(&dst_untrusted_server)
		testing.expect(t, !cache_server_has(&dst_untrusted_server, big_hash), "untrusted signer must not pollute objects/")
		testing.expect(t, !cache_server_has(&dst_untrusted_server, recipe_hash))
	}

	// 2. Stripping has_realisation while --signer is required is refused and leaves objects/ untouched.
	raw, read_err := os.read_entire_file(big_path, context.allocator)
	defer delete(raw)
	testing.expect_value(t, read_err, nil)

	stripped := make([]u8, len(raw) - object_cache.REALISATION_WIRE_SIZE)
	defer delete(stripped)
	copy(stripped, raw[:len(stripped)])
	stripped[12] = 0
	stripped[13] = 0
	stripped[14] = 0
	stripped[15] = 0
	stripped_path := fmt.tprintf("%s/stripped.modclos", usb_dir)
	testing.expect_value(t, os.write_entire_file(stripped_path, stripped), nil)
	_, prob_stripped := cache_closure_import(dst_dir, stripped_path, [][object_cache.PUBLIC_KEY_SIZE]u8{pub})
	testing.expect(t, prob_stripped != "")
	{
		dst_strip_server, s_open := cache_server_open(dst_dir, nil)
		testing.expect(t, s_open)
		defer cache_server_destroy(&dst_strip_server)
		testing.expect(t, !cache_server_has(&dst_strip_server, big_hash), "stripped unsigned bundle with --signer must not write objects/")
	}

	// 3. Tampered byte in >1 MiB blob payload refused before committing object.
	dst_bad_dir := make_temp_store_dir(t)
	defer {
		os.remove_all(dst_bad_dir)
		delete(dst_bad_dir)
	}

	tampered := make([]u8, len(raw))
	defer delete(tampered)
	copy(tampered, raw)
	tampered[object_cache.CLOSURE_STREAM_HEADER_SIZE + object_cache.CLOSURE_RECORD_HEADER_SIZE + 512] ~= 0x01
	tampered_path := fmt.tprintf("%s/tampered.modclos", usb_dir)
	testing.expect_value(t, os.write_entire_file(tampered_path, tampered), nil)
	_, prob_tamper := cache_closure_import(dst_bad_dir, tampered_path, [][object_cache.PUBLIC_KEY_SIZE]u8{pub})
	testing.expect(t, prob_tamper != "")

	dst_bad_server, bad_open := cache_server_open(dst_bad_dir, nil)
	testing.expect(t, bad_open)
	defer cache_server_destroy(&dst_bad_server)
	testing.expect(t, !cache_server_has(&dst_bad_server, big_hash), "tampered blob must never be committed to objects/")
	testing.expect(t, !cache_server_has(&dst_bad_server, recipe_hash), "realisation must never be committed after tamper")

	// 4. Trailing byte appended to valid closure stream refused and leaves objects/ untouched.
	trailing := make([]u8, len(raw) + 1)
	defer delete(trailing)
	copy(trailing, raw)
	trailing[len(raw)] = 0xAA
	trailing_path := fmt.tprintf("%s/trailing.modclos", usb_dir)
	testing.expect_value(t, os.write_entire_file(trailing_path, trailing), nil)
	_, prob_trailing := cache_closure_import(dst_bad_dir, trailing_path, [][object_cache.PUBLIC_KEY_SIZE]u8{pub})
	testing.expect(t, prob_trailing != "")
	testing.expect(t, !cache_server_has(&dst_bad_server, big_hash), "trailing garbage stream must not pollute objects/")

	// 4. Valid import succeeds into clean dst_dir and preserves exact >1 MiB bytes.
	dst_ok_dir := make_temp_store_dir(t)
	defer {
		os.remove_all(dst_ok_dir)
		delete(dst_ok_dir)
	}
	imp_stats, imp_prob := cache_closure_import(dst_ok_dir, big_path, [][object_cache.PUBLIC_KEY_SIZE]u8{pub})
	testing.expect_value(t, imp_prob, "")
	testing.expect_value(t, imp_stats.objects_imported, u64(1))
	testing.expect_value(t, imp_stats.root_hash, big_hash)

	// 5. CLI usage refusals return EXIT_USAGE.
	testing.expect_value(t, run_cache_export(nil), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_export([]string{"--dir", src_dir, "not-a-hash", big_path}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_import(nil), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_import([]string{"--bogus"}), foundation.EXIT_USAGE)
}

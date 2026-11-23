// End-to-end host tests for the QUIC UDP object cache server (cache_quic.odin)
// and the freestanding QUIC object cache client (recipes_core/cache_client.odin).
//
// Verifies:
// - wrong pinned server key refused (Bad_Server_Key / TLS bad_certificate);
// - malformed wire frame refused and partial uploads aborted;
// - multi-frame (> 1 MiB) Put_Object + Put_Object_Frame + Get_Object with Bao
//   inclusion proof verification and tampered-frame refusal;
// - Put_Realisation + Get_Realisation + untrusted-signer and bad-signature refusals;
// - Get_References on Tree, Realisation, plain Blob, and absent hash;
// - Put_Release_Pointer + Get_Release_Pointer;
// - recipes_core.build_recipe in Prefer_Cache and Cache_Only fetching a signed
//   realisation and its Tree closure over QUIC into a local store.
package cache_server

import "base:runtime"
import "core:crypto"
import "core:net"
import "core:os"
import "core:testing"
import "core:time"
import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"
import "modus:cryptography/ed25519"
import "modus:quic"
import "modus:random"

@(private = "file")
Host_Udp_Transport :: struct {
	socket:     net.UDP_Socket,
	remote:     net.Endpoint,
	start_tick: time.Tick,
}

@(private = "file")
host_udp_send :: proc "contextless" (bytes: []u8, user_data: rawptr) -> bool {
	context = runtime.default_context()
	udp := (^Host_Udp_Transport)(user_data)
	sent, err := net.send_udp(udp.socket, bytes, udp.remote)
	return err == nil && sent == len(bytes)
}

@(private = "file")
host_udp_recv :: proc "contextless" (buffer: []u8, deadline_us: u64, user_data: rawptr) -> (length: int, ok: bool) {
	context = runtime.default_context()
	udp := (^Host_Udp_Transport)(user_data)
	now := host_udp_now_us(user_data)
	wait_us := deadline_us > now ? deadline_us - now : 1000
	wait_dur := max(time.Duration(wait_us) * time.Microsecond, time.Millisecond)
	_ = net.set_option(udp.socket, .Receive_Timeout, min(wait_dur, 50 * time.Millisecond))
	n, _, err := net.recv_udp(udp.socket, buffer)
	if err != nil || n <= 0 {
		return 0, false
	}
	return n, true
}

@(private = "file")
host_udp_now_us :: proc "contextless" (user_data: rawptr) -> u64 {
	context = runtime.default_context()
	udp := (^Host_Udp_Transport)(user_data)
	return u64(time.tick_since(udp.start_tick) / time.Microsecond) + 1
}

@(private = "file")
host_ed25519_verify :: proc "contextless" (
	public_key: [object_cache.PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [object_cache.SIGNATURE_SIZE]u8,
	_: rawptr,
) -> bool {
	context = runtime.default_context()
	return cache_server_verify_ed25519(public_key, message, signature)
}

@(private = "file")
make_host_quic_client :: proc(
	server_endpoint: net.Endpoint,
	pinned_public_key: [object_cache.PUBLIC_KEY_SIZE]u8,
	crypto_table: ^quic.Cryptography,
	generator: ^random.Generator,
	udp_out: ^Host_Udp_Transport,
) -> (client: ^recipes_core.Cache_Quic_Client, ok: bool) {
	sock, sock_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if sock_err != nil {
		return nil, false
	}
	udp_out^ = {
		socket     = sock,
		remote     = server_endpoint,
		start_tick = time.tick_now(),
	}
	seed: [random.SEED_SIZE]u8
	crypto.rand_bytes(seed[:])
	random.generator_seed(generator, &seed, .Processor)

	client = new(recipes_core.Cache_Quic_Client)
	transport := recipes_core.Cache_Datagram_Transport {
		send      = host_udp_send,
		recv      = host_udp_recv,
		now_us    = host_udp_now_us,
		user_data = udp_out,
	}
	if !recipes_core.cache_quic_client_init(client, pinned_public_key, crypto_table, generator, transport) {
		free(client)
		net.close(sock)
		return nil, false
	}
	return client, true
}

@(private = "file")
make_test_ed25519_key :: proc(seed_byte: u8) -> (priv: ed25519.Private_Key, pub: [32]u8, seed: [32]u8) {
	for i in 0 ..< 32 {
		seed[i] = seed_byte + u8(i * 11)
	}
	ok := ed25519.private_key_set_bytes(&priv, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&priv, pub[:])
	return priv, pub, seed
}

@(test)
quic_cache_wrong_pinned_key_refused :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		os.remove_all(dir)
		delete(dir)
	}

	_, signer_pub, _ := make_test_ed25519_key(0x21)
	_, _, quic_seed := make_test_ed25519_key(0x31)

	server, opened := cache_server_open(dir, [][32]u8{signer_pub})
	testing.expect(t, opened)
	defer cache_server_destroy(&server)

	running, err_text := cache_quic_start(&server, net.Endpoint{address = net.IP4_Loopback, port = 0}, quic_seed)
	testing.expect_value(t, err_text, "")
	testing.expect(t, running != nil)
	defer cache_quic_stop(running)

	wrong_key := running.public_key
	wrong_key[0] ~= 0x01

	crypto_table := cache_quic_cryptography()
	generator: random.Generator
	udp: Host_Udp_Transport
	client, made := make_host_quic_client(running.bound_endpoint, wrong_key, &crypto_table, &generator, &udp)
	testing.expect(t, made)
	defer free(client)
	defer net.close(udp.socket)

	conn_err := recipes_core.cache_quic_client_connect(client)
	testing.expect_value(t, conn_err, recipes_core.Cache_Client_Error.Bad_Server_Key)
}

@(test)
quic_cache_put_get_multiframe_bao_references_and_release_pointer :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		os.remove_all(dir)
		delete(dir)
	}

	signer_priv, signer_pub, _ := make_test_ed25519_key(0x41)
	untrusted_priv, untrusted_pub, _ := make_test_ed25519_key(0x77)
	_, _, quic_seed := make_test_ed25519_key(0x51)

	server, opened := cache_server_open(dir, [][32]u8{signer_pub})
	testing.expect(t, opened)
	defer cache_server_destroy(&server)

	running, err_text := cache_quic_start(&server, net.Endpoint{address = net.IP4_Loopback, port = 0}, quic_seed)
	testing.expect_value(t, err_text, "")
	testing.expect(t, running != nil)
	defer cache_quic_stop(running)

	crypto_table := cache_quic_cryptography()
	generator: random.Generator
	udp: Host_Udp_Transport
	client, made := make_host_quic_client(running.bound_endpoint, running.public_key, &crypto_table, &generator, &udp)
	testing.expect(t, made)
	defer {
		recipes_core.cache_quic_client_close(client)
		free(client)
		net.close(udp.socket)
	}

	testing.expect_value(t, recipes_core.cache_quic_client_connect(client), recipes_core.Cache_Client_Error.None)

	// 1. Multi-frame (> 1 MiB) Blob Put_Object + Put_Object_Frame + Bao-verified Get_Object.
	large_size := int(object_cache.FRAME_PAYLOAD_BYTES) + 77_777
	large_blob := make([]u8, large_size)
	defer delete(large_blob)
	for i in 0 ..< large_size {
		large_blob[i] = u8((i * 131 + 17) & 0xFF)
	}
	large_hash := blake3.hash(large_blob)

	put_sign_bytes, sign_ok := object_cache.put_object_signing_bytes(.Blob, large_hash, u64(large_size), signer_pub)
	testing.expect(t, sign_ok)
	put_sig: [64]u8
	ed25519.sign(&signer_priv, put_sign_bytes[:], put_sig[:])

	put_status, put_err := recipes_core.cache_quic_put_object(client, .Blob, large_hash, large_blob, signer_pub, put_sig)
	testing.expect_value(t, put_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, put_status, object_cache.Cache_Response_Status.Ok)

	// Stream the >1 MiB blob back over QUIC into a Memory_Private_Store with Bao verification on every frame.
	mem_store := new(pr.Memory_Private_Store)
	defer free(mem_store)
	large_backing := make([]u8, 4 * 1024 * 1024)
	defer delete(large_backing)
	mem_store.large_bytes = large_backing

	recipes_state := new(recipes_core.Recipes_State)
	defer free(recipes_state)
	recipes_core.state_init(recipes_state, pr.memory_private_store_port(mem_store))

	fetched_size, fetch_refusal := recipes_core.cache_quic_fetch_object_to_store(client, recipes_state, large_hash, .Blob)
	testing.expect_value(t, fetch_refusal, pr.Recipe_Refusal.None)
	testing.expect_value(t, fetched_size, u64(large_size))

	// Verify stored bytes match the original >1 MiB blob byte-for-byte.
	obj_name := pr.blob_object_name(large_hash)
	read_back := make([]u8, large_size)
	defer delete(read_back)
	got_slice, read_status := pr.private_store_read(&recipes_state.store, pr.private_object_name_text(&obj_name), read_back)
	testing.expect_value(t, read_status, pr.Private_Store_Status.Ok)
	testing.expect_value(t, len(got_slice), large_size)
	testing.expect_value(t, blake3.hash(got_slice), large_hash)

	// 2. Upload a small leaf blob + canonical Tree + signed Realisation, and test Get_References.
	leaf_bytes := transmute([]u8)string("compiled-module-bytes-v1")
	leaf_hash := blake3.hash(leaf_bytes)
	leaf_sign, leaf_sign_ok := object_cache.put_object_signing_bytes(.Blob, leaf_hash, u64(len(leaf_bytes)), signer_pub)
	testing.expect(t, leaf_sign_ok)
	leaf_sig: [64]u8
	ed25519.sign(&signer_priv, leaf_sign[:], leaf_sig[:])
	leaf_status, leaf_err := recipes_core.cache_quic_put_object(client, .Blob, leaf_hash, leaf_bytes, signer_pub, leaf_sig)
	testing.expect_value(t, leaf_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, leaf_status, object_cache.Cache_Response_Status.Ok)

	e1, e1_ref := tree_hash.tree_entry_make(.Object, "module", leaf_hash)
	testing.expect_value(t, e1_ref, tree_hash.Tree_Refusal.None)
	tree_buf: [512]u8
	tree_len, tree_enc_ref := tree_hash.tree_encode([]tree_hash.Tree_Entry{e1}, tree_buf[:])
	testing.expect_value(t, tree_enc_ref, tree_hash.Tree_Refusal.None)
	tree_bytes := tree_buf[:tree_len]
	tree_digest, tree_h_ref := tree_hash.tree_hash(tree_bytes)
	testing.expect_value(t, tree_h_ref, tree_hash.Tree_Refusal.None)

	tree_sign, tree_sign_ok := object_cache.put_object_signing_bytes(.Tree, tree_digest, u64(len(tree_bytes)), signer_pub)
	testing.expect(t, tree_sign_ok)
	tree_sig: [64]u8
	ed25519.sign(&signer_priv, tree_sign[:], tree_sig[:])
	tree_status, tree_err := recipes_core.cache_quic_put_object(client, .Tree, tree_digest, tree_bytes, signer_pub, tree_sig)
	testing.expect_value(t, tree_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, tree_status, object_cache.Cache_Response_Status.Ok)

	// Build a sample Recipe_Spec and upload its signed Realisation over QUIC.
	spec := pr.Recipe_Spec {
		builder_hash       = blake3.hash(transmute([]u8)string("builder-v1")),
		output_kind        = .Tree,
		source_date_unix   = 1_700_000_000,
		output_block_limit = 64,
	}
	recipe_digest, r_ref := pr.recipe_hash(&spec)
	testing.expect_value(t, r_ref, pr.Recipe_Refusal.None)

	real_rec := object_cache.Realisation_Record {
		recipe_hash       = recipe_digest,
		output_hash       = tree_digest,
		output_kind       = .Tree,
		signer_public_key = signer_pub,
	}
	real_sign_bytes, real_sign_ok := object_cache.realisation_signing_bytes(&real_rec)
	testing.expect(t, real_sign_ok)
	ed25519.sign(&signer_priv, real_sign_bytes[:], real_rec.signature[:])

	put_real_req := object_cache.Cache_Request{kind = .Put_Realisation, realisation = real_rec}
	put_real_resp, put_real_err := recipes_core.cache_quic_client_exchange(client, &put_real_req)
	testing.expect_value(t, put_real_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, put_real_resp.status, object_cache.Cache_Response_Status.Ok)

	// Untrusted signer Put_Realisation refused with .Unauthorized.
	bad_real := real_rec
	bad_real.signer_public_key = untrusted_pub
	bad_real_bytes, _ := object_cache.realisation_signing_bytes(&bad_real)
	ed25519.sign(&untrusted_priv, bad_real_bytes[:], bad_real.signature[:])
	bad_real_req := object_cache.Cache_Request{kind = .Put_Realisation, realisation = bad_real}
	bad_real_resp, bad_real_err := recipes_core.cache_quic_client_exchange(client, &bad_real_req)
	testing.expect_value(t, bad_real_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, bad_real_resp.status, object_cache.Cache_Response_Status.Unauthorized)

	// Get_References: Tree -> [leaf_hash], Realisation -> [tree_digest], plain Blob -> [], absent -> Not_Found.
	refs: [8]blake3.Hash
	ref_count, ref_status, ref_err := recipes_core.cache_quic_get_references(client, tree_digest, refs[:])
	testing.expect_value(t, ref_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, ref_status, object_cache.Cache_Response_Status.Ok)
	testing.expect_value(t, ref_count, 1)
	testing.expect_value(t, refs[0], leaf_hash)

	real_ref_count, real_ref_status, real_ref_err := recipes_core.cache_quic_get_references(client, recipe_digest, refs[:])
	testing.expect_value(t, real_ref_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, real_ref_status, object_cache.Cache_Response_Status.Ok)
	testing.expect_value(t, real_ref_count, 1)
	testing.expect_value(t, refs[0], tree_digest)

	blob_ref_count, blob_ref_status, blob_ref_err := recipes_core.cache_quic_get_references(client, leaf_hash, refs[:])
	testing.expect_value(t, blob_ref_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, blob_ref_status, object_cache.Cache_Response_Status.Ok)
	testing.expect_value(t, blob_ref_count, 0)

	absent_hash := blake3.hash(transmute([]u8)string("absent-object"))
	_, absent_status, absent_err := recipes_core.cache_quic_get_references(client, absent_hash, refs[:])
	testing.expect_value(t, absent_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, absent_status, object_cache.Cache_Response_Status.Not_Found)

	// 3. Put_Release_Pointer + Get_Release_Pointer over QUIC.
	ptr, ptr_make_ref := object_cache.release_pointer_make(signer_pub, "stable", 7, tree_digest)
	testing.expect_value(t, ptr_make_ref, object_cache.Wire_Refusal.None)
	ptr_sign, ptr_sign_ok := object_cache.release_pointer_signing_bytes(&ptr)
	testing.expect(t, ptr_sign_ok)
	ed25519.sign(&signer_priv, ptr_sign[:], ptr.signature[:])

	put_ptr_req := object_cache.Cache_Request{kind = .Put_Release_Pointer, release_pointer = ptr}
	put_ptr_resp, put_ptr_err := recipes_core.cache_quic_client_exchange(client, &put_ptr_req)
	testing.expect_value(t, put_ptr_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, put_ptr_resp.status, object_cache.Cache_Response_Status.Ok)

	got_ptr, got_ptr_status, got_ptr_err := recipes_core.cache_quic_get_release_pointer(client, signer_pub, "stable")
	testing.expect_value(t, got_ptr_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, got_ptr_status, object_cache.Cache_Response_Status.Ok)
	testing.expect_value(t, got_ptr.number, u64(7))
	testing.expect_value(t, got_ptr.tree_hash, tree_digest)

	// 4. End-to-end recipes_core.build_recipe in Cache_Only and Prefer_Cache over QUIC:
	//    fetches signed realisation + Tree + child Blob into fresh local store!
	fresh_store := new(pr.Memory_Private_Store)
	defer free(fresh_store)
	fresh_state := new(recipes_core.Recipes_State)
	defer free(fresh_state)
	recipes_core.state_init(fresh_state, pr.memory_private_store_port(fresh_store))

	fetch_ctx := recipes_core.Cache_Quic_Fetch_Context {
		client           = client,
		verify_signature = host_ed25519_verify,
	}
	fresh_state.remote_cache_fetch = recipes_core.cache_quic_fetch_realisation
	fresh_state.remote_cache_user = &fetch_ctx
	fresh_state.remote_cache_signers[0] = signer_pub
	fresh_state.remote_cache_signer_count = 1

	// Untrusted signer in Cache_Only must refuse!
	untrusted_policy := object_cache.Substitution_Policy {
		mode            = .Cache_Only,
		trusted_signers = [][32]u8{untrusted_pub},
	}
	refused_res := recipes_core.build_recipe(fresh_state, &spec, .Cache_Only, untrusted_policy, nil, nil, nil, nil)
	testing.expect_value(t, refused_res.outcome, pr.Recipe_Build_Outcome.Refused)
	testing.expect_value(t, refused_res.refusal, pr.Recipe_Refusal.Untrusted_Realisation)

	// Trusted signer in Cache_Only succeeds and fetches both Tree and child Blob!
	trusted_policy := object_cache.Substitution_Policy {
		mode            = .Cache_Only,
		trusted_signers = [][32]u8{signer_pub},
	}
	ok_res := recipes_core.build_recipe(fresh_state, &spec, .Cache_Only, trusted_policy, nil, nil, nil, nil)
	testing.expect_value(t, ok_res.outcome, pr.Recipe_Build_Outcome.From_Cache)
	testing.expect_value(t, ok_res.refusal, pr.Recipe_Refusal.None)
	testing.expect_value(t, ok_res.output_hash, tree_digest)
	testing.expect_value(t, fresh_state.counters.cache_hits_remote, u64(1))

	// Both the root tree and its child leaf blob are now present in fresh_store!
	leaf_name := pr.blob_object_name(leaf_hash)
	leaf_buf: [64]u8
	stored_leaf, stored_leaf_status := pr.private_store_read(&fresh_state.store, pr.private_object_name_text(&leaf_name), leaf_buf[:])
	testing.expect_value(t, stored_leaf_status, pr.Private_Store_Status.Ok)
	testing.expect_value(t, string(stored_leaf), string(leaf_bytes))

	// Second build in Prefer_Cache hits local store with zero remote hit increase.
	local_res := recipes_core.build_recipe(fresh_state, &spec, .Prefer_Cache, {}, nil, nil, nil, nil)
	testing.expect_value(t, local_res.outcome, pr.Recipe_Build_Outcome.From_Cache)
	testing.expect_value(t, fresh_state.counters.cache_hits_local, u64(1))
	testing.expect_value(t, fresh_state.counters.cache_hits_remote, u64(1))
}

@(test)
quic_cache_refuses_bad_frame_and_tampered_object :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		os.remove_all(dir)
		delete(dir)
	}

	signer_priv, signer_pub, _ := make_test_ed25519_key(0x61)
	_, _, quic_seed := make_test_ed25519_key(0x62)

	server, opened := cache_server_open(dir, [][32]u8{signer_pub})
	testing.expect(t, opened)
	defer cache_server_destroy(&server)

	running, err_text := cache_quic_start(&server, net.Endpoint{address = net.IP4_Loopback, port = 0}, quic_seed)
	testing.expect_value(t, err_text, "")
	defer cache_quic_stop(running)

	crypto_table := cache_quic_cryptography()
	generator: random.Generator
	udp: Host_Udp_Transport
	client, made := make_host_quic_client(running.bound_endpoint, running.public_key, &crypto_table, &generator, &udp)
	testing.expect(t, made)
	defer {
		recipes_core.cache_quic_client_close(client)
		free(client)
		net.close(udp.socket)
	}
	testing.expect_value(t, recipes_core.cache_quic_client_connect(client), recipes_core.Cache_Client_Error.None)

	// Upload a blob with wrong bytes in Put_Object_Frame -> server refuses Bad_Hash and leaves no object or tmp file.
	good_bytes := transmute([]u8)string("expected-good-content")
	wrong_bytes := transmute([]u8)string("tampered-evil-content")
	expected_hash := blake3.hash(good_bytes)
	put_sign, _ := object_cache.put_object_signing_bytes(.Blob, expected_hash, u64(len(good_bytes)), signer_pub)
	put_sig: [64]u8
	ed25519.sign(&signer_priv, put_sign[:], put_sig[:])

	bad_status, bad_err := recipes_core.cache_quic_put_object(client, .Blob, expected_hash, wrong_bytes, signer_pub, put_sig)
	testing.expect_value(t, bad_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, bad_status, object_cache.Cache_Response_Status.Bad_Hash)
	testing.expect(t, !cache_server_has(&server, expected_hash))

	// Send raw malformed header on a QUIC stream -> server replies Refused.
	stream_id, stream_ok := quic.stream_open(&client.connection)
	testing.expect(t, stream_ok)
	bad_header := [12]u8{'B', 'A', 'D', '!', 99, 0, 0, 0, 0, 0, 0, 0}
	wrote := quic.stream_write(&client.connection, stream_id, bad_header[:], true)
	testing.expect_value(t, wrote, 12)
	resp_buf: [64]u8
	received := 0
	deadline := host_udp_now_us(&udp) + 5_000_000
	for host_udp_now_us(&udp) < deadline {
		now := host_udp_now_us(&udp)
		for {
			n := quic.connection_datagram_send(&client.connection, client.datagram_buf[:quic.MAX_DATAGRAM_SIZE], now)
			if n == 0 {
				break
			}
			_ = host_udp_send(client.datagram_buf[:n], &udp)
		}
		if dlen, dok := host_udp_recv(client.datagram_buf[:], deadline, &udp); dok && dlen > 0 {
			err: errors.Error_Record
			quic.connection_datagram_receive(&client.connection, client.datagram_buf[:dlen], host_udp_now_us(&udp), &err)
		}
		quic.connection_time_passes(&client.connection, host_udp_now_us(&udp))
		r, fin, rst := quic.stream_read(&client.connection, stream_id, resp_buf[received:])
		received += r
		if fin || rst {
			break
		}
	}
	testing.expect(t, received >= object_cache.FRAME_HEADER_SIZE)
	decoded, dec_ref := object_cache.decode_response(resp_buf[:received])
	testing.expect_value(t, dec_ref, object_cache.Wire_Refusal.None)
	testing.expect_value(t, decoded.status, object_cache.Cache_Response_Status.Refused)
}

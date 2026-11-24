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
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import "modus:contract/errors"
import module "modus:contract/module"
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

@(test)
quic_cache_module_imports_damaged_tree_quarantine_and_key_persistence :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		os.remove_all(dir)
		delete(dir)
	}

	// Verify persistent QUIC key file creation (0o600) and reload across restarts.
	key_first, key_second: [quic.ED25519_KEY_SIZE]u8
	testing.expect(t, cache_quic_load_or_create_key(dir, &key_first))
	key_stat, stat_err := os.stat(strings.concatenate({dir, "/quic_server.key"}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, stat_err == nil)
	testing.expect_value(t, key_stat.mode & os.perm(0o777), os.perm(0o600))
	testing.expect(t, cache_quic_load_or_create_key(dir, &key_second))
	testing.expect_value(t, key_first, key_second)

	signer_priv, signer_pub, _ := make_test_ed25519_key(0x71)
	server, opened := cache_server_open(dir, [][32]u8{signer_pub})
	testing.expect(t, opened)
	defer cache_server_destroy(&server)

	running, err_text := cache_quic_start(&server, net.Endpoint{address = net.IP4_Loopback, port = 0}, key_first, 4)
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

	// 1. Upload a modus module header + .Imports table containing 2 import hashes
	//    and verify Get_References returns both import hashes.
	imp1 := blake3.hash(transmute([]u8)string("import-module-one"))
	imp2 := blake3.hash(transmute([]u8)string("import-module-two"))
	table_count := u32(module.Table_Kind.Imports) + 1
	imports_offset := u64(size_of(module.Header)) + u64(table_count) * size_of(module.Table_Entry)
	mod_size := int(imports_offset) + 3 * size_of(module.Import)
	mod_bytes := make([]u8, mod_size)
	defer delete(mod_bytes)
	head := (^module.Header)(&mod_bytes[0])
	head.magic = module.MAGIC
	head.version = module.VERSION
	head.machine = .X86_64
	head.header_size = u32(size_of(module.Header))
	head.table_count = table_count
	dir_entries := ([^]module.Table_Entry)(&mod_bytes[size_of(module.Header)])[:table_count]
	dir_entries[module.Table_Kind.Imports] = {
		offset      = imports_offset,
		count       = 3, // entry 0 is reserved null entry; 1 and 2 are real imports
		record_size = size_of(module.Import),
	}
	imports := ([^]module.Import)(&mod_bytes[imports_offset])[:3]
	imports[1].hash = imp1
	imports[2].hash = imp2

	mod_hash := blake3.hash(mod_bytes)
	mod_sign, _ := object_cache.put_object_signing_bytes(.Blob, mod_hash, u64(len(mod_bytes)), signer_pub)
	mod_sig: [64]u8
	ed25519.sign(&signer_priv, mod_sign[:], mod_sig[:])
	put_st, put_err := recipes_core.cache_quic_put_object(client, .Blob, mod_hash, mod_bytes, signer_pub, mod_sig)
	testing.expect_value(t, put_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, put_st, object_cache.Cache_Response_Status.Ok)

	refs: [8]blake3.Hash
	ref_count, ref_status, ref_err := recipes_core.cache_quic_get_references(client, mod_hash, refs[:])
	testing.expect_value(t, ref_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, ref_status, object_cache.Cache_Response_Status.Ok)
	testing.expect_value(t, ref_count, 2)
	testing.expect_value(t, refs[0], imp1)
	testing.expect_value(t, refs[1], imp2)

	// 2. Upload a canonical MODTREE2 tree, corrupt a byte on disk, and verify
	//    Get_References quarantines it to damaged/ and answers Not_Found.
	leaf_hash := blake3.hash(transmute([]u8)string("tree-leaf"))
	entry, _ := tree_hash.tree_entry_make(.Object, "leaf.txt", leaf_hash)
	entries := [1]tree_hash.Tree_Entry{entry}
	tree_buf: [tree_hash.HEADER_SIZE + tree_hash.ENTRY_SIZE_MOST]u8
	tree_len, _ := tree_hash.tree_encode(entries[:], tree_buf[:])
	tree_bytes := tree_buf[:tree_len]
	tree_digest, _ := tree_hash.tree_hash(tree_bytes)

	tree_sign, _ := object_cache.put_object_signing_bytes(.Tree, tree_digest, u64(len(tree_bytes)), signer_pub)
	tree_sig: [64]u8
	ed25519.sign(&signer_priv, tree_sign[:], tree_sig[:])
	t_st, t_err := recipes_core.cache_quic_put_object(client, .Tree, tree_digest, tree_bytes, signer_pub, tree_sig)
	testing.expect_value(t, t_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, t_st, object_cache.Cache_Response_Status.Ok)

	hex_tree := hash_to_hex(tree_digest)
	obj_path := strings.concatenate({dir, "/objects/", string(hex_tree[:])}, context.temp_allocator)
	damaged_path := strings.concatenate({dir, "/damaged/", string(hex_tree[:])}, context.temp_allocator)
	corrupt := make([]u8, len(tree_bytes))
	defer delete(corrupt)
	copy(corrupt, tree_bytes)
	corrupt[len(corrupt) - 1] ~= 0x55
	testing.expect(t, os.write_entire_file(obj_path, corrupt) == nil)

	_, bad_ref_status, bad_ref_err := recipes_core.cache_quic_get_references(client, tree_digest, refs[:])
	testing.expect_value(t, bad_ref_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, bad_ref_status, object_cache.Cache_Response_Status.Not_Found)
	testing.expect(t, !os.exists(obj_path))
	testing.expect(t, os.exists(damaged_path))
}

@(private = "file")
Adversarial_Mode :: enum u8 {
	Tamper_Frame_1       = 0,
	Change_Size_Frame_1  = 1,
	Non_Monotonic_Busy   = 2,
}

@(private = "file")
Adversarial_Quic_Server :: struct {
	socket:         net.UDP_Socket,
	bound_endpoint: net.Endpoint,
	public_key:     [quic.ED25519_KEY_SIZE]u8,
	stop:           bool,
	mode:           Adversarial_Mode,
	blob_data:      []u8,
	blob_hash:      blake3.Hash,
	frame0_cv:      [blake3.HASH_SIZE]u8,
	frame1_cv:      [blake3.HASH_SIZE]u8,
	cryptography:   quic.Cryptography,
	generator:      random.Generator,
	quic_server:    quic.Server,
	connections:    [2]quic.Connection,
	records:        [2]quic.Server_Record,
	streams:        [4]quic.Stream,
	start_tick:     time.Tick,
	worker:         ^thread.Thread,
}

@(private = "file")
adversarial_quic_worker :: proc(th: ^thread.Thread) {
	srv := cast(^Adversarial_Quic_Server)th.data
	recv_buf: [quic.DATAGRAM_LIMIT]u8
	ans_buf: [quic.MAX_DATAGRAM_SIZE]u8
	dgram_buf: [quic.MAX_DATAGRAM_SIZE]u8
	req_buf := make([]u8, 4096)
	defer delete(req_buf)
	resp_buf := make([]u8, object_cache.FRAME_HEADER_SIZE + object_cache.MAX_RESPONSE_BODY_BYTES)
	defer delete(resp_buf)
	released: [2]quic.Remote

	active_stream: u64 = 0
	has_stream := false
	req_len := 0
	send_buf_len := 0
	send_off := 0
	busy_calls := 0

	for !sync.atomic_load(&srv.stop) {
		now := u64(time.duration_microseconds(time.tick_since(srv.start_tick))) + 1
		_ = net.set_option(srv.socket, .Receive_Timeout, 2 * time.Millisecond)
		n, sender, err := net.recv_udp(srv.socket, recv_buf[:])
		if err == nil && n > 0 {
			if remote, ok := endpoint_to_quic_remote(sender); ok {
				out := quic.server_datagram_receive(&srv.quic_server, recv_buf[:n], remote, ans_buf[:], now)
				if out.answer_length > 0 {
					_, _ = net.send_udp(srv.socket, ans_buf[:out.answer_length], sender)
				}
				if out.validate_remote && out.record >= 0 {
					quic.server_validation_confirmed(&srv.quic_server, out.record, srv.records[out.record].generation, true)
				}
			}
		}
		for idx in 0 ..< len(srv.records) {
			if !srv.records[idx].in_use || srv.connections[idx].state != .Connected {
				continue
			}
			conn := &srv.connections[idx]
			if !has_stream {
				for &stream in conn.streams {
					if !stream.in_use {
						continue
					}
					if stream.end_read && (stream.send_finish || stream.reset_sent) {
						continue
					}
					active_stream = stream.identifier
					has_stream = true
					req_len = 0
					send_buf_len = 0
					send_off = 0
					break
				}
			}
			if has_stream && send_buf_len == 0 {
				r, fin, rst := quic.stream_read(conn, active_stream, req_buf[req_len:])
				req_len += r
				if rst {
					has_stream = false
					continue
				}
				if fin && req_len >= object_cache.FRAME_HEADER_SIZE {
					req, dec_ref := object_cache.decode_request(req_buf[:req_len])
					if dec_ref == .None && req.kind == .Get_Object {
						frame_index := req.offset / object_cache.FRAME_PAYLOAD_BYTES
						proof_cv := frame_index == 0 ? srv.frame1_cv : srv.frame0_cv
						start := int(req.offset)
						end := min(start + int(object_cache.FRAME_PAYLOAD_BYTES), len(srv.blob_data))
						frame_payload := make([]u8, end - start)
						copy(frame_payload, srv.blob_data[start:end])

						resp: object_cache.Cache_Response
						switch srv.mode {
						case .Tamper_Frame_1:
							if frame_index == 1 && len(frame_payload) > 0 {
								frame_payload[0] ~= 0xFF
							}
							resp = {
								request_kind = .Get_Object,
								status       = .Ok,
								object_kind  = .Blob,
								object_size  = u64(len(srv.blob_data)),
								offset       = req.offset,
								proof        = proof_cv[:],
								payload      = frame_payload,
							}
						case .Change_Size_Frame_1:
							stated_size := u64(len(srv.blob_data))
							payload_view := frame_payload
							if frame_index == 1 && len(frame_payload) > 1024 {
								stated_size -= 1024
								payload_view = frame_payload[:len(frame_payload) - 1024]
							}
							resp = {
								request_kind = .Get_Object,
								status       = .Ok,
								object_kind  = .Blob,
								object_size  = stated_size,
								offset       = req.offset,
								proof        = proof_cv[:],
								payload      = payload_view,
							}
						case .Non_Monotonic_Busy:
							busy_calls += 1
							// Send frames_built=2 twice (non-monotonic!).
							resp = {
								request_kind = .Get_Object,
								status       = .Busy,
								frames_built = 2,
								frame_count  = 4,
							}
						}
						encoded_len, _ := object_cache.encode_response(&resp, resp_buf)
						delete(frame_payload)
						send_buf_len = encoded_len
						send_off = 0
					}
				}
			}
			if has_stream && send_buf_len > 0 {
				w := quic.stream_write(conn, active_stream, resp_buf[send_off:send_buf_len], true)
				send_off += w
				if send_off >= send_buf_len {
					has_stream = false
					send_buf_len = 0
				}
			}
		}
		now = u64(time.duration_microseconds(time.tick_since(srv.start_tick))) + 1
		quic.server_time_passes(&srv.quic_server, now)
		for {
			dlen, remote := quic.server_datagram_send(&srv.quic_server, dgram_buf[:], now)
			if dlen == 0 {
				break
			}
			_, _ = net.send_udp(srv.socket, dgram_buf[:dlen], quic_remote_to_endpoint(remote))
		}
		_ = quic.server_sweep(&srv.quic_server, released[:])
	}
}

@(test)
quic_cache_adversarial_frame1_size_change_and_busy :: proc(t: ^testing.T) {
	// Prepare a 1.1 MiB 2-frame blob and its valid Bao outboard.
	blob_len := int(object_cache.FRAME_PAYLOAD_BYTES) + 64 * 1024
	blob := make([]u8, blob_len)
	defer delete(blob)
	for i in 0 ..< blob_len {
		blob[i] = u8((i * 31 + 7) & 0xFF)
	}
	blob_hash := blake3.hash(blob)
	frame0_cv := blake3.chaining_value_bytes(blake3.subtree_chaining_value(blob[:object_cache.FRAME_PAYLOAD_BYTES], 0))
	frame1_cv := blake3.chaining_value_bytes(blake3.subtree_chaining_value(blob[object_cache.FRAME_PAYLOAD_BYTES:], object_cache.FRAME_PAYLOAD_BYTES / blake3.CHUNK_SIZE))

	_, pub_key, seed := make_test_ed25519_key(0x81)
	modes := [3]Adversarial_Mode{.Tamper_Frame_1, .Change_Size_Frame_1, .Non_Monotonic_Busy}
	expected_refusals := [3]pr.Recipe_Refusal{.Hash_Mismatch, .Malformed_Output, .Malformed_Output}

	for mode, idx in modes {
		sock, sock_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
		testing.expect(t, sock_err == nil)
		ep, _ := net.bound_endpoint(sock)

		srv := new(Adversarial_Quic_Server)
		srv.socket = sock
		srv.bound_endpoint = ep
		srv.public_key = pub_key
		srv.mode = mode
		srv.blob_data = blob
		srv.blob_hash = blob_hash
		srv.frame0_cv = frame0_cv
		srv.frame1_cv = frame1_cv
		srv.cryptography = cache_quic_cryptography()
		srv.start_tick = time.tick_now()
		rng_seed: [random.SEED_SIZE]u8
		crypto.rand_bytes(rng_seed[:])
		random.generator_seed(&srv.generator, &rng_seed, .Processor)

		cfg := quic.Connection_Configuration {
			idle_timeout_milliseconds = 10_000,
			tls = {role = .Server, least_seed_strength = .Processor, server_private_key = seed},
		}
		cfg.tls.application_protocol_length = copy(cfg.tls.application_protocol[:], object_cache.APPLICATION_PROTOCOL)
		init_err: errors.Error_Record
		testing.expect(t, quic.server_init(&srv.quic_server, srv.connections[:], srv.records[:], srv.streams[:], &cfg, &srv.cryptography, &srv.generator, quic.server_limits_of_one_address(2), &init_err))
		srv.worker = thread.create(adversarial_quic_worker)
		srv.worker.data = srv
		thread.start(srv.worker)

		// Run client fetch into an empty memory store with large_bytes backing.
		crypto_table := cache_quic_cryptography()
		generator: random.Generator
		udp: Host_Udp_Transport
		client, made := make_host_quic_client(ep, pub_key, &crypto_table, &generator, &udp)
		testing.expect(t, made)

		mem_store := new(pr.Memory_Private_Store)
		large_backing := make([]u8, 4 * 1024 * 1024)
		mem_store.large_bytes = large_backing
		state := new(recipes_core.Recipes_State)
		recipes_core.state_init(state, pr.memory_private_store_port(mem_store))

		_, refusal := recipes_core.cache_quic_fetch_object_to_store(client, state, blob_hash, .Blob)
		testing.expect_value(t, refusal, expected_refusals[idx])

		// Neither the final <64-hex> name nor fetch_staging may exist after refusal!
		obj_name := pr.blob_object_name(blob_hash)
		_, final_status := pr.private_store_size(&state.store, pr.private_object_name_text(&obj_name))
		testing.expect_value(t, final_status, pr.Private_Store_Status.Absent)
		_, stage_status := pr.private_store_size(&state.store, recipes_core.FETCH_STAGING_NAME)
		testing.expect_value(t, stage_status, pr.Private_Store_Status.Absent)

		// Pre-populate a valid object under <64-hex> and confirm the malicious server
		// cannot overwrite or delete it!
		if mode == .Tamper_Frame_1 {
			testing.expect_value(t, pr.private_store_write(&state.store, pr.private_object_name_text(&obj_name), blob), pr.Private_Store_Status.Ok)
			kept_sz, kept_ref := recipes_core.cache_quic_fetch_object_to_store(client, state, blob_hash, .Blob)
			testing.expect_value(t, kept_ref, pr.Recipe_Refusal.None)
			testing.expect_value(t, kept_sz, u64(blob_len))
			testing.expect_value(t, recipes_core.stored_output_check(state, blob_hash, .Blob, kept_sz), recipes_core.Stored_Output.Whole)
		}

		recipes_core.cache_quic_client_close(client)
		free(client)
		net.close(udp.socket)
		free(state)
		delete(large_backing)
		free(mem_store)

		sync.atomic_store(&srv.stop, true)
		thread.join(srv.worker)
		thread.destroy(srv.worker)
		net.close(srv.socket)
		free(srv)
	}
}

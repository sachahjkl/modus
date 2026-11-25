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
import "core:fmt"
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

@(test)
quic_cache_pipelined_multiframe_and_window_bounds :: proc(t: ^testing.T) {
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

	// Pipeline window border refusals leave the configured window intact.
	testing.expect_value(t, client.pipeline_window, recipes_core.CACHE_PIPELINE_WINDOW)
	testing.expect(t, !recipes_core.cache_quic_client_set_pipeline_window(nil, 2))
	testing.expect(t, !recipes_core.cache_quic_client_set_pipeline_window(client, 0))
	testing.expect(t, !recipes_core.cache_quic_client_set_pipeline_window(client, -1))
	testing.expect(t, !recipes_core.cache_quic_client_set_pipeline_window(client, recipes_core.CACHE_PIPELINE_WINDOW + 1))
	testing.expect(t, !recipes_core.cache_quic_client_set_pipeline_window(client, max(int)))
	testing.expect_value(t, client.pipeline_window, recipes_core.CACHE_PIPELINE_WINDOW)

	// Upload a 5-frame (4 MiB + 123 KiB) blob over QUIC.
	blob_len := 4 * int(object_cache.FRAME_PAYLOAD_BYTES) + 123_456
	blob := make([]u8, blob_len)
	defer delete(blob)
	for i in 0 ..< blob_len {
		blob[i] = u8((i * 73 + 29) & 0xFF)
	}
	blob_hash := blake3.hash(blob)
	sign_bytes, sign_ok := object_cache.put_object_signing_bytes(.Blob, blob_hash, u64(blob_len), signer_pub)
	testing.expect(t, sign_ok)
	sig: [64]u8
	ed25519.sign(&signer_priv, sign_bytes[:], sig[:])

	put_status, put_err := recipes_core.cache_quic_put_object(client, .Blob, blob_hash, blob, signer_pub, sig)
	testing.expect_value(t, put_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, put_status, object_cache.Cache_Response_Status.Ok)

	// Run 1: single-frame lockstep (window = 1).
	testing.expect(t, recipes_core.cache_quic_client_set_pipeline_window(client, 1))
	mem_lockstep := new(pr.Memory_Private_Store)
	defer free(mem_lockstep)
	backing_lockstep := make([]u8, 6 * 1024 * 1024)
	defer delete(backing_lockstep)
	mem_lockstep.large_bytes = backing_lockstep
	state_lockstep := new(recipes_core.Recipes_State)
	defer free(state_lockstep)
	recipes_core.state_init(state_lockstep, pr.memory_private_store_port(mem_lockstep))

	t0 := time.tick_now()
	sz1, ref1 := recipes_core.cache_quic_fetch_object_to_store(client, state_lockstep, blob_hash, .Blob)
	dur_lockstep := time.tick_since(t0)
	testing.expect_value(t, ref1, pr.Recipe_Refusal.None)
	testing.expect_value(t, sz1, u64(blob_len))
	testing.expect_value(t, client.last_fetch_frames, u64(5))
	testing.expect_value(t, client.last_fetch_max_in_flight, 1)

	// Run 2: pipelined 4 frames in flight (window = 4).
	testing.expect(t, recipes_core.cache_quic_client_set_pipeline_window(client, recipes_core.CACHE_PIPELINE_WINDOW))
	mem_pipe := new(pr.Memory_Private_Store)
	defer free(mem_pipe)
	backing_pipe := make([]u8, 6 * 1024 * 1024)
	defer delete(backing_pipe)
	mem_pipe.large_bytes = backing_pipe
	state_pipe := new(recipes_core.Recipes_State)
	defer free(state_pipe)
	recipes_core.state_init(state_pipe, pr.memory_private_store_port(mem_pipe))

	t1 := time.tick_now()
	sz4, ref4 := recipes_core.cache_quic_fetch_object_to_store(client, state_pipe, blob_hash, .Blob)
	dur_pipe := time.tick_since(t1)
	testing.expect_value(t, ref4, pr.Recipe_Refusal.None)
	testing.expect_value(t, sz4, u64(blob_len))
	testing.expect_value(t, client.last_fetch_frames, u64(5))
	testing.expect_value(t, client.last_fetch_max_in_flight, recipes_core.CACHE_PIPELINE_WINDOW)

	// Verify both fetched blobs match the original byte-for-byte.
	obj_name := pr.blob_object_name(blob_hash)
	verify_buf := make([]u8, blob_len)
	defer delete(verify_buf)
	for st in ([2]^recipes_core.Recipes_State{state_lockstep, state_pipe}) {
		got, r_st := pr.private_store_read(&st.store, pr.private_object_name_text(&obj_name), verify_buf)
		testing.expect_value(t, r_st, pr.Private_Store_Status.Ok)
		testing.expect_value(t, len(got), blob_len)
		testing.expect_value(t, blake3.hash(got), blob_hash)
	}

	// Print measured transfer durations (measure only, never asserted).
	fmt.printf("measure: quic 5-frame fetch (%d bytes): lockstep(w=1)=%.2f ms, pipelined(w=%d)=%.2f ms\n",
		blob_len,
		time.duration_milliseconds(dur_lockstep),
		recipes_core.CACHE_PIPELINE_WINDOW,
		time.duration_milliseconds(dur_pipe),
	)
}

@(private = "file")
Pipeline_Fault_Mode :: enum u8 {
	Reverse_Order_Valid = 0, // Hold frames 1..4 until all 4 arrive, then reply in reverse order (4,3,2,1).
	Corrupt_Mid_Pipeline = 1, // Corrupt 1 byte in frame 2 while delivering valid frames 4,3,1.
	Truncate_Mid_Pipeline = 2, // Truncate frame 2 response mid-body with FIN.
	Reset_Mid_Pipeline = 3, // Send RESET_STREAM on frame 2 mid-pipeline.
}

@(private = "file")
Pipeline_Held_Stream :: struct {
	active:      bool,
	stream_id:   u64,
	frame_index: u64,
	req_buf:     [128]u8,
	req_len:     int,
	req_done:    bool,
	resp_bytes:  []u8,
	send_len:    int,
	send_off:    int,
	reset_only:  bool,
	released:    bool,
}

@(private = "file")
Pipeline_Adversarial_Server :: struct {
	backing:        ^Cache_Server,
	socket:         net.UDP_Socket,
	bound_endpoint: net.Endpoint,
	mode:           Pipeline_Fault_Mode,
	stop:           bool,
	worker:         ^thread.Thread,
	cryptography:   quic.Cryptography,
	generator:      random.Generator,
	quic_server:    quic.Server,
	connections:    [2]quic.Connection,
	records:        [2]quic.Server_Record,
	streams:        [2 * CACHE_QUIC_STREAMS_PER_CONNECTION]quic.Stream,
	start_tick:     time.Tick,
}

@(private = "file")
pipeline_adversarial_worker :: proc(t: ^thread.Thread) {
	srv := (^Pipeline_Adversarial_Server)(t.data)
	recv_buf: [quic.DATAGRAM_LIMIT]u8
	ans_buf: [quic.MAX_DATAGRAM_SIZE]u8
	dgram_buf: [quic.MAX_DATAGRAM_SIZE]u8
	released: [2]quic.Remote

	conn_helper: Cache_Connection
	cache_connection_init(&conn_helper)
	defer cache_connection_destroy(&conn_helper)

	held: [CACHE_QUIC_STREAMS_PER_CONNECTION]Pipeline_Held_Stream
	defer {
		for &h in held {
			delete(h.resp_bytes)
		}
	}
	batch_released := false

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
			_ = net.set_blocking(srv.socket, false)
			for _ in 0 ..< 64 {
				mn, msender, merr := net.recv_udp(srv.socket, recv_buf[:])
				if merr != nil || mn <= 0 {
					break
				}
				if remote, ok := endpoint_to_quic_remote(msender); ok {
					out := quic.server_datagram_receive(&srv.quic_server, recv_buf[:mn], remote, ans_buf[:], now)
					if out.answer_length > 0 {
						_, _ = net.send_udp(srv.socket, ans_buf[:out.answer_length], msender)
					}
					if out.validate_remote && out.record >= 0 {
						quic.server_validation_confirmed(&srv.quic_server, out.record, srv.records[out.record].generation, true)
					}
				}
			}
			_ = net.set_blocking(srv.socket, true)
		}

		for idx in 0 ..< len(srv.records) {
			if !srv.records[idx].in_use || srv.connections[idx].state != .Connected {
				continue
			}
			conn := &srv.connections[idx]

			// Attach newly opened streams.
			for &stream in conn.streams {
				if !stream.in_use || (stream.end_read && (stream.send_finish || stream.reset_sent)) {
					continue
				}
				known := false
				for &h in held {
					if h.active && h.stream_id == stream.identifier {
						known = true
						break
					}
				}
				if !known {
					for &h in held {
						if !h.active {
							delete(h.resp_bytes)
							h = {active = true, stream_id = stream.identifier}
							break
						}
					}
				}
			}

			// Read incoming requests across all concurrent streams.
			ready_nonzero := 0
			for &h in held {
				if !h.active {
					continue
				}
				if !h.req_done {
					r, fin, rst := quic.stream_read(conn, h.stream_id, h.req_buf[h.req_len:])
					if rst {
						delete(h.resp_bytes)
						h = {}
						continue
					}
					h.req_len += r
					if fin && h.req_len >= object_cache.FRAME_HEADER_SIZE {
						req, dec_ref := object_cache.decode_request(h.req_buf[:h.req_len])
						if dec_ref == .None && req.kind == .Get_Object {
							h.frame_index = req.offset / object_cache.FRAME_PAYLOAD_BYTES
							resp, _ := cache_server_handle_connection_frame(srv.backing, &conn_helper, h.req_buf[:h.req_len])
							h.resp_bytes = make([]u8, len(resp))
							copy(h.resp_bytes, resp)
							h.send_len = len(resp)
							if h.frame_index == 2 {
								switch srv.mode {
								case .Reverse_Order_Valid:
								case .Corrupt_Mid_Pipeline:
									// Flip one byte inside frame 2's payload so Bao verification must fail.
									if len(h.resp_bytes) > 64 {
										h.resp_bytes[len(h.resp_bytes) - 17] ~= 0xFF
									}
								case .Truncate_Mid_Pipeline:
									if h.send_len > 512 {
										h.send_len = 512
									}
								case .Reset_Mid_Pipeline:
									h.reset_only = true
								}
							}
							h.req_done = true
							// Frame 0 answers immediately so the client learns object_size and opens frames 1..4.
							if h.frame_index == 0 {
								h.released = true
							}
						}
					}
				}
				if h.req_done && h.frame_index > 0 {
					ready_nonzero += 1
				}
			}

			// Release frames 1..4 ONLY once all 4 concurrent requests have arrived,
			// proving the client had all 4 frames in flight simultaneously!
			if !batch_released && ready_nonzero == CACHE_QUIC_STREAMS_PER_CONNECTION {
				batch_released = true
				for &h in held {
					if h.active && h.req_done && h.frame_index > 0 {
						h.released = true
					}
				}
			}

			// Send released responses in REVERSE frame_index order (4, 3, 2, 1) so
			// later frames complete ahead of earlier frames.
			for target_frame := i64(CACHE_QUIC_STREAMS_PER_CONNECTION); target_frame >= 0; target_frame -= 1 {
				for &h in held {
					if !h.active || !h.released || i64(h.frame_index) != target_frame {
						continue
					}
					if h.reset_only {
						quic.stream_reset(conn, h.stream_id, 1)
						quic.stream_stop_sending(conn, h.stream_id, 1)
						delete(h.resp_bytes)
						h = {}
						continue
					}
					if h.send_off < h.send_len {
						w := quic.stream_write(conn, h.stream_id, h.resp_bytes[h.send_off:h.send_len], true)
						h.send_off += w
					}
					if h.send_off >= h.send_len {
						delete(h.resp_bytes)
						h = {}
					}
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
quic_cache_pipelined_out_of_order_and_fault_refusals :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		os.remove_all(dir)
		delete(dir)
	}

	signer_priv, signer_pub, _ := make_test_ed25519_key(0x91)
	_, quic_pub, quic_seed := make_test_ed25519_key(0x92)

	backing, opened := cache_server_open(dir, [][32]u8{signer_pub})
	testing.expect(t, opened)
	defer cache_server_destroy(&backing)

	// Populate backing store with a 5-frame (4 MiB + 64 KiB) blob and its Bao outboard.
	blob_len := 4 * int(object_cache.FRAME_PAYLOAD_BYTES) + 64 * 1024
	blob := make([]u8, blob_len)
	defer delete(blob)
	for i in 0 ..< blob_len {
		blob[i] = u8((i * 47 + 13) & 0xFF)
	}
	blob_hash := blake3.hash(blob)
	sign_bytes, sign_ok := object_cache.put_object_signing_bytes(.Blob, blob_hash, u64(blob_len), signer_pub)
	testing.expect(t, sign_ok)
	sig: [64]u8
	ed25519.sign(&signer_priv, sign_bytes[:], sig[:])

	put_conn: Cache_Connection
	cache_connection_init(&put_conn)
	defer cache_connection_destroy(&put_conn)
	head_req := object_cache.Cache_Request {
		kind                = .Put_Object,
		object_hash         = blob_hash,
		object_kind         = .Blob,
		object_size         = u64(blob_len),
		uploader_public_key = signer_pub,
		uploader_signature  = sig,
	}
	hlen, _ := object_cache.encode_request(&head_req, put_conn.request_buffer[:])
	hresp, _ := cache_server_handle_connection_frame(&backing, &put_conn, put_conn.request_buffer[:hlen])
	hdec, _ := object_cache.decode_response(hresp)
	testing.expect_value(t, hdec.status, object_cache.Cache_Response_Status.Ok)
	for fidx in u64(0) ..< 5 {
		off := fidx * object_cache.FRAME_PAYLOAD_BYTES
		flen, _ := object_cache.object_frame_length(u64(blob_len), fidx)
		freq := object_cache.Cache_Request{kind = .Put_Object_Frame, object_hash = blob_hash, offset = off, payload = blob[off:off + flen]}
		req_n, _ := object_cache.encode_request(&freq, put_conn.request_buffer[:])
		fresp, _ := cache_server_handle_connection_frame(&backing, &put_conn, put_conn.request_buffer[:req_n])
		fdec, _ := object_cache.decode_response(fresp)
		testing.expect_value(t, fdec.status, object_cache.Cache_Response_Status.Ok)
	}

	modes := [4]Pipeline_Fault_Mode{.Reverse_Order_Valid, .Corrupt_Mid_Pipeline, .Truncate_Mid_Pipeline, .Reset_Mid_Pipeline}
	expected := [4]pr.Recipe_Refusal{.None, .Hash_Mismatch, .Malformed_Output, .Malformed_Output}

	for mode, idx in modes {
		sock, sock_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
		testing.expect(t, sock_err == nil)
		ep, _ := net.bound_endpoint(sock)

		srv := new(Pipeline_Adversarial_Server)
		srv.backing = &backing
		srv.socket = sock
		srv.bound_endpoint = ep
		srv.mode = mode
		srv.cryptography = cache_quic_cryptography()
		srv.start_tick = time.tick_now()
		rng_seed: [random.SEED_SIZE]u8
		crypto.rand_bytes(rng_seed[:])
		random.generator_seed(&srv.generator, &rng_seed, .Processor)

		cfg := quic.Connection_Configuration {
			idle_timeout_milliseconds = 10_000,
			tls = {role = .Server, least_seed_strength = .Processor, server_private_key = quic_seed},
		}
		cfg.tls.application_protocol_length = copy(cfg.tls.application_protocol[:], object_cache.APPLICATION_PROTOCOL)
		init_err: errors.Error_Record
		testing.expect(t, quic.server_init(&srv.quic_server, srv.connections[:], srv.records[:], srv.streams[:], &cfg, &srv.cryptography, &srv.generator, quic.server_limits_of_one_address(2), &init_err))
		srv.worker = thread.create(pipeline_adversarial_worker)
		srv.worker.data = srv
		thread.start(srv.worker)

		crypto_table := cache_quic_cryptography()
		generator: random.Generator
		udp: Host_Udp_Transport
		client, made := make_host_quic_client(ep, quic_pub, &crypto_table, &generator, &udp)
		testing.expect(t, made)

		mem_store := new(pr.Memory_Private_Store)
		large_backing := make([]u8, 6 * 1024 * 1024)
		mem_store.large_bytes = large_backing
		state := new(recipes_core.Recipes_State)
		recipes_core.state_init(state, pr.memory_private_store_port(mem_store))

		got_sz, ref := recipes_core.cache_quic_fetch_object_to_store(client, state, blob_hash, .Blob)
		testing.expect_value(t, ref, expected[idx])
		testing.expect_value(t, client.last_fetch_max_in_flight, recipes_core.CACHE_PIPELINE_WINDOW)

		obj_name := pr.blob_object_name(blob_hash)
		if mode == .Reverse_Order_Valid {
			testing.expect_value(t, got_sz, u64(blob_len))
			testing.expect(t, client.last_fetch_out_of_order > 0, "reverse-order responses must trigger out-of-order completion")
			read_buf := make([]u8, blob_len)
			got_slice, r_st := pr.private_store_read(&state.store, pr.private_object_name_text(&obj_name), read_buf)
			testing.expect_value(t, r_st, pr.Private_Store_Status.Ok)
			testing.expect_value(t, len(got_slice), blob_len)
			testing.expect_value(t, blake3.hash(got_slice), blob_hash)
			delete(read_buf)
		} else {
			// Any mid-pipeline fault must leave neither <64-hex> nor fetch_staging behind.
			_, final_st := pr.private_store_size(&state.store, pr.private_object_name_text(&obj_name))
			testing.expect_value(t, final_st, pr.Private_Store_Status.Absent)
			_, stage_st := pr.private_store_size(&state.store, recipes_core.FETCH_STAGING_NAME)
			testing.expect_value(t, stage_st, pr.Private_Store_Status.Absent)
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

// Sending a malformed request header with fin = false plus trailing bytes must
// answer with a refusal, send STOP_SENDING, never re-attach that finished
// stream, and allow a subsequent valid request on a fresh stream to succeed.
@(test)
quic_cache_malformed_header_without_fin_does_not_wedge_slot :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		os.remove_all(dir)
		delete(dir)
	}

	_, signer_pub, _ := make_test_ed25519_key(0xA1)
	_, _, quic_seed := make_test_ed25519_key(0xA2)

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

	// Open a raw stream and send a malformed 12-byte header + trailing bytes with fin = false.
	bad_stream, bad_opened := quic.stream_open(&client.connection)
	testing.expect(t, bad_opened)
	bad_payload := [32]u8{'B', 'A', 'D', '!', 99, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}
	wrote := quic.stream_write(&client.connection, bad_stream, bad_payload[:], false)
	testing.expect_value(t, wrote, len(bad_payload))

	// Pump until the server answers with a refusal response and FIN on bad_stream.
	resp_buf: [256]u8
	recv_len := 0
	got_fin := false
	deadline := host_udp_now_us(&udp) + 5_000_000
	for !got_fin && host_udp_now_us(&udp) < deadline {
		now := host_udp_now_us(&udp)
		for {
			dlen := quic.connection_datagram_send(&client.connection, client.datagram_buf[:quic.MAX_DATAGRAM_SIZE], now)
			if dlen == 0 {
				break
			}
			_ = host_udp_send(client.datagram_buf[:dlen], &udp)
		}
		if n, ok := host_udp_recv(client.datagram_buf[:], deadline, &udp); ok && n > 0 {
			err: errors.Error_Record
			quic.connection_datagram_receive(&client.connection, client.datagram_buf[:n], host_udp_now_us(&udp), &err)
		}
		quic.connection_time_passes(&client.connection, host_udp_now_us(&udp))
		r, fin, _ := quic.stream_read(&client.connection, bad_stream, resp_buf[recv_len:])
		recv_len += r
		if fin {
			got_fin = true
		}
	}
	testing.expect(t, got_fin, "server must close the malformed non-FIN stream with a refusal response")
	testing.expect(t, recv_len >= object_cache.FRAME_HEADER_SIZE)
	bad_resp, bad_dec := object_cache.decode_response(resp_buf[:recv_len])
	testing.expect_value(t, bad_dec, object_cache.Wire_Refusal.None)
	testing.expect_value(t, bad_resp.status, object_cache.Cache_Response_Status.Refused)

	// Send additional trailing bytes without FIN on the already-rejected stream,
	// then verify a fresh stream immediately serves a valid Get_Object request cleanly.
	_ = quic.stream_write(&client.connection, bad_stream, bad_payload[:8], false)

	probe_hash := blake3.hash(transmute([]u8)string("fresh-stream-after-malformed"))
	get_req := object_cache.Cache_Request{kind = .Get_Object, object_hash = probe_hash, object_kind = .Blob, offset = 0}
	get_resp, get_err := recipes_core.cache_quic_client_exchange(client, &get_req)
	testing.expect_value(t, get_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, get_resp.status, object_cache.Cache_Response_Status.Not_Found)
}

@(private = "file")
Publish_Sign_Recorder :: struct {
	priv:            ^ed25519.Private_Key,
	fail_all:        bool,
	corrupt_sig:     bool,
	order_hashes:    [32]blake3.Hash,
	order_is_real:   [32]bool,
	order_count:     int,
}

@(private = "file")
host_publish_sign :: proc "contextless" (
	message: []u8,
	out_signature: ^[object_cache.SIGNATURE_SIZE]u8,
	user: rawptr,
) -> bool {
	context = runtime.default_context()
	rec := (^Publish_Sign_Recorder)(user)
	if rec == nil || rec.priv == nil || rec.fail_all {
		return false
	}
	if rec.order_count < len(rec.order_hashes) {
		put_domain := object_cache.PUT_OBJECT_SIGNING_DOMAIN
		real_domain := object_cache.REALISATION_SIGNING_DOMAIN
		if len(message) == object_cache.PUT_OBJECT_SIGNING_BYTES_SIZE && string(message[:len(put_domain)]) == put_domain {
			// Put_Object signing bytes: [0..19] domain, [19] 0x00, [20] kind, [21..24] reserved, [24..56] object_hash
			copy(rec.order_hashes[rec.order_count][:], message[24:][:blake3.HASH_SIZE])
			rec.order_is_real[rec.order_count] = false
			rec.order_count += 1
		} else if len(message) == object_cache.REALISATION_SIGNING_BYTES_SIZE && string(message[:len(real_domain)]) == real_domain {
			// Realisation signing bytes: [0..20] domain, [20] 0x00, [21] kind, [22..24] reserved, [24..56] recipe_hash
			copy(rec.order_hashes[rec.order_count][:], message[24:][:blake3.HASH_SIZE])
			rec.order_is_real[rec.order_count] = true
			rec.order_count += 1
		}
	}
	ed25519.sign(rec.priv, message, out_signature[:])
	if rec.corrupt_sig {
		out_signature[0] ~= 0xFF
	}
	return true
}

@(private = "file")
publish_test_builder_invoke :: proc "contextless" (
	_: ^pr.Builder_Sandbox_Spec,
	staging: []u8,
	user_data: rawptr,
) -> (payload: []u8, ok: bool) {
	src := (^[]u8)(user_data)^
	if len(src) > len(staging) {
		return nil, false
	}
	copy(staging[:len(src)], src)
	return staging[:len(src)], true
}

// End-to-end QUIC publish + fetch + .Verify + .Cache_Only test:
// - builds a nested Tree closure containing a >1 MiB multi-frame Blob and small Blobs;
// - publishes from recipes_core via cache_quic_publish_realisation (recalling
//   realisation_<hash> directly from private store);
// - asserts strict bottom-up upload order (all child blobs -> sub tree -> root tree -> Put_Realisation last);
// - re-publishes and asserts all objects are skipped via Already_Present;
// - fetches from a fresh Recipes_State in Cache_Only mode over QUIC;
// - verifies reproducibility in Verify mode (matching -> verify_agreements = 1,
//   disagreeing -> Verify_Disagreement + verify_disagreements = 1).
@(test)
quic_cache_publish_closure_bottom_up_multiframe_verify_and_cache_only :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		os.remove_all(dir)
		delete(dir)
	}

	pub_priv, pub_key, _ := make_test_ed25519_key(0x61)
	_, _, quic_seed := make_test_ed25519_key(0x62)

	server, opened := cache_server_open(dir, [][32]u8{pub_key})
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

	// Populate publisher's local Recipes_State private store with:
	//   root_tree -> { "module": root_mod_blob, "sub": sub_tree }
	//   sub_tree  -> { "big.bin": large_blob (>1 MiB), "small.txt": small_blob }
	pub_mem := new(pr.Memory_Private_Store)
	defer free(pub_mem)
	large_backing := make([]u8, 4 * 1024 * 1024)
	defer delete(large_backing)
	pub_mem.large_bytes = large_backing

	pub_state := new(recipes_core.Recipes_State)
	defer free(pub_state)
	recipes_core.state_init(pub_state, pr.memory_private_store_port(pub_mem))

	small_blob := transmute([]u8)string("small-nested-leaf-v1")
	small_hash := blake3.hash(small_blob)
	large_size := int(object_cache.FRAME_PAYLOAD_BYTES) + 45_678
	large_blob := make([]u8, large_size)
	defer delete(large_blob)
	for i in 0 ..< large_size {
		large_blob[i] = u8((i * 73 + 9) & 0xFF)
	}
	large_hash := blake3.hash(large_blob)
	root_mod_blob := transmute([]u8)string("compiled-module-payload-v1")
	root_mod_hash := blake3.hash(root_mod_blob)

	// Write blobs into publisher private store.
	sn := pr.blob_object_name(small_hash)
	testing.expect_value(t, pr.private_store_write(&pub_state.store, pr.private_object_name_text(&sn), small_blob), pr.Private_Store_Status.Ok)
	ln := pr.blob_object_name(large_hash)
	testing.expect_value(t, pr.private_store_write(&pub_state.store, pr.private_object_name_text(&ln), large_blob), pr.Private_Store_Status.Ok)
	rn := pr.blob_object_name(root_mod_hash)
	testing.expect_value(t, pr.private_store_write(&pub_state.store, pr.private_object_name_text(&rn), root_mod_blob), pr.Private_Store_Status.Ok)

	// Encode sub_tree and root_tree.
	se1, _ := tree_hash.tree_entry_make(.Object, "big.bin", large_hash)
	se2, _ := tree_hash.tree_entry_make(.Object, "small.txt", small_hash)
	sub_buf: [512]u8
	sub_len, sub_enc_ref := tree_hash.tree_encode([]tree_hash.Tree_Entry{se1, se2}, sub_buf[:])
	testing.expect_value(t, sub_enc_ref, tree_hash.Tree_Refusal.None)
	sub_bytes := sub_buf[:sub_len]
	sub_hash, sub_h_ref := tree_hash.tree_hash(sub_bytes)
	testing.expect_value(t, sub_h_ref, tree_hash.Tree_Refusal.None)
	subn := pr.blob_object_name(sub_hash)
	testing.expect_value(t, pr.private_store_write(&pub_state.store, pr.private_object_name_text(&subn), sub_bytes), pr.Private_Store_Status.Ok)

	re1, _ := tree_hash.tree_entry_make(.Object, "module", root_mod_hash)
	re2, _ := tree_hash.tree_entry_make(.Tree, "sub", sub_hash)
	root_buf: [512]u8
	root_len, root_enc_ref := tree_hash.tree_encode([]tree_hash.Tree_Entry{re1, re2}, root_buf[:])
	testing.expect_value(t, root_enc_ref, tree_hash.Tree_Refusal.None)
	root_bytes := root_buf[:root_len]
	root_hash, root_h_ref := tree_hash.tree_hash(root_bytes)
	testing.expect_value(t, root_h_ref, tree_hash.Tree_Refusal.None)
	rootn := pr.blob_object_name(root_hash)
	testing.expect_value(t, pr.private_store_write(&pub_state.store, pr.private_object_name_text(&rootn), root_bytes), pr.Private_Store_Status.Ok)

	// Write realisation_<recipe_hash> ONLY in private store (not in pub_state.realisations index)
	// to verify publish recalls realisations persisted across restarts.
	spec := pr.Recipe_Spec {
		builder_hash       = blake3.hash(transmute([]u8)string("publish-test-builder-v1")),
		output_kind        = .Tree,
		source_date_unix   = 1_700_000_001,
		output_block_limit = 1024,
	}
	recipe_hash, r_ref := pr.recipe_hash(&spec)
	testing.expect_value(t, r_ref, pr.Recipe_Refusal.None)

	local_real := object_cache.Realisation_Record {
		recipe_hash = recipe_hash,
		output_hash = root_hash,
		output_kind = .Tree,
	}
	real_obj_buf: [pr.REALISATION_OBJECT_HEAD_SIZE]u8
	real_obj_len, real_enc_ref := pr.encode_realisation_object(&local_real, u64(recipes_core.Provenance_Origin.Local_Build), u64(root_len), real_obj_buf[:])
	testing.expect_value(t, real_enc_ref, pr.Recipe_Refusal.None)
	real_obj_name := pr.realisation_object_name(recipe_hash)
	testing.expect_value(t, pr.private_store_write(&pub_state.store, pr.private_object_name_text(&real_obj_name), real_obj_buf[:real_obj_len]), pr.Private_Store_Status.Ok)

	// 1. Publish over QUIC and verify bottom-up ordering + exact counts.
	recorder := Publish_Sign_Recorder{priv = &pub_priv}
	stats, pub_ref, pub_st, pub_err := recipes_core.cache_quic_publish_realisation(
		client,
		pub_state,
		recipe_hash,
		pub_key,
		host_publish_sign,
		&recorder,
	)
	testing.expect_value(t, pub_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, pub_st, object_cache.Cache_Response_Status.Ok)
	testing.expect_value(t, pub_ref, pr.Recipe_Refusal.None)
	testing.expect_value(t, stats.recipe_hash, recipe_hash)
	testing.expect_value(t, stats.output_hash, root_hash)
	testing.expect_value(t, stats.signer_public_key, pub_key)
	testing.expect_value(t, stats.objects_uploaded, u64(5))
	testing.expect_value(t, stats.objects_skipped, u64(0))
	expected_bytes := u64(len(small_blob) + len(large_blob) + len(root_mod_blob) + len(sub_bytes) + len(root_bytes))
	testing.expect_value(t, stats.bytes_uploaded, expected_bytes)

	// Assert strict bottom-up ordering: 5 objects + 1 realisation = 6 signatures.
	testing.expect_value(t, recorder.order_count, 6)
	pos_of :: proc(rec: ^Publish_Sign_Recorder, target: blake3.Hash, is_real: bool) -> int {
		for i in 0 ..< rec.order_count {
			if rec.order_hashes[i] == target && rec.order_is_real[i] == is_real {
				return i
			}
		}
		return -1
	}
	pos_small := pos_of(&recorder, small_hash, false)
	pos_large := pos_of(&recorder, large_hash, false)
	pos_sub := pos_of(&recorder, sub_hash, false)
	pos_mod := pos_of(&recorder, root_mod_hash, false)
	pos_root := pos_of(&recorder, root_hash, false)
	pos_real := pos_of(&recorder, recipe_hash, true)
	testing.expect(t, pos_small >= 0 && pos_large >= 0 && pos_sub >= 0 && pos_mod >= 0 && pos_root >= 0 && pos_real == 5)
	testing.expect(t, pos_small < pos_sub && pos_large < pos_sub, "sub tree children must upload before sub tree")
	testing.expect(t, pos_sub < pos_root && pos_mod < pos_root, "root tree children must upload before root tree")
	testing.expect(t, pos_root < pos_real, "root tree must upload before Put_Realisation")

	// 2. Re-publish: all 5 objects return Already_Present -> objects_skipped == 5, bytes_uploaded == 0.
	stats2, pub_ref2, pub_st2, pub_err2 := recipes_core.cache_quic_publish_realisation(
		client,
		pub_state,
		recipe_hash,
		pub_key,
		host_publish_sign,
		&recorder,
	)
	testing.expect_value(t, pub_err2, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, pub_st2, object_cache.Cache_Response_Status.Ok)
	testing.expect_value(t, pub_ref2, pr.Recipe_Refusal.None)
	testing.expect_value(t, stats2.objects_uploaded, u64(0))
	testing.expect_value(t, stats2.objects_skipped, u64(5))
	testing.expect_value(t, stats2.bytes_uploaded, u64(0))

	// 3. Fresh consumer fetches over QUIC in Cache_Only mode -> full nested closure restored.
	consumer_mem := new(pr.Memory_Private_Store)
	defer free(consumer_mem)
	consumer_backing := make([]u8, 4 * 1024 * 1024)
	defer delete(consumer_backing)
	consumer_mem.large_bytes = consumer_backing

	consumer_state := new(recipes_core.Recipes_State)
	defer free(consumer_state)
	recipes_core.state_init(consumer_state, pr.memory_private_store_port(consumer_mem))

	fetch_ctx := recipes_core.Cache_Quic_Fetch_Context {
		client           = client,
		verify_signature = host_ed25519_verify,
	}
	consumer_state.remote_cache_fetch = recipes_core.cache_quic_fetch_realisation
	consumer_state.remote_cache_user = &fetch_ctx

	signers := [1][object_cache.PUBLIC_KEY_SIZE]u8{pub_key}
	policy := object_cache.Substitution_Policy{mode = .Cache_Only, trusted_signers = signers[:]}

	res_cache_only := recipes_core.build_recipe(consumer_state, &spec, .Cache_Only, policy, nil, nil, host_ed25519_verify, nil)
	testing.expect_value(t, res_cache_only.outcome, pr.Recipe_Build_Outcome.From_Cache)
	testing.expect_value(t, res_cache_only.refusal, pr.Recipe_Refusal.None)
	testing.expect_value(t, res_cache_only.output_hash, root_hash)
	testing.expect_value(t, consumer_state.counters.cache_hits_remote, u64(1))
	testing.expect_value(t, recipes_core.stored_output_check(consumer_state, large_hash, .Blob, u64(large_size)), recipes_core.Stored_Output.Whole)

	// 4. Verify mode on publisher's already-local state: skips local cache, fetches
	//    remote QUIC cache, rebuilds locally, and confirms reproducibility.
	pub_state.remote_cache_fetch = recipes_core.cache_quic_fetch_realisation
	pub_state.remote_cache_user = &fetch_ctx
	matching_payload := root_bytes
	verify_policy := object_cache.Substitution_Policy{mode = .Verify, trusted_signers = signers[:]}
	res_verify := recipes_core.build_recipe(pub_state, &spec, .Verify, verify_policy, nil, publish_test_builder_invoke, host_ed25519_verify, nil, &matching_payload)
	testing.expect_value(t, res_verify.outcome, pr.Recipe_Build_Outcome.Built_Locally)
	testing.expect_value(t, res_verify.refusal, pr.Recipe_Refusal.None)
	testing.expect(t, res_verify.verified_reproducible, "Verify mode must confirm remote cache match")
	testing.expect_value(t, pub_state.counters.verify_agreements, u64(1))

	// 5. Verify mode with a different local output -> Refused(Verify_Disagreement).
	other_blob := transmute([]u8)string("different-module-bytes")
	oe1, _ := tree_hash.tree_entry_make(.Object, "module", blake3.hash(other_blob))
	other_buf: [256]u8
	other_len, _ := tree_hash.tree_encode([]tree_hash.Tree_Entry{oe1}, other_buf[:])
	disagree_payload := other_buf[:other_len]
	res_disagree := recipes_core.build_recipe(pub_state, &spec, .Verify, verify_policy, nil, publish_test_builder_invoke, host_ed25519_verify, nil, &disagree_payload)
	testing.expect_value(t, res_disagree.outcome, pr.Recipe_Build_Outcome.Refused)
	testing.expect_value(t, res_disagree.refusal, pr.Recipe_Refusal.Verify_Disagreement)
	testing.expect_value(t, pub_state.counters.verify_disagreements, u64(1))
}

// Adversarial QUIC publish refusals: unauthorized publisher key, bad signature,
// tampered leaf blob, and missing child blob must each be refused cleanly and
// leave zero realisation on the server.
@(test)
quic_cache_publish_refuses_unauthorized_bad_sig_tampered_and_missing_child :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		os.remove_all(dir)
		delete(dir)
	}

	_, auth_pub, _ := make_test_ed25519_key(0x71)
	unauth_priv, unauth_pub, _ := make_test_ed25519_key(0x72)
	auth_priv, _, _ := make_test_ed25519_key(0x71)
	_, _, quic_seed := make_test_ed25519_key(0x73)

	server, opened := cache_server_open(dir, [][32]u8{auth_pub})
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

	pub_mem := new(pr.Memory_Private_Store)
	defer free(pub_mem)
	pub_state := new(recipes_core.Recipes_State)
	defer free(pub_state)
	recipes_core.state_init(pub_state, pr.memory_private_store_port(pub_mem))

	leaf := transmute([]u8)string("adversarial-leaf")
	leaf_hash := blake3.hash(leaf)
	ln := pr.blob_object_name(leaf_hash)
	testing.expect_value(t, pr.private_store_write(&pub_state.store, pr.private_object_name_text(&ln), leaf), pr.Private_Store_Status.Ok)

	e1, _ := tree_hash.tree_entry_make(.Object, "module", leaf_hash)
	tree_buf: [256]u8
	t_len, _ := tree_hash.tree_encode([]tree_hash.Tree_Entry{e1}, tree_buf[:])
	t_hash, _ := tree_hash.tree_hash(tree_buf[:t_len])
	tn := pr.blob_object_name(t_hash)
	testing.expect_value(t, pr.private_store_write(&pub_state.store, pr.private_object_name_text(&tn), tree_buf[:t_len]), pr.Private_Store_Status.Ok)

	recipe_hash := blake3.hash(transmute([]u8)string("adversarial-recipe"))
	real_rec := object_cache.Realisation_Record{recipe_hash = recipe_hash, output_hash = t_hash, output_kind = .Tree}
	real_buf: [pr.REALISATION_OBJECT_HEAD_SIZE]u8
	real_len, _ := pr.encode_realisation_object(&real_rec, u64(recipes_core.Provenance_Origin.Local_Build), u64(t_len), real_buf[:])
	real_name := pr.realisation_object_name(recipe_hash)
	testing.expect_value(t, pr.private_store_write(&pub_state.store, pr.private_object_name_text(&real_name), real_buf[:real_len]), pr.Private_Store_Status.Ok)

	// 1. Unauthorized key -> server refuses with Unauthorized -> Untrusted_Realisation.
	unauth_rec := Publish_Sign_Recorder{priv = &unauth_priv}
	_, ref1, st1, err1 := recipes_core.cache_quic_publish_realisation(client, pub_state, recipe_hash, unauth_pub, host_publish_sign, &unauth_rec)
	testing.expect_value(t, err1, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, st1, object_cache.Cache_Response_Status.Unauthorized)
	testing.expect_value(t, ref1, pr.Recipe_Refusal.Untrusted_Realisation)

	// 2. Corrupted signature with authorized key -> Bad_Signature.
	bad_sig_rec := Publish_Sign_Recorder{priv = &auth_priv, corrupt_sig = true}
	_, ref2, st2, err2 := recipes_core.cache_quic_publish_realisation(client, pub_state, recipe_hash, auth_pub, host_publish_sign, &bad_sig_rec)
	testing.expect_value(t, err2, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, st2, object_cache.Cache_Response_Status.Bad_Signature)
	testing.expect_value(t, ref2, pr.Recipe_Refusal.Bad_Signature)

	// 3. Tampered leaf blob in local store -> Hash_Mismatch before uploading parent tree or realisation.
	tampered := transmute([]u8)string("tampered-leaf-!!")
	testing.expect_value(t, pr.private_store_write(&pub_state.store, pr.private_object_name_text(&ln), tampered), pr.Private_Store_Status.Ok)
	auth_rec := Publish_Sign_Recorder{priv = &auth_priv}
	_, ref3, _, _ := recipes_core.cache_quic_publish_realisation(client, pub_state, recipe_hash, auth_pub, host_publish_sign, &auth_rec)
	testing.expect_value(t, ref3, pr.Recipe_Refusal.Hash_Mismatch)

	// 4. Missing leaf blob in local store -> Cache_Miss.
	testing.expect_value(t, pr.private_store_remove(&pub_state.store, pr.private_object_name_text(&ln)), pr.Private_Store_Status.Ok)
	_, ref4, _, _ := recipes_core.cache_quic_publish_realisation(client, pub_state, recipe_hash, auth_pub, host_publish_sign, &auth_rec)
	testing.expect_value(t, ref4, pr.Recipe_Refusal.Cache_Miss)

	// Confirm the server still holds no realisation for recipe_hash.
	get_real := object_cache.Cache_Request{kind = .Get_Realisation, recipe_hash = recipe_hash}
	resp, gerr := recipes_core.cache_quic_client_exchange(client, &get_real)
	testing.expect_value(t, gerr, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, resp.status, object_cache.Cache_Response_Status.Not_Found)
}

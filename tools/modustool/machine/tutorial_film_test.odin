// Host tests for the tutorial film scenario, placeholder expansion, project
// tree hashing + recipe evaluation, peer cache UDP forwarder, and signed QUIC
// cache seeding.
package machine

import "base:runtime"
import "core:crypto"
import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import module "modus:contract/module"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/release"
import "modus:cryptography/ed25519"
import "modus:random"
import "modustool:build"
import "modustool:cache_server"

@(private = "file")
sample_tutorial_bindings :: proc() -> Tutorial_Film_Bindings {
	return {
		cache_server_key  = strings.repeat("1", 64, context.temp_allocator),
		cache_signer_key  = strings.repeat("2", 64, context.temp_allocator),
		collatz_here      = strings.repeat("3", 64, context.temp_allocator),
		db_browser_here   = strings.repeat("4", 64, context.temp_allocator),
		db_browser_recipe = strings.repeat("5", 64, context.temp_allocator),
		db_browser_output = strings.repeat("6", 64, context.temp_allocator),
		db_browser_hash   = strings.repeat("7", 64, context.temp_allocator),
	}
}

// Placeholder expansion refuses missing required bindings, expands every
// tutorial placeholder cleanly, and produces only keystrokes supported by
// key_names_of_a_text.
@(test)
tutorial_film_expands_placeholders_and_refuses_missing_bindings :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Missing required binding is refused.
	incomplete := sample_tutorial_bindings()
	incomplete.cache_server_key = ""
	_, ok := tutorial_film_expand_steps(scenario_tutorial_film[:], incomplete)
	testing.expect(t, !ok, "empty cache_server_key binding is refused")

	incomplete2 := sample_tutorial_bindings()
	incomplete2.db_browser_recipe = ""
	_, ok = tutorial_film_expand_steps(scenario_tutorial_film[:], incomplete2)
	testing.expect(t, !ok, "empty db_browser_recipe binding is refused")

	// Complete bindings expand cleanly with zero leftover placeholders.
	bindings := sample_tutorial_bindings()
	expanded, expanded_ok := tutorial_film_expand_steps(scenario_tutorial_film[:], bindings)
	if !testing.expect(t, expanded_ok, "complete bindings expand cleanly") {
		return
	}
	defer tutorial_film_steps_free(expanded)
	testing.expect_value(t, len(expanded), len(scenario_tutorial_film))

	for step, index in expanded {
		testing.expectf(t, !strings.contains_rune(step.text, '{'), "step %d text still has placeholder: %s", index + 1, step.text)
		testing.expectf(t, !strings.contains_rune(step.expected, '{'), "step %d expected still has placeholder: %s", index + 1, step.expected)
		if step.kind == .Type || step.kind == .Film_Type {
			_, unknown := key_names_of_a_text(step.text)
			testing.expectf(t, unknown < 0, "step %d (%v) contains untypeable character at %d: %q", index + 1, step.kind, unknown, step.text)
		}
	}
}

// The real outside project folders hash deterministically under MODTREE2 and
// their project.lex outputs.default recipes evaluate cleanly against a
// generated catalog.lex.
@(test)
tutorial_project_trees_hash_and_evaluate_recipes_deterministically :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	collatz_objs, collatz_trees, collatz_here, collatz_ok := tutorial_read_project_tree(TUTORIAL_COLLATZ_DIR)
	if !testing.expect(t, collatz_ok, "collatz project tree reads and hashes") {
		return
	}
	defer tutorial_free_project_tree(collatz_objs, collatz_trees)

	db_objs, db_trees, db_here, db_ok := tutorial_read_project_tree(TUTORIAL_DB_BROWSER_DIR)
	if !testing.expect(t, db_ok, "db_browser project tree reads and hashes") {
		return
	}
	defer tutorial_free_project_tree(db_objs, db_trees)
	testing.expect(t, len(db_trees) >= 1, "db_browser includes nested core/ subtree")

	se_objs, se_trees, se_here, se_ok := tutorial_read_project_tree(TUTORIAL_STORE_EXPLORER_DIR)
	if !testing.expect(t, se_ok, "store_explorer project tree reads and hashes") {
		return
	}
	defer tutorial_free_project_tree(se_objs, se_trees)
	testing.expect(t, collatz_here != db_here && db_here != se_here, "distinct projects have distinct here() hashes")

	// Build a deterministic catalog.lex with the four required builder modules.
	catalog_modules := [?]build.Module_Hash{
		{name = "assemble", hash = blake3.hash(transmute([]u8)string("asm"))},
		{name = "c_builder", hash = blake3.hash(transmute([]u8)string("cb"))},
		{name = "c_compiler", hash = blake3.hash(transmute([]u8)string("cc"))},
		{name = "host", hash = blake3.hash(transmute([]u8)string("host"))},
	}
	catalog_lex, cat_problem := build.system_catalog_of_modules(catalog_modules[:], release.RELEASE_NUMBER, .Boot_Image)
	testing.expect_value(t, cat_problem, "")

	db_lex, db_lex_err := os.read_entire_file(TUTORIAL_DB_BROWSER_DIR + "/project.lex", context.temp_allocator)
	testing.expect(t, db_lex_err == nil)
	se_lex, se_lex_err := os.read_entire_file(TUTORIAL_STORE_EXPLORER_DIR + "/project.lex", context.temp_allocator)
	testing.expect(t, se_lex_err == nil)

	db_recipe_1, r1_ok := tutorial_evaluate_project_recipe(string(db_lex), db_here, catalog_lex)
	db_recipe_2, r2_ok := tutorial_evaluate_project_recipe(string(db_lex), db_here, catalog_lex)
	se_recipe, r3_ok := tutorial_evaluate_project_recipe(string(se_lex), se_here, catalog_lex)
	testing.expect(t, r1_ok && r2_ok && r3_ok, "db_browser and store_explorer outputs.default evaluate to recipes")
	testing.expect_value(t, db_recipe_1, db_recipe_2)
	testing.expect(t, db_recipe_1 != se_recipe, "distinct projects evaluate to distinct recipe hashes")

	// Malformed project.lex is refused cleanly.
	_, bad_ok := tutorial_evaluate_project_recipe("project { outputs = { default = 42 } }", db_here, catalog_lex)
	testing.expect(t, !bad_ok, "non-recipe outputs.default is refused")
}

// peer_cache answers ARP for 10.0.2.100, builds checksum-valid UDP frames from
// 10.0.2.100:5010, forwards UDP datagrams bidirectionally to a loopback socket,
// and drops oversized datagrams without sending.
@(test)
peer_cache_answers_arp_and_forwards_udp_bidirectionally :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// 1. ARP reply claims 10.0.2.100 at PEER_CACHE_HARDWARE.
	req_frame: [60]u8
	req_frame[0], req_frame[1], req_frame[2], req_frame[3], req_frame[4], req_frame[5] = 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	machine_mac := [6]u8{0x52, 0x54, 0x00, 0x12, 0x34, 0x56}
	copy(req_frame[6:12], machine_mac[:])
	put16(req_frame[:], 12, 0x0806)
	put16(req_frame[:], 14, 1)
	put16(req_frame[:], 16, 0x0800)
	req_frame[18], req_frame[19] = 6, 4
	put16(req_frame[:], 20, 1)
	copy(req_frame[22:28], machine_mac[:])
	copy(req_frame[28:32], MACHINE_ADDRESS[:])
	copy(req_frame[38:42], PEER_CACHE_ADDRESS[:])

	arp_reply := peer_cache_arp_reply(req_frame[:], req_frame[14:])
	testing.expect_value(t, be16(arp_reply[:], 12), 0x0806)
	testing.expect_value(t, be16(arp_reply[:], 20), 2)
	testing.expect(t, slice.equal(arp_reply[22:28], PEER_CACHE_HARDWARE[:]))
	testing.expect(t, slice.equal(arp_reply[28:32], PEER_CACHE_ADDRESS[:]))
	testing.expect(t, slice.equal(arp_reply[32:38], machine_mac[:]))

	// 2. Generated IPv4 + UDP frame has valid checksums and ports.
	payload := transmute([]u8)string("hello-cache")
	udp_frame := peer_cache_udp_frame(machine_mac, 54321, payload)
	testing.expect_value(t, internet_sum(0, udp_frame[14:34]), 0)
	udp_len := 8 + len(payload)
	testing.expect_value(t, be16(udp_frame, 34), int(PEER_CACHE_PORT))
	testing.expect_value(t, be16(udp_frame, 36), 54321)
	testing.expect_value(t, internet_sum(pseudo_sum(PEER_CACHE_ADDRESS[:], MACHINE_ADDRESS[:], udp_len), udp_frame[34:34 + udp_len]), 0)

	// 3. Bidirectional forwarding through Peer_Cache against a loopback UDP socket.
	echo_sock, echo_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if !testing.expect(t, echo_err == nil) {
		return
	}
	defer net.close(echo_sock)
	echo_ep, ep_err := net.bound_endpoint(echo_sock)
	testing.expect(t, ep_err == nil)
	_ = net.set_option(echo_sock, .Receive_Timeout, 200 * time.Millisecond)

	recv_sock, recv_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if !testing.expect(t, recv_err == nil) {
		return
	}
	defer net.close(recv_sock)
	recv_ep, recv_ep_err := net.bound_endpoint(recv_sock)
	testing.expect(t, recv_ep_err == nil)
	_ = net.set_option(recv_sock, .Receive_Timeout, 200 * time.Millisecond)

	peer_sock, peer_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if !testing.expect(t, peer_err == nil) {
		return
	}
	defer net.close(peer_sock)

	peer := Peer{
		socket   = peer_sock,
		machine  = recv_ep,
		hardware = machine_mac,
	}
	testing.expect(t, peer_cache_start(&peer.cache, echo_ep))
	defer peer_cache_stop(&peer.cache)

	// Oversized datagram is refused and counted.
	oversized := make([]u8, PEER_CACHE_DATA_LIMIT + 1, context.temp_allocator)
	peer_cache_datagram(&peer, 44444, oversized)
	testing.expect_value(t, peer.cache.too_long, 1)
	testing.expect_value(t, peer.cache.to_cache, 0)

	// Valid datagram forwards to echo_sock and reply relays back as an Ethernet frame.
	peer_cache_datagram(&peer, 44444, payload)
	testing.expect_value(t, peer.cache.to_cache, 1)

	got: [128]u8
	n, from, r_err := net.recv_udp(echo_sock, got[:])
	testing.expect(t, r_err == nil && n == len(payload))
	testing.expect(t, slice.equal(got[:n], payload))

	// Stray loopback datagram from another sender is dropped, never injected.
	stray_sock, stray_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if testing.expect(t, stray_err == nil) {
		defer net.close(stray_sock)
		cache_ep, cache_ep_err := net.bound_endpoint(peer.cache.socket)
		testing.expect(t, cache_ep_err == nil)
		_, _ = net.send_udp(stray_sock, transmute([]u8)string("spoofed"), cache_ep)
	}

	reply_msg := transmute([]u8)string("cache-reply")
	_, s_err := net.send_udp(echo_sock, reply_msg, from)
	testing.expect(t, s_err == nil)

	// Wait bounded for peer_cache_tick to relay the Ethernet frame back to recv_sock.
	relayed := false
	frame_buf: [2048]u8
	for started := time.tick_now(); time.tick_since(started) < 2 * time.Second; {
		peer_cache_tick(&peer)
		fn, _, f_err := net.recv_udp(recv_sock, frame_buf[:])
		if f_err == nil && fn >= 42 + len(reply_msg) {
			testing.expect_value(t, be16(frame_buf[:fn], 34), int(PEER_CACHE_PORT))
			testing.expect_value(t, be16(frame_buf[:fn], 36), 44444)
			testing.expect(t, slice.equal(frame_buf[42:42 + len(reply_msg)], reply_msg))
			relayed = true
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, relayed, "peer_cache relayed UDP reply back to machine")
	testing.expect_value(t, peer.cache.to_machine, 1)
	testing.expect_value(t, peer.cache.wrong_sender, 1)
}

@(private = "file")
Tutorial_Test_Udp :: struct {
	socket:     net.UDP_Socket,
	remote:     net.Endpoint,
	start_tick: time.Tick,
}

@(private = "file")
tutorial_test_udp_send :: proc "contextless" (bytes: []u8, user_data: rawptr) -> bool {
	context = runtime.default_context()
	u := (^Tutorial_Test_Udp)(user_data)
	sent, err := net.send_udp(u.socket, bytes, u.remote)
	return err == nil && sent == len(bytes)
}

@(private = "file")
tutorial_test_udp_recv :: proc "contextless" (buffer: []u8, deadline_us: u64, user_data: rawptr) -> (length: int, ok: bool) {
	context = runtime.default_context()
	u := (^Tutorial_Test_Udp)(user_data)
	now := tutorial_test_udp_now_us(user_data)
	wait_us := deadline_us > now ? deadline_us - now : 1000
	_ = net.set_option(u.socket, .Receive_Timeout, min(max(time.Duration(wait_us) * time.Microsecond, time.Millisecond), 50 * time.Millisecond))
	n, _, err := net.recv_udp(u.socket, buffer)
	if err != nil || n <= 0 {
		return 0, false
	}
	return n, true
}

@(private = "file")
tutorial_test_udp_now_us :: proc "contextless" (user_data: rawptr) -> u64 {
	context = runtime.default_context()
	u := (^Tutorial_Test_Udp)(user_data)
	return u64(time.tick_since(u.start_tick) / time.Microsecond) + 1
}

// cache_server_seed_object + cache_server_seed_realisation refuse bad inputs
// and serve verified signed objects/realisations over QUIC to recipes_core.
@(test)
tutorial_cache_seed_serves_signed_realisation_over_quic :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	temp_base, _ := os.temp_dir(context.temp_allocator)
	if temp_base == "" {
		temp_base = "/tmp"
	}
	dir := fmt.aprintf("%s/modus_tutorial_cache_test_%d", strings.trim_right(temp_base, "/"), os.get_pid())
	_ = os.remove_all(dir)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}

	signer_seed := [32]u8{}
	quic_seed := [32]u8{}
	untrusted_seed := [32]u8{}
	for i in 0 ..< 32 {
		signer_seed[i] = 0x31 + u8(i * 7)
		quic_seed[i] = 0x51 + u8(i * 9)
		untrusted_seed[i] = 0x91 + u8(i * 5)
	}
	signer_priv: ed25519.Private_Key
	defer ed25519.private_key_clear(&signer_priv)
	testing.expect(t, ed25519.private_key_set_bytes(&signer_priv, signer_seed[:]))
	signer_pub: [32]u8
	ed25519.private_key_public_bytes(&signer_priv, signer_pub[:])

	server, opened := cache_server.cache_server_open(dir, [][32]u8{signer_pub})
	if !testing.expect(t, opened) {
		return
	}
	defer cache_server.cache_server_destroy(&server)

	// Refusal cases: empty blob, invalid kind, untrusted signer.
	_, ok := cache_server.cache_server_seed_object(&server, .Blob, nil, signer_seed)
	testing.expect(t, !ok, "empty blob seed is refused")
	_, ok = cache_server.cache_server_seed_object(&server, object_cache.Cache_Object_Kind(0), transmute([]u8)string("x"), signer_seed)
	testing.expect(t, !ok, "invalid kind seed is refused")
	_, ok = cache_server.cache_server_seed_object(&server, .Blob, transmute([]u8)string("x"), untrusted_seed)
	testing.expect(t, !ok, "untrusted signer seed is refused")

	// Seed a blob, its canonical single-entry "module" tree, and a signed Tree
	// realisation, then fetch the tree closure over live QUIC.
	blob := transmute([]u8)string("tutorial-db-browser-module-bytes-v1")
	blob_hash, obj_ok := cache_server.cache_server_seed_object(&server, .Blob, blob, signer_seed)
	testing.expect(t, obj_ok)
	testing.expect_value(t, blob_hash, blake3.hash(blob))

	tree_bytes, tree_ok := tutorial_module_output_tree(blob_hash, context.temp_allocator)
	testing.expect(t, tree_ok)
	out_hash, tree_seed_ok := cache_server.cache_server_seed_object(&server, .Tree, tree_bytes, signer_seed)
	testing.expect(t, tree_seed_ok)

	recipe_hash := blake3.hash(transmute([]u8)string("tutorial-db-browser-recipe"))
	_, real_ok := cache_server.cache_server_seed_realisation(&server, recipe_hash, out_hash, .Tree, signer_seed)
	testing.expect(t, real_ok)

	running, q_err := cache_server.cache_quic_start(&server, net.Endpoint{address = net.IP4_Loopback, port = 0}, quic_seed)
	if !testing.expect(t, q_err == "" && running != nil) {
		return
	}
	defer cache_server.cache_quic_stop(running)

	sock, s_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if !testing.expect(t, s_err == nil) {
		return
	}
	defer net.close(sock)

	udp := Tutorial_Test_Udp{socket = sock, remote = running.bound_endpoint, start_tick = time.tick_now()}
	crypto_table := cache_server.cache_quic_cryptography()
	generator: random.Generator
	seed: [random.SEED_SIZE]u8
	crypto.rand_bytes(seed[:])
	random.generator_seed(&generator, &seed, .Processor)

	client := new(recipes_core.Cache_Quic_Client)
	defer free(client)
	transport := recipes_core.Cache_Datagram_Transport{
		send      = tutorial_test_udp_send,
		recv      = tutorial_test_udp_recv,
		now_us    = tutorial_test_udp_now_us,
		user_data = &udp,
	}
	testing.expect(t, recipes_core.cache_quic_client_init(client, running.public_key, &crypto_table, &generator, transport))
	testing.expect_value(t, recipes_core.cache_quic_client_connect(client), recipes_core.Cache_Client_Error.None)
	defer recipes_core.cache_quic_client_close(client)

	get_real_req := object_cache.Cache_Request{kind = .Get_Realisation, recipe_hash = recipe_hash}
	real_resp, rec_err := recipes_core.cache_quic_client_exchange(client, &get_real_req)
	testing.expect_value(t, rec_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, real_resp.status, object_cache.Cache_Response_Status.Ok)
	testing.expect_value(t, real_resp.realisation.output_hash, out_hash)
	testing.expect_value(t, real_resp.realisation.output_kind, object_cache.Cache_Object_Kind.Tree)

	mem_store := new(pr.Memory_Private_Store)
	defer free(mem_store)
	recipes_state := new(recipes_core.Recipes_State)
	defer free(recipes_state)
	recipes_core.state_init(recipes_state, pr.memory_private_store_port(mem_store))

	fetched_size, fetch_ref := recipes_core.cache_quic_fetch_closure_to_store(client, recipes_state, out_hash, .Tree)
	testing.expect_value(t, fetch_ref, pr.Recipe_Refusal.None)
	testing.expect_value(t, fetched_size, u64(len(tree_bytes)))
	blob_name := pr.blob_object_name(blob_hash)
	blob_size, blob_sz_st := pr.private_store_size(&recipes_state.store, pr.private_object_name_text(&blob_name))
	testing.expect_value(t, blob_sz_st, pr.Private_Store_Status.Ok)
	testing.expect_value(t, blob_size, u64(len(blob)))
}

// When SQLITE_SOURCE is provided by the development shell, tutorial_build_sqlite_module
// compiles a valid freestanding sqlite.module and tutorial_build_initial_main_db
// executes it in memory to produce a valid 4 KiB-page SQLite 3 database file.
@(test)
tutorial_sqlite_build_and_initial_main_db_seed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if os.get_env("SQLITE_SOURCE", context.temp_allocator) == "" {
		return
	}
	temp_base, _ := os.temp_dir(context.temp_allocator)
	if temp_base == "" {
		temp_base = "/tmp"
	}
	work := fmt.aprintf("%s/modus_tutorial_sqlite_test_%d", strings.trim_right(temp_base, "/"), os.get_pid())
	_ = os.remove_all(work)
	defer {
		_ = os.remove_all(work)
		delete(work)
	}
	testing.expect(t, os.make_directory_all(work) == nil)

	sqlite_bytes, built := tutorial_build_sqlite_module(work)
	if !testing.expect(t, built, "tutorial_build_sqlite_module produces a valid sqlite.module") {
		return
	}
	defer delete(sqlite_bytes)
	testing.expect_value(t, module.validate(sqlite_bytes), module.Error.None)

	// Invalid module bytes are refused cleanly by tutorial_build_initial_main_db.
	_, bad_db := tutorial_build_initial_main_db(transmute([]u8)string("not-a-module"))
	testing.expect(t, !bad_db, "corrupt module bytes are refused")

	main_db, seeded := tutorial_build_initial_main_db(sqlite_bytes)
	if !testing.expect(t, seeded, "tutorial_build_initial_main_db seeds main.db via sqlite.module") {
		return
	}
	defer delete(main_db)
	testing.expect(t, len(main_db) >= 8192 && len(main_db) % 4096 == 0, "seeded main.db is aligned to 4 KiB pages")
	testing.expect_value(t, string(main_db[:16]), "SQLite format 3\x00")
}

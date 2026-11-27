#+build !freestanding
package disk_processes_core

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/object_cache"
import rd "modus:contract/root_delegation"
import "modus:cryptography_primitives"
import "modus:quic"
import "modus:random"

@(private = "file")
cache_test_key :: proc(tag: u8) -> (key: [32]u8) {
	for i in 0 ..< 32 {
		key[i] = tag + u8(i * 7 + 1)
	}
	return key
}

@(private = "file")
cache_load_request :: proc(hash: blake3.Hash, key: [32]u8) -> (req: rd.Load_Request) {
	req.kind = u8(rd.Load_Kind.Script_Fonts_Cache)
	req.principal = 0
	req.module_hash = hash
	req.nickname_length = u8(copy(req.nickname[:], "script_fonts"))
	req.cache_server_key = key
	return req
}

@(private = "file")
store_load_request :: proc(hash: blake3.Hash, size: u64) -> (req: rd.Load_Request) {
	req.kind = u8(rd.Load_Kind.Script_Fonts_Store)
	req.principal = 0
	req.module_hash = hash
	req.nickname_length = u8(copy(req.nickname[:], "script_fonts"))
	req.storage_module_length = u8(copy(req.storage_module[:], "storage"))
	req.store_byte_count = size
	return req
}

// Builds a synthetic Bao outboard for a multi-frame blob and produces the proof
// for a single frame_index.
@(private = "file")
build_blob_frame_proof :: proc(blob: []u8, frame_index: u64) -> (root: blake3.Hash, proof: []u8, frame: []u8) {
	size := u64(len(blob))
	frame_count, _ := object_cache.object_frame_count(size)
	outboard_bytes, _ := object_cache.object_outboard_bytes(size)
	outboard := make([]u8, outboard_bytes, context.temp_allocator)

	builder, _ := object_cache.frame_tree_builder_start(size)
	parents: [object_cache.MAX_PROOF_DEPTH]object_cache.Frame_Parent
	for idx in u64(0) ..< frame_count {
		start := idx * object_cache.FRAME_PAYLOAD_BYTES
		length, _ := object_cache.object_frame_length(size, idx)
		pcount, _ := object_cache.frame_tree_builder_add(&builder, blob[start:][:length], &parents)
		for p in 0 ..< pcount {
			entry := object_cache.frame_parent_entry(parents[p])
			off := parents[p].index * object_cache.OUTBOARD_ENTRY_SIZE
			copy(outboard[off:][:object_cache.OUTBOARD_ENTRY_SIZE], entry[:])
		}
	}
	root = builder.root

	path, _ := object_cache.object_frame_path(frame_count, frame_index)
	proof = make([]u8, path.depth * object_cache.PROOF_ENTRY_SIZE, context.temp_allocator)
	for level in 0 ..< path.depth {
		off := path.parent_index[level] * object_cache.OUTBOARD_ENTRY_SIZE
		var_entry: [object_cache.OUTBOARD_ENTRY_SIZE]u8
		copy(var_entry[:], outboard[off:][:object_cache.OUTBOARD_ENTRY_SIZE])
		sibling := object_cache.frame_proof_entry(var_entry, path.in_left[level])
		copy(proof[level * object_cache.PROOF_ENTRY_SIZE:][:object_cache.PROOF_ENTRY_SIZE], sibling[:])
	}

	fstart := frame_index * object_cache.FRAME_PAYLOAD_BYTES
	flen, _ := object_cache.object_frame_length(size, frame_index)
	frame = blob[fstart:][:flen]
	return root, proof, frame
}

// Adversarial cache-fetch state machine tests: refuses empty, oversized
// (> SCRIPT_FONTS_BYTES_LIMIT), wrong Bao proof / tampered byte, missing/unconfigured
// cache, bad server key, network failure, Not_Found, malformed response,
// size change mid-transfer, wrong offset, and Continue after Module_Filled.
@(test)
script_fonts_cache_fetch_refuses_hostile_answers :: proc(t: ^testing.T) {
	blob := make([]u8, 4096, context.temp_allocator)
	for i in 0 ..< len(blob) {
		blob[i] = u8((i * 31 + 17) & 0xFF)
	}
	hash := blake3.hash(blob)
	key := cache_test_key(0x21)
	req := cache_load_request(hash, key)

	run_frame0_refusal :: proc(t: ^testing.T, req: ^rd.Load_Request, answer: Cache_Frame_Answer, expected: rd.Disk_Load_Refusal) {
		m: Machine
		machine_init(&m, {})
		a0 := load_begin(&m, req)
		testing.expect_value(t, a0.kind, Action_Kind.Ask_Cache_Frame)
		testing.expect_value(t, a0.offset, u64(0))
		ans := answer
		a1 := cache_frame_answered(&m, &ans)
		testing.expect_value(t, a1.kind, Action_Kind.Send_Event)
		testing.expect_value(t, a1.event, rd.Disk_Load_Event.Refused)
		testing.expect_value(t, m.report.refusal, u32(expected))
		testing.expect(t, rd.event_report_check(.Script_Fonts_Cache, .Module_Asked, a1.event, &m.report, 0, 0))
	}

	// Empty object refused.
	run_frame0_refusal(t, &req, {kind = .Ok, object_kind = .Blob, object_size = 0, offset = 0}, .Object_Empty)
	// Oversized object (SCRIPT_FONTS_BYTES_LIMIT + 1) refused before any memory loan.
	run_frame0_refusal(t, &req, {kind = .Ok, object_kind = .Blob, object_size = rd.load_bytes_limit(.Script_Fonts_Cache) + 1, offset = 0}, .Object_Too_Large)
	// Wrong object kind (.Tree) refused.
	run_frame0_refusal(t, &req, {kind = .Ok, object_kind = .Tree, object_size = u64(len(blob)), offset = 0, payload = blob}, .Cache_Bad_Response)
	// Non-zero offset on frame 0 refused.
	run_frame0_refusal(t, &req, {kind = .Ok, object_kind = .Blob, object_size = u64(len(blob)), offset = object_cache.FRAME_PAYLOAD_BYTES, payload = blob}, .Cache_Bad_Response)
	// Tampered byte -> Bao hash mismatch refused before any memory loan.
	tampered := make([]u8, len(blob), context.temp_allocator)
	copy(tampered, blob)
	tampered[100] ~= 0x01
	run_frame0_refusal(t, &req, {kind = .Ok, object_kind = .Blob, object_size = u64(len(tampered)), offset = 0, payload = tampered}, .Cache_Hash_Mismatch)
	// Transport/cache errors mapped cleanly and pass core border check.
	run_frame0_refusal(t, &req, {kind = .Not_Configured}, .Cache_Not_Configured)
	run_frame0_refusal(t, &req, {kind = .Bad_Server_Key}, .Cache_Bad_Server_Key)
	run_frame0_refusal(t, &req, {kind = .Network_Failed}, .Cache_Network_Failed)
	run_frame0_refusal(t, &req, {kind = .Not_Found}, .Cache_Not_Found)
	run_frame0_refusal(t, &req, {kind = .Bad_Response}, .Cache_Bad_Response)
}

// Multi-frame (> 1 MiB) Script_Fonts_Cache fetch verifies every Bao frame proof,
// refuses a tampered or wrong-size second frame, and completes cleanly on valid frames.
@(test)
script_fonts_cache_fetch_multi_frame_and_tamper :: proc(t: ^testing.T) {
	total := int(object_cache.FRAME_PAYLOAD_BYTES) + 8192
	blob := make([]u8, total, context.temp_allocator)
	for i in 0 ..< total {
		blob[i] = u8((i * 13 + 7) & 0xFF)
	}
	root0, proof0, frame0 := build_blob_frame_proof(blob, 0)
	_, proof1, frame1 := build_blob_frame_proof(blob, 1)
	testing.expect_value(t, root0, blake3.hash(blob))

	key := cache_test_key(0x55)
	req := cache_load_request(root0, key)

	// 1. Tampered frame 1 is refused with Cache_Hash_Mismatch after memory is lent.
	{
		m: Machine
		machine_init(&m, {})
		_ = load_begin(&m, &req)
		a0 := Cache_Frame_Answer{kind = .Ok, object_kind = .Blob, object_size = u64(total), offset = 0, proof = proof0, payload = frame0}
		ev0 := cache_frame_answered(&m, &a0)
		testing.expect_value(t, ev0.event, rd.Disk_Load_Event.Memory_Wanted)
		testing.expect(t, rd.event_report_check(.Script_Fonts_Cache, .Module_Asked, ev0.event, &m.report, 0, 0))

		lent := make([]u8, total, context.temp_allocator)
		a_next := cache_memory_lent(&m, lent, frame0)
		testing.expect_value(t, a_next.kind, Action_Kind.Ask_Cache_Frame)
		testing.expect_value(t, a_next.offset, u64(object_cache.FRAME_PAYLOAD_BYTES))

		bad_frame1 := make([]u8, len(frame1), context.temp_allocator)
		copy(bad_frame1, frame1)
		bad_frame1[7] ~= 0x80
		a1 := Cache_Frame_Answer{kind = .Ok, object_kind = .Blob, object_size = u64(total), offset = object_cache.FRAME_PAYLOAD_BYTES, proof = proof1, payload = bad_frame1}
		ev1 := cache_frame_answered(&m, &a1)
		testing.expect_value(t, ev1.event, rd.Disk_Load_Event.Refused)
		testing.expect_value(t, m.report.refusal, u32(rd.Disk_Load_Refusal.Cache_Hash_Mismatch))
		testing.expect(t, ev1.release_lent)
		testing.expect(t, rd.event_report_check(.Script_Fonts_Cache, .Module_Lent, ev1.event, &m.report, 0, 0))
	}

	// 2. Size changing on frame 1 is refused with Cache_Bad_Response.
	{
		m: Machine
		machine_init(&m, {})
		_ = load_begin(&m, &req)
		a0 := Cache_Frame_Answer{kind = .Ok, object_kind = .Blob, object_size = u64(total), offset = 0, proof = proof0, payload = frame0}
		_ = cache_frame_answered(&m, &a0)
		lent := make([]u8, total, context.temp_allocator)
		_ = cache_memory_lent(&m, lent, frame0)

		a1 := Cache_Frame_Answer{kind = .Ok, object_kind = .Blob, object_size = u64(total) + 1, offset = object_cache.FRAME_PAYLOAD_BYTES, proof = proof1, payload = frame1}
		ev1 := cache_frame_answered(&m, &a1)
		testing.expect_value(t, ev1.event, rd.Disk_Load_Event.Refused)
		testing.expect_value(t, m.report.refusal, u32(rd.Disk_Load_Refusal.Cache_Bad_Response))
	}

	// 3. Valid 2-frame transfer fills lent memory identically to blob and emits Module_Filled.
	{
		m: Machine
		machine_init(&m, {})
		_ = load_begin(&m, &req)
		a0 := Cache_Frame_Answer{kind = .Ok, object_kind = .Blob, object_size = u64(total), offset = 0, proof = proof0, payload = frame0}
		ev0 := cache_frame_answered(&m, &a0)
		testing.expect_value(t, ev0.event, rd.Disk_Load_Event.Memory_Wanted)
		testing.expect_value(t, m.report.byte_count, u64(total))

		lent := make([]u8, total, context.temp_allocator)
		a_next := cache_memory_lent(&m, lent, frame0)
		testing.expect_value(t, a_next.kind, Action_Kind.Ask_Cache_Frame)
		testing.expect_value(t, a_next.offset, u64(object_cache.FRAME_PAYLOAD_BYTES))

		a1 := Cache_Frame_Answer{kind = .Ok, object_kind = .Blob, object_size = u64(total), offset = object_cache.FRAME_PAYLOAD_BYTES, proof = proof1, payload = frame1}
		ev1 := cache_frame_answered(&m, &a1)
		testing.expect_value(t, ev1.kind, Action_Kind.Send_Event)
		testing.expect_value(t, ev1.event, rd.Disk_Load_Event.Module_Filled)
		testing.expect(t, ev1.release_lent)
		testing.expect(t, rd.event_report_check(.Script_Fonts_Cache, .Module_Lent, ev1.event, &m.report, 0, 0))
		testing.expect_value(t, blake3.hash(lent), root0)

		// Continue after Module_Filled on Script_Fonts_Cache is refused.
		cont := continue_given(&m)
		testing.expect_value(t, cont.event, rd.Disk_Load_Event.Command_Refused)
	}
}

// Script_Fonts_Store writes verified bytes in STORE_WRITE_CHUNK_BYTES pieces
// with set_size -> write_range... -> commit -> Ready, and refuses any storage error.
@(test)
script_fonts_store_persists_in_chunks_and_refuses_errors :: proc(t: ^testing.T) {
	size := STORE_WRITE_CHUNK_BYTES * 2 + 123
	src := make([]u8, size, context.temp_allocator)
	for i in 0 ..< size {
		src[i] = u8((i * 19 + 3) & 0xFF)
	}
	req := store_load_request(blake3.hash(src), u64(size))

	// 1. Storage failure during write_range refuses with Store_Write_Failed.
	{
		m: Machine
		machine_init(&m, {})
		a0 := load_begin(&m, &req)
		testing.expect_value(t, a0.kind, Action_Kind.Wait_Command)
		a1 := store_memory_given(&m, src)
		testing.expect_value(t, a1.kind, Action_Kind.Ask_Store_Set_Size)
		testing.expect_value(t, a1.size, u64(size))
		ok_ans := Storage_Answer{kind = .Value, value = 0}
		a2 := storage_answered(&m, &ok_ans)
		testing.expect_value(t, a2.kind, Action_Kind.Ask_Store_Write_Range)
		fail_ans := Storage_Answer{kind = .Failed, value = -1}
		a3 := storage_answered(&m, &fail_ans)
		testing.expect_value(t, a3.event, rd.Disk_Load_Event.Refused)
		testing.expect_value(t, m.report.refusal, u32(rd.Disk_Load_Refusal.Store_Write_Failed))
		testing.expect(t, rd.event_report_check(.Script_Fonts_Store, .Module_Lent, a3.event, &m.report, 0, 0))
	}

	// 2. Full persistence copies exact bytes across 3 write_range chunks and commits.
	{
		m: Machine
		machine_init(&m, {})
		_ = load_begin(&m, &req)
		action := store_memory_given(&m, src)
		written := make([]u8, size, context.temp_allocator)
		chunks := 0
		committed := false
		for action.kind != .Send_Event {
			#partial switch action.kind {
			case .Ask_Store_Set_Size:
				testing.expect_value(t, action.size, u64(size))
			case .Ask_Store_Write_Range:
				copy(written[action.offset:][:len(action.data)], action.data)
				chunks += 1
			case .Ask_Store_Commit:
				committed = true
			case:
				testing.fail(t)
				return
			}
			ans := Storage_Answer{kind = .Value, value = 1}
			action = storage_answered(&m, &ans)
		}
		testing.expect_value(t, chunks, 3)
		testing.expect(t, committed)
		testing.expect_value(t, action.event, rd.Disk_Load_Event.Ready)
		testing.expect(t, action.release_lent)
		testing.expect(t, rd.event_report_check(.Script_Fonts_Store, .Module_Lent, action.event, &m.report, 0, 0))
		testing.expect_value(t, blake3.hash(written), blake3.hash(src))
	}
}

@(private = "file")
test_quic_cryptography :: proc() -> quic.Cryptography {
	return {
		seal_with_aes_128_gcm                = cryptography_primitives.seal_with_aes_128_gcm,
		open_with_aes_128_gcm                = cryptography_primitives.open_with_aes_128_gcm,
		seal_with_chacha20_poly1305          = cryptography_primitives.seal_with_chacha20_poly1305,
		open_with_chacha20_poly1305          = cryptography_primitives.open_with_chacha20_poly1305,
		hkdf_sha256_extract                  = cryptography_primitives.hkdf_sha256_extract,
		hkdf_sha256_expand                   = cryptography_primitives.hkdf_sha256_expand,
		header_protection_mask_with_aes_128  = cryptography_primitives.header_protection_mask_with_aes_128,
		header_protection_mask_with_chacha20 = cryptography_primitives.header_protection_mask_with_chacha20,
		sha256                               = cryptography_primitives.sha256,
		hmac_sha256                          = cryptography_primitives.hmac_sha256,
		x25519                               = cryptography_primitives.x25519,
		ed25519_public_key                   = cryptography_primitives.ed25519_public_key,
		ed25519_sign                         = cryptography_primitives.ed25519_sign,
		ed25519_verify                       = cryptography_primitives.ed25519_verify,
	}
}

@(private = "file")
test_generator_seed :: proc(tag: u8) -> (gen: random.Generator) {
	seed: [random.SEED_SIZE]u8
	for i in 0 ..< len(seed) {
		seed[i] = tag + u8(i * 11 + 3)
	}
	random.generator_seed(&gen, &seed, .Processor)
	return gen
}

@(private = "file")
Stub_Transport :: struct {
	now:          u64,
	step_us:      u64,
	fail_send:    bool,
	send_calls:   int,
	recv_calls:   int,
	recv_len:     int,
	recv_ok:      bool,
	is_cancelled: bool,
}

@(private = "file")
stub_send :: proc "contextless" (_: []u8, ud: rawptr) -> bool {
	s := (^Stub_Transport)(ud)
	s.send_calls += 1
	return !s.fail_send
}

@(private = "file")
stub_recv :: proc "contextless" (_: []u8, _: u64, ud: rawptr) -> (int, bool) {
	s := (^Stub_Transport)(ud)
	s.recv_calls += 1
	if s.step_us > 0 {
		s.now = saturating_add_u64(s.now, s.step_us)
	}
	return s.recv_len, s.recv_ok
}

@(private = "file")
stub_now :: proc "contextless" (ud: rawptr) -> u64 {
	return (^Stub_Transport)(ud).now
}

@(private = "file")
stub_cancelled :: proc "contextless" (ud: rawptr) -> bool {
	return (^Stub_Transport)(ud).is_cancelled
}

// Adversarial transport and deadline checks on Cache_Quic_Fetcher:
// - saturating_add_u64 saturates cleanly at max(u64);
// - transport send failure aborts immediately without looping;
// - oversized received length (> len(datagram_buf)) fails cleanly without slicing;
// - close(send_close = false) sends 0 datagrams, resets connection to .Idle, and is idempotent.
@(test)
cache_quic_fetcher_refuses_send_failure_oversized_recv_and_saturates_deadlines :: proc(t: ^testing.T) {
	// 1. Saturating microsecond deadline arithmetic.
	testing.expect_value(t, saturating_add_u64(100, 250), u64(350))
	testing.expect_value(t, saturating_add_u64(max(u64) - 5, 10), max(u64))
	testing.expect_value(t, saturating_add_u64(max(u64), max(u64)), max(u64))
	testing.expect_value(t, saturating_add_u64(max(u64), 0), max(u64))

	crypto := test_quic_cryptography()
	gen := test_generator_seed(0x41)
	fetcher := new(Cache_Quic_Fetcher)
	defer free(fetcher)

	// 2. Send failure aborts connect immediately on first send without spinning.
	stub := Stub_Transport{now = 1_000, fail_send = true}
	transport := Cache_Quic_Transport{
		send      = stub_send,
		recv      = stub_recv,
		now_us    = stub_now,
		cancelled = stub_cancelled,
		user_data = &stub,
	}
	testing.expect(t, cache_quic_fetcher_init(fetcher, cache_test_key(0x11), &crypto, &gen, transport, 5_000_000))
	ans := cache_quic_fetcher_get_frame(fetcher, cache_test_key(0x22), 0)
	testing.expect_value(t, ans.kind, Cache_Answer_Kind.Network_Failed)
	testing.expect_value(t, stub.send_calls, 1)
	testing.expect_value(t, stub.recv_calls, 0)
	testing.expect(t, !fetcher.connected)
	testing.expect_value(t, fetcher.connection.state, quic.Connection_State.Idle)

	// 3. Oversized received length (> len(datagram_buf)) fails immediately without OOB slice.
	stub = Stub_Transport{now = 1_000, fail_send = false, recv_ok = true, recv_len = len(fetcher.datagram_buf) + 1}
	testing.expect(t, cache_quic_fetcher_init(fetcher, cache_test_key(0x11), &crypto, &gen, transport, 5_000_000))
	ans = cache_quic_fetcher_get_frame(fetcher, cache_test_key(0x22), 0)
	testing.expect_value(t, ans.kind, Cache_Answer_Kind.Network_Failed)
	testing.expect_value(t, stub.recv_calls, 1)
	testing.expect(t, !fetcher.connected)
	testing.expect_value(t, fetcher.connection.state, quic.Connection_State.Idle)

	// 4. Clock near max(u64) saturates deadline and exits cleanly when clock reaches max(u64).
	stub = Stub_Transport{now = max(u64) - 10, step_us = 20, fail_send = false, recv_ok = false}
	testing.expect(t, cache_quic_fetcher_init(fetcher, cache_test_key(0x11), &crypto, &gen, transport, 5_000_000))
	ans = cache_quic_fetcher_get_frame(fetcher, cache_test_key(0x22), 0)
	testing.expect_value(t, ans.kind, Cache_Answer_Kind.Network_Failed)
	testing.expect(t, stub.recv_calls == 1)
	testing.expect(t, !fetcher.connected)

	// 5. Non-blocking close (send_close = false) sends 0 datagrams, resets connection, and is idempotent.
	stub = Stub_Transport{now = 2_000, fail_send = false}
	testing.expect(t, cache_quic_fetcher_init(fetcher, cache_test_key(0x11), &crypto, &gen, transport, 5_000_000))
	fetcher.connection.state = .Closing
	fetcher.connected = true
	cache_quic_fetcher_close(fetcher, false)
	testing.expect_value(t, stub.send_calls, 0)
	testing.expect(t, !fetcher.connected)
	testing.expect(t, !fetcher.configured)
	testing.expect_value(t, fetcher.connection.state, quic.Connection_State.Idle)
	cache_quic_fetcher_close(fetcher, false)
	testing.expect_value(t, stub.send_calls, 0)
}

@(private = "file")
Loopback_Reply_Kind :: enum u8 {
	Malformed_Bytes,
	Busy_Oversized_Frames,
	Busy_Progress_Then_Ok,
	Busy_Forever,
	Ok_Blob,
}

@(private = "file")
Quic_Loopback_Server :: struct {
	crypto:        quic.Cryptography,
	gen:           random.Generator,
	secret_key:    [quic.ED25519_KEY_SIZE]u8,
	public_key:    [quic.ED25519_KEY_SIZE]u8,
	conn:          quic.Connection,
	streams:       [1]quic.Stream,
	started:       bool,
	now:           u64,
	tick_us:       u64,
	mode:          Loopback_Reply_Kind,
	exchange_seq:  int,
	ok_payload:    []u8,
	req_buf:               [256]u8,
	req_len:               int,
	req_stream_id:         u64,
	last_served_stream_id: u64,
	has_req_stream:        bool,
	resp_buf:      [4096]u8,
	resp_len:      int,
	resp_sent:     int,
	resp_ready:    bool,
	out_queue:     [32][quic.DATAGRAM_LIMIT]u8,
	out_lens:      [32]int,
	out_head:      int,
	out_tail:      int,
	out_count:     int,
}

@(private = "file")
loopback_server_reset :: proc(srv: ^Quic_Loopback_Server) {
	srv.conn = {}
	srv.streams = {}
	srv.started = false
	srv.req_len = 0
	srv.req_stream_id = 0
	srv.last_served_stream_id = max(u64)
	srv.has_req_stream = false
	srv.resp_len = 0
	srv.resp_sent = 0
	srv.resp_ready = false
	srv.out_head = 0
	srv.out_tail = 0
	srv.out_count = 0
}

@(private = "file")
loopback_server_start :: proc(srv: ^Quic_Loopback_Server) {
	loopback_server_reset(srv)
	cfg := quic.Connection_Configuration {
		idle_timeout_milliseconds = CACHE_FETCHER_IDLE_TIMEOUT_MS,
		tls = {
			role                = .Server,
			least_seed_strength = .Processor,
			server_private_key  = srv.secret_key,
		},
	}
	cfg.tls.application_protocol_length = copy(cfg.tls.application_protocol[:], object_cache.APPLICATION_PROTOCOL)
	err: errors.Error_Record
	srv.started = quic.connection_start_server(&srv.conn, srv.streams[:], &cfg, &srv.crypto, &srv.gen, srv.now, &err)
}

@(private = "file")
loopback_server_pump_out :: proc "contextless" (srv: ^Quic_Loopback_Server) {
	for srv.out_count < len(srv.out_queue) {
		n := quic.connection_datagram_send(&srv.conn, srv.out_queue[srv.out_tail][:quic.MAX_DATAGRAM_SIZE], srv.now)
		if n == 0 {
			break
		}
		srv.out_lens[srv.out_tail] = n
		srv.out_tail = (srv.out_tail + 1) % len(srv.out_queue)
		srv.out_count += 1
	}
}

@(private = "file")
loopback_build_reply :: proc "contextless" (srv: ^Quic_Loopback_Server) {
	srv.exchange_seq += 1
	srv.resp_sent = 0
	switch srv.mode {
	case .Malformed_Bytes:
		// Bad magic header triggers inspect_response_header refusal -> .Bad_Response.
		bad := [8]u8{'X', 'X', 'X', 'X', 0, 0, 0, 0}
		srv.resp_len = copy(srv.resp_buf[:], bad[:])
	case .Busy_Oversized_Frames:
		resp := object_cache.Cache_Response {
			request_kind = .Get_Object,
			status       = .Busy,
			frames_built = 1,
			frame_count  = CACHE_FETCHER_MAX_SCRIPT_FONTS_FRAMES + 1,
		}
		srv.resp_len, _ = object_cache.encode_response(&resp, srv.resp_buf[:])
	case .Busy_Forever:
		resp := object_cache.Cache_Response {
			request_kind = .Get_Object,
			status       = .Busy,
			frames_built = u64(srv.exchange_seq),
			frame_count  = 64,
		}
		srv.resp_len, _ = object_cache.encode_response(&resp, srv.resp_buf[:])
	case .Busy_Progress_Then_Ok:
		if srv.exchange_seq <= 2 {
			resp := object_cache.Cache_Response {
				request_kind = .Get_Object,
				status       = .Busy,
				frames_built = u64(srv.exchange_seq),
				frame_count  = 4,
			}
			srv.resp_len, _ = object_cache.encode_response(&resp, srv.resp_buf[:])
		} else {
			resp := object_cache.Cache_Response {
				request_kind = .Get_Object,
				status       = .Ok,
				object_kind  = .Blob,
				object_size  = u64(len(srv.ok_payload)),
				offset       = 0,
				payload      = srv.ok_payload,
			}
			srv.resp_len, _ = object_cache.encode_response(&resp, srv.resp_buf[:])
		}
	case .Ok_Blob:
		resp := object_cache.Cache_Response {
			request_kind = .Get_Object,
			status       = .Ok,
			object_kind  = .Blob,
			object_size  = u64(len(srv.ok_payload)),
			offset       = 0,
			payload      = srv.ok_payload,
		}
		srv.resp_len, _ = object_cache.encode_response(&resp, srv.resp_buf[:])
	}
	srv.resp_ready = true
}

@(private = "file")
loopback_send :: proc "contextless" (bytes: []u8, ud: rawptr) -> bool {
	srv := (^Quic_Loopback_Server)(ud)
	srv.now = saturating_add_u64(srv.now, srv.tick_us)
	if !srv.started {
		return false
	}
	err: errors.Error_Record
	quic.connection_datagram_receive(&srv.conn, bytes, srv.now, &err)
	if srv.conn.state == .Connected {
		if !srv.has_req_stream {
			if srv.streams[0].in_use && srv.streams[0].identifier != srv.last_served_stream_id {
				srv.req_stream_id = srv.streams[0].identifier
				srv.has_req_stream = true
				srv.req_len = 0
				srv.resp_ready = false
			}
		}
		if srv.has_req_stream && !srv.resp_ready {
			n, fin, _ := quic.stream_read(&srv.conn, srv.req_stream_id, srv.req_buf[srv.req_len:])
			srv.req_len += n
			if fin {
				loopback_build_reply(srv)
			}
		}
		if srv.has_req_stream && srv.resp_ready {
			if srv.resp_sent < srv.resp_len {
				w := quic.stream_write(&srv.conn, srv.req_stream_id, srv.resp_buf[srv.resp_sent:srv.resp_len], true)
				srv.resp_sent += w
			}
			if srv.resp_sent == srv.resp_len {
				srv.last_served_stream_id = srv.req_stream_id
				srv.has_req_stream = false
				srv.resp_ready = false
			}
		}
	}
	quic.connection_time_passes(&srv.conn, srv.now)
	loopback_server_pump_out(srv)
	return true
}

@(private = "file")
loopback_recv :: proc "contextless" (buffer: []u8, _: u64, ud: rawptr) -> (int, bool) {
	srv := (^Quic_Loopback_Server)(ud)
	srv.now = saturating_add_u64(srv.now, srv.tick_us)
	if srv.out_count == 0 && srv.started {
		quic.connection_time_passes(&srv.conn, srv.now)
		loopback_server_pump_out(srv)
	}
	if srv.out_count == 0 {
		return 0, false
	}
	n := srv.out_lens[srv.out_head]
	copied := copy(buffer, srv.out_queue[srv.out_head][:n])
	srv.out_head = (srv.out_head + 1) % len(srv.out_queue)
	srv.out_count -= 1
	return copied, true
}

@(private = "file")
loopback_now :: proc "contextless" (ud: rawptr) -> u64 {
	return (^Quic_Loopback_Server)(ud).now
}

// In-memory QUIC loopback tests verifying:
// 1. .Bad_Response resets connection/stream slot so a subsequent fetch reconnects cleanly;
// 2. .Busy with frame_count > CACHE_FETCHER_MAX_SCRIPT_FONTS_FRAMES is refused on exchange 1;
// 3. .Busy retries are bounded by the single per-frame deadline;
// 4. Valid monotonic .Busy progress followed by .Ok succeeds on one connection.
@(test)
cache_quic_fetcher_bad_response_resets_connection_and_bounds_busy :: proc(t: ^testing.T) {
	srv := new(Quic_Loopback_Server)
	defer free(srv)
	srv.crypto = test_quic_cryptography()
	srv.gen = test_generator_seed(0x63)
	srv.secret_key = cache_test_key(0x77)
	secret_str := string(srv.secret_key[:])
	pub_slice := srv.public_key[:]
	key_err: errors.Error_Record
	key_outcome, _ := srv.crypto.ed25519_public_key(&secret_str, &pub_slice, &key_err)
	testing.expect_value(t, key_outcome, call_outcome.Call_Outcome.Succeeded)

	payload := [?]u8{'O', 'U', 'T', 'L', 'I', 'N', 'E', 'S', 1, 2, 3, 4}
	srv.ok_payload = payload[:]
	payload_hash := blake3.hash(payload[:])

	fetcher := new(Cache_Quic_Fetcher)
	defer free(fetcher)
	client_gen := test_generator_seed(0x91)
	transport := Cache_Quic_Transport {
		send      = loopback_send,
		recv      = loopback_recv,
		now_us    = loopback_now,
		user_data = srv,
	}

	// 1. Malformed response resets connection + stream slot; next fetch reconnects cleanly.
	srv.now = 1_000
	srv.tick_us = 1_000
	srv.mode = .Malformed_Bytes
	srv.exchange_seq = 0
	loopback_server_start(srv)
	testing.expect(t, cache_quic_fetcher_init(fetcher, srv.public_key, &srv.crypto, &client_gen, transport, 5_000_000))
	bad_ans := cache_quic_fetcher_get_frame(fetcher, payload_hash, 0)
	testing.expect_value(t, bad_ans.kind, Cache_Answer_Kind.Bad_Response)
	testing.expect(t, !fetcher.connected)
	testing.expect_value(t, fetcher.connection.state, quic.Connection_State.Idle)
	testing.expect(t, !fetcher.streams[0].in_use)

	// Reconnect on the same fetcher after .Bad_Response and succeed.
	srv.mode = .Ok_Blob
	srv.exchange_seq = 0
	loopback_server_start(srv)
	ok_ans := cache_quic_fetcher_get_frame(fetcher, payload_hash, 0)
	testing.expect_value(t, ok_ans.kind, Cache_Answer_Kind.Ok)
	testing.expect_value(t, len(ok_ans.payload), len(payload))

	// 2. Oversized frame_count (> 64) on .Busy is refused immediately on exchange 1.
	srv.mode = .Busy_Oversized_Frames
	srv.exchange_seq = 0
	loopback_server_start(srv)
	testing.expect(t, cache_quic_fetcher_init(fetcher, srv.public_key, &srv.crypto, &client_gen, transport, 5_000_000))
	busy_big := cache_quic_fetcher_get_frame(fetcher, payload_hash, 0)
	testing.expect_value(t, busy_big.kind, Cache_Answer_Kind.Bad_Response)
	testing.expect_value(t, srv.exchange_seq, 1)
	testing.expect(t, !fetcher.connected)

	// 3. Endless monotonic .Busy hits the overall per-frame deadline (not 64 x timeout).
	srv.mode = .Busy_Forever
	srv.tick_us = 50_000
	srv.exchange_seq = 0
	loopback_server_start(srv)
	testing.expect(t, cache_quic_fetcher_init(fetcher, srv.public_key, &srv.crypto, &client_gen, transport, 500_000))
	busy_timeout := cache_quic_fetcher_get_frame(fetcher, payload_hash, 0)
	testing.expect_value(t, busy_timeout.kind, Cache_Answer_Kind.Network_Failed)
	testing.expect(t, srv.exchange_seq < CACHE_FETCHER_BUSY_LIMIT)
	testing.expect(t, !fetcher.connected)

	// 4. Valid monotonic .Busy progress followed by .Ok succeeds cleanly.
	srv.mode = .Busy_Progress_Then_Ok
	srv.tick_us = 1_000
	srv.exchange_seq = 0
	loopback_server_start(srv)
	testing.expect(t, cache_quic_fetcher_init(fetcher, srv.public_key, &srv.crypto, &client_gen, transport, 5_000_000))
	busy_ok := cache_quic_fetcher_get_frame(fetcher, payload_hash, 0)
	testing.expect_value(t, busy_ok.kind, Cache_Answer_Kind.Ok)
	testing.expect_value(t, srv.exchange_seq, 3)
	testing.expect_value(t, len(busy_ok.payload), len(payload))
}

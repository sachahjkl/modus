package cache_server

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/object_cache"

// A loopback server whose worker thread tracks every heap allocation so tests
// can verify server memory stays bounded for objects of any size.
@(private = "file")
Tracked_Loopback_Server :: struct {
	server:     Cache_Server,
	listener:   net.TCP_Socket,
	endpoint:   string,
	worker:     ^thread.Thread,
	peak_bytes: i64,
}

@(private = "file")
tracked_server_start :: proc(t: ^testing.T, directory: string, authorized: [][object_cache.PUBLIC_KEY_SIZE]u8) -> ^Tracked_Loopback_Server {
	running := new(Tracked_Loopback_Server)
	open_ok: bool
	running.server, open_ok = cache_server_open(directory, authorized)
	testing.expect(t, open_ok)
	listen_err: net.Network_Error
	running.listener, listen_err = net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect_value(t, listen_err, nil)
	bound, _ := net.bound_endpoint(running.listener)
	running.endpoint = strings.clone(net.endpoint_to_string(bound, context.temp_allocator))
	running.worker = thread.create_and_start_with_poly_data(running, proc(r: ^Tracked_Loopback_Server) {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		context.allocator = mem.tracking_allocator(&track)
		cache_server_serve_listener(&r.server, r.listener)
		sync.atomic_store(&r.peak_bytes, track.peak_memory_allocated)
	})
	return running
}

@(private = "file")
tracked_server_stop :: proc(running: ^Tracked_Loopback_Server) -> i64 {
	sync.atomic_store(&running.server.stop, true)
	_ = net.shutdown(running.listener, .Both)
	net.close(running.listener)
	thread.join(running.worker)
	thread.destroy(running.worker)
	peak := sync.atomic_load(&running.peak_bytes)
	cache_server_destroy(&running.server)
	delete(running.endpoint)
	free(running)
	return peak
}

// write_pattern_file creates a deterministic file of size bytes in 1 MiB
// chunks and returns its exact BLAKE3 hash without holding the file in RAM.
@(private = "file")
write_pattern_file :: proc(t: ^testing.T, path: string, size: u64, seed: u8) -> blake3.Hash {
	file, err := os.create(path)
	testing.expect_value(t, err, nil)
	defer os.close(file)

	builder, b_ok := object_cache.frame_tree_builder_start(size)
	testing.expect(t, b_ok)

	buf := make([]u8, object_cache.FRAME_PAYLOAD_BYTES)
	defer delete(buf)

	for frame_index in u64(0) ..< builder.frame_count {
		frame_len, len_ok := object_cache.object_frame_length(size, frame_index)
		testing.expect(t, len_ok)
		slice := buf[:int(frame_len)]
		// Fill with a fast deterministic pattern that varies across frames and bytes.
		frame_tag := u8((frame_index * 29 + u64(seed)) & 0xFF)
		for i in 0 ..< len(slice) {
			slice[i] = frame_tag ~ u8((i * 13 + i >> 8) & 0xFF)
		}
		if len(slice) > 0 {
			testing.expect(t, file_write_all(file, slice))
		}
		parents: [object_cache.MAX_PROOF_DEPTH]object_cache.Frame_Parent
		_, add_ok := object_cache.frame_tree_builder_add(&builder, slice, &parents)
		testing.expect(t, add_ok)
	}
	testing.expect(t, builder.finished)
	return builder.root
}

// hash_file_streaming computes the exact BLAKE3 hash of path in 1 MiB chunks.
@(private = "file")
hash_file_streaming :: proc(t: ^testing.T, path: string) -> (hash: blake3.Hash, size: u64) {
	file, err := os.open(path)
	testing.expect_value(t, err, nil)
	defer os.close(file)
	raw_size, sz_err := os.file_size(file)
	testing.expect_value(t, sz_err, nil)
	size = u64(raw_size)

	builder, b_ok := object_cache.frame_tree_builder_start(size)
	testing.expect(t, b_ok)
	buf := make([]u8, object_cache.FRAME_PAYLOAD_BYTES)
	defer delete(buf)

	for frame_index in u64(0) ..< builder.frame_count {
		frame_len, _ := object_cache.object_frame_length(size, frame_index)
		slice := buf[:int(frame_len)]
		if frame_len > 0 {
			testing.expect(t, file_read_exact_at(file, slice, i64(frame_index * object_cache.FRAME_PAYLOAD_BYTES)))
		}
		parents: [object_cache.MAX_PROOF_DEPTH]object_cache.Frame_Parent
		_, add_ok := object_cache.frame_tree_builder_add(&builder, slice, &parents)
		testing.expect(t, add_ok)
	}
	testing.expect(t, builder.finished)
	return builder.root, size
}

// A multi-response fake server that replies with answers[i] to request i.
@(private = "file")
Scripted_Server :: struct {
	listener: net.TCP_Socket,
	endpoint: string,
	answers:  [][]u8,
	worker:   ^thread.Thread,
}

@(private = "file")
scripted_server_start :: proc(t: ^testing.T, answers: [][]u8) -> ^Scripted_Server {
	s := new(Scripted_Server)
	s.answers = answers
	err: net.Network_Error
	s.listener, err = net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect_value(t, err, nil)
	bound, _ := net.bound_endpoint(s.listener)
	s.endpoint = strings.clone(net.endpoint_to_string(bound, context.temp_allocator))
	s.worker = thread.create_and_start_with_poly_data(s, proc(s: ^Scripted_Server) {
		client, _, accept_err := net.accept_tcp(s.listener)
		if accept_err != nil {
			return
		}
		defer net.close(client)
		for answer in s.answers {
			header: [object_cache.FRAME_HEADER_SIZE]u8
			if ok, _ := tcp_read_exact(client, header[:], false); !ok {
				return
			}
			body_len := int(byte_order.read_u32_little_endian(header[:], 8))
			if body_len > 0 {
				body := make([]u8, body_len)
				ok, _ := tcp_read_exact(client, body, false)
				delete(body)
				if !ok {
					return
				}
			}
			if !tcp_write_all(client, answer) {
				return
			}
		}
		_ = net.shutdown(client, .Send)
		drain: [256]u8
		for {
			n, rerr := net.recv_tcp(client, drain[:])
			if rerr != nil || n == 0 {
				return
			}
		}
	})
	return s
}

@(private = "file")
scripted_server_stop :: proc(s: ^Scripted_Server) {
	_ = net.shutdown(s.listener, .Both)
	thread.join(s.worker)
	thread.destroy(s.worker)
	net.close(s.listener)
	delete(s.endpoint)
	free(s)
}

@(test)
large_object_refusals_ranges_alignment_lying_sender_and_halfway_stop :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	priv, pub, _ := make_test_keypair(0x81)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{pub}
	server, open_ok := cache_server_open(dir, authorized[:])
	testing.expect(t, open_ok)
	defer cache_server_destroy(&server)

	conn: Cache_Connection
	cache_connection_init(&conn)
	defer cache_connection_destroy(&conn)

	// 1. Frame past the bound (Put_Object_Frame header claiming FRAME_PAYLOAD_BYTES + 1) -> Too_Large.
	oversize_frame: [object_cache.FRAME_HEADER_SIZE]u8
	magic := object_cache.REQUEST_MAGIC
	copy(oversize_frame[0:4], magic[:])
	oversize_frame[4] = object_cache.WIRE_VERSION
	oversize_frame[5] = u8(object_cache.Cache_Request_Kind.Put_Object_Frame)
	byte_order.write_u32_little_endian(oversize_frame[:], 8, u32(object_cache.MAX_REQUEST_BODY_BYTES) + 1)
	_, over_status := cache_server_handle_connection_frame(&server, &conn, oversize_frame[:])
	testing.expect_value(t, over_status, object_cache.Cache_Response_Status.Too_Large)

	// 2. Unaligned offsets in raw Get_Object and Put_Object_Frame -> Refused.
	sample_h := blake3.hash(transmute([]u8)string("sample"))
	for bad_off in ([]u64{1, 1024, object_cache.FRAME_PAYLOAD_BYTES - 1, object_cache.FRAME_PAYLOAD_BYTES + 1}) {
		raw_get: [object_cache.FRAME_HEADER_SIZE + object_cache.GET_OBJECT_BODY_SIZE]u8
		copy(raw_get[0:4], magic[:])
		raw_get[4] = object_cache.WIRE_VERSION
		raw_get[5] = u8(object_cache.Cache_Request_Kind.Get_Object)
		byte_order.write_u32_little_endian(raw_get[:], 8, object_cache.GET_OBJECT_BODY_SIZE)
		copy(raw_get[object_cache.FRAME_HEADER_SIZE:object_cache.FRAME_HEADER_SIZE + 32], sample_h[:])
		raw_get[object_cache.FRAME_HEADER_SIZE + 32] = u8(object_cache.Cache_Object_Kind.Blob)
		byte_order.write_u64_little_endian(raw_get[:], object_cache.FRAME_HEADER_SIZE + 36, bad_off)
		_, st_g := cache_server_handle_connection_frame(&server, &conn, raw_get[:])
		testing.expect_value(t, st_g, object_cache.Cache_Response_Status.Refused)

		raw_pf: [object_cache.FRAME_HEADER_SIZE + object_cache.PUT_OBJECT_FRAME_HEADER_SIZE]u8
		copy(raw_pf[0:4], magic[:])
		raw_pf[4] = object_cache.WIRE_VERSION
		raw_pf[5] = u8(object_cache.Cache_Request_Kind.Put_Object_Frame)
		byte_order.write_u32_little_endian(raw_pf[:], 8, object_cache.PUT_OBJECT_FRAME_HEADER_SIZE)
		copy(raw_pf[object_cache.FRAME_HEADER_SIZE:object_cache.FRAME_HEADER_SIZE + 32], sample_h[:])
		byte_order.write_u64_little_endian(raw_pf[:], object_cache.FRAME_HEADER_SIZE + 32, bad_off)
		byte_order.write_u32_little_endian(raw_pf[:], object_cache.FRAME_HEADER_SIZE + 40, 0)
		_, st_pf := cache_server_handle_connection_frame(&server, &conn, raw_pf[:])
		testing.expect_value(t, st_pf, object_cache.Cache_Response_Status.Refused)
	}

	// 3. Multi-frame blob with a corrupted byte in frame 1 -> Bad_Hash, nothing stored, tmp/ empty.
	three_frame := make([]u8, 2 * object_cache.FRAME_PAYLOAD_BYTES + 17)
	defer delete(three_frame)
	for &b, i in three_frame {
		b = u8((i * 7 + 3) & 0xFF)
	}
	true_hash := blake3.hash(three_frame)

	corrupt_head := make_signed_put_object_request(.Blob, true_hash, u64(len(three_frame)), &priv, pub)
	three_frame[object_cache.FRAME_PAYLOAD_BYTES + 500] ~= 0x01
	testing.expect_value(t, test_put_object_on_server(&server, &corrupt_head, three_frame), object_cache.Cache_Response_Status.Bad_Hash)
	testing.expect(t, !cache_server_has(&server, true_hash))
	three_frame[object_cache.FRAME_PAYLOAD_BYTES + 500] ~= 0x01

	// 4. Sender lying about object_size (claims shorter size 2 MiB for 2 MiB + 17 hash):
	//    Sending 2 MiB fails at final root check with Bad_Hash, nothing stored.
	short_lie := make_signed_put_object_request(.Blob, true_hash, 2 * object_cache.FRAME_PAYLOAD_BYTES, &priv, pub)
	testing.expect_value(t, test_put_object_on_server(&server, &short_lie, three_frame[:2 * object_cache.FRAME_PAYLOAD_BYTES]), object_cache.Cache_Response_Status.Bad_Hash)
	testing.expect(t, !cache_server_has(&server, true_hash))

	//    Sender claims 2 MiB + 17, sends a short frame 0 (512 bytes instead of 1 MiB) -> Refused, session aborted.
	head_w, _ := object_cache.encode_request(&corrupt_head, conn.request_buffer)
	_, hs := cache_server_handle_connection_frame(&server, &conn, conn.request_buffer[:head_w])
	testing.expect_value(t, hs, object_cache.Cache_Response_Status.Ok)
	bad_len_pf := object_cache.Cache_Request {
		kind        = .Put_Object_Frame,
		object_hash = true_hash,
		offset      = 0,
		payload     = three_frame[:512],
	}
	bl_w, _ := object_cache.encode_request(&bad_len_pf, conn.request_buffer)
	_, bl_st := cache_server_handle_connection_frame(&server, &conn, conn.request_buffer[:bl_w])
	testing.expect_value(t, bl_st, object_cache.Cache_Response_Status.Refused)
	testing.expect(t, !conn.put.active)
	testing.expect(t, !cache_server_has(&server, true_hash))

	// 5. Out-of-order frame (offset = 1 MiB when server expects 0) -> Refused.
	head_w2, _ := object_cache.encode_request(&corrupt_head, conn.request_buffer)
	_, hs2 := cache_server_handle_connection_frame(&server, &conn, conn.request_buffer[:head_w2])
	testing.expect_value(t, hs2, object_cache.Cache_Response_Status.Ok)
	ooo_pf := object_cache.Cache_Request {
		kind        = .Put_Object_Frame,
		object_hash = true_hash,
		offset      = object_cache.FRAME_PAYLOAD_BYTES,
		payload     = three_frame[object_cache.FRAME_PAYLOAD_BYTES:2 * object_cache.FRAME_PAYLOAD_BYTES],
	}
	ooo_w, _ := object_cache.encode_request(&ooo_pf, conn.request_buffer)
	_, ooo_st := cache_server_handle_connection_frame(&server, &conn, conn.request_buffer[:ooo_w])
	testing.expect_value(t, ooo_st, object_cache.Cache_Response_Status.Refused)
	testing.expect(t, !conn.put.active)

	// 6. Stream stopped halfway over TCP: Put_Object + frame 0 + frame 1, then disconnect.
	//    Verify Has is false while in flight AND after disconnect, and objects/, outboards/, tmp/ are all empty.
	running := tracked_server_start(t, dir, authorized[:])
	defer {
		_ = tracked_server_stop(running)
	}
	client, c_out := cache_client_connect(running.endpoint)
	testing.expect_value(t, c_out, Cache_Client_Outcome.Done)
	send_buf := make([]u8, object_cache.FRAME_HEADER_SIZE + object_cache.MAX_REQUEST_BODY_BYTES)
	defer delete(send_buf)
	recv_buf: [64]u8

	head_resp, h_out := cache_client_exchange_into(&client, &corrupt_head, send_buf, recv_buf[:])
	testing.expect_value(t, h_out, Cache_Client_Outcome.Done)
	testing.expect_value(t, head_resp.put_state, object_cache.Put_Object_State.Accept_Frames)

	for idx in u64(0) ..< 2 {
		off := idx * object_cache.FRAME_PAYLOAD_BYTES
		pf := object_cache.Cache_Request {
			kind        = .Put_Object_Frame,
			object_hash = true_hash,
			offset      = off,
			payload     = three_frame[int(off):int(off) + object_cache.FRAME_PAYLOAD_BYTES],
		}
		_, pf_out := cache_client_exchange_into(&client, &pf, send_buf, recv_buf[:])
		testing.expect_value(t, pf_out, Cache_Client_Outcome.Done)
	}
	// While upload is halfway in flight, Has must still report 0!
	hashes := [1]blake3.Hash{true_hash}
	in_flight_has, if_out := cache_client_has(&client, hashes[:])
	testing.expect_value(t, if_out, Cache_Client_Outcome.Done)
	testing.expect_value(t, in_flight_has, u64(0))

	// Drop connection halfway without sending final frame.
	cache_client_close(&client)

	// Reconnect on a fresh client to ensure the previous connection finished cleanup.
	client2, c2_out := cache_client_connect(running.endpoint)
	testing.expect_value(t, c2_out, Cache_Client_Outcome.Done)
	defer cache_client_close(&client2)
	after_has, ah_out := cache_client_has(&client2, hashes[:])
	testing.expect_value(t, ah_out, Cache_Client_Outcome.Done)
	testing.expect_value(t, after_has, u64(0))

	for sub in ([3]string{"objects", "outboards", "tmp"}) {
		entries, rerr := os.read_all_directory_by_path(fmt.tprintf("%s/%s", dir, sub), context.temp_allocator)
		testing.expect_value(t, rerr, nil)
		testing.expect_value(t, len(entries), 0)
	}
}

@(test)
hostile_server_refused_on_short_proof_corrupt_chunk_and_lying_size :: proc(t: ^testing.T) {
	// Build a valid 2-frame blob (1 MiB + 11 bytes) and its real outboard.
	size :: object_cache.FRAME_PAYLOAD_BYTES + 11
	data := make([]u8, size)
	defer delete(data)
	for &b, i in data {
		b = u8((i * 19 + 5) & 0xFF)
	}
	root := blake3.hash(data)
	builder, _ := object_cache.frame_tree_builder_start(size)
	parents: [object_cache.MAX_PROOF_DEPTH]object_cache.Frame_Parent
	_, _ = object_cache.frame_tree_builder_add(&builder, data[:object_cache.FRAME_PAYLOAD_BYTES], &parents)
	pc, _ := object_cache.frame_tree_builder_add(&builder, data[object_cache.FRAME_PAYLOAD_BYTES:], &parents)
	testing.expect_value(t, pc, 1)
	testing.expect_value(t, builder.root, root)
	root_entry := object_cache.frame_parent_entry(parents[0])
	proof0 := object_cache.frame_proof_entry(root_entry, true)
	proof1 := object_cache.frame_proof_entry(root_entry, false)

	encode_ans :: proc(resp: ^object_cache.Cache_Response) -> []u8 {
		n, ref := object_cache.encoded_response_size(resp)
		assert(ref == .None)
		buf := make([]u8, n)
		_, eref := object_cache.encode_response(resp, buf)
		assert(eref == .None)
		return buf
	}

	// 1. Short proof: frame 0 of a 2-frame blob sent with proof_count = 0 (mutated raw wire bytes).
	valid_f0 := object_cache.Cache_Response {
		request_kind = .Get_Object,
		status       = .Ok,
		object_kind  = .Blob,
		object_size  = size,
		offset       = 0,
		proof        = proof0[:],
		payload      = data[:object_cache.FRAME_PAYLOAD_BYTES],
	}
	f0_wire := encode_ans(&valid_f0)
	defer delete(f0_wire)

	// Strip the 32-byte proof and set proof_count=0 and adjusted body_length.
	short_proof_wire := make([]u8, len(f0_wire) - object_cache.PROOF_ENTRY_SIZE)
	defer delete(short_proof_wire)
	copy(short_proof_wire[:object_cache.FRAME_HEADER_SIZE + object_cache.GET_OBJECT_RESPONSE_HEADER_SIZE], f0_wire[:object_cache.FRAME_HEADER_SIZE + object_cache.GET_OBJECT_RESPONSE_HEADER_SIZE])
	short_proof_wire[object_cache.FRAME_HEADER_SIZE + 1] = 0
	byte_order.write_u32_little_endian(short_proof_wire, 8, u32(len(short_proof_wire) - object_cache.FRAME_HEADER_SIZE))
	copy(short_proof_wire[object_cache.FRAME_HEADER_SIZE + object_cache.GET_OBJECT_RESPONSE_HEADER_SIZE:], data[:object_cache.FRAME_PAYLOAD_BYTES])

	{
		ans := [1][]u8{short_proof_wire}
		srv := scripted_server_start(t, ans[:])
		defer scripted_server_stop(srv)
		c, _ := cache_client_connect(srv.endpoint)
		defer cache_client_close(&c)
		got, out := cache_client_get_object(&c, .Blob, root)
		delete(got)
		testing.expect_value(t, out, Cache_Client_Outcome.Damaged_Answer)
	}

	// 2. Corrupt byte in frame 1 -> Hash_Mismatch.
	valid_f1 := object_cache.Cache_Response {
		request_kind = .Get_Object,
		status       = .Ok,
		object_kind  = .Blob,
		object_size  = size,
		offset       = object_cache.FRAME_PAYLOAD_BYTES,
		proof        = proof1[:],
		payload      = data[object_cache.FRAME_PAYLOAD_BYTES:],
	}
	f1_corrupt := encode_ans(&valid_f1)
	defer delete(f1_corrupt)
	f1_corrupt[len(f1_corrupt) - 1] ~= 0x01
	{
		ans := [2][]u8{f0_wire, f1_corrupt}
		srv := scripted_server_start(t, ans[:])
		defer scripted_server_stop(srv)
		c, _ := cache_client_connect(srv.endpoint)
		defer cache_client_close(&c)
		got, out := cache_client_get_object(&c, .Blob, root)
		delete(got)
		testing.expect_value(t, out, Cache_Client_Outcome.Hash_Mismatch)
	}

	// 3. Server lies about size: claims single-frame 1 MiB for 1 MiB + 11 root -> Hash_Mismatch.
	lying_single := object_cache.Cache_Response {
		request_kind = .Get_Object,
		status       = .Ok,
		object_kind  = .Blob,
		object_size  = object_cache.FRAME_PAYLOAD_BYTES,
		offset       = 0,
		proof        = nil,
		payload      = data[:object_cache.FRAME_PAYLOAD_BYTES],
	}
	lying_wire := encode_ans(&lying_single)
	defer delete(lying_wire)
	{
		ans := [1][]u8{lying_wire}
		srv := scripted_server_start(t, ans[:])
		defer scripted_server_stop(srv)
		c, _ := cache_client_connect(srv.endpoint)
		defer cache_client_close(&c)
		got, out := cache_client_get_object(&c, .Blob, root)
		delete(got)
		testing.expect_value(t, out, Cache_Client_Outcome.Hash_Mismatch)
	}
}

@(test)
edge_sizes_outboard_rebuild_bitrot_and_get_resume :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	work := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(work)
		delete(work)
	}
	priv, pub, _ := make_test_keypair(0x82)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{pub}
	running := tracked_server_start(t, dir, authorized[:])
	defer {
		_ = tracked_server_stop(running)
	}

	client, c_out := cache_client_connect(running.endpoint)
	testing.expect_value(t, c_out, Cache_Client_Outcome.Done)
	defer cache_client_close(&client)

	recv_buf := make([]u8, object_cache.FRAME_HEADER_SIZE + object_cache.MAX_RESPONSE_BODY_BYTES)
	defer delete(recv_buf)

	// 1. Edge sizes: 0 bytes, 1 byte, exact 1 MiB, 1 MiB + 1 byte.
	edge_sizes := [4]u64{0, 1, object_cache.FRAME_PAYLOAD_BYTES, object_cache.FRAME_PAYLOAD_BYTES + 1}
	for sz, idx in edge_sizes {
		src_path := fmt.tprintf("%s/edge_%d.bin", work, idx)
		dst_path := fmt.tprintf("%s/edge_%d.out", work, idx)
		expected_hash := write_pattern_file(t, src_path, sz, u8(idx + 1))

		put_hash, put_size, put_out := cache_client_put_file(&client, &priv, src_path)
		testing.expect_value(t, put_out, Cache_Client_Outcome.Done)
		testing.expect_value(t, put_hash, expected_hash)
		testing.expect_value(t, put_size, sz)

		// Second put returns Already_Present cleanly without re-uploading.
		put_hash2, _, put_out2 := cache_client_put_file(&client, &priv, src_path)
		testing.expect_value(t, put_out2, Cache_Client_Outcome.Done)
		testing.expect_value(t, put_hash2, expected_hash)

		// Outboard exists if and only if sz > FRAME_PAYLOAD_BYTES.
		hex_h := hash_to_hex(expected_hash)
		out_path, _ := store_path_for_hex(dir, .Outboards, string(hex_h[:]), context.temp_allocator)
		testing.expect_value(t, os.exists(out_path), sz > object_cache.FRAME_PAYLOAD_BYTES)

		// Range past the end returns Out_Of_Range.
		frame_count, _ := object_cache.object_frame_count(sz)
		_, oor_out := cache_client_get_frame(&client, .Blob, expected_hash, frame_count * object_cache.FRAME_PAYLOAD_BYTES, recv_buf)
		testing.expect_value(t, oor_out, Cache_Client_Outcome.Out_Of_Range)

		// Get to file and verify exact bytes and hash.
		got_size, resumed, get_out := cache_client_get_file(&client, expected_hash, dst_path)
		testing.expect_value(t, get_out, Cache_Client_Outcome.Done)
		testing.expect_value(t, got_size, sz)
		testing.expect_value(t, resumed, u64(0))
		got_hash, disk_size := hash_file_streaming(t, dst_path)
		testing.expect_value(t, disk_size, sz)
		testing.expect_value(t, got_hash, expected_hash)
	}

	// 2. Outboard missing on disk for a multi-frame blob -> transparently rebuilt on Get_Object.
	multi_src := fmt.tprintf("%s/multi_3m.bin", work)
	multi_size :: u64(3 * object_cache.FRAME_PAYLOAD_BYTES + 19)
	multi_hash := write_pattern_file(t, multi_src, multi_size, 0x44)
	_, _, multi_put_out := cache_client_put_file(&client, &priv, multi_src)
	testing.expect_value(t, multi_put_out, Cache_Client_Outcome.Done)

	multi_hex := hash_to_hex(multi_hash)
	multi_out_path, _ := store_path_for_hex(dir, .Outboards, string(multi_hex[:]), context.temp_allocator)
	testing.expect(t, os.exists(multi_out_path))
	testing.expect_value(t, os.remove(multi_out_path), nil)
	testing.expect(t, !os.exists(multi_out_path))

	// Fetching frame 3 (the 19-byte tail) triggers outboard rebuild and returns valid proof.
	tail_resp, tail_out := cache_client_get_frame(&client, .Blob, multi_hash, 3 * object_cache.FRAME_PAYLOAD_BYTES, recv_buf)
	testing.expect_value(t, tail_out, Cache_Client_Outcome.Done)
	testing.expect_value(t, tail_resp.object_size, multi_size)
	testing.expect_value(t, len(tail_resp.payload), 19)
	testing.expect(t, os.exists(multi_out_path))

	// A damaged outboard of the right size: the frame does not verify with
	// it, the server builds it again from the object and serves the frame.
	{
		outboard_file, outboard_error := os.open(multi_out_path, {.Read, .Write})
		testing.expect_value(t, outboard_error, nil)
		garbage: [object_cache.OUTBOARD_ENTRY_SIZE]u8
		for &b in garbage {
			b = 0xA5
		}
		testing.expect(t, file_write_all_at(outboard_file, garbage[:], 0))
		_ = os.close(outboard_file)
	}
	repaired_resp, repaired_out := cache_client_get_frame(&client, .Blob, multi_hash, 0, recv_buf)
	testing.expect_value(t, repaired_out, Cache_Client_Outcome.Done)
	testing.expect_value(t, len(repaired_resp.payload), object_cache.FRAME_PAYLOAD_BYTES)

	// A get into memory refuses an object past the bound of its caller
	// before it allocates; the same object passes under a larger bound.
	too_large, too_large_out := cache_client_get_object(&client, .Blob, multi_hash, context.allocator, 1024)
	testing.expect_value(t, too_large_out, Cache_Client_Outcome.Too_Large)
	testing.expect(t, too_large == nil)
	whole, whole_out := cache_client_get_object(&client, .Blob, multi_hash)
	testing.expect_value(t, whole_out, Cache_Client_Outcome.Done)
	testing.expect_value(t, blake3.hash(whole), multi_hash)
	delete(whole)

	// 3. Resume of an interrupted Get transfer (2 MiB valid + 137 torn trailing bytes).
	resume_dst := fmt.tprintf("%s/resumed.bin", work)
	part_path := fmt.tprintf("%s.%s.part", resume_dst, string(multi_hex[:]))
	{
		src_f, serr := os.open(multi_src)
		testing.expect_value(t, serr, nil)
		defer os.close(src_f)
		part_f, perr := os.create(part_path)
		testing.expect_value(t, perr, nil)
		defer os.close(part_f)
		tmp := make([]u8, object_cache.FRAME_PAYLOAD_BYTES)
		defer delete(tmp)
		for idx in 0 ..< 2 {
			testing.expect(t, file_read_exact_at(src_f, tmp, i64(idx * object_cache.FRAME_PAYLOAD_BYTES)))
			testing.expect(t, file_write_all(part_f, tmp))
		}
		torn: [137]u8
		for &b in torn {
			b = 0xEE
		}
		testing.expect(t, file_write_all(part_f, torn[:]))
	}
	res_size, res_bytes, res_out := cache_client_get_file(&client, multi_hash, resume_dst)
	testing.expect_value(t, res_out, Cache_Client_Outcome.Done)
	testing.expect_value(t, res_size, multi_size)
	testing.expect_value(t, res_bytes, u64(2 * object_cache.FRAME_PAYLOAD_BYTES))
	testing.expect(t, !os.exists(part_path))
	res_hash, res_disk_size := hash_file_streaming(t, resume_dst)
	testing.expect_value(t, res_disk_size, multi_size)
	testing.expect_value(t, res_hash, multi_hash)

	// 4. Tampered .part file on disk is caught before rename: Hash_Mismatch, no output file created.
	bad_resume_dst := fmt.tprintf("%s/bad_resumed.bin", work)
	bad_part_path := fmt.tprintf("%s.%s.part", bad_resume_dst, string(multi_hex[:]))
	{
		src_f, _ := os.open(multi_src)
		defer os.close(src_f)
		part_f, _ := os.create(bad_part_path)
		defer os.close(part_f)
		tmp := make([]u8, object_cache.FRAME_PAYLOAD_BYTES)
		defer delete(tmp)
		testing.expect(t, file_read_exact_at(src_f, tmp, 0))
		tmp[42] ~= 0x01 // corrupt byte inside resumed frame 0
		testing.expect(t, file_write_all(part_f, tmp))
	}
	_, _, bad_res_out := cache_client_get_file(&client, multi_hash, bad_resume_dst)
	testing.expect_value(t, bad_res_out, Cache_Client_Outcome.Hash_Mismatch)
	testing.expect(t, !os.exists(bad_resume_dst))
	testing.expect(t, !os.exists(bad_part_path))

	// 5. On-disk corruption of a multi-frame blob is detected by server -> Bad_Hash.
	multi_obj_path, _ := store_path_for_hex(dir, .Objects, string(multi_hex[:]), context.temp_allocator)
	{
		of, oerr := os.open(multi_obj_path, {.Read, .Write})
		testing.expect_value(t, oerr, nil)
		defer os.close(of)
		flip := [1]u8{0xFF}
		orig: [1]u8
		testing.expect(t, file_read_exact_at(of, orig[:], i64(object_cache.FRAME_PAYLOAD_BYTES + 100)))
		flip[0] = orig[0] ~ 0x01
		testing.expect(t, file_write_all_at(of, flip[:], i64(object_cache.FRAME_PAYLOAD_BYTES + 100)))
	}
	_, rot_out := cache_client_get_frame(&client, .Blob, multi_hash, object_cache.FRAME_PAYLOAD_BYTES, recv_buf)
	testing.expect_value(t, rot_out, Cache_Client_Outcome.Server_Refused)
	testing.expect_value(t, client.server_status, object_cache.Cache_Response_Status.Bad_Hash)
}

@(test)
hundred_mib_loopback_with_bounded_memory :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	work := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(work)
		delete(work)
	}
	priv, pub, seed := make_test_keypair(0x83)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{pub}

	blob_size :: u64(100 * 1024 * 1024)
	src_path := fmt.tprintf("%s/blob_100m.bin", work)
	dst_path := fmt.tprintf("%s/blob_100m.got", work)
	expected_hash := write_pattern_file(t, src_path, blob_size, 0x99)

	running := tracked_server_start(t, dir, authorized[:])

	// Measure client peak heap allocation across Put + Has + Get of 100 MiB.
	client_peak: i64 = 0
	{
		client_track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&client_track, context.allocator)
		defer mem.tracking_allocator_destroy(&client_track)
		saved_alloc := context.allocator
		context.allocator = mem.tracking_allocator(&client_track)
		defer context.allocator = saved_alloc

		client, c_out := cache_client_connect(running.endpoint)
		testing.expect_value(t, c_out, Cache_Client_Outcome.Done)
		defer cache_client_close(&client)

		put_hash, put_size, put_out := cache_client_put_file(&client, &priv, src_path)
		testing.expect_value(t, put_out, Cache_Client_Outcome.Done)
		testing.expect_value(t, put_hash, expected_hash)
		testing.expect_value(t, put_size, blob_size)

		hashes := [1]blake3.Hash{expected_hash}
		present, has_out := cache_client_has(&client, hashes[:])
		testing.expect_value(t, has_out, Cache_Client_Outcome.Done)
		testing.expect_value(t, present, u64(1))

		got_size, resumed, get_out := cache_client_get_file(&client, expected_hash, dst_path)
		testing.expect_value(t, get_out, Cache_Client_Outcome.Done)
		testing.expect_value(t, got_size, blob_size)
		testing.expect_value(t, resumed, u64(0))

		client_peak = client_track.peak_memory_allocated
	}

	// Verify store counts and page/status output show the 100 MiB largest object.
	snap := cache_status_snapshot(&running.server.status)
	testing.expect_value(t, snap.counts.objects, u64(1))
	testing.expect_value(t, snap.counts.object_bytes, blob_size)
	testing.expect_value(t, snap.counts.largest_object_bytes, blob_size)
	settings := Cache_Page_Settings{endpoint = running.endpoint, site_address = DEFAULT_SITE_ADDRESS}
	page_html := cache_page_html(&running.server, settings, snap, 0, false)
	testing.expect(t, strings.contains(page_html, "Largest object"))
	testing.expect(t, strings.contains(page_html, "100.0 MiB"))
	status_json := cache_status_json(&running.server, settings, snap, 0, false)
	testing.expect(t, strings.contains(status_json, "\"largest_object_bytes\": 104857600,"))

	// Also verify CLI cache-put and cache-get on a multi-frame blob with throwaway keys.
	seed_path := fmt.tprintf("%s/throwaway.key", work)
	seed_hex := hash_to_hex(seed)
	testing.expect_value(t, os.write_entire_file(seed_path, transmute([]u8)fmt.tprintf("%s\n", string(seed_hex[:]))), nil)
	testing.expect_value(t, os.chmod(seed_path, os.perm(0o600)), nil)
	cli_src := fmt.tprintf("%s/cli_2m.bin", work)
	cli_dst := fmt.tprintf("%s/cli_2m.out", work)
	cli_hash := write_pattern_file(t, cli_src, 2 * object_cache.FRAME_PAYLOAD_BYTES + 13, 0x55)
	cli_hex := hash_to_hex(cli_hash)
	testing.expect_value(t, run_cache_put({running.endpoint, "--key", seed_path, "blob", cli_src}), 0)
	testing.expect_value(t, run_cache_get({running.endpoint, "blob", string(cli_hex[:]), cli_dst}), 0)
	cli_got_hash, cli_got_size := hash_file_streaming(t, cli_dst)
	testing.expect_value(t, cli_got_size, u64(2 * object_cache.FRAME_PAYLOAD_BYTES + 13))
	testing.expect_value(t, cli_got_hash, cli_hash)

	server_peak := tracked_server_stop(running)

	// Verify the downloaded 100 MiB file matches the original hash and size.
	got_hash, got_disk_size := hash_file_streaming(t, dst_path)
	testing.expect_value(t, got_disk_size, blob_size)
	testing.expect_value(t, got_hash, expected_hash)

	// Print measured peak memory of both sides and assert both are strictly bounded
	// far below the 100 MiB object size (< 8 MiB each; actual ~2 MiB server, ~1 MiB client).
	fmt.printfln("cache_large_test: 100 MiB loopback peak heap: server=%d bytes, client=%d bytes", server_peak, client_peak)
	MEMORY_BOUND :: i64(8 * 1024 * 1024)
	testing.expectf(t, server_peak > 0 && server_peak < MEMORY_BOUND, "server peak heap %d bytes exceeded bound %d", server_peak, MEMORY_BOUND)
	testing.expectf(t, client_peak > 0 && client_peak < MEMORY_BOUND, "client peak heap %d bytes exceeded bound %d", client_peak, MEMORY_BOUND)
}

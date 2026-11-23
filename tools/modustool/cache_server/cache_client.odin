// The client of the binary object cache protocol: the commands cache-put and
// cache-get use it, and the host tests drive cache-serve through it
// (src/md/infrastructure/cache_publication.md, "The client").
package cache_server

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import "modus:contract/blake3"
import "modus:contract/object_cache"
import "modus:contract/tree_hash"
import "modus:cryptography/ed25519"
import "modustool:foundation"

// The outcome of one request of the client. Each refusal names its cause; a
// status of the server that is not Ok is kept beside it.
Cache_Client_Outcome :: enum u8 {
	Done             = 1,
	Unreachable      = 2, // No connection, or the connection ended before a whole answer.
	Damaged_Answer   = 3, // An answer that the protocol refuses, or an answer to another request.
	Not_Found        = 4,
	Server_Refused   = 5, // The server answered a status other than Ok, Not_Found, and Out_Of_Range.
	Hash_Mismatch    = 6,
	Untrusted_Signer = 7,
	Bad_Signature    = 8,
	Too_Large        = 9, // An object past the bound of its kind, the free space of the disk, or the memory bound of the caller.
	Bad_Request      = 10, // A request that the protocol refuses, refused before it leaves the host.
	Deadline_Passed  = 11, // The request and its whole answer took longer than the bound of one exchange.
	Out_Of_Range     = 12, // The requested offset is past the end of the object.
	Local_File_Fault = 13, // A local file was not opened, read, written or renamed.
}

// One connection to an object cache.
Cache_Client :: struct {
	socket:         net.TCP_Socket,
	// The bound of one exchange: the send of a request and the read of its
	// whole answer. A bound on each read alone lets a server that sends one
	// byte before each timeout hold the client for hours.
	exchange_bound: time.Duration,
	// The last status of the server, for the sentence of a refusal.
	server_status:  object_cache.Cache_Response_Status,
}

// cache_client_outcome_text gives the sentence of an outcome.
cache_client_outcome_text :: proc(outcome: Cache_Client_Outcome, server_status: object_cache.Cache_Response_Status) -> string {
	switch outcome {
	case .Done:
		return "done"
	case .Unreachable:
		return "the object cache did not answer, or the connection ended before a whole answer"
	case .Damaged_Answer:
		return "the object cache gave an answer that the protocol refuses"
	case .Not_Found:
		return "the object cache does not hold it"
	case .Server_Refused:
		switch server_status {
		case .Unauthorized:
			return "the object cache does not authorise the key that signed the upload"
		case .Bad_Signature:
			return "the object cache found a signature that does not verify"
		case .Bad_Hash:
			return "the object cache found bytes that do not have their hash"
		case .Too_Large:
			return "the object cache refused its size"
		case .Refused, .Ok, .Not_Found, .Out_Of_Range:
			return "the object cache refused it"
		}
	case .Hash_Mismatch:
		return "the bytes that the object cache gave do not have the hash that was asked"
	case .Untrusted_Signer:
		return "the realisation is signed by another key than the trusted signer"
	case .Bad_Signature:
		return "the signature of the realisation does not verify"
	case .Too_Large:
		return "the object is larger than the bound of its kind, the free space of the disk, or the memory that the caller gives it"
	case .Bad_Request:
		return "the protocol refuses the request"
	case .Deadline_Passed:
		return "the object cache did not give its whole answer within the bound of one exchange"
	case .Out_Of_Range:
		return "the requested range is past the end of the object"
	case .Local_File_Fault:
		return "the local file was not read or written"
	}
	return ""
}

// cache_client_connect opens a connection to host:port, with the rule of the
// endpoint of the page (cache_page_endpoint_valid). A host name is resolved
// once.
cache_client_connect :: proc(endpoint: string, exchange_bound := foundation.HANG_BOUND) -> (client: Cache_Client, outcome: Cache_Client_Outcome) {
	if !cache_page_endpoint_valid(endpoint) {
		return {}, .Bad_Request
	}
	socket, dial_error := net.dial_tcp_from_hostname_and_port_string(endpoint)
	if dial_error != nil {
		return {}, .Unreachable
	}
	return Cache_Client{socket = socket, exchange_bound = exchange_bound}, .Done
}

cache_client_close :: proc(client: ^Cache_Client) {
	net.close(client.socket)
}

// The time left before the deadline of an exchange, or false when it passed.
@(private = "file")
time_left :: proc(deadline: time.Tick) -> (left: time.Duration, ok: bool) {
	left = -time.tick_diff(deadline, time.tick_now())
	return left, left > 0
}

// client_send_all sends all bytes before the deadline. Each send waits at
// most the time that remains.
@(private = "file")
client_send_all :: proc(socket: net.TCP_Socket, data: []u8, deadline: time.Tick) -> Cache_Client_Outcome {
	sent := 0
	for sent < len(data) {
		left, in_time := time_left(deadline)
		if !in_time {
			return .Deadline_Passed
		}
		if net.set_option(socket, .Send_Timeout, left) != nil {
			return .Unreachable
		}
		count, send_error := net.send_tcp(socket, data[sent:])
		if send_error != nil || count == 0 {
			if _, still := time_left(deadline); !still {
				return .Deadline_Passed
			}
			return .Unreachable
		}
		sent += count
	}
	return .Done
}

// client_read_exact reads exactly len(buffer) bytes before the deadline.
// Each read waits at most the time that remains, so a server that sends one
// byte at a time still ends at the deadline.
@(private = "file")
client_read_exact :: proc(socket: net.TCP_Socket, buffer: []u8, deadline: time.Tick) -> Cache_Client_Outcome {
	received := 0
	for received < len(buffer) {
		left, in_time := time_left(deadline)
		if !in_time {
			return .Deadline_Passed
		}
		if net.set_option(socket, .Receive_Timeout, left) != nil {
			return .Unreachable
		}
		count, receive_error := net.recv_tcp(socket, buffer[received:])
		if receive_error != nil || count == 0 {
			if _, still := time_left(deadline); !still {
				return .Deadline_Passed
			}
			return .Unreachable
		}
		received += count
	}
	return .Done
}

// cache_client_read_answer_into reads one answer frame into recv_buf before
// the deadline. It refuses a head that the protocol refuses before it reads
// a byte of the body.
cache_client_read_answer_into :: proc(socket: net.TCP_Socket, deadline: time.Tick, recv_buf: []u8) -> (frame: []u8, outcome: Cache_Client_Outcome) {
	if len(recv_buf) < object_cache.FRAME_HEADER_SIZE {
		return nil, .Bad_Request
	}
	header := recv_buf[:object_cache.FRAME_HEADER_SIZE]
	if read_outcome := client_read_exact(socket, header, deadline); read_outcome != .Done {
		return nil, read_outcome
	}
	_, _, body_length, header_refusal := object_cache.inspect_response_header(header)
	if header_refusal != .None {
		return nil, .Damaged_Answer
	}
	total := object_cache.FRAME_HEADER_SIZE + body_length
	if total > len(recv_buf) {
		return nil, .Damaged_Answer
	}
	if body_length > 0 {
		if body_outcome := client_read_exact(socket, recv_buf[object_cache.FRAME_HEADER_SIZE:total], deadline); body_outcome != .Done {
			return nil, body_outcome
		}
	}
	return recv_buf[:total], .Done
}

// cache_client_read_answer reads one answer frame before the deadline,
// allocating the frame buffer after validating the 12-byte header.
cache_client_read_answer :: proc(socket: net.TCP_Socket, deadline: time.Tick, allocator := context.allocator) -> (frame: []u8, outcome: Cache_Client_Outcome) {
	header: [object_cache.FRAME_HEADER_SIZE]u8
	if read_outcome := client_read_exact(socket, header[:], deadline); read_outcome != .Done {
		return nil, read_outcome
	}
	_, _, body_length, header_refusal := object_cache.inspect_response_header(header[:])
	if header_refusal != .None {
		return nil, .Damaged_Answer
	}
	frame = make([]u8, object_cache.FRAME_HEADER_SIZE + body_length, allocator)
	copy(frame[:object_cache.FRAME_HEADER_SIZE], header[:])
	if body_length > 0 {
		if body_outcome := client_read_exact(socket, frame[object_cache.FRAME_HEADER_SIZE:], deadline); body_outcome != .Done {
			delete(frame, allocator)
			return nil, body_outcome
		}
	}
	return frame, .Done
}

// cache_client_answer_outcome checks that an answer answers this request,
// and gives the outcome of its status.
cache_client_answer_outcome :: proc(request_kind: object_cache.Cache_Request_Kind, response: ^object_cache.Cache_Response) -> Cache_Client_Outcome {
	if response.request_kind != request_kind {
		return .Damaged_Answer
	}
	switch response.status {
	case .Ok:
		return .Done
	case .Not_Found:
		// Only a get can find nothing: a Has or a put answered Not_Found is
		// an answer that the protocol does not give.
		switch request_kind {
		case .Get_Object, .Get_Realisation:
			return .Not_Found
		case .Has, .Put_Object, .Put_Object_Frame, .Put_Realisation:
			return .Damaged_Answer
		}
		return .Damaged_Answer
	case .Out_Of_Range:
		switch request_kind {
		case .Get_Object:
			return .Out_Of_Range
		case .Has, .Get_Realisation, .Put_Object, .Put_Object_Frame, .Put_Realisation:
			return .Damaged_Answer
		}
		return .Damaged_Answer
	case .Refused, .Too_Large, .Bad_Hash, .Bad_Signature, .Unauthorized:
		return .Server_Refused
	}
	return .Damaged_Answer
}

// cache_client_exchange_into sends request encoded in send_buf and reads its
// answer into recv_buf without heap allocation. response borrows from recv_buf.
cache_client_exchange_into :: proc(
	client: ^Cache_Client,
	request: ^object_cache.Cache_Request,
	send_buf: []u8,
	recv_buf: []u8,
) -> (response: object_cache.Cache_Response, outcome: Cache_Client_Outcome) {
	written, encode_refusal := object_cache.encode_request(request, send_buf)
	if encode_refusal == .Too_Large {
		return {}, .Too_Large
	}
	if encode_refusal != .None {
		return {}, .Bad_Request
	}
	deadline := time.tick_add(time.tick_now(), client.exchange_bound)
	if send_outcome := client_send_all(client.socket, send_buf[:written], deadline); send_outcome != .Done {
		return {}, send_outcome
	}
	answer_frame, read_outcome := cache_client_read_answer_into(client.socket, deadline, recv_buf)
	if read_outcome != .Done {
		return {}, read_outcome
	}
	decode_refusal: object_cache.Wire_Refusal
	response, decode_refusal = object_cache.decode_response(answer_frame)
	if decode_refusal != .None {
		return {}, .Damaged_Answer
	}
	client.server_status = response.status
	outcome = cache_client_answer_outcome(request.kind, &response)
	return response, outcome
}

// cache_client_exchange sends one request and reads its answer. The frame of
// the answer is allocated with allocator; response borrows from it.
cache_client_exchange :: proc(
	client: ^Cache_Client,
	request: ^object_cache.Cache_Request,
	allocator := context.allocator,
) -> (frame: []u8, response: object_cache.Cache_Response, outcome: Cache_Client_Outcome) {
	size, size_refusal := object_cache.encoded_request_size(request)
	if size_refusal == .Too_Large {
		return nil, {}, .Too_Large
	}
	if size_refusal != .None {
		return nil, {}, .Bad_Request
	}
	request_frame := make([]u8, size)
	defer delete(request_frame)
	if _, encode_refusal := object_cache.encode_request(request, request_frame); encode_refusal != .None {
		return nil, {}, .Bad_Request
	}
	deadline := time.tick_add(time.tick_now(), client.exchange_bound)
	if send_outcome := client_send_all(client.socket, request_frame, deadline); send_outcome != .Done {
		return nil, {}, send_outcome
	}
	frame, outcome = cache_client_read_answer(client.socket, deadline, allocator)
	if outcome != .Done {
		return nil, {}, outcome
	}
	decode_refusal: object_cache.Wire_Refusal
	response, decode_refusal = object_cache.decode_response(frame)
	if decode_refusal != .None {
		delete(frame, allocator)
		return nil, {}, .Damaged_Answer
	}
	client.server_status = response.status
	outcome = cache_client_answer_outcome(request.kind, &response)
	return frame, response, outcome
}

// cache_client_has asks which of at most 64 hashes the cache holds.
cache_client_has :: proc(client: ^Cache_Client, hashes: []blake3.Hash) -> (present: u64, outcome: Cache_Client_Outcome) {
	if len(hashes) == 0 || len(hashes) > object_cache.MAX_HAS_HASHES {
		return 0, .Bad_Request
	}
	request := object_cache.Cache_Request {
		kind       = .Has,
		hash_count = u8(len(hashes)),
	}
	copy(request.hashes[:], hashes)
	frame, response, exchange_outcome := cache_client_exchange(client, &request)
	defer delete(frame)
	if exchange_outcome != .Done {
		return 0, exchange_outcome
	}
	// A bit past the hashes that were asked answers no question.
	if len(hashes) < 64 && response.present_bitset >> u64(len(hashes)) != 0 {
		return 0, .Damaged_Answer
	}
	return response.present_bitset, .Done
}

// send_put_object_head signs and sends the Put_Object header and validates
// the server's Put_Object_State response.
@(private = "file")
send_put_object_head :: proc(
	client: ^Cache_Client,
	uploader: ^ed25519.Private_Key,
	kind: object_cache.Cache_Object_Kind,
	object_hash: blake3.Hash,
	object_size: u64,
) -> (state: object_cache.Put_Object_State, next_offset: u64, outcome: Cache_Client_Outcome) {
	request := object_cache.Cache_Request {
		kind        = .Put_Object,
		object_hash = object_hash,
		object_kind = kind,
		object_size = object_size,
	}
	ed25519.private_key_public_bytes(uploader, request.uploader_public_key[:])
	signing_bytes, signing_ok := object_cache.put_object_signing_bytes(kind, object_hash, object_size, request.uploader_public_key)
	if !signing_ok {
		return {}, 0, .Bad_Request
	}
	ed25519.sign(uploader, signing_bytes[:], request.uploader_signature[:])

	send_buf: [object_cache.FRAME_HEADER_SIZE + object_cache.PUT_OBJECT_BODY_SIZE]u8
	recv_buf: [object_cache.FRAME_HEADER_SIZE + object_cache.PUT_OBJECT_RESPONSE_BODY_SIZE]u8
	response, exchange_outcome := cache_client_exchange_into(client, &request, send_buf[:], recv_buf[:])
	if exchange_outcome != .Done {
		return {}, 0, exchange_outcome
	}
	return response.put_state, response.offset, .Done
}

// cache_client_put_object puts an in-memory object of any size, signed by the
// uploader key, streaming it in FRAME_PAYLOAD_BYTES frames.
cache_client_put_object :: proc(
	client: ^Cache_Client,
	uploader: ^ed25519.Private_Key,
	kind: object_cache.Cache_Object_Kind,
	payload: []u8,
) -> (object_hash: blake3.Hash, outcome: Cache_Client_Outcome) {
	checked_kind, kind_ok := object_cache.cache_object_kind_of_word(u64(kind))
	if !kind_ok {
		return {}, .Bad_Request
	}
	object_size := u64(len(payload))
	if object_size > object_cache.payload_bound_for_kind(checked_kind) {
		return {}, .Too_Large
	}
	switch checked_kind {
	case .Blob:
		object_hash = blake3.hash(payload)
	case .Tree:
		tree_digest, tree_refusal := tree_hash.tree_hash(payload)
		if tree_refusal != .None {
			return {}, .Bad_Request
		}
		object_hash = tree_digest
	}

	put_state, next_offset, head_outcome := send_put_object_head(client, uploader, checked_kind, object_hash, object_size)
	if head_outcome != .Done {
		return object_hash, head_outcome
	}
	switch put_state {
	case .Already_Present:
		return object_hash, .Done
	case .Accept_Frames:
	}

	frame_count, count_ok := object_cache.object_frame_count(object_size)
	start_frame, idx_ok := object_cache.object_offset_to_frame_index(next_offset)
	if !count_ok || !idx_ok || start_frame >= frame_count {
		return object_hash, .Damaged_Answer
	}

	send_buf := make([]u8, object_cache.FRAME_HEADER_SIZE + object_cache.MAX_REQUEST_BODY_BYTES)
	defer delete(send_buf)
	recv_buf: [object_cache.FRAME_HEADER_SIZE + 32]u8

	for frame_index in start_frame ..< frame_count {
		frame_len, len_ok := object_cache.object_frame_length(object_size, frame_index)
		if !len_ok {
			return object_hash, .Bad_Request
		}
		offset := frame_index * object_cache.FRAME_PAYLOAD_BYTES
		frame_req := object_cache.Cache_Request {
			kind        = .Put_Object_Frame,
			object_hash = object_hash,
			offset      = offset,
			payload     = payload[int(offset):int(offset) + int(frame_len)],
		}
		_, frame_outcome := cache_client_exchange_into(client, &frame_req, send_buf, recv_buf[:])
		if frame_outcome != .Done {
			return object_hash, frame_outcome
		}
	}
	return object_hash, .Done
}

// cache_client_put_file streams a file of any size from disk to the cache in
// FRAME_PAYLOAD_BYTES frames using one 1 MiB frame buffer (two streaming
// passes: hash first, then upload if not already held).
cache_client_put_file :: proc(
	client: ^Cache_Client,
	uploader: ^ed25519.Private_Key,
	path: string,
) -> (object_hash: blake3.Hash, file_size: u64, outcome: Cache_Client_Outcome) {
	file, open_err := os.open(path)
	if open_err != nil {
		return {}, 0, .Local_File_Fault
	}
	defer os.close(file)

	raw_size, size_err := os.file_size(file)
	if size_err != nil || raw_size < 0 {
		return {}, 0, .Local_File_Fault
	}
	file_size = u64(raw_size)
	if file_size > object_cache.MAX_OBJECT_BYTES {
		return {}, file_size, .Too_Large
	}

	builder, b_ok := object_cache.frame_tree_builder_start(file_size)
	if !b_ok {
		return {}, file_size, .Too_Large
	}

	// One 1 MiB send buffer reused for both the hashing pass and upload pass.
	send_buf := make([]u8, object_cache.FRAME_HEADER_SIZE + object_cache.MAX_REQUEST_BODY_BYTES)
	defer delete(send_buf)
	payload_off :: object_cache.FRAME_HEADER_SIZE + object_cache.PUT_OBJECT_FRAME_HEADER_SIZE

	// Pass 1: compute the exact BLAKE3 hash of the file without holding it in memory.
	for frame_index in u64(0) ..< builder.frame_count {
		frame_len, len_ok := object_cache.object_frame_length(file_size, frame_index)
		if !len_ok {
			return {}, file_size, .Bad_Request
		}
		frame_slice := send_buf[payload_off:payload_off + int(frame_len)]
		if frame_len > 0 && !file_read_exact_at(file, frame_slice, i64(frame_index * object_cache.FRAME_PAYLOAD_BYTES)) {
			return {}, file_size, .Local_File_Fault
		}
		parents: [object_cache.MAX_PROOF_DEPTH]object_cache.Frame_Parent
		if _, add_ok := object_cache.frame_tree_builder_add(&builder, frame_slice, &parents); !add_ok {
			return {}, file_size, .Local_File_Fault
		}
	}
	if !builder.finished {
		return {}, file_size, .Local_File_Fault
	}
	object_hash = builder.root

	put_state, next_offset, head_outcome := send_put_object_head(client, uploader, .Blob, object_hash, file_size)
	if head_outcome != .Done {
		return object_hash, file_size, head_outcome
	}
	switch put_state {
	case .Already_Present:
		return object_hash, file_size, .Done
	case .Accept_Frames:
	}

	start_frame, idx_ok := object_cache.object_offset_to_frame_index(next_offset)
	if !idx_ok || start_frame >= builder.frame_count {
		return object_hash, file_size, .Damaged_Answer
	}

	// Pass 2: stream frames in place through send_buf.
	recv_buf: [object_cache.FRAME_HEADER_SIZE + 32]u8
	for frame_index in start_frame ..< builder.frame_count {
		frame_len, len_ok := object_cache.object_frame_length(file_size, frame_index)
		if !len_ok {
			return object_hash, file_size, .Bad_Request
		}
		offset := frame_index * object_cache.FRAME_PAYLOAD_BYTES
		frame_slice := send_buf[payload_off:payload_off + int(frame_len)]
		if frame_len > 0 && !file_read_exact_at(file, frame_slice, i64(offset)) {
			return object_hash, file_size, .Local_File_Fault
		}
		frame_req := object_cache.Cache_Request {
			kind        = .Put_Object_Frame,
			object_hash = object_hash,
			offset      = offset,
			payload     = frame_slice,
		}
		_, frame_outcome := cache_client_exchange_into(client, &frame_req, send_buf, recv_buf[:])
		if frame_outcome != .Done {
			return object_hash, file_size, frame_outcome
		}
	}
	return object_hash, file_size, .Done
}

// cache_client_realisation_sign gives the realisation of a recipe, signed by
// signer.
cache_client_realisation_sign :: proc(
	signer: ^ed25519.Private_Key,
	recipe_hash, output_hash: blake3.Hash,
	output_kind: object_cache.Cache_Object_Kind,
) -> (record: object_cache.Realisation_Record, ok: bool) {
	record = {
		recipe_hash = recipe_hash,
		output_hash = output_hash,
		output_kind = output_kind,
	}
	ed25519.private_key_public_bytes(signer, record.signer_public_key[:])
	signing_bytes := object_cache.realisation_signing_bytes(&record) or_return
	ed25519.sign(signer, signing_bytes[:], record.signature[:])
	return record, true
}

// cache_client_put_realisation puts one signed realisation.
cache_client_put_realisation :: proc(client: ^Cache_Client, record: object_cache.Realisation_Record) -> Cache_Client_Outcome {
	request := object_cache.Cache_Request {
		kind        = .Put_Realisation,
		realisation = record,
	}
	frame, _, outcome := cache_client_exchange(client, &request)
	delete(frame)
	return outcome
}

// cache_client_frame_check verifies one ranged Get_Object answer against the
// asked kind, hash, and offset using its BLAKE3 inclusion proof (or tree_hash
// for a single-frame tree). The client trusts no server.
cache_client_frame_check :: proc(
	asked_kind: object_cache.Cache_Object_Kind,
	asked_hash: blake3.Hash,
	asked_offset: u64,
	response: ^object_cache.Cache_Response,
) -> Cache_Client_Outcome {
	if response.object_kind != asked_kind || response.offset != asked_offset {
		return .Damaged_Answer
	}
	frame_index, idx_ok := object_cache.object_offset_to_frame_index(asked_offset)
	if !idx_ok {
		return .Damaged_Answer
	}
	switch object_cache.object_frame_verify(asked_kind, asked_hash, response.object_size, frame_index, response.proof, response.payload) {
	case .Trust_By_Hash:
		return .Done
	case .Refuse_Hash_Mismatch:
		return .Hash_Mismatch
	case .Refuse_Malformed, .Trust_By_Signer, .Refuse_Untrusted_Signer, .Refuse_Bad_Signature:
		return .Damaged_Answer
	}
	return .Damaged_Answer
}

// cache_client_get_frame fetches and verifies one aligned frame into recv_buf
// (which must hold at least FRAME_HEADER_SIZE + MAX_RESPONSE_BODY_BYTES).
cache_client_get_frame :: proc(
	client: ^Cache_Client,
	kind: object_cache.Cache_Object_Kind,
	object_hash: blake3.Hash,
	offset: u64,
	recv_buf: []u8,
) -> (response: object_cache.Cache_Response, outcome: Cache_Client_Outcome) {
	request := object_cache.Cache_Request {
		kind        = .Get_Object,
		object_kind = kind,
		object_hash = object_hash,
		offset      = offset,
	}
	send_buf: [object_cache.FRAME_HEADER_SIZE + object_cache.GET_OBJECT_BODY_SIZE]u8
	response, outcome = cache_client_exchange_into(client, &request, send_buf[:], recv_buf)
	if outcome != .Done {
		return {}, outcome
	}
	if check := cache_client_frame_check(kind, object_hash, offset, &response); check != .Done {
		return {}, check
	}
	return response, .Done
}

// The most bytes that cache_client_get_object holds in memory by default.
// An object of any size goes to a file with cache_client_get_file.
CACHE_CLIENT_MEMORY_OBJECT_LIMIT :: u64(64 * 1024 * 1024)

// cache_client_get_object fetches an object frame by frame into memory and
// verifies every frame against object_hash. Only the last frame proves the
// size that the server states, so the size is checked against limit before
// the allocation.
cache_client_get_object :: proc(
	client: ^Cache_Client,
	kind: object_cache.Cache_Object_Kind,
	object_hash: blake3.Hash,
	allocator := context.allocator,
	limit := CACHE_CLIENT_MEMORY_OBJECT_LIMIT,
) -> (payload: []u8, outcome: Cache_Client_Outcome) {
	recv_buf := make([]u8, object_cache.FRAME_HEADER_SIZE + object_cache.MAX_RESPONSE_BODY_BYTES)
	defer delete(recv_buf)

	first, first_outcome := cache_client_get_frame(client, kind, object_hash, 0, recv_buf)
	if first_outcome != .Done {
		return nil, first_outcome
	}
	object_size := first.object_size
	if object_size > limit {
		return nil, .Too_Large
	}
	frame_count, count_ok := object_cache.object_frame_count(object_size)
	if !count_ok {
		return nil, .Damaged_Answer
	}
	payload = make([]u8, int(object_size), allocator)
	copy(payload[:len(first.payload)], first.payload)

	for frame_index in u64(1) ..< frame_count {
		offset := frame_index * object_cache.FRAME_PAYLOAD_BYTES
		frame_resp, frame_outcome := cache_client_get_frame(client, kind, object_hash, offset, recv_buf)
		if frame_outcome != .Done {
			delete(payload, allocator)
			return nil, frame_outcome
		}
		if frame_resp.object_size != object_size {
			delete(payload, allocator)
			return nil, .Damaged_Answer
		}
		copy(payload[int(offset):int(offset) + len(frame_resp.payload)], frame_resp.payload)
	}
	return payload, .Done
}

// cache_client_verify_object streams every frame of object_hash using one 1 MiB
// buffer and checks each frame against object_hash without storing the bytes.
cache_client_verify_object :: proc(
	client: ^Cache_Client,
	kind: object_cache.Cache_Object_Kind,
	object_hash: blake3.Hash,
) -> (object_size: u64, outcome: Cache_Client_Outcome) {
	recv_buf := make([]u8, object_cache.FRAME_HEADER_SIZE + object_cache.MAX_RESPONSE_BODY_BYTES)
	defer delete(recv_buf)

	first, first_outcome := cache_client_get_frame(client, kind, object_hash, 0, recv_buf)
	if first_outcome != .Done {
		return 0, first_outcome
	}
	object_size = first.object_size
	frame_count, count_ok := object_cache.object_frame_count(object_size)
	if !count_ok {
		return 0, .Damaged_Answer
	}
	for frame_index in u64(1) ..< frame_count {
		offset := frame_index * object_cache.FRAME_PAYLOAD_BYTES
		frame_resp, frame_outcome := cache_client_get_frame(client, kind, object_hash, offset, recv_buf)
		if frame_outcome != .Done {
			return 0, frame_outcome
		}
		if frame_resp.object_size != object_size {
			return 0, .Damaged_Answer
		}
	}
	return object_size, .Done
}

@(private = "file")
parent_directory_of :: proc(path: string) -> string {
	slash := strings.last_index_byte(path, '/')
	if slash < 0 {
		return "."
	}
	if slash == 0 {
		return "/"
	}
	return path[:slash]
}

// verify_file_root streams file in FRAME_PAYLOAD_BYTES chunks using scratch_buf
// and checks that its BLAKE3 root equals expected_hash.
@(private = "file")
verify_file_root :: proc(file: ^os.File, object_size: u64, expected_hash: blake3.Hash, scratch_buf: []u8) -> bool {
	builder, start_ok := object_cache.frame_tree_builder_start(object_size)
	if !start_ok {
		return false
	}
	for frame_index in u64(0) ..< builder.frame_count {
		frame_len, len_ok := object_cache.object_frame_length(object_size, frame_index)
		if !len_ok {
			return false
		}
		slice := scratch_buf[:int(frame_len)]
		if frame_len > 0 && !file_read_exact_at(file, slice, i64(frame_index * object_cache.FRAME_PAYLOAD_BYTES)) {
			return false
		}
		parents: [object_cache.MAX_PROOF_DEPTH]object_cache.Frame_Parent
		if _, add_ok := object_cache.frame_tree_builder_add(&builder, slice, &parents); !add_ok {
			return false
		}
	}
	return builder.finished && object_cache.hashes_equal_constant_time(builder.root, expected_hash)
}

// cache_client_get_file streams a blob of any size to output_path via a
// verified .part file, keeping client memory bounded to one 1 MiB frame buffer.
// If <output_path>.<hash>.part already exists, it keeps whole aligned frames,
// downloads only the remaining frames, re-hashes the whole file before rename,
// and atomically renames to output_path only when the root matches.
cache_client_get_file :: proc(
	client: ^Cache_Client,
	object_hash: blake3.Hash,
	output_path: string,
) -> (object_size: u64, resumed_bytes: u64, outcome: Cache_Client_Outcome) {
	if output_path == "" || object_cache.hash_is_zero(object_hash) {
		return 0, 0, .Bad_Request
	}
	hex_bytes := hash_to_hex(object_hash)
	part_path := fmt.tprintf("%s.%s.part", output_path, string(hex_bytes[:]))

	recv_buf := make([]u8, object_cache.FRAME_HEADER_SIZE + object_cache.MAX_RESPONSE_BODY_BYTES)
	defer delete(recv_buf)

	part_file: ^os.File
	keep_bytes: u64 = 0
	start_frame: u64 = 0

	if os.exists(part_path) {
		opened, open_err := os.open(part_path, {.Read, .Write})
		if open_err == nil {
			existing_size, sz_err := os.file_size(opened)
			if sz_err == nil && existing_size > 0 {
				aligned := u64(existing_size) - (u64(existing_size) % object_cache.FRAME_PAYLOAD_BYTES)
				if u64(existing_size) != aligned {
					_ = os.truncate(opened, i64(aligned))
				}
				keep_bytes = aligned
				start_frame = aligned / object_cache.FRAME_PAYLOAD_BYTES
				part_file = opened
			} else {
				_ = os.close(opened)
			}
		}
	}
	defer if part_file != nil {
		_ = os.close(part_file)
	}

	first, first_outcome := cache_client_get_frame(client, .Blob, object_hash, start_frame * object_cache.FRAME_PAYLOAD_BYTES, recv_buf)
	// If a stale .part file reached or passed the true object size, restart from offset 0.
	if first_outcome == .Out_Of_Range && start_frame > 0 {
		keep_bytes = 0
		start_frame = 0
		if part_file != nil {
			_ = os.truncate(part_file, 0)
		}
		first, first_outcome = cache_client_get_frame(client, .Blob, object_hash, 0, recv_buf)
	}
	if first_outcome != .Done {
		return 0, 0, first_outcome
	}

	object_size = first.object_size
	frame_count, count_ok := object_cache.object_frame_count(object_size)
	if !count_ok {
		return 0, 0, .Damaged_Answer
	}

	// Check free disk space in the destination directory before writing.
	needed := object_size > keep_bytes ? object_size - keep_bytes : 0
	if free_bytes, free_known := cache_disk_free_bytes(parent_directory_of(output_path)); free_known {
		if needed > free_bytes {
			return 0, 0, .Too_Large
		}
	}

	if part_file == nil {
		created, create_err := os.create(part_path)
		if create_err != nil {
			return 0, 0, .Local_File_Fault
		}
		part_file = created
	}

	if len(first.payload) > 0 && !file_write_all_at(part_file, first.payload, i64(first.offset)) {
		return 0, 0, .Local_File_Fault
	}

	for frame_index in start_frame + 1 ..< frame_count {
		offset := frame_index * object_cache.FRAME_PAYLOAD_BYTES
		frame_resp, frame_outcome := cache_client_get_frame(client, .Blob, object_hash, offset, recv_buf)
		if frame_outcome != .Done {
			// Keep already-verified frames in part_path so a later run can resume.
			return 0, keep_bytes, frame_outcome
		}
		if frame_resp.object_size != object_size {
			return 0, keep_bytes, .Damaged_Answer
		}
		if len(frame_resp.payload) > 0 && !file_write_all_at(part_file, frame_resp.payload, i64(offset)) {
			return 0, keep_bytes, .Local_File_Fault
		}
	}

	// The frames kept from an earlier run were checked then, but a file on the
	// disk is not a check: another program or a fault of the disk changes it.
	// So a resumed file is hashed whole once more before its rename.
	if keep_bytes > 0 {
		if !verify_file_root(part_file, object_size, object_hash, recv_buf) {
			_ = os.close(part_file)
			part_file = nil
			_ = os.remove(part_path)
			return 0, 0, .Hash_Mismatch
		}
	}

	if close_err := os.close(part_file); close_err != nil {
		part_file = nil
		return 0, keep_bytes, .Local_File_Fault
	}
	part_file = nil

	if rename_err := os.rename(part_path, output_path); rename_err != nil {
		return 0, keep_bytes, .Local_File_Fault
	}
	return object_size, keep_bytes, .Done
}

// cache_client_realisation_check keeps a realisation only when it names the
// recipe asked, its signer is the trusted signer that the caller gave (never
// the key that the answer carries alone), and its signature verifies.
cache_client_realisation_check :: proc(
	asked_recipe: blake3.Hash,
	trusted_signer: [object_cache.PUBLIC_KEY_SIZE]u8,
	record: ^object_cache.Realisation_Record,
) -> Cache_Client_Outcome {
	if !object_cache.hashes_equal_constant_time(record.recipe_hash, asked_recipe) {
		return .Damaged_Answer
	}
	if !object_cache.hashes_equal_constant_time(record.signer_public_key, trusted_signer) {
		return .Untrusted_Signer
	}
	signing_bytes, signing_ok := object_cache.realisation_signing_bytes(record)
	if !signing_ok {
		return .Damaged_Answer
	}
	if !cache_server_verify_ed25519(trusted_signer, signing_bytes[:], record.signature) {
		return .Bad_Signature
	}
	return .Done
}

// cache_client_get_realisation gets the realisation of a recipe and checks it
// against the trusted signer.
cache_client_get_realisation :: proc(
	client: ^Cache_Client,
	recipe_hash: blake3.Hash,
	trusted_signer: [object_cache.PUBLIC_KEY_SIZE]u8,
) -> (record: object_cache.Realisation_Record, outcome: Cache_Client_Outcome) {
	request := object_cache.Cache_Request {
		kind        = .Get_Realisation,
		recipe_hash = recipe_hash,
	}
	frame, response, exchange_outcome := cache_client_exchange(client, &request)
	defer delete(frame)
	if exchange_outcome != .Done {
		return {}, exchange_outcome
	}
	record = response.realisation
	if check := cache_client_realisation_check(recipe_hash, trusted_signer, &record); check != .Done {
		return {}, check
	}
	return record, .Done
}

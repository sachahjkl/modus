// The client of the binary object cache protocol: the commands cache-put and
// cache-get use it, and the host tests drive cache-serve through it
// (src/md/infrastructure/cache_publication.md, "The client").
package cache_server

import "core:fmt"
import "core:net"
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
	Server_Refused   = 5, // The server answered a status other than Ok and Not_Found.
	Hash_Mismatch    = 6,
	Untrusted_Signer = 7,
	Bad_Signature    = 8,
	Too_Large        = 9, // A payload past the bound of its kind, refused before it leaves the host.
	Bad_Request      = 10, // A request that the protocol refuses, refused before it leaves the host.
	Deadline_Passed  = 11, // The request and its whole answer took longer than the bound of one exchange.
}

// One connection to an object cache.
Cache_Client :: struct {
	socket:        net.TCP_Socket,
	// The bound of one exchange: the send of a request and the read of its
	// whole answer. A bound on each read alone lets a server that sends one
	// byte before each timeout hold the client for hours.
	exchange_bound: time.Duration,
	// The last status of the server, for the sentence of a refusal.
	server_status: object_cache.Cache_Response_Status,
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
		case .Refused, .Ok, .Not_Found:
			return "the object cache refused it"
		}
	case .Hash_Mismatch:
		return "the bytes that the object cache gave do not have the hash that was asked"
	case .Untrusted_Signer:
		return "the realisation is signed by another key than the trusted signer"
	case .Bad_Signature:
		return "the signature of the realisation does not verify"
	case .Too_Large:
		return fmt.tprintf("the object is larger than the %d bytes that one object can hold", object_cache.MAX_OBJECT_PAYLOAD_BYTES)
	case .Bad_Request:
		return "the protocol refuses the request"
	case .Deadline_Passed:
		return "the object cache did not give its whole answer within the bound of one exchange"
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

// cache_client_read_answer reads one answer frame before the deadline. It
// refuses the head before it allocates: a wrong magic or version, a kind or
// a status that names no member, a nonzero reserved byte, a body past
// MAX_RESPONSE_BODY_BYTES.
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
		case .Has, .Put_Object, .Put_Realisation:
			return .Damaged_Answer
		}
		return .Damaged_Answer
	case .Refused, .Too_Large, .Bad_Hash, .Bad_Signature, .Unauthorized:
		return .Server_Refused
	}
	return .Damaged_Answer
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
	// A put frame holds up to 16 MiB: it is freed here, not left to the
	// temporary allocator of a caller that puts a whole release.
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

// cache_client_put_object puts one object, signed by the uploader key. A
// payload past the bound of its kind, or bytes that are not of their kind,
// never leave the host.
cache_client_put_object :: proc(
	client: ^Cache_Client,
	uploader: ^ed25519.Private_Key,
	kind: object_cache.Cache_Object_Kind,
	payload: []u8,
) -> (object_hash: blake3.Hash, outcome: Cache_Client_Outcome) {
	if _, kind_ok := object_cache.cache_object_kind_of_word(u64(kind)); !kind_ok {
		return {}, .Bad_Request
	}
	if len(payload) > object_cache.payload_bound_for_kind(kind) {
		return {}, .Too_Large
	}
	switch kind {
	case .Blob:
		object_hash = blake3.hash(payload)
	case .Tree:
		tree_digest, tree_refusal := tree_hash.tree_hash(payload)
		if tree_refusal != .None {
			return {}, .Bad_Request
		}
		object_hash = tree_digest
	}
	request := object_cache.Cache_Request {
		kind        = .Put_Object,
		object_hash = object_hash,
		object_kind = kind,
		payload     = payload,
	}
	ed25519.private_key_public_bytes(uploader, request.uploader_public_key[:])
	signing_bytes, signing_ok := object_cache.put_object_signing_bytes(kind, object_hash, u64(len(payload)), request.uploader_public_key)
	if !signing_ok {
		return {}, .Bad_Request
	}
	ed25519.sign(uploader, signing_bytes[:], request.uploader_signature[:])
	frame, _, exchange_outcome := cache_client_exchange(client, &request)
	delete(frame)
	return object_hash, exchange_outcome
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

// cache_client_object_check keeps an answer to Get_Object only when its
// kind is the kind asked and its bytes have the hash asked. The client
// trusts no server.
cache_client_object_check :: proc(
	asked_kind: object_cache.Cache_Object_Kind,
	asked_hash: blake3.Hash,
	response: ^object_cache.Cache_Response,
) -> Cache_Client_Outcome {
	if response.object_kind != asked_kind {
		return .Damaged_Answer
	}
	switch object_cache.verify_object_content(asked_kind, asked_hash, response.payload) {
	case .Trust_By_Hash:
		return .Done
	case .Refuse_Hash_Mismatch:
		return .Hash_Mismatch
	case .Refuse_Malformed, .Trust_By_Signer, .Refuse_Untrusted_Signer, .Refuse_Bad_Signature:
		return .Damaged_Answer
	}
	return .Damaged_Answer
}

// cache_client_get_object gets one object and checks its hash. The bytes
// are allocated with allocator.
cache_client_get_object :: proc(
	client: ^Cache_Client,
	kind: object_cache.Cache_Object_Kind,
	object_hash: blake3.Hash,
	allocator := context.allocator,
) -> (payload: []u8, outcome: Cache_Client_Outcome) {
	request := object_cache.Cache_Request {
		kind        = .Get_Object,
		object_kind = kind,
		object_hash = object_hash,
	}
	// The frame can hold 16 MiB: it is freed here, not left to the
	// temporary allocator of a caller that gets many objects.
	frame, response, exchange_outcome := cache_client_exchange(client, &request)
	defer delete(frame)
	if exchange_outcome != .Done {
		return nil, exchange_outcome
	}
	if check := cache_client_object_check(kind, object_hash, &response); check != .Done {
		return nil, check
	}
	payload = make([]u8, len(response.payload), allocator)
	copy(payload, response.payload)
	return payload, .Done
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

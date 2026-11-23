package cache_server

import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "modus:contract/blake3"
import "modus:contract/object_cache"
import "modustool:foundation"

// A deadline for the head that a test can pass in a slow head, short so
// that the test of the deadline ends soon. The tests assert the outcome,
// never a time.
@(private = "file")
TEST_DEADLINE :: 300 * time.Millisecond

@(private = "file")
Status_Test :: struct {
	directory: string,
	server:    Cache_Server,
	running:   ^Cache_Status_Running,
	endpoint:  net.Endpoint,
}

@(private = "file")
status_test_start :: proc(t: ^testing.T, authorized: [][object_cache.PUBLIC_KEY_SIZE]u8) -> ^Status_Test {
	test := new(Status_Test)
	test.directory = make_temp_store_dir(t)
	open_ok: bool
	test.server, open_ok = cache_server_open(test.directory, authorized)
	testing.expect(t, open_ok)
	socket, listen_error := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect_value(t, listen_error, nil)
	bound_error: net.Network_Error
	test.endpoint, bound_error = net.bound_endpoint(socket)
	testing.expect_value(t, bound_error, nil)
	// The settings are values of this frame: the start keeps its own copy.
	settings := Cache_Page_Settings{endpoint = strings.clone("cache.example:5010", context.temp_allocator), site_address = DEFAULT_SITE_ADDRESS}
	test.running = cache_status_start(&test.server, settings, socket, TEST_DEADLINE)
	return test
}

@(private = "file")
status_test_stop :: proc(test: ^Status_Test) {
	sync.atomic_store(&test.server.stop, true)
	cache_status_stop(test.running)
	cache_server_destroy(&test.server)
	_ = os.remove_all(test.directory)
	delete(test.directory)
	free(test)
}

// status_exchange sends bytes on one connection, then reads the whole answer
// until the server closes. With end_send, the client also ends its side.
@(private = "file")
status_exchange :: proc(t: ^testing.T, test: ^Status_Test, request: []u8, end_send := false) -> string {
	client, dial_error := net.dial_tcp(test.endpoint)
	testing.expect_value(t, dial_error, nil)
	defer net.close(client)
	_ = net.set_option(client, .Receive_Timeout, foundation.HANG_BOUND)
	if len(request) > 0 {
		testing.expect(t, tcp_write_all(client, request))
	}
	if end_send {
		_ = net.shutdown(client, .Send)
	}
	answer := strings.builder_make(context.temp_allocator)
	buffer: [4096]u8
	for {
		count, receive_error := net.recv_tcp(client, buffer[:])
		if receive_error != .None || count == 0 {
			break
		}
		strings.write_bytes(&answer, buffer[:count])
	}
	return strings.to_string(answer)
}

@(private = "file")
answer_line :: proc(answer: string) -> string {
	end := strings.index(answer, "\r\n")
	return end < 0 ? answer : answer[:end]
}

@(private = "file")
answer_body :: proc(answer: string) -> string {
	end := strings.index(answer, "\r\n\r\n")
	return end < 0 ? "" : answer[end + 4:]
}

@(private = "file")
head_bytes :: proc(text: string) -> []u8 {
	return transmute([]u8)text
}

@(test)
status_parse_refuses_each_malformed_head :: proc(t: ^testing.T) {
	Case :: struct {
		head:   string,
		answer: Status_Answer,
	}
	cases := [?]Case {
		// The bytes before any field.
		{"", .Bad_Request},
		{"\r\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1\r\n\r", .Bad_Request},
		{"GET /\x00 HTTP/1.1\r\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1\r\nHost: a\x00b\r\n\r\n", .Bad_Request},
		{"GET /\x80 HTTP/1.1\r\n\r\n", .Bad_Request},
		{"GET /\x7f HTTP/1.1\r\n\r\n", .Bad_Request},
		{"GET /\x1b HTTP/1.1\r\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1\r\r\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\n\r\n", .Bad_Request},
		// The request line.
		{"GET\r\n\r\n", .Bad_Request},
		{"GET /\r\n\r\n", .Bad_Request},
		{" GET / HTTP/1.1\r\n\r\n", .Bad_Request},
		{"GET  / HTTP/1.1\r\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1 \r\n\r\n", .Bad_Request},
		{"GET / HTTP/2\r\n\r\n", .Bad_Request},
		{"GET / http/1.1\r\n\r\n", .Bad_Request},
		{"get / HTTP/1.1\r\n\r\n", .Bad_Request},
		{"G-T / HTTP/1.1\r\n\r\n", .Bad_Request},
		{"GET /\t HTTP/1.1\r\n\r\n", .Bad_Request},
		// The header lines.
		{"GET / HTTP/1.1\r\nHost\r\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1\r\n: a\r\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1\r\nHo st: a\r\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1\r\nHost : a\r\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1\r\nHost: a\r\n b\r\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1\r\nHost: a\r\n\tb\r\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1\r\ncontent-length: 5\r\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", .Bad_Request},
		{"GET / HTTP/1.1\r\nTRANSFER-ENCODING: chunked\r\n\r\n", .Bad_Request},
		// The method, after a well-formed head.
		{"POST / HTTP/1.1\r\n\r\n", .Method_Not_Allowed},
		{"HEAD / HTTP/1.1\r\n\r\n", .Method_Not_Allowed},
		{"PUT /status.json HTTP/1.1\r\n\r\n", .Method_Not_Allowed},
		{"DELETE /style.css HTTP/1.0\r\n\r\n", .Method_Not_Allowed},
		{"GETS / HTTP/1.1\r\n\r\n", .Method_Not_Allowed},
		// The path: compared whole, never decoded.
		{"GET /index.html HTTP/1.1\r\n\r\n", .Not_Found},
		{"GET // HTTP/1.1\r\n\r\n", .Not_Found},
		{"GET /? HTTP/1.1\r\n\r\n", .Not_Found},
		{"GET /status.json?x=1 HTTP/1.1\r\n\r\n", .Not_Found},
		{"GET /status.json/ HTTP/1.1\r\n\r\n", .Not_Found},
		{"GET /STATUS.JSON HTTP/1.1\r\n\r\n", .Not_Found},
		{"GET /../objects HTTP/1.1\r\n\r\n", .Not_Found},
		{"GET /./status.json HTTP/1.1\r\n\r\n", .Not_Found},
		{"GET /%2e%2e/objects HTTP/1.1\r\n\r\n", .Not_Found},
		{"GET /%2E%2E/realisations HTTP/1.1\r\n\r\n", .Not_Found},
		{"GET /%2fstatus.json HTTP/1.1\r\n\r\n", .Not_Found},
		{"GET /objects/0000000000000000000000000000000000000000000000000000000000000000 HTTP/1.1\r\n\r\n", .Not_Found},
		{"GET http://host/ HTTP/1.1\r\n\r\n", .Not_Found},
		{"GET * HTTP/1.1\r\n\r\n", .Not_Found},
	}
	for item in cases {
		_, answer := status_request_parse(head_bytes(item.head))
		testing.expectf(t, answer == item.answer, "%q: %v, expected %v", item.head, answer, item.answer)
	}
	// The three paths, last: with a header, with HTTP/1.0, with no header.
	path, answer := status_request_parse(head_bytes("GET / HTTP/1.1\r\nHost: cache.example\r\nAccept: */*\r\n\r\n"))
	testing.expect_value(t, answer, Status_Answer.Ok)
	testing.expect_value(t, path, Status_Path.Page)
	path, answer = status_request_parse(head_bytes("GET /status.json HTTP/1.0\r\n\r\n"))
	testing.expect_value(t, answer, Status_Answer.Ok)
	testing.expect_value(t, path, Status_Path.Status_Record)
	path, answer = status_request_parse(head_bytes("GET /style.css HTTP/1.1\r\n\r\n"))
	testing.expect_value(t, answer, Status_Answer.Ok)
	testing.expect_value(t, path, Status_Path.Style_Sheet)
}

@(test)
status_page_settings_refuse_unsafe_values :: proc(t: ^testing.T) {
	bad_endpoints := [?]string{"", ":5010", "cache.example", "cache example:5010", "cache.example:5010\r\nX: y", "<b>:1", "a\"b:1", "a;b:1", "a/b:1"}
	for value in bad_endpoints {
		testing.expectf(t, !cache_page_endpoint_valid(value), "endpoint %q", value)
	}
	bad_sites := [?]string{"", "modus.systems", "ftp://modus.systems", "https://", "https:///x", "https://a b", "https://a\"b", "https://a;b", "https://a'b", "https://a<b", "https://a?b", "https://a#b", "javascript:alert(1)", "https://a\x7fb"}
	for value in bad_sites {
		testing.expectf(t, !cache_page_site_address_valid(value), "site %q", value)
	}
	testing.expect(t, cache_page_endpoint_valid("cache.modus.systems:5010"))
	testing.expect(t, cache_page_endpoint_valid("[::1]:5010"))
	testing.expect(t, cache_page_site_address_valid("https://modus.systems"))
	testing.expect(t, cache_page_site_address_valid("http://127.0.0.1:8000/site"))

	// The command refuses them before it opens any store.
	testing.expect_value(t, run_cache_serve([]string{"--dir", "/nonexistent", "--endpoint", "a b:1"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_serve([]string{"--dir", "/nonexistent", "--site", "https://a;b"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_serve([]string{"--dir", "/nonexistent", "--status-listen"}), foundation.EXIT_USAGE)
}

@(test)
status_reader_refuses_on_the_socket :: proc(t: ^testing.T) {
	test := status_test_start(t, nil)
	defer status_test_stop(test)

	// A head past the bound: 431, and no byte of it comes back.
	long_head := strings.concatenate({"GET / HTTP/1.1\r\nX-Filler: ", strings.repeat("q", STATUS_HEAD_BOUND, context.temp_allocator)}, context.temp_allocator)
	answer := status_exchange(t, test, head_bytes(long_head))
	testing.expect_value(t, answer_line(answer), "HTTP/1.1 431 Request Header Fields Too Large")
	testing.expect(t, !strings.contains(answer, "qqqq"))
	testing.expect_value(t, answer_body(answer), "")

	// The edges of the bound: a whole head of exactly the bound is read; one
	// byte more is refused.
	at_bound_prefix := "GET / HTTP/1.1\r\nX-Filler: "
	at_bound := strings.concatenate({at_bound_prefix, strings.repeat("q", STATUS_HEAD_BOUND - len(at_bound_prefix) - 4, context.temp_allocator), "\r\n\r\n"}, context.temp_allocator)
	testing.expect_value(t, len(at_bound), STATUS_HEAD_BOUND)
	testing.expect_value(t, answer_line(status_exchange(t, test, head_bytes(at_bound))), "HTTP/1.1 200 OK")
	past_bound := strings.concatenate({at_bound_prefix, strings.repeat("q", STATUS_HEAD_BOUND - len(at_bound_prefix) - 3, context.temp_allocator), "\r\n\r\n"}, context.temp_allocator)
	testing.expect_value(t, answer_line(status_exchange(t, test, head_bytes(past_bound))), "HTTP/1.1 431 Request Header Fields Too Large")

	// A slow head that never ends: 408 after the deadline.
	testing.expect_value(t, answer_line(status_exchange(t, test, head_bytes("GET / HT"))), "HTTP/1.1 408 Request Timeout")
	testing.expect_value(t, answer_line(status_exchange(t, test, head_bytes("GET / HTTP/1.1\r\nHost: a\r\n"))), "HTTP/1.1 408 Request Timeout")
	// A connection that sends nothing: 408 too.
	testing.expect_value(t, answer_line(status_exchange(t, test, nil)), "HTTP/1.1 408 Request Timeout")
	// A head with no end, then the client closes its side: no answer.
	testing.expect_value(t, status_exchange(t, test, head_bytes("GET / HTTP/1.1\r\nHost: a\r\n"), end_send = true), "")

	// A NUL byte, a byte past ASCII and a bare line feed end the read at
	// once, before the deadline would: 400.
	testing.expect_value(t, answer_line(status_exchange(t, test, head_bytes("GET /\x00"))), "HTTP/1.1 400 Bad Request")
	testing.expect_value(t, answer_line(status_exchange(t, test, head_bytes("GET /\xff"))), "HTTP/1.1 400 Bad Request")
	testing.expect_value(t, answer_line(status_exchange(t, test, head_bytes("GET / HTTP/1.1\n"))), "HTTP/1.1 400 Bad Request")

	// A method other than GET: 405, with the method that is allowed.
	answer = status_exchange(t, test, head_bytes("POST /status.json HTTP/1.1\r\n\r\n"))
	testing.expect_value(t, answer_line(answer), "HTTP/1.1 405 Method Not Allowed")
	testing.expect(t, strings.contains(answer, "\r\nAllow: GET\r\n"))
	testing.expect_value(t, answer_body(answer), "")

	// A path outside the set, with '..' or '%2e': 404 with no body.
	paths := [?]string{"/objects", "/../objects", "/%2e%2e/objects", "/status.json?x=1", "/style.css%00"}
	for path in paths {
		answer = status_exchange(t, test, head_bytes(strings.concatenate({"GET ", path, " HTTP/1.1\r\n\r\n"}, context.temp_allocator)))
		testing.expectf(t, answer_line(answer) == "HTTP/1.1 404 Not Found", "%s: %s", path, answer_line(answer))
		testing.expect_value(t, answer_body(answer), "")
		testing.expect(t, !strings.contains(answer, path))
	}

	// A body: 400.
	testing.expect_value(t, answer_line(status_exchange(t, test, head_bytes("GET / HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcd"))), "HTTP/1.1 400 Bad Request")

	// Two requests on one connection: one answer, then the server closes.
	answer = status_exchange(t, test, head_bytes("GET /style.css HTTP/1.1\r\n\r\nGET /status.json HTTP/1.1\r\n\r\n"))
	testing.expect_value(t, strings.count(answer, "HTTP/1.1 "), 1)
	testing.expect_value(t, answer_line(answer), "HTTP/1.1 200 OK")
	testing.expect(t, strings.contains(answer, "\r\nContent-Type: text/css; charset=utf-8\r\n"))
	testing.expect(t, strings.contains(answer, "\r\nConnection: close\r\n"))
}

@(private = "file")
put_frame :: proc(t: ^testing.T, server: ^Cache_Server, request: ^object_cache.Cache_Request) -> object_cache.Cache_Response_Status {
	frame := encode_req_alloc(t, request)
	defer delete(frame)
	answer, status := cache_server_handle_frame(server, frame)
	delete(answer)
	return status
}

@(test)
status_counts_follow_each_write :: proc(t: ^testing.T) {
	directory := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	private_key, public_key, _ := make_test_keypair(0x21)
	stranger_key, stranger_public, _ := make_test_keypair(0x77)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{public_key}

	// A file of the store whose name is no hash is not counted.
	testing.expect(t, foundation.make_folder(strings.concatenate({directory, "/objects"}, context.temp_allocator)))
	testing.expect_value(t, os.write_entire_file(strings.concatenate({directory, "/objects/notes.txt"}, context.temp_allocator), transmute([]u8)string("x")), nil)

	server, open_ok := cache_server_open(directory, authorized[:])
	testing.expect(t, open_ok)
	snapshot := cache_status_snapshot(&server.status)
	testing.expect_value(t, snapshot.counts, Store_Counts{last_write = snapshot.counts.last_write})
	testing.expect_value(t, snapshot.counts.objects, 0)
	testing.expect_value(t, snapshot.recent_count, 0)

	payload := transmute([]u8)string("an object of the page test")
	object_hash := blake3.hash(payload)

	// A refused put changes nothing: an unknown key, a bad signature, a
	// wrong hash.
	stranger_put := make_signed_put_object_request(.Blob, object_hash, payload, &stranger_key, stranger_public)
	testing.expect_value(t, put_frame(t, &server, &stranger_put), object_cache.Cache_Response_Status.Unauthorized)
	forged_put := make_signed_put_object_request(.Blob, object_hash, payload, &private_key, public_key)
	forged_put.uploader_signature[0] ~= 1
	testing.expect_value(t, put_frame(t, &server, &forged_put), object_cache.Cache_Response_Status.Bad_Signature)
	wrong_hash := blake3.hash(transmute([]u8)string("other bytes"))
	wrong_put := make_signed_put_object_request(.Blob, wrong_hash, payload, &private_key, public_key)
	testing.expect_value(t, put_frame(t, &server, &wrong_put), object_cache.Cache_Response_Status.Bad_Hash)
	before := cache_status_snapshot(&server.status)
	testing.expect_value(t, before.counts, snapshot.counts)

	// A put of an object: one more object and its bytes.
	object_put := make_signed_put_object_request(.Blob, object_hash, payload, &private_key, public_key)
	testing.expect_value(t, put_frame(t, &server, &object_put), object_cache.Cache_Response_Status.Ok)
	after_object := cache_status_snapshot(&server.status)
	testing.expect_value(t, after_object.counts.objects, 1)
	testing.expect_value(t, after_object.counts.object_bytes, u64(len(payload)))
	testing.expect(t, after_object.counts.last_write._nsec != 0)

	// The same object again adds nothing.
	testing.expect_value(t, put_frame(t, &server, &object_put), object_cache.Cache_Response_Status.Ok)
	testing.expect_value(t, cache_status_snapshot(&server.status).counts.objects, 1)
	testing.expect_value(t, cache_status_snapshot(&server.status).counts.object_bytes, u64(len(payload)))

	// A refused realisation changes nothing.
	recipe_hash := blake3.hash(transmute([]u8)string("a recipe of the page test"))
	stranger_record := make_signed_realisation_record(recipe_hash, object_hash, .Blob, &stranger_key, stranger_public)
	stranger_realisation := object_cache.Cache_Request{kind = .Put_Realisation, realisation = stranger_record}
	testing.expect_value(t, put_frame(t, &server, &stranger_realisation), object_cache.Cache_Response_Status.Unauthorized)
	testing.expect_value(t, cache_status_snapshot(&server.status).counts.realisations, 0)
	testing.expect_value(t, cache_status_snapshot(&server.status).recent_count, 0)

	// A put of a realisation: one more, at the top of the list.
	record := make_signed_realisation_record(recipe_hash, object_hash, .Blob, &private_key, public_key)
	realisation_put := object_cache.Cache_Request{kind = .Put_Realisation, realisation = record}
	testing.expect_value(t, put_frame(t, &server, &realisation_put), object_cache.Cache_Response_Status.Ok)
	after_realisation := cache_status_snapshot(&server.status)
	testing.expect_value(t, after_realisation.counts.realisations, 1)
	testing.expect_value(t, after_realisation.counts.realisation_bytes, u64(object_cache.REALISATION_WIRE_SIZE))
	testing.expect_value(t, after_realisation.recent_count, 1)
	testing.expect_value(t, after_realisation.recent[0].record.recipe_hash, recipe_hash)

	// The same recipe again keeps one entry of the list and one count.
	testing.expect_value(t, put_frame(t, &server, &realisation_put), object_cache.Cache_Response_Status.Ok)
	testing.expect_value(t, cache_status_snapshot(&server.status).counts.realisations, 1)
	testing.expect_value(t, cache_status_snapshot(&server.status).recent_count, 1)

	// More realisations than the list holds: the list keeps the newest.
	for index in 0 ..< RECENT_REALISATION_COUNT + 2 {
		other_recipe := blake3.hash(transmute([]u8)strings.repeat("r", index + 1, context.temp_allocator))
		other := make_signed_realisation_record(other_recipe, object_hash, .Blob, &private_key, public_key)
		other_put := object_cache.Cache_Request{kind = .Put_Realisation, realisation = other}
		testing.expect_value(t, put_frame(t, &server, &other_put), object_cache.Cache_Response_Status.Ok)
	}
	full := cache_status_snapshot(&server.status)
	testing.expect_value(t, full.counts.realisations, u64(RECENT_REALISATION_COUNT + 3))
	testing.expect_value(t, full.recent_count, RECENT_REALISATION_COUNT)
	newest_recipe := blake3.hash(transmute([]u8)strings.repeat("r", RECENT_REALISATION_COUNT + 2, context.temp_allocator))
	testing.expect_value(t, full.recent[0].record.recipe_hash, newest_recipe)
	cache_server_destroy(&server)

	// A new open counts the same store from its listing.
	reopened, reopen_ok := cache_server_open(directory, authorized[:])
	testing.expect(t, reopen_ok)
	defer cache_server_destroy(&reopened)
	counted := cache_status_snapshot(&reopened.status)
	testing.expect_value(t, counted.counts.objects, full.counts.objects)
	testing.expect_value(t, counted.counts.object_bytes, full.counts.object_bytes)
	testing.expect_value(t, counted.counts.realisations, full.counts.realisations)
	testing.expect_value(t, counted.counts.realisation_bytes, full.counts.realisation_bytes)
	testing.expect_value(t, counted.recent_count, RECENT_REALISATION_COUNT)
}

@(test)
status_answers_the_page_the_record_and_the_style_sheet :: proc(t: ^testing.T) {
	private_key, public_key, _ := make_test_keypair(0x31)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{public_key}
	test := status_test_start(t, authorized[:])
	defer status_test_stop(test)

	payload := transmute([]u8)string("an object that the page counts")
	object_hash := blake3.hash(payload)
	object_put := make_signed_put_object_request(.Blob, object_hash, payload, &private_key, public_key)
	testing.expect_value(t, put_frame(t, &test.server, &object_put), object_cache.Cache_Response_Status.Ok)
	recipe_hash := blake3.hash(transmute([]u8)string("the recipe that the page lists"))
	record := make_signed_realisation_record(recipe_hash, object_hash, .Blob, &private_key, public_key)
	realisation_put := object_cache.Cache_Request{kind = .Put_Realisation, realisation = record}
	testing.expect_value(t, put_frame(t, &test.server, &realisation_put), object_cache.Cache_Response_Status.Ok)
	key_hex := hash_to_hex(public_key)
	recipe_hex := hash_to_hex(recipe_hash)

	page := status_exchange(t, test, head_bytes("GET / HTTP/1.1\r\nHost: cache.example\r\n\r\n"))
	testing.expect_value(t, answer_line(page), "HTTP/1.1 200 OK")
	testing.expect(t, strings.contains(page, "\r\nContent-Type: text/html; charset=utf-8\r\n"))
	testing.expect(t, strings.contains(page, "\r\nContent-Security-Policy: default-src 'none'; style-src 'self';"))
	body := answer_body(page)
	testing.expect(t, strings.contains(body, "<title>public object cache - modus</title>"))
	testing.expect(t, strings.contains(body, "<h1>public object cache</h1>"))
	testing.expect(t, strings.contains(body, string(key_hex[:])))
	testing.expect(t, strings.contains(body, "cache.example:5010"))
	testing.expect(t, strings.contains(body, string(recipe_hex[:CACHE_PAGE_HASH_DIGITS])))
	testing.expect(t, !strings.contains(body, "<script"))
	testing.expect(t, !strings.contains(body, "Modus"))
	// The host is an object cache, never "the cache"; "the cache protocol"
	// names the protocol.
	testing.expect_value(t, strings.count(body, "the cache"), strings.count(body, "the cache protocol"))

	record_answer := status_exchange(t, test, head_bytes("GET /status.json HTTP/1.1\r\n\r\n"))
	testing.expect_value(t, answer_line(record_answer), "HTTP/1.1 200 OK")
	json := answer_body(record_answer)
	testing.expect(t, strings.contains(json, "\"objects\": 1,"))
	testing.expect(t, strings.contains(json, "\"realisations\": 1,"))
	testing.expect(t, strings.contains(json, strings.concatenate({"\"recipe\": \"", string(recipe_hex[:]), "\""}, context.temp_allocator)))
	testing.expect(t, strings.contains(json, strings.concatenate({"\"signer_keys\": [\"", string(key_hex[:]), "\"]"}, context.temp_allocator)))

	style := status_exchange(t, test, head_bytes("GET /style.css HTTP/1.1\r\n\r\n"))
	testing.expect_value(t, answer_line(style), "HTTP/1.1 200 OK")
	testing.expect(t, strings.contains(answer_body(style), "url(\"https://modus.systems/fonts/"))
	testing.expect(t, !strings.contains(answer_body(style), "url(\"fonts/"))
}

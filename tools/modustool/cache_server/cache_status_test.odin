package cache_server

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "modus:contract/blake3"
import "modus:contract/object_cache"
import "modustool:foundation"

// The deadline of the cases that must reach it: a head that never ends, a
// client that never reads, a client that reads slowly. Every other case
// runs under the hang bound, so no success depends on the speed of the
// host. The tests assert the outcome, never a time.
@(private = "file")
SHORT_DEADLINE :: 500 * time.Millisecond

@(private)
Status_Test :: struct {
	directory: string,
	server:    Cache_Server,
	running:   ^Cache_Status_Running,
	endpoint:  net.Endpoint,
}

// status_test_start starts the page of a fresh store. A style sheet of a
// test takes the place of the style sheet of the site before the thread
// starts, so a test can make an answer larger than the buffers of the
// system.
@(private)
status_test_start :: proc(t: ^testing.T, authorized: [][object_cache.PUBLIC_KEY_SIZE]u8, deadline := foundation.HANG_BOUND, style_sheet := "") -> ^Status_Test {
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
	test.running = cache_status_prepare(&test.server, settings, socket, deadline)
	if style_sheet != "" {
		delete(test.running.status_listener.style_sheet)
		test.running.status_listener.style_sheet = strings.clone(style_sheet)
	}
	testing.expect(t, cache_status_run(test.running))
	return test
}

@(private)
status_test_stop :: proc(test: ^Status_Test) {
	sync.atomic_store(&test.server.stop, true)
	cache_status_stop(test.running)
	cache_server_destroy(&test.server)
	_ = os.remove_all(test.directory)
	delete(test.directory)
	free(test)
}

@(private = "file")
status_dial :: proc(t: ^testing.T, test: ^Status_Test) -> net.TCP_Socket {
	client, dial_error := net.dial_tcp(test.endpoint)
	testing.expect_value(t, dial_error, nil)
	_ = net.set_option(client, .Receive_Timeout, foundation.HANG_BOUND)
	return client
}

// status_read_to_end reads until the server closes or the hang bound.
@(private = "file")
status_read_to_end :: proc(client: net.TCP_Socket) -> string {
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

// status_exchange sends bytes on one connection, then reads the whole answer
// until the server closes. With end_send, the client also ends its side.
@(private)
status_exchange :: proc(t: ^testing.T, test: ^Status_Test, request: []u8, end_send := false) -> string {
	client := status_dial(t, test)
	defer net.close(client)
	if len(request) > 0 {
		testing.expect(t, tcp_write_all(client, request))
	}
	if end_send {
		_ = net.shutdown(client, .Send)
	}
	return status_read_to_end(client)
}

@(private)
answer_line :: proc(answer: string) -> string {
	end := strings.index(answer, "\r\n")
	return end < 0 ? answer : answer[:end]
}

@(private)
answer_body :: proc(answer: string) -> string {
	end := strings.index(answer, "\r\n\r\n")
	return end < 0 ? "" : answer[end + 4:]
}

@(private)
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
		{"GET / HTTP/1.1\r\nX: a\r\n\r\nY: b\r\n\r\n", .Bad_Request},
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
	request, answer := status_request_parse(head_bytes("GET / HTTP/1.1\r\nHost: cache.example\r\nAccept: */*\r\n\r\n"))
	testing.expect_value(t, answer, Status_Answer.Ok)
	testing.expect_value(t, request.path, Status_Path.Page)
	request, answer = status_request_parse(head_bytes("GET /status.json HTTP/1.0\r\n\r\n"))
	testing.expect_value(t, answer, Status_Answer.Ok)
	testing.expect_value(t, request.path, Status_Path.Status_Record)
	request, answer = status_request_parse(head_bytes("GET /style.css HTTP/1.1\r\n\r\n"))
	testing.expect_value(t, answer, Status_Answer.Ok)
	testing.expect_value(t, request.path, Status_Path.Style_Sheet)
}

@(test)
status_page_settings_refuse_unsafe_values :: proc(t: ^testing.T) {
	bad_endpoints := [?]string{"", ":5010", "host:", ":::", "[::1]", "-:1", "...:1", "a:05010", "a:00", "a-:1", "-a:1", "a..b:1", ".a:1", "a.:1", "A.example:1", "a_b:1", "1.2.3:1", "1.2.3.4.5:1", "256.1.1.1:1", "01.2.3.4:1", "1.2.3.-4:1", "cache.example", "cache example:5010", "cache.example:5010\r\nX: y", "<b>:1", "a\"b:1", "a;b:1", "a/b:1", "a:0", "a:65536", "a:123456", "a:+1", "a:1a", "a:b:1", "[zz::1]:5010", "[]:5010", "[::1:5010", "a&b:1"}
	for value in bad_endpoints {
		testing.expectf(t, !cache_page_endpoint_valid(value), "endpoint %q", value)
	}
	bad_sites := [?]string{"", "modus.systems", "ftp://modus.systems", "https://", "https:///x", "https://a b", "https://a\"b", "https://a;b", "https://a'b", "https://a<b", "https://a?b", "https://a#b", "https://a&b", "https://a\\b", "javascript:alert(1)", "https://a\x7fb", "https://a\xc3\xa9"}
	for value in bad_sites {
		testing.expectf(t, !cache_page_site_address_valid(value), "site %q", value)
	}
	// The edges of the port, last.
	testing.expect(t, cache_page_endpoint_valid("127.0.0.1:5010"))
	testing.expect(t, cache_page_endpoint_valid("0.0.0.0:1"))
	testing.expect(t, cache_page_endpoint_valid("cache-1.example:5010"))
	testing.expect(t, cache_page_endpoint_valid("1a.example:5010"))
	testing.expect(t, cache_page_endpoint_valid("a:1"))
	testing.expect(t, cache_page_endpoint_valid("a:65535"))
	testing.expect(t, cache_page_endpoint_valid("cache.modus.systems:5010"))
	testing.expect(t, cache_page_endpoint_valid("[::1]:5010"))
	testing.expect(t, cache_page_site_address_valid(DEFAULT_SITE_ADDRESS))
	testing.expect(t, cache_page_site_address_valid("http://127.0.0.1:8000/site"))

	// The command refuses them before it opens any store.
	testing.expect_value(t, run_cache_serve([]string{"--dir", "/nonexistent", "--endpoint", "a b:1"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_serve([]string{"--dir", "/nonexistent", "--endpoint", "host:"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_serve([]string{"--dir", "/nonexistent", "--site", "https://a;b"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_serve([]string{"--dir", "/nonexistent", "--site", "https://a&b"}), foundation.EXIT_USAGE)
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

	// A head with no end, then the client closes its side: no answer.
	testing.expect_value(t, status_exchange(t, test, head_bytes("GET / HTTP/1.1\r\nHost: a\r\n"), end_send = true), "")
	// A connection closed with nothing sent: no answer, and the thread goes on.
	testing.expect_value(t, status_exchange(t, test, nil, end_send = true), "")

	// A NUL byte, a byte past ASCII and a bare line feed end the read at
	// once, with no wait for the end of the head: 400.
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

	// Two requests on one connection, and a second empty line after a
	// header: the head ends at the first empty line, one answer comes, then
	// the server closes.
	answer = status_exchange(t, test, head_bytes("GET /style.css HTTP/1.1\r\n\r\nGET /status.json HTTP/1.1\r\n\r\n"))
	testing.expect_value(t, strings.count(answer, "HTTP/1.1 "), 1)
	testing.expect_value(t, answer_line(answer), "HTTP/1.1 200 OK")
	testing.expect(t, strings.contains(answer, "\r\nContent-Type: text/css; charset=utf-8\r\n"))
	testing.expect(t, strings.contains(answer, "\r\nConnection: close\r\n"))
	answer = status_exchange(t, test, head_bytes("GET /status.json HTTP/1.1\r\nX: a\r\n\r\nPOST / HTTP/1.1\r\n\r\n"))
	testing.expect_value(t, strings.count(answer, "HTTP/1.1 "), 1)
	testing.expect_value(t, answer_line(answer), "HTTP/1.1 200 OK")
	testing.expect(t, strings.contains(answer, "\r\nContent-Type: application/json\r\n"))
}

@(test)
status_reader_times_out_a_head_that_does_not_end :: proc(t: ^testing.T) {
	test := status_test_start(t, nil, SHORT_DEADLINE)
	defer status_test_stop(test)
	// A slow head that never ends, a head with no empty line, and a
	// connection that sends nothing: 408 at the deadline.
	testing.expect_value(t, answer_line(status_exchange(t, test, head_bytes("GET / HT"))), "HTTP/1.1 408 Request Timeout")
	testing.expect_value(t, answer_line(status_exchange(t, test, head_bytes("GET / HTTP/1.1\r\nHost: a\r\n"))), "HTTP/1.1 408 Request Timeout")
	testing.expect_value(t, answer_line(status_exchange(t, test, nil)), "HTTP/1.1 408 Request Timeout")
}

// The answer of the deadline tests: larger than the buffers of the system on
// both sides of a loopback connection, so the write blocks on a reader that
// does not read.
@(private = "file")
LARGE_ANSWER_BYTES :: 32 * 1024 * 1024

// The pause of the slow reader between two reads of 16 bytes: each read
// frees room, so no single write of the server stalls for long, and the
// pace stays far under LARGE_ANSWER_BYTES in SHORT_DEADLINE, so only the one
// deadline of the connection can end the answer.
@(private = "file")
SLOW_READER_PAUSE :: 5 * time.Millisecond

@(private = "file")
Slow_Reader :: struct {
	socket:      net.TCP_Socket,
	received:    int,
	// The first bytes of the answer: its status line.
	head:        [32]u8,
	head_length: int,
	// Set by the test when the next client got its answer: the bytes that
	// the system queued on the side of the reader before the reset are not
	// the subject of the test.
	done:     bool,
}

@(test)
status_one_deadline_frees_the_thread_from_a_slow_reader :: proc(t: ^testing.T) {
	test := status_test_start(t, nil, SHORT_DEADLINE, strings.repeat("x", LARGE_ANSWER_BYTES, context.temp_allocator))
	defer status_test_stop(test)

	// A client that never reads. The next client is answered: the write to
	// the first one ends at its deadline.
	silent := status_dial(t, test)
	defer net.close(silent)
	_ = net.set_option(silent, .Receive_Buffer_Size, 4096)
	testing.expect(t, tcp_write_all(silent, head_bytes("GET /style.css HTTP/1.1\r\n\r\n")))
	// The next client gets an answer: the thread is free. Its code is not
	// the subject, so the test does not depend on the time that the answer
	// takes under the short deadline.
	testing.expect(t, strings.has_prefix(status_exchange(t, test, head_bytes("GET /status.json HTTP/1.1\r\n\r\n")), "HTTP/1.1 "))
	// The silent client was answered: the head of a 200 waits in its buffer.
	silent_head: [32]u8
	silent_count, _ := net.recv_tcp(silent, silent_head[:])
	testing.expect(t, strings.has_prefix(string(silent_head[:max(silent_count, 0)]), "HTTP/1.1 200 OK"))

	// A client that reads a few bytes at a time, never enough to stop a send
	// for long. Its pace is the hostile input, not a wait of the test: the
	// test waits only for the answer of the next client.
	slow := Slow_Reader{socket = status_dial(t, test)}
	defer net.close(slow.socket)
	_ = net.set_option(slow.socket, .Receive_Buffer_Size, 4096)
	testing.expect(t, tcp_write_all(slow.socket, head_bytes("GET /style.css HTTP/1.1\r\n\r\n")))
	reader := thread.create_and_start_with_poly_data(&slow, proc(slow: ^Slow_Reader) {
		buffer: [16]u8
		for !sync.atomic_load(&slow.done) {
			count, receive_error := net.recv_tcp(slow.socket, buffer[:])
			if receive_error != .None || count == 0 {
				return
			}
			taken := min(count, len(slow.head) - slow.head_length)
			copy(slow.head[slow.head_length:], buffer[:taken])
			slow.head_length += taken
			slow.received += count
			time.sleep(SLOW_READER_PAUSE)
		}
	})
	testing.expect(t, strings.has_prefix(status_exchange(t, test, head_bytes("GET /status.json HTTP/1.1\r\n\r\n")), "HTTP/1.1 "))
	sync.atomic_store(&slow.done, true)
	thread.join(reader)
	thread.destroy(reader)
	// The slow reader was answered with a 200, then cut at the deadline: it
	// read some bytes, and fewer than the whole answer.
	testing.expect(t, strings.has_prefix(string(slow.head[:slow.head_length]), "HTTP/1.1 200 OK"))
	testing.expect(t, slow.received > 0)
	testing.expect(t, slow.received < LARGE_ANSWER_BYTES)
}

@(test)
status_drain_ends_at_its_bound_and_at_the_deadline :: proc(t: ^testing.T) {
	// The bound of the bytes: under the hang bound, only the bound of the
	// drain frees the thread from a client that sends without end.
	test := status_test_start(t, nil)
	flood := status_dial(t, test)
	request := strings.concatenate({"GET /status.json HTTP/1.1\r\n\r\n", strings.repeat("z", 1024 * 1024, context.temp_allocator)}, context.temp_allocator)
	_ = tcp_write_all(flood, head_bytes(request))
	testing.expect_value(t, answer_line(status_exchange(t, test, head_bytes("GET /status.json HTTP/1.1\r\n\r\n"))), "HTTP/1.1 200 OK")
	net.close(flood)
	status_test_stop(test)

	// A client silent after the answer, which keeps its side open: the drain
	// ends at the deadline and the next client gets an answer. The test
	// asserts only that the thread is free, not the code of either answer,
	// which the short deadline makes depend on the speed of the host.
	short := status_test_start(t, nil, SHORT_DEADLINE)
	defer status_test_stop(short)
	quiet := status_dial(t, short)
	defer net.close(quiet)
	testing.expect(t, tcp_write_all(quiet, head_bytes("GET /status.json HTTP/1.1\r\n\r\n")))
	_ = status_read_to_end(quiet)
	testing.expect(t, strings.has_prefix(status_exchange(t, short, head_bytes("GET /status.json HTTP/1.1\r\n\r\n")), "HTTP/1.1 "))
}

@(private)
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
	stranger_put := make_signed_put_object_request(.Blob, object_hash, u64(len(payload)), &stranger_key, stranger_public)
	testing.expect_value(t, test_put_object_on_server(&server, &stranger_put, payload), object_cache.Cache_Response_Status.Unauthorized)
	forged_put := make_signed_put_object_request(.Blob, object_hash, u64(len(payload)), &private_key, public_key)
	forged_put.uploader_signature[0] ~= 1
	testing.expect_value(t, test_put_object_on_server(&server, &forged_put, payload), object_cache.Cache_Response_Status.Bad_Signature)
	wrong_hash := blake3.hash(transmute([]u8)string("other bytes"))
	wrong_put := make_signed_put_object_request(.Blob, wrong_hash, u64(len(payload)), &private_key, public_key)
	testing.expect_value(t, test_put_object_on_server(&server, &wrong_put, payload), object_cache.Cache_Response_Status.Bad_Hash)
	before := cache_status_snapshot(&server.status)
	testing.expect_value(t, before.counts, snapshot.counts)

	// A put of an object: one more object and its bytes.
	object_put := make_signed_put_object_request(.Blob, object_hash, u64(len(payload)), &private_key, public_key)
	testing.expect_value(t, test_put_object_on_server(&server, &object_put, payload), object_cache.Cache_Response_Status.Ok)
	after_object := cache_status_snapshot(&server.status)
	testing.expect_value(t, after_object.counts.objects, 1)
	testing.expect_value(t, after_object.counts.object_bytes, u64(len(payload)))
	testing.expect_value(t, after_object.counts.largest_object_bytes, u64(len(payload)))
	testing.expect(t, after_object.counts.last_write._nsec != 0)

	// The same object again adds nothing.
	testing.expect_value(t, test_put_object_on_server(&server, &object_put, payload), object_cache.Cache_Response_Status.Ok)
	testing.expect_value(t, cache_status_snapshot(&server.status).counts.objects, 1)
	testing.expect_value(t, cache_status_snapshot(&server.status).counts.object_bytes, u64(len(payload)))
	testing.expect_value(t, cache_status_snapshot(&server.status).counts.largest_object_bytes, u64(len(payload)))

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
	testing.expect_value(t, counted.counts.largest_object_bytes, full.counts.largest_object_bytes)
	testing.expect_value(t, counted.counts.realisations, full.counts.realisations)
	testing.expect_value(t, counted.counts.realisation_bytes, full.counts.realisation_bytes)
	testing.expect_value(t, counted.recent_count, RECENT_REALISATION_COUNT)
}

@(test)
status_page_and_record_escape_each_value :: proc(t: ^testing.T) {
	server := Cache_Server{root_directory = "/nonexistent/folder"}
	hostile := Cache_Page_Settings {
		endpoint     = "<script>alert(1)</script>&\"x'\n:1",
		site_address = "https://a\"><script>alert(2)</script>&'",
	}
	snapshot: Cache_Status_Snapshot
	page := cache_page_html(&server, hostile, snapshot, 0, false)
	testing.expect(t, !strings.contains(page, "<script"))
	testing.expect(t, strings.contains(page, "&lt;script&gt;alert(1)&lt;/script&gt;&amp;&quot;x&#39;"))
	testing.expect(t, strings.contains(page, "https://a&quot;&gt;&lt;script&gt;alert(2)&lt;/script&gt;&amp;&#39;/"))
	record := cache_status_json(&server, hostile, snapshot, 0, false)
	testing.expect(t, strings.contains(record, "\"endpoint\": \"<script>alert(1)</script>&\\\"x'\\u000a:1\""))
}

@(test)
status_free_space_is_kept_and_can_be_unknown :: proc(t: ^testing.T) {
	directory := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	server := Cache_Server{root_directory = directory}
	listener := Cache_Status_Listener{server = &server}
	first, first_known := cache_status_disk_free(&listener)
	testing.expect(t, first_known)
	testing.expect(t, first > 0)
	// Within its age the value is kept: no new call to the system.
	listener.disk_free_bytes = 12345
	kept, kept_known := cache_status_disk_free(&listener)
	testing.expect_value(t, kept, 12345)
	testing.expect(t, kept_known)
	// Past its age it is read again: the last read is set one age and one
	// nanosecond before now, whatever the time since the start of the host.
	listener.disk_free_read_at = time.Tick{_nsec = time.tick_now()._nsec - i64(DISK_FREE_LONGEST_AGE) - 1}
	again, again_known := cache_status_disk_free(&listener)
	testing.expect(t, again_known)
	testing.expect(t, again != 12345)

	// A folder that does not exist: not known, on the page and in the record.
	missing := Cache_Server{root_directory = "/nonexistent/folder"}
	unknown_listener := Cache_Status_Listener{server = &missing}
	_, unknown_known := cache_status_disk_free(&unknown_listener)
	testing.expect(t, !unknown_known)
	snapshot: Cache_Status_Snapshot
	settings := Cache_Page_Settings{endpoint = "cache.example:5010", site_address = DEFAULT_SITE_ADDRESS}
	testing.expect(t, strings.contains(cache_page_html(&missing, settings, snapshot, 0, false), "not known on this host"))
	testing.expect(t, strings.contains(cache_status_json(&missing, settings, snapshot, 0, false), "\"disk_free_bytes\": null,"))
}

@(test)
status_open_refuses_a_listing_that_fails :: proc(t: ^testing.T) {
	directory := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	// A file where the folder of the objects must be: its listing fails, so
	// the open fails, in place of counts of zero.
	objects := strings.concatenate({directory, "/objects"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(objects, transmute([]u8)string("not a folder")), nil)
	server, open_ok := cache_server_open(directory, nil)
	testing.expect(t, !open_ok)
	if open_ok {
		cache_server_destroy(&server)
	}
	// The same store with the folder in its place opens.
	testing.expect_value(t, os.remove(objects), nil)
	reopened, reopen_ok := cache_server_open(directory, nil)
	testing.expect(t, reopen_ok)
	cache_server_destroy(&reopened)
}

@(private = "file")
CONCURRENT_PUT_COUNT :: 200

@(private = "file")
Concurrent_Writer :: struct {
	server:   ^Cache_Server,
	// The puts that did not give Ok, counted on the thread of the writer
	// and checked on the thread of the test, which alone uses testing.T.
	failures: int,
}

@(test)
status_snapshots_while_another_thread_puts :: proc(t: ^testing.T) {
	directory := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	_, public_key, _ := make_test_keypair(0x51)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{public_key}
	server, open_ok := cache_server_open(directory, authorized[:])
	testing.expect(t, open_ok)
	defer cache_server_destroy(&server)

	writer := Concurrent_Writer{server = &server}
	worker := thread.create_and_start_with_poly_data(&writer, proc(writer: ^Concurrent_Writer) {
		private_key, public_key, _ := make_test_keypair(0x51)
		for index in 0 ..< CONCURRENT_PUT_COUNT {
			payload := transmute([]u8)strings.repeat("p", index + 1, context.temp_allocator)
			request := make_signed_put_object_request(.Blob, blake3.hash(payload), u64(len(payload)), &private_key, public_key)
			if test_put_object_on_server(writer.server, &request, payload) != .Ok {
				writer.failures += 1
			}
		}
	})
	// Each copy is whole: the counts only grow, and the bytes match the
	// objects (object n has n bytes).
	last: u64 = 0
	for !thread.is_done(worker) {
		snapshot := cache_status_snapshot(&server.status)
		testing.expect(t, snapshot.counts.objects >= last)
		testing.expect_value(t, snapshot.counts.object_bytes, snapshot.counts.objects * (snapshot.counts.objects + 1) / 2)
		last = snapshot.counts.objects
	}
	thread.join(worker)
	thread.destroy(worker)
	testing.expect_value(t, writer.failures, 0)
	final := cache_status_snapshot(&server.status)
	testing.expect_value(t, final.counts.objects, u64(CONCURRENT_PUT_COUNT))
	testing.expect_value(t, final.counts.object_bytes, u64(CONCURRENT_PUT_COUNT * (CONCURRENT_PUT_COUNT + 1) / 2))
}

@(test)
status_page_shows_the_signer_only_for_several_signers :: proc(t: ^testing.T) {
	first_key, first_public, _ := make_test_keypair(0x41)
	second_key, second_public, _ := make_test_keypair(0x42)
	keys := [2][object_cache.PUBLIC_KEY_SIZE]u8{first_public, second_public}
	server := Cache_Server{authorized_signers = make([dynamic][object_cache.PUBLIC_KEY_SIZE]u8, context.temp_allocator)}
	append(&server.authorized_signers, ..keys[:])
	settings := Cache_Page_Settings{endpoint = "cache.example:5010", site_address = DEFAULT_SITE_ADDRESS}
	output := blake3.hash(transmute([]u8)string("output"))

	// No row: no table, so no signer column.
	empty: Cache_Status_Snapshot
	testing.expect_value(t, cache_page_distinct_signers(empty.recent[:0]), 0)
	testing.expect(t, !strings.contains(cache_page_html(&server, settings, empty, 0, false), ">Signer<"))

	// Three rows of one signer: the key is in the list, not in each row.
	one: Cache_Status_Snapshot
	for index in 0 ..< 3 {
		recipe := blake3.hash(transmute([]u8)strings.repeat("o", index + 1, context.temp_allocator))
		one.recent[index] = Recent_Realisation{record = make_signed_realisation_record(recipe, output, .Blob, &first_key, first_public)}
	}
	one.recent_count = 3
	testing.expect_value(t, cache_page_distinct_signers(one.recent[:one.recent_count]), 1)
	one_page := cache_page_html(&server, settings, one, 0, false)
	testing.expect(t, !strings.contains(one_page, ">Signer<"))
	first_hex := hash_to_hex(first_public)
	testing.expect_value(t, strings.count(one_page, string(first_hex[:])), 1)

	// A second signer in the rows: the column comes back.
	two := one
	recipe := blake3.hash(transmute([]u8)string("second"))
	two.recent[3] = Recent_Realisation{record = make_signed_realisation_record(recipe, output, .Blob, &second_key, second_public)}
	two.recent_count = 4
	testing.expect_value(t, cache_page_distinct_signers(two.recent[:two.recent_count]), 2)
	testing.expect(t, strings.contains(cache_page_html(&server, settings, two, 0, false), ">Signer<"))
}

@(test)
status_answers_the_page_the_record_and_the_style_sheet :: proc(t: ^testing.T) {
	private_key, public_key, _ := make_test_keypair(0x31)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{public_key}
	test := status_test_start(t, authorized[:])
	defer status_test_stop(test)

	payload := transmute([]u8)string("an object that the page counts")
	object_hash := blake3.hash(payload)
	object_put := make_signed_put_object_request(.Blob, object_hash, u64(len(payload)), &private_key, public_key)
	testing.expect_value(t, test_put_object_on_server(&test.server, &object_put, payload), object_cache.Cache_Response_Status.Ok)
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
	// The whole hash, in the cell and in its title, in a table of the
	// whole width with a column of hashes; the browser cuts it, not the
	// server.
	testing.expect(t, strings.contains(body, strings.concatenate({"<a href=\"/realisation/", string(recipe_hex[:]), "\" title=\"", string(recipe_hex[:]), "\"><code class=\"value value-version\">", string(recipe_hex[:]), "</code></a>"}, context.temp_allocator)))
	testing.expect(t, strings.contains(body, "<div class=\"table table-whole-width\""))
	testing.expect(t, strings.contains(body, "<td class=\"column-hash value value-version\">"))
	testing.expect(t, !strings.contains(body, "…</code>"))
	testing.expect(t, !strings.contains(body, "<script"))
	testing.expect(t, !strings.contains(body, "Modus"))
	// The host is an object cache, never "the cache"; "the cache protocol"
	// names the protocol.
	testing.expect_value(t, strings.count(body, "the cache"), strings.count(body, "the cache protocol"))

	record_answer := status_exchange(t, test, head_bytes("GET /status.json HTTP/1.1\r\n\r\n"))
	testing.expect_value(t, answer_line(record_answer), "HTTP/1.1 200 OK")
	json := answer_body(record_answer)
	testing.expect(t, strings.contains(json, "\"objects\": 1,"))
	testing.expect(t, strings.contains(json, fmt.tprintf("\"largest_object_bytes\": %d,", len(payload))))
	testing.expect(t, strings.contains(json, "\"realisations\": 1,"))
	testing.expect(t, strings.contains(json, strings.concatenate({"\"recipe\": \"", string(recipe_hex[:]), "\""}, context.temp_allocator)))
	testing.expect(t, strings.contains(json, strings.concatenate({"\"signer_keys\": [\"", string(key_hex[:]), "\"]"}, context.temp_allocator)))

	style := status_exchange(t, test, head_bytes("GET /style.css HTTP/1.1\r\n\r\n"))
	testing.expect_value(t, answer_line(style), "HTTP/1.1 200 OK")
	testing.expect(t, strings.contains(answer_body(style), strings.concatenate({"url(\"", DEFAULT_SITE_ADDRESS, "/fonts/"}, context.temp_allocator)))
	testing.expect(t, !strings.contains(answer_body(style), "url(\"fonts/"))
}

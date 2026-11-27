#+build !freestanding
package machine

import "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "modustool:build"
import "modustool:foundation"

// Path resolution refuses traversal, backslashes, percent-encoding, control
// bytes, and missing leading slashes, while mapping clean URLs accurately.
@(test)
browser_artifact_resolve_path_refuses_traversal_and_maps_routes :: proc(t: ^testing.T) {
	refused := [?]struct {
		target: string,
		status: Artifact_Http_Status,
	}{
		{"", .Bad_Request},
		{"console/index.html", .Bad_Request},
		{"/../etc/passwd", .Forbidden},
		{"/console/../../secret", .Forbidden},
		{"/a//b.js", .Forbidden},
		{"/./a.js", .Forbidden},
		{"/a\\b.js", .Forbidden},
		{"/%2e%2e/secret", .Forbidden},
		{"/a\x00b", .Forbidden},
		{"/unknown/", .Not_Found},
	}
	for item in refused {
		_, status := browser_artifact_resolve_path(item.target)
		testing.expectf(t, status == item.status, "target %q gave %v, expected %v", item.target, status, item.status)
	}

	accepted := [?]struct {
		target:   string,
		expected: string,
	}{
		{"/", build.BROWSER_MACHINE_CONSOLE_PAGE_FILE},
		{"/console", build.BROWSER_MACHINE_CONSOLE_PAGE_FILE},
		{"/console/", build.BROWSER_MACHINE_CONSOLE_PAGE_FILE},
		{"/console/?cache=https://example.invalid", build.BROWSER_MACHINE_CONSOLE_PAGE_FILE},
		{"/desktop", build.BROWSER_MACHINE_DESKTOP_PAGE_FILE},
		{"/desktop/", build.BROWSER_MACHINE_DESKTOP_PAGE_FILE},
		{"/modulus_kernel.wasm", "modulus_kernel.wasm"},
		{"/browser_machine_worker.js", "browser_machine_worker.js"},
		{"/console.image.trust", "console.image.trust"},
	}
	for item in accepted {
		rel, status := browser_artifact_resolve_path(item.target)
		testing.expect_value(t, status, Artifact_Http_Status.Ok)
		testing.expect_value(t, rel, item.expected)
	}
}

// MIME type mapping and COOP/COEP response header formatting match browser
// machine requirements (both isolated and non-isolated modes).
@(test)
browser_artifact_mime_and_coop_coep_headers :: proc(t: ^testing.T) {
	cases := [?]struct {
		path: string,
		mime: string,
	}{
		{"console/index.html", "text/html; charset=utf-8"},
		{"browser_machine_worker.js", "application/javascript; charset=utf-8"},
		{"browser_machine.css", "text/css; charset=utf-8"},
		{"modulus_kernel.wasm", "application/wasm"},
		{"console.image", "application/octet-stream"},
		{"console.image.trust", "text/plain; charset=utf-8"},
		{"favicon.ico", "image/x-icon"},
		{"manifest.json", "application/json; charset=utf-8"},
	}
	for c in cases {
		testing.expect_value(t, artifact_mime_header_value(artifact_mime_kind_of(c.path)), c.mime)
	}

	isolated := browser_artifact_response_head(.Ok, .Webassembly, 4096, true)
	testing.expect(t, strings.has_prefix(isolated, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(isolated, "Content-Type: application/wasm\r\n"))
	testing.expect(t, strings.contains(isolated, "Content-Length: 4096\r\n"))
	testing.expect(t, strings.contains(isolated, "Cross-Origin-Opener-Policy: same-origin\r\n"))
	testing.expect(t, strings.contains(isolated, "Cross-Origin-Embedder-Policy: require-corp\r\n"))
	testing.expect(t, strings.contains(isolated, "Cross-Origin-Resource-Policy: same-origin\r\n"))

	plain := browser_artifact_response_head(.Ok, .Html, 128, false)
	testing.expect(t, !strings.contains(plain, "Cross-Origin-Opener-Policy"))
	testing.expect(t, !strings.contains(plain, "Cross-Origin-Embedder-Policy"))
}

// Live loopback HTTP artifact server serves files with exact bytes, MIME types,
// COOP/COEP headers, HEAD support, and refuses traversal, 404, and POST.
@(test)
browser_artifact_server_loopback_roundtrip :: proc(t: ^testing.T) {
	root :: foundation.BUILD_FOLDER + "/browser_artifact_server_unit_test"
	_ = os.remove_all(root)
	defer {
		_ = os.remove_all(root)
	}
	testing.expect(t, foundation.make_folder(root + "/console"))
	testing.expect(t, os.write_entire_file(root + "/console/index.html", "<!doctype html><title>test</title>") == nil)
	testing.expect(t, os.write_entire_file(root + "/modulus_kernel.wasm", []u8{0x00, 'a', 's', 'm', 1, 0, 0, 0}) == nil)
	testing.expect(t, os.write_entire_file(root + "/browser_machine_worker.js", "export const ok = 1;\n") == nil)
	testing.expect(t, os.write_entire_file(root + "/console.image.trust", "0123456789abcdef\n") == nil)

	server: Browser_Artifact_Server
	if !testing.expect(t, browser_artifact_server_start(&server, root, true)) {
		return
	}
	defer browser_artifact_server_stop(&server)

	// Refusals first.
	trav, ok_t := loopback_http_get(server.port, "/../secret.txt")
	testing.expect(t, ok_t && strings.has_prefix(trav.status_line, "HTTP/1.1 403"))
	miss, ok_m := loopback_http_get(server.port, "/absent.wasm")
	testing.expect(t, ok_m && strings.has_prefix(miss.status_line, "HTTP/1.1 404"))
	post_r, ok_p := loopback_http_get(server.port, "/console/", "POST")
	testing.expect(t, ok_p && strings.has_prefix(post_r.status_line, "HTTP/1.1 405"))

	// Valid GETs and HEADs.
	html, ok_h := loopback_http_get(server.port, "/console/")
	testing.expect(t, ok_h && strings.has_prefix(html.status_line, "HTTP/1.1 200"))
	testing.expect(t, strings.contains(html.headers, "Content-Type: text/html; charset=utf-8\r\n"))
	testing.expect(t, strings.contains(html.headers, "Cross-Origin-Opener-Policy: same-origin\r\n"))
	testing.expect(t, strings.contains(html.headers, "Cross-Origin-Embedder-Policy: require-corp\r\n"))
	testing.expect_value(t, string(html.body), "<!doctype html><title>test</title>")

	wasm, ok_w := loopback_http_get(server.port, "/modulus_kernel.wasm")
	testing.expect(t, ok_w && strings.has_prefix(wasm.status_line, "HTTP/1.1 200"))
	testing.expect(t, strings.contains(wasm.headers, "Content-Type: application/wasm\r\n"))
	testing.expect_value(t, len(wasm.body), 8)

	head_js, ok_j := loopback_http_get(server.port, "/browser_machine_worker.js", "HEAD")
	testing.expect(t, ok_j && strings.has_prefix(head_js.status_line, "HTTP/1.1 200"))
	testing.expect(t, strings.contains(head_js.headers, "Content-Type: application/javascript; charset=utf-8\r\n"))
	testing.expect_value(t, len(head_js.body), 0)

	// Refusal: oversized request header stream without "\r\n\r\n" terminator returns 400 Bad Request.
	raw_sock, dial_err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, server.port})
	if testing.expect(t, dial_err == nil, "connect for oversized header refusal") {
		defer net.close(raw_sock)
		_ = net.set_option(raw_sock, .Receive_Timeout, ARTIFACT_SERVER_SOCKET_TIMEOUT)
		prefix := "GET /console/ HTTP/1.1\r\nX-Pad: "
		pad_len := ARTIFACT_REQUEST_MAX_BYTES - len(prefix)
		unterminated := strings.concatenate({prefix, strings.repeat("A", pad_len, context.temp_allocator)}, context.temp_allocator)
		testing.expect(t, send_all(raw_sock, transmute([]u8)unterminated))
		resp_buf: [512]u8
		n, rerr := net.recv_tcp(raw_sock, resp_buf[:])
		testing.expect(t, rerr == nil && n > 0, "server replies to unterminated headers")
		testing.expect(t, strings.has_prefix(string(resp_buf[:n]), "HTTP/1.1 400"), "unterminated headers return 400 Bad Request")
	}
}

// DevToolsActivePort, /json/list target parser, RFC 6455 WebSocket handshake
// and frame codec, browser PATH lookup, and CDP event/log parser.
@(test)
cdp_protocol_and_browser_parsers :: proc(t: ^testing.T) {
	// DevToolsActivePort refusals and valid form.
	for bad in ([?]string{"", "0\n/devtools/browser/1\n", "70000\n/devtools/browser/1\n", "-1\n/devtools\n", "9222\nrelative\n", "9222"}) {
		_, _, ok := devtools_active_port_parse(bad)
		testing.expectf(t, !ok, "DevToolsActivePort %q must be refused", bad)
	}
	port, ws_path, ok := devtools_active_port_parse("41234\n/devtools/browser/abc-123\n")
	testing.expect(t, ok)
	testing.expect_value(t, port, 41234)
	testing.expect_value(t, ws_path, "/devtools/browser/abc-123")

	// /json/list parser refusals and page target selection.
	for bad_json in ([?]string{"", "{}", "[]", `[{"type":"worker","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/worker/1"}]`, `[{"type":"page","webSocketDebuggerUrl":"http://bad"}]`}) {
		_, ok_j := cdp_target_ws_path_parse(bad_json)
		testing.expectf(t, !ok_j, "target list %q must be refused", bad_json)
	}
	targets := `[{"type":"service_worker","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/sw/1"},{"type":"page","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/PAGE42"}]`
	page_ws, ok_ws := cdp_target_ws_path_parse(targets)
	testing.expect(t, ok_ws)
	testing.expect_value(t, page_ws, "/devtools/page/PAGE42")

	// RFC 6455 Section 1.3 test vector for Sec-WebSocket-Accept and Section 4.1 16-byte client key length.
	testing.expect_value(t, cdp_websocket_accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
	decoded_key, key_err := base64.decode(CDP_WEBSOCKET_CLIENT_KEY, allocator = context.temp_allocator)
	testing.expect(t, key_err == nil && len(decoded_key) == 16, "Sec-WebSocket-Key must decode to exactly 16 bytes")

	// RFC 6455 frame encode + decode roundtrip (small and >125 byte extended length).
	small := "hello cdp"
	enc_small := cdp_websocket_frame_encode(.Text, transmute([]u8)small, {0x37, 0xFA, 0x21, 0x3D})
	dec_small, dec_status := cdp_websocket_frame_decode(enc_small)
	testing.expect(t, dec_status == .Ok && dec_small.fin && dec_small.opcode == .Text)
	testing.expect_value(t, string(dec_small.payload), small)
	testing.expect_value(t, dec_small.consumed, len(enc_small))

	large := strings.repeat("A", 300, context.temp_allocator)
	enc_large := cdp_websocket_frame_encode(.Text, transmute([]u8)large, {0x11, 0x22, 0x33, 0x44})
	dec_large, dec_l_status := cdp_websocket_frame_decode(enc_large)
	testing.expect(t, dec_l_status == .Ok && dec_large.fin && len(dec_large.payload) == 300)

	// Incomplete frames report .Need_More_Data; invalid opcode and oversized length report .Protocol_Error.
	_, empty_status := cdp_websocket_frame_decode([]u8{0x81})
	testing.expect_value(t, empty_status, Ws_Decode_Status.Need_More_Data)
	_, trunc_status := cdp_websocket_frame_decode(enc_large[:len(enc_large) - 1])
	testing.expect_value(t, trunc_status, Ws_Decode_Status.Need_More_Data)

	_, bad_op_status := cdp_websocket_frame_decode([]u8{0x83, 0x00})
	testing.expect_value(t, bad_op_status, Ws_Decode_Status.Protocol_Error)

	// 64-bit extended length declaring CDP_FRAME_MAX_BYTES + 1 bytes must report .Protocol_Error.
	over_len := u64(CDP_FRAME_MAX_BYTES + 1)
	over_hdr := [10]u8{
		0x81, 0x7F,
		u8(over_len >> 56), u8(over_len >> 48), u8(over_len >> 40), u8(over_len >> 32),
		u8(over_len >> 24), u8(over_len >> 16), u8(over_len >> 8), u8(over_len),
	}
	_, over_status := cdp_websocket_frame_decode(over_hdr[:])
	testing.expect_value(t, over_status, Ws_Decode_Status.Protocol_Error)

	// CDP event and response parser.
	_, bad_cdp := cdp_event_parse("not json")
	testing.expect(t, !bad_cdp)

	resp_msg, ok_r := cdp_event_parse(`{"id":7,"result":{"result":{"type":"string","value":"true|/console/"}}}`)
	testing.expect(t, ok_r && resp_msg.kind == .Response && resp_msg.id == 7 && !resp_msg.has_error)
	testing.expect_value(t, resp_msg.eval_value, "true|/console/")

	err_msg, ok_e := cdp_event_parse(`{"id":8,"error":{"code":-32000,"message":"target closed"}}`)
	testing.expect(t, ok_e && err_msg.kind == .Response && err_msg.id == 8 && err_msg.has_error)
	testing.expect_value(t, err_msg.error_text, "target closed")

	con_msg, ok_c := cdp_event_parse(`{"method":"Runtime.consoleAPICalled","params":{"type":"log","args":[{"type":"string","value":"kernel:"},{"type":"string","value":"ok"}]}}`)
	testing.expect(t, ok_c && con_msg.kind == .Console && con_msg.level == "log")
	testing.expect_value(t, con_msg.console_text, "kernel: ok")

	exc_msg, ok_x := cdp_event_parse(`{"method":"Runtime.exceptionThrown","params":{"exceptionDetails":{"text":"Uncaught","exception":{"description":"RangeError: trap"}}}}`)
	testing.expect(t, ok_x && exc_msg.kind == .Exception && exc_msg.has_error)
	testing.expect_value(t, exc_msg.error_text, "RangeError: trap")

	log_msg, ok_l := cdp_event_parse(`{"method":"Log.entryAdded","params":{"entry":{"level":"error","text":"Failed to load resource","url":"http://127.0.0.1:8080/favicon.ico"}}}`)
	testing.expect(t, ok_l && log_msg.kind == .Log_Entry && log_msg.level == "error")
	testing.expect_value(t, log_msg.console_text, "Failed to load resource")
	testing.expect_value(t, log_msg.url, "http://127.0.0.1:8080/favicon.ico")

	// Headless browser PATH discovery: empty PATH gives .None; synthetic bin folder finds chromium before firefox.
	none_k, none_p := headless_browser_find_in_path("")
	testing.expect_value(t, none_k, Headless_Browser_Kind.None)
	testing.expect_value(t, none_p, "")

	fake_bin :: foundation.BUILD_FOLDER + "/headless_browser_path_test"
	_ = os.remove_all(fake_bin)
	defer {
		_ = os.remove_all(fake_bin)
	}
	testing.expect(t, foundation.make_folder(fake_bin))
	testing.expect(t, os.write_entire_file(fake_bin + "/firefox", "#!/bin/sh\n") == nil)
	ff_k, ff_p := headless_browser_find_in_path(fake_bin)
	testing.expect_value(t, ff_k, Headless_Browser_Kind.Firefox)
	testing.expect_value(t, ff_p, fmt.tprintf("%s/firefox", fake_bin))

	testing.expect(t, os.write_entire_file(fake_bin + "/chromium", "#!/bin/sh\n") == nil)
	cr_k, cr_p := headless_browser_find_in_path(fake_bin)
	testing.expect_value(t, cr_k, Headless_Browser_Kind.Chromium)
	testing.expect_value(t, cr_p, fmt.tprintf("%s/chromium", fake_bin))
}

// Plan value: short deadline bound for verifying that cdp_read_next_text stops
// when an incomplete fragmented WebSocket message never finishes.
CDP_FRAGMENT_DEADLINE_TEST_BOUND :: 200 * time.Millisecond

// cdp_read_next_text closes immediately on protocol errors or oversized
// fragmented messages, and stops at `deadline` on an unfinished fragment.
@(test)
cdp_read_next_text_bounds_and_deadline :: proc(t: ^testing.T) {
	// 1. Protocol error in rx_buf returns closed=true immediately.
	conn_err: Cdp_Connection
	conn_err.rx_buf = make([dynamic]u8)
	defer delete(conn_err.rx_buf)
	append(&conn_err.rx_buf, 0x83, 0x00)
	_, got_e, closed_e := cdp_read_next_text(&conn_err, time.tick_add(time.tick_now(), foundation.HANG_BOUND))
	testing.expect(t, !got_e && closed_e, "protocol error frame must close the CDP connection")

	// 2. Fragmented text frames exceeding CDP_FRAME_MAX_BYTES return closed=true.
	conn_big: Cdp_Connection
	conn_big.rx_buf = make([dynamic]u8)
	defer delete(conn_big.rx_buf)
	half_plus := (CDP_FRAME_MAX_BYTES / 2) + 1
	// Unmasked non-final text frame of size half_plus, followed by final continuation of size half_plus.
	chunk_hdr := [10]u8{
		0x01, 0x7F,
		0, 0, 0, 0,
		u8(half_plus >> 24), u8(half_plus >> 16), u8(half_plus >> 8), u8(half_plus),
	}
	payload := make([]u8, half_plus, context.temp_allocator)
	append(&conn_big.rx_buf, ..chunk_hdr[:])
	append(&conn_big.rx_buf, ..payload)
	cont_hdr := chunk_hdr
	cont_hdr[0] = 0x80 // FIN=1, Continuation
	append(&conn_big.rx_buf, ..cont_hdr[:])
	append(&conn_big.rx_buf, ..payload)
	_, got_b, closed_b := cdp_read_next_text(&conn_big, time.tick_add(time.tick_now(), foundation.HANG_BOUND))
	testing.expect(t, !got_b && closed_b, "oversized fragmented message must close the CDP connection")

	// 3. Unfinished fragment over loopback TCP stops promptly at deadline.
	listener, listen_err := net.listen_tcp(net.Endpoint{net.IP4_Loopback, 0})
	if !testing.expect(t, listen_err == nil, "listen loopback for fragment deadline test") {
		return
	}
	defer net.close(listener)
	ep, ep_err := net.bound_endpoint(listener)
	if !testing.expect(t, ep_err == nil) {
		return
	}
	client, dial_err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, ep.port})
	if !testing.expect(t, dial_err == nil) {
		return
	}
	defer net.close(client)
	peer, _, acc_err := net.accept_tcp(listener)
	if !testing.expect(t, acc_err == nil) {
		return
	}
	defer net.close(peer)
	_ = net.set_option(client, .Receive_Timeout, CDP_SOCKET_POLL_TIMEOUT)

	// Send non-final text frame ("hi", FIN=0) and hold the peer open without sending a continuation.
	partial := [4]u8{0x01, 0x02, 'h', 'i'}
	testing.expect(t, send_all(peer, partial[:]))

	conn_frag := Cdp_Connection{socket = client, rx_buf = make([dynamic]u8)}
	defer delete(conn_frag.rx_buf)
	deadline := time.tick_add(time.tick_now(), CDP_FRAGMENT_DEADLINE_TEST_BOUND)
	_, got_f, closed_f := cdp_read_next_text(&conn_frag, deadline)
	testing.expect(t, !got_f && !closed_f, "unfinished fragment must return at deadline without hanging")
}

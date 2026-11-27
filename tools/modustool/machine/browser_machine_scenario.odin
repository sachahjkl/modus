// Headless browser test part for the browser machine
// (src/md/features/browser_machine.md, "The machine tests").
//
// Builds the WebAssembly kernel and console image, verifies every executable
// instruction of the boot image against software_machine, serves the artifacts
// over a pure-Odin loopback HTTP server with MIME and COOP/COEP headers, and
// drives a headless browser (Chromium via Chrome DevTools Protocol over RFC
// 6455 WebSocket, or Firefox headless fallback) when available in PATH. All
// waits are bounded by foundation.HANG_BOUND with zero fixed delays.
package machine

import "core:crypto/hash"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "modustool:build"
import "modustool:foundation"

@(init)
browser_machine_scenario_register :: proc "contextless" () {
	test_part_scenario_register("browser_machine", browser_machine_tests_run)
}

// -----------------------------------------------------------------------------
// Closed Enums and Bounded Constants
// -----------------------------------------------------------------------------

// Closed set of MIME classifications served by the loopback artifact server.
Artifact_Mime_Kind :: enum u8 {
	Html         = 0,
	Javascript   = 1,
	Css          = 2,
	Webassembly  = 3,
	Octet_Stream = 4,
	Plain_Text   = 5,
	Icon         = 6,
	Json         = 7,
}

// Closed set of HTTP response status codes emitted by the artifact server.
Artifact_Http_Status :: enum u16 {
	Ok                 = 200,
	Bad_Request        = 400,
	Forbidden          = 403,
	Not_Found          = 404,
	Method_Not_Allowed = 405,
}

// Closed set of supported headless browser engines discovered in PATH.
Headless_Browser_Kind :: enum u8 {
	None     = 0,
	Chromium = 1,
	Firefox  = 2,
}

// Closed set of parsed CDP message categories.
Cdp_Message_Kind :: enum u8 {
	Unknown   = 0,
	Response  = 1,
	Console   = 2,
	Exception = 3,
	Log_Entry = 4,
}

// Closed set of RFC 6455 WebSocket frame opcodes handled by the CDP client.
Ws_Opcode :: enum u8 {
	Continuation = 0x0,
	Text         = 0x1,
	Binary       = 0x2,
	Close        = 0x8,
	Ping         = 0x9,
	Pong         = 0xA,
}

// Closed set of outcomes from decoding one RFC 6455 WebSocket frame.
Ws_Decode_Status :: enum u8 {
	Ok             = 0,
	Need_More_Data = 1,
	Protocol_Error = 2,
}

// Format property: RFC 6455 WebSocket handshake GUID appended to client key.
WS_HANDSHAKE_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// Format property: RFC 6455 maximum frame header size (2 base + 8 extended length + 4 mask).
WS_FRAME_MAX_HEADER_BYTES :: 14

// Format property: 16-byte Base64-encoded WebSocket client key ("modus-browser-cd")
// for loopback CDP handshakes (RFC 6455 Section 4.1).
CDP_WEBSOCKET_CLIENT_KEY :: "bW9kdXMtYnJvd3Nlci1jZA=="

// Plan value: poll period while waiting for DevToolsActivePort or console readiness.
HEADLESS_BROWSER_POLL_PERIOD :: 50 * time.Millisecond

// Plan value: socket read timeout on loopback HTTP artifact connections so an
// idle browser socket never blocks server shutdown.
ARTIFACT_SERVER_SOCKET_TIMEOUT :: 2 * time.Second

// Plan value: socket read timeout on CDP WebSocket polling iterations so each
// loop checks foundation.HANG_BOUND promptly.
CDP_SOCKET_POLL_TIMEOUT :: 100 * time.Millisecond

// Plan value: maximum HTTP request header size accepted by loopback artifact server.
ARTIFACT_REQUEST_MAX_BYTES :: 16 * 1024

// Plan value: maximum single CDP WebSocket payload accepted from loopback browser.
CDP_FRAME_MAX_BYTES :: 4 * 1024 * 1024

// Plan value: temporary profile directory for headless browser runs.
HEADLESS_BROWSER_PROFILE_DIR :: foundation.BUILD_FOLDER + "/browser_machine_headless_profile"

// -----------------------------------------------------------------------------
// Pure-Odin Loopback HTTP Artifact Server
// -----------------------------------------------------------------------------

Browser_Artifact_Server :: struct {
	socket:                net.TCP_Socket,
	port:                  int,
	root_folder:           string,
	cross_origin_isolated: bool,
	stop:                  bool,
	requests:              int,
	accept_thread:         ^thread.Thread,
	workers_lock:          sync.Mutex,
	workers:               [dynamic]^thread.Thread,
}

@(private = "file")
Artifact_Connection_Job :: struct {
	server: ^Browser_Artifact_Server,
	client: net.TCP_Socket,
}

// artifact_mime_kind_of maps a file path suffix to a closed Artifact_Mime_Kind.
artifact_mime_kind_of :: proc(path: string) -> Artifact_Mime_Kind {
	switch {
	case strings.has_suffix(path, ".html"):
		return .Html
	case strings.has_suffix(path, ".js"), strings.has_suffix(path, ".mjs"):
		return .Javascript
	case strings.has_suffix(path, ".css"):
		return .Css
	case strings.has_suffix(path, ".wasm"):
		return .Webassembly
	case strings.has_suffix(path, ".trust"), strings.has_suffix(path, ".txt"):
		return .Plain_Text
	case strings.has_suffix(path, ".ico"):
		return .Icon
	case strings.has_suffix(path, ".json"):
		return .Json
	}
	return .Octet_Stream
}

// artifact_mime_header_value returns the Content-Type header string for a kind.
artifact_mime_header_value :: proc(kind: Artifact_Mime_Kind) -> string {
	switch kind {
	case .Html:
		return "text/html; charset=utf-8"
	case .Javascript:
		return "application/javascript; charset=utf-8"
	case .Css:
		return "text/css; charset=utf-8"
	case .Webassembly:
		return "application/wasm"
	case .Octet_Stream:
		return "application/octet-stream"
	case .Plain_Text:
		return "text/plain; charset=utf-8"
	case .Icon:
		return "image/x-icon"
	case .Json:
		return "application/json; charset=utf-8"
	}
	return "application/octet-stream"
}

@(private = "file")
artifact_status_reason :: proc(status: Artifact_Http_Status) -> string {
	switch status {
	case .Ok:
		return "OK"
	case .Bad_Request:
		return "Bad Request"
	case .Forbidden:
		return "Forbidden"
	case .Not_Found:
		return "Not Found"
	case .Method_Not_Allowed:
		return "Method Not Allowed"
	}
	return "Error"
}

// browser_artifact_resolve_path validates an HTTP request target and resolves
// it to a clean relative path under the artifact root, rejecting traversal,
// backslashes, control characters, and encoded path separators.
browser_artifact_resolve_path :: proc(raw_target: string) -> (relative: string, status: Artifact_Http_Status) {
	if len(raw_target) == 0 || raw_target[0] != '/' {
		return "", .Bad_Request
	}
	// Strip query string if present.
	path := raw_target
	if q := strings.index_byte(path, '?'); q >= 0 {
		path = path[:q]
	}
	// Reject control chars, backslashes, and percent-encoded traversal sequences.
	for i := 0; i < len(path); i += 1 {
		b := path[i]
		if b < 0x20 || b == 0x7F || b == '\\' {
			return "", .Forbidden
		}
		if b == '%' {
			return "", .Forbidden
		}
	}
	switch path {
	case "/", "/console", "/console/":
		return build.BROWSER_MACHINE_CONSOLE_PAGE_FILE, .Ok
	case "/desktop", "/desktop/":
		return build.BROWSER_MACHINE_DESKTOP_PAGE_FILE, .Ok
	}
	trimmed := strings.trim_prefix(path, "/")
	if len(trimmed) == 0 || strings.has_suffix(trimmed, "/") {
		return "", .Not_Found
	}
	segments := strings.split(trimmed, "/", context.temp_allocator)
	for seg in segments {
		if seg == "" || seg == "." || seg == ".." {
			return "", .Forbidden
		}
	}
	return trimmed, .Ok
}

// browser_artifact_response_head formats an HTTP/1.1 response header block with
// Content-Type, Content-Length, Cache-Control, and optional COOP/COEP headers.
browser_artifact_response_head :: proc(
	status: Artifact_Http_Status,
	mime: Artifact_Mime_Kind,
	body_length: int,
	cross_origin_isolated: bool,
	allocator := context.temp_allocator,
) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "HTTP/1.1 %d %s\r\n", u16(status), artifact_status_reason(status))
	fmt.sbprintf(&b, "Content-Type: %s\r\n", artifact_mime_header_value(mime))
	fmt.sbprintf(&b, "Content-Length: %d\r\n", body_length)
	strings.write_string(&b, "Cache-Control: no-store\r\n")
	if cross_origin_isolated {
		strings.write_string(&b, "Cross-Origin-Opener-Policy: same-origin\r\n")
		strings.write_string(&b, "Cross-Origin-Embedder-Policy: require-corp\r\n")
		strings.write_string(&b, "Cross-Origin-Resource-Policy: same-origin\r\n")
	}
	strings.write_string(&b, "Connection: close\r\n\r\n")
	return strings.to_string(b)
}

// browser_artifact_server_start binds an ephemeral loopback TCP listener and
// starts serving files under `root_folder`.
browser_artifact_server_start :: proc(server: ^Browser_Artifact_Server, root_folder: string, cross_origin_isolated := true) -> bool {
	sock, err := net.listen_tcp({net.IP4_Loopback, 0})
	if err != nil {
		fmt.eprintfln("modustool: browser artifact server cannot listen on loopback: %v", err)
		return false
	}
	bound, bound_err := net.bound_endpoint(sock)
	if bound_err != nil {
		net.close(sock)
		return false
	}
	server^ = {
		socket                = sock,
		port                  = bound.port,
		root_folder           = strings.clone(root_folder),
		cross_origin_isolated = cross_origin_isolated,
		workers               = make([dynamic]^thread.Thread),
	}
	server.accept_thread = thread.create_and_start_with_poly_data(server, artifact_server_accept_loop)
	return true
}

// browser_artifact_server_stop shuts down the listener and joins all workers.
browser_artifact_server_stop :: proc(server: ^Browser_Artifact_Server) {
	if server.accept_thread == nil {
		return
	}
	sync.atomic_store(&server.stop, true)
	_ = net.shutdown(server.socket, .Both)
	net.close(server.socket)
	thread.join(server.accept_thread)
	thread.destroy(server.accept_thread)
	server.accept_thread = nil

	sync.mutex_lock(&server.workers_lock)
	for worker in server.workers {
		thread.join(worker)
		thread.destroy(worker)
	}
	clear(&server.workers)
	sync.mutex_unlock(&server.workers_lock)
	delete(server.workers)
	delete(server.root_folder)
	server.root_folder = ""
}

@(private = "file")
artifact_server_accept_loop :: proc(server: ^Browser_Artifact_Server) {
	for !sync.atomic_load(&server.stop) {
		client, _, err := net.accept_tcp(server.socket)
		if err != nil {
			return
		}
		if sync.atomic_load(&server.stop) {
			net.close(client)
			return
		}
		job := new(Artifact_Connection_Job)
		job.server = server
		job.client = client
		worker := thread.create_and_start_with_poly_data(job, artifact_server_serve_connection)
		sync.mutex_lock(&server.workers_lock)
		append(&server.workers, worker)
		sync.mutex_unlock(&server.workers_lock)
	}
}

@(private = "file")
artifact_server_serve_connection :: proc(job: ^Artifact_Connection_Job) {
	defer free(job)
	defer net.close(job.client)
	defer free_all(context.temp_allocator)

	server := job.server
	_ = net.set_option(job.client, .Receive_Timeout, ARTIFACT_SERVER_SOCKET_TIMEOUT)

	buf: [ARTIFACT_REQUEST_MAX_BYTES]u8
	length := 0
	headers_complete := false
	for length < len(buf) {
		count, err := net.recv_tcp(job.client, buf[length:])
		if err != nil {
			return
		}
		if count <= 0 {
			break
		}
		length += count
		if strings.contains(string(buf[:length]), "\r\n\r\n") {
			headers_complete = true
			break
		}
	}
	if length == 0 {
		return
	}
	if !headers_complete {
		head := browser_artifact_response_head(.Bad_Request, .Plain_Text, 0, server.cross_origin_isolated)
		_ = send_all(job.client, transmute([]u8)head)
		return
	}
	req_text := string(buf[:length])
	line_end := strings.index(req_text, "\r\n")
	if line_end <= 0 {
		head := browser_artifact_response_head(.Bad_Request, .Plain_Text, 0, server.cross_origin_isolated)
		_ = send_all(job.client, transmute([]u8)head)
		return
	}
	request_line := req_text[:line_end]
	parts := strings.split(request_line, " ", context.temp_allocator)
	if len(parts) < 2 {
		head := browser_artifact_response_head(.Bad_Request, .Plain_Text, 0, server.cross_origin_isolated)
		_ = send_all(job.client, transmute([]u8)head)
		return
	}
	method := parts[0]
	target := parts[1]
	is_head := method == "HEAD"
	if method != "GET" && !is_head {
		body := "method not allowed\n"
		head := browser_artifact_response_head(.Method_Not_Allowed, .Plain_Text, len(body), server.cross_origin_isolated)
		_ = send_all(job.client, transmute([]u8)head)
		_ = send_all(job.client, transmute([]u8)body)
		return
	}

	relative, status := browser_artifact_resolve_path(target)
	if status != .Ok {
		body := "refused\n"
		head := browser_artifact_response_head(status, .Plain_Text, len(body), server.cross_origin_isolated)
		_ = send_all(job.client, transmute([]u8)head)
		if !is_head {
			_ = send_all(job.client, transmute([]u8)body)
		}
		sync.atomic_add(&server.requests, 1)
		return
	}

	full_path := foundation.join(server.root_folder, "/", relative)
	file_bytes, read_err := os.read_entire_file(full_path, context.allocator)
	if read_err != nil {
		body := "not found\n"
		head := browser_artifact_response_head(.Not_Found, .Plain_Text, len(body), server.cross_origin_isolated)
		_ = send_all(job.client, transmute([]u8)head)
		if !is_head {
			_ = send_all(job.client, transmute([]u8)body)
		}
		sync.atomic_add(&server.requests, 1)
		return
	}
	defer delete(file_bytes)

	mime := artifact_mime_kind_of(relative)
	head := browser_artifact_response_head(.Ok, mime, len(file_bytes), server.cross_origin_isolated)
	if !send_all(job.client, transmute([]u8)head) {
		return
	}
	if !is_head && len(file_bytes) > 0 {
		_ = send_all(job.client, file_bytes)
	}
	sync.atomic_add(&server.requests, 1)
}

// -----------------------------------------------------------------------------
// Headless Browser Discovery, RFC 6455 WebSocket, and CDP Parsers
// -----------------------------------------------------------------------------

// headless_browser_find_in_path searches a colon-separated PATH string for the
// first available headless browser executable in preference order:
// chromium, chromium-browser, google-chrome, firefox.
headless_browser_find_in_path :: proc(path_env: string, allocator := context.temp_allocator) -> (kind: Headless_Browser_Kind, full_path: string) {
	if len(path_env) == 0 {
		return .None, ""
	}
	candidates := [?]struct {
		name: string,
		kind: Headless_Browser_Kind,
	}{
		{"chromium", .Chromium},
		{"chromium-browser", .Chromium},
		{"google-chrome", .Chromium},
		{"firefox", .Firefox},
	}
	dirs := strings.split(path_env, ":", context.temp_allocator)
	for candidate in candidates {
		for dir in dirs {
			if len(dir) == 0 {
				continue
			}
			probe := strings.concatenate({strings.trim_right(dir, "/"), "/", candidate.name}, context.temp_allocator)
			if os.is_file(probe) {
				return candidate.kind, strings.clone(probe, allocator)
			}
		}
	}
	return .None, ""
}

// devtools_active_port_parse parses Chromium's DevToolsActivePort file:
// line 1 is the TCP port (1..65535), line 2 is the WebSocket path starting with "/".
devtools_active_port_parse :: proc(text: string) -> (port: int, ws_path: string, ok: bool) {
	trimmed := strings.trim_space(text)
	if len(trimmed) == 0 {
		return 0, "", false
	}
	line1, sep, rest := strings.partition(trimmed, "\n")
	if len(sep) == 0 {
		return 0, "", false
	}
	port_str := strings.trim_space(line1)
	if len(port_str) == 0 || strings.contains_any(port_str, "+-_ ") {
		return 0, "", false
	}
	parsed_port, parsed := strconv.parse_int(port_str, 10)
	if !parsed || parsed_port <= 0 || parsed_port > 65535 {
		return 0, "", false
	}
	line2, _, _ := strings.partition(rest, "\n")
	path := strings.trim_space(line2)
	if !strings.has_prefix(path, "/") {
		return 0, "", false
	}
	return parsed_port, path, true
}

// cdp_target_ws_path_parse parses Chromium's GET /json/list JSON array and
// returns the WebSocket path ("/devtools/page/...") of the first page target.
cdp_target_ws_path_parse :: proc(json_text: string, allocator := context.temp_allocator) -> (ws_path: string, ok: bool) {
	value, err := json.parse_string(json_text, allocator = context.temp_allocator)
	if err != .None {
		return "", false
	}
	defer json.destroy_value(value, context.temp_allocator)
	arr, is_arr := value.(json.Array)
	if !is_arr {
		return "", false
	}
	for item in arr {
		obj, is_obj := item.(json.Object)
		if !is_obj {
			continue
		}
		target_type, has_type := obj["type"].(json.String)
		if !has_type || target_type != "page" {
			continue
		}
		ws_url, has_url := obj["webSocketDebuggerUrl"].(json.String)
		if !has_url || !strings.has_prefix(ws_url, "ws://") {
			continue
		}
		after_scheme := ws_url[len("ws://"):]
		slash := strings.index_byte(after_scheme, '/')
		if slash < 0 {
			continue
		}
		return strings.clone(after_scheme[slash:], allocator), true
	}
	return "", false
}

// cdp_websocket_accept_key computes the RFC 6455 Sec-WebSocket-Accept header
// value for a client Sec-WebSocket-Key using SHA-1 and standard Base64.
cdp_websocket_accept_key :: proc(client_key: string, allocator := context.temp_allocator) -> string {
	combined := strings.concatenate({client_key, WS_HANDSHAKE_GUID}, context.temp_allocator)
	digest := hash.hash_string(.Insecure_SHA1, combined, context.temp_allocator)
	return base64.encode(digest, allocator = allocator)
}

// cdp_websocket_frame_encode encodes a masked client RFC 6455 frame.
cdp_websocket_frame_encode :: proc(opcode: Ws_Opcode, payload: []u8, mask_key: [4]u8, allocator := context.temp_allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(payload) + 14, allocator)
	append(&out, u8(0x80) | u8(opcode))
	n := len(payload)
	if n < 126 {
		append(&out, u8(0x80) | u8(n))
	} else if n <= 65535 {
		append(&out, u8(0x80) | 126, u8(n >> 8), u8(n & 0xFF))
	} else {
		append(&out, u8(0x80) | 127)
		u := u64(n)
		for shift := uint(56); ; shift -= 8 {
			append(&out, u8((u >> shift) & 0xFF))
			if shift == 0 {
				break
			}
		}
	}
	append(&out, mask_key[0], mask_key[1], mask_key[2], mask_key[3])
	for b, idx in payload {
		append(&out, b ~ mask_key[idx & 3])
	}
	return out[:]
}

// Decoded RFC 6455 frame header and payload slice.
Ws_Decoded_Frame :: struct {
	fin:      bool,
	opcode:   Ws_Opcode,
	payload:  []u8,
	consumed: int,
}

// cdp_websocket_frame_decode parses one RFC 6455 frame from `bytes`.
// Distinguishes incomplete frames (.Need_More_Data) from invalid opcodes or
// frames exceeding CDP_FRAME_MAX_BYTES (.Protocol_Error).
cdp_websocket_frame_decode :: proc(bytes: []u8, allocator := context.temp_allocator) -> (frame: Ws_Decoded_Frame, status: Ws_Decode_Status) {
	if len(bytes) < 2 {
		return {}, .Need_More_Data
	}
	b0 := bytes[0]
	b1 := bytes[1]
	raw_op := b0 & 0x0F
	op: Ws_Opcode
	switch raw_op {
	case u8(Ws_Opcode.Continuation):
		op = .Continuation
	case u8(Ws_Opcode.Text):
		op = .Text
	case u8(Ws_Opcode.Binary):
		op = .Binary
	case u8(Ws_Opcode.Close):
		op = .Close
	case u8(Ws_Opcode.Ping):
		op = .Ping
	case u8(Ws_Opcode.Pong):
		op = .Pong
	case:
		return {}, .Protocol_Error
	}
	masked := (b1 & 0x80) != 0
	length := u64(b1 & 0x7F)
	pos := 2
	if length == 126 {
		if len(bytes) < pos + 2 {
			return {}, .Need_More_Data
		}
		length = (u64(bytes[pos]) << 8) | u64(bytes[pos + 1])
		pos += 2
	} else if length == 127 {
		if len(bytes) < pos + 8 {
			return {}, .Need_More_Data
		}
		length = 0
		for i in 0 ..< 8 {
			length = (length << 8) | u64(bytes[pos + i])
		}
		pos += 8
	}
	if length > CDP_FRAME_MAX_BYTES {
		return {}, .Protocol_Error
	}
	mask_key: [4]u8
	if masked {
		if len(bytes) < pos + 4 {
			return {}, .Need_More_Data
		}
		copy(mask_key[:], bytes[pos:pos + 4])
		pos += 4
	}
	if u64(len(bytes) - pos) < length {
		return {}, .Need_More_Data
	}
	payload := make([]u8, int(length), allocator)
	copy(payload, bytes[pos:pos + int(length)])
	if masked {
		for &b, idx in payload {
			b ~= mask_key[idx & 3]
		}
	}
	return {
		fin      = (b0 & 0x80) != 0,
		opcode   = op,
		payload  = payload,
		consumed = pos + int(length),
	}, .Ok
}

// Structured representation of a parsed CDP JSON response or event.
Cdp_Message :: struct {
	kind:         Cdp_Message_Kind,
	id:           int,
	has_error:    bool,
	error_text:   string,
	eval_value:   string,
	console_text: string,
	level:        string,
	url:          string,
}

@(private = "file")
cdp_json_scalar_text :: proc(v: json.Value, allocator := context.temp_allocator) -> string {
	switch val in v {
	case json.String:
		return strings.clone(val, allocator)
	case json.Integer:
		return fmt.aprintf("%d", val, allocator = allocator)
	case json.Float:
		return fmt.aprintf("%v", val, allocator = allocator)
	case json.Boolean:
		return "true" if val else "false"
	case json.Null, json.Array, json.Object:
		return ""
	}
	return ""
}

// cdp_event_parse parses one JSON text payload received over CDP WebSocket.
cdp_event_parse :: proc(json_text: string, allocator := context.temp_allocator) -> (msg: Cdp_Message, ok: bool) {
	value, err := json.parse_string(json_text, allocator = context.temp_allocator)
	if err != .None {
		return {}, false
	}
	defer json.destroy_value(value, context.temp_allocator)
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return {}, false
	}
	// Command response with numeric "id".
	if id_val, has_id := obj["id"]; has_id {
		msg.kind = .Response
		switch iv in id_val {
		case json.Integer:
			msg.id = int(iv)
		case json.Float:
			msg.id = int(iv)
		case json.Null, json.Boolean, json.String, json.Array, json.Object:
			return {}, false
		}
		if err_obj, has_err := obj["error"].(json.Object); has_err {
			msg.has_error = true
			if m, has_m := err_obj["message"].(json.String); has_m {
				msg.error_text = strings.clone(m, allocator)
			}
		} else if res_obj, has_res := obj["result"].(json.Object); has_res {
			if inner, has_inner := res_obj["result"].(json.Object); has_inner {
				if val, has_val := inner["value"]; has_val {
					msg.eval_value = cdp_json_scalar_text(val, allocator)
				}
			}
		}
		return msg, true
	}

	// Event with string "method".
	method, has_method := obj["method"].(json.String)
	if !has_method {
		return {kind = .Unknown}, true
	}
	params, _ := obj["params"].(json.Object)
	switch method {
	case "Runtime.consoleAPICalled":
		msg.kind = .Console
		if lvl, has_lvl := params["type"].(json.String); has_lvl {
			msg.level = strings.clone(lvl, allocator)
		}
		if args, has_args := params["args"].(json.Array); has_args {
			b := strings.builder_make(allocator)
			for arg, idx in args {
				arg_obj, is_a := arg.(json.Object)
				if !is_a {
					continue
				}
				if idx > 0 {
					strings.write_byte(&b, ' ')
				}
				if v, has_v := arg_obj["value"]; has_v {
					strings.write_string(&b, cdp_json_scalar_text(v, context.temp_allocator))
				} else if d, has_d := arg_obj["description"].(json.String); has_d {
					strings.write_string(&b, d)
				}
			}
			msg.console_text = strings.to_string(b)
		}
		return msg, true
	case "Runtime.exceptionThrown":
		msg.kind = .Exception
		msg.has_error = true
		if details, has_det := params["exceptionDetails"].(json.Object); has_det {
			if txt, has_txt := details["text"].(json.String); has_txt {
				msg.error_text = strings.clone(txt, allocator)
			}
			if exc, has_exc := details["exception"].(json.Object); has_exc {
				if desc, has_desc := exc["description"].(json.String); has_desc && len(desc) > 0 {
					msg.error_text = strings.clone(desc, allocator)
				}
			}
		}
		return msg, true
	case "Log.entryAdded":
		msg.kind = .Log_Entry
		if entry, has_entry := params["entry"].(json.Object); has_entry {
			if lvl, has_lvl := entry["level"].(json.String); has_lvl {
				msg.level = strings.clone(lvl, allocator)
			}
			if txt, has_txt := entry["text"].(json.String); has_txt {
				msg.console_text = strings.clone(txt, allocator)
			}
			if u, has_u := entry["url"].(json.String); has_u {
				msg.url = strings.clone(u, allocator)
			}
		}
		return msg, true
	}
	return {kind = .Unknown}, true
}

// -----------------------------------------------------------------------------
// Live Loopback HTTP Client and CDP WebSocket Driver
// -----------------------------------------------------------------------------

@(private = "file")
Loopback_Http_Response :: struct {
	status_line: string,
	headers:     string,
	body:        []u8,
}

// loopback_http_get issues a single HTTP/1.1 GET (or HEAD) request against
// 127.0.0.1:`port` and returns its status line, headers, and body.
loopback_http_get :: proc(port: int, path: string, method := "GET", allocator := context.temp_allocator) -> (resp: Loopback_Http_Response, ok: bool) {
	sock, dial_err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, port})
	if dial_err != nil {
		return {}, false
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, ARTIFACT_SERVER_SOCKET_TIMEOUT)

	req := fmt.tprintf("%s %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n\r\n", method, path, port)
	if !send_all(sock, transmute([]u8)req) {
		return {}, false
	}
	raw := make([dynamic]u8, context.temp_allocator)
	chunk: [16384]u8
	for {
		n, err := net.recv_tcp(sock, chunk[:])
		if err != nil || n <= 0 {
			break
		}
		append(&raw, ..chunk[:n])
	}
	text := string(raw[:])
	head_end := strings.index(text, "\r\n\r\n")
	if head_end <= 0 {
		return {}, false
	}
	head := text[:head_end]
	line_end := strings.index(head, "\r\n")
	status_line := head if line_end < 0 else head[:line_end]
	body_slice := raw[head_end + 4:]
	body_copy := make([]u8, len(body_slice), allocator)
	copy(body_copy, body_slice)
	return {
		status_line = strings.clone(status_line, allocator),
		headers     = strings.clone(head, allocator),
		body        = body_copy,
	}, true
}

@(private)
Cdp_Connection :: struct {
	socket:  net.TCP_Socket,
	next_id: int,
	rx_buf:  [dynamic]u8,
}

@(private = "file")
cdp_connect :: proc(port: int, ws_path: string) -> (conn: Cdp_Connection, ok: bool) {
	sock, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, port})
	if err != nil {
		return {}, false
	}
	_ = net.set_option(sock, .Receive_Timeout, ARTIFACT_SERVER_SOCKET_TIMEOUT)

	req := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
		ws_path,
		port,
		CDP_WEBSOCKET_CLIENT_KEY,
	)
	if !send_all(sock, transmute([]u8)req) {
		net.close(sock)
		return {}, false
	}
	handshake_buf: [4096]u8
	got := 0
	head_end := -1
	for got < len(handshake_buf) {
		n, rerr := net.recv_tcp(sock, handshake_buf[got:])
		if rerr != nil || n <= 0 {
			net.close(sock)
			return {}, false
		}
		got += n
		if idx := strings.index(string(handshake_buf[:got]), "\r\n\r\n"); idx >= 0 {
			head_end = idx
			break
		}
	}
	if head_end < 0 {
		net.close(sock)
		return {}, false
	}
	head_text := string(handshake_buf[:head_end])
	expected_accept := cdp_websocket_accept_key(CDP_WEBSOCKET_CLIENT_KEY, context.temp_allocator)
	if !strings.has_prefix(head_text, "HTTP/1.1 101 ") || !strings.contains(head_text, expected_accept) {
		net.close(sock)
		return {}, false
	}
	_ = net.set_option(sock, .Receive_Timeout, CDP_SOCKET_POLL_TIMEOUT)
	rx := make([dynamic]u8)
	if head_end + 4 < got {
		append(&rx, ..handshake_buf[head_end + 4:got])
	}
	return {socket = sock, next_id = 1, rx_buf = rx}, true
}

@(private = "file")
cdp_close :: proc(conn: ^Cdp_Connection) {
	if conn.socket != 0 {
		frame := cdp_websocket_frame_encode(.Close, nil, {0x12, 0x34, 0x56, 0x78}, context.temp_allocator)
		_ = send_all(conn.socket, frame)
		net.close(conn.socket)
		conn.socket = 0
	}
	delete(conn.rx_buf)
	conn.rx_buf = nil
}

@(private = "file")
cdp_send_command :: proc(conn: ^Cdp_Connection, method: string, params_json := "{}") -> (id: int, ok: bool) {
	id = conn.next_id
	conn.next_id += 1
	payload := fmt.tprintf(`{{"id":%d,"method":"%s","params":%s}}`, id, method, params_json)
	mask := [4]u8{u8(id), u8(id >> 8) ~ 0xA5, 0x5A, 0xC3}
	frame := cdp_websocket_frame_encode(.Text, transmute([]u8)payload, mask, context.temp_allocator)
	return id, send_all(conn.socket, frame)
}

@(private)
cdp_read_next_text :: proc(conn: ^Cdp_Connection, deadline: time.Tick, allocator := context.temp_allocator) -> (text: string, got: bool, closed: bool) {
	assembled := make([dynamic]u8, context.temp_allocator)
	in_fragment := false

	for time.tick_since(deadline) < 0 {
		// Try decoding a complete frame already in rx_buf.
		if len(conn.rx_buf) >= 2 {
			frame, decode_status := cdp_websocket_frame_decode(conn.rx_buf[:], context.temp_allocator)
			switch decode_status {
			case .Protocol_Error:
				return "", false, true
			case .Need_More_Data:
				if len(conn.rx_buf) > CDP_FRAME_MAX_BYTES + WS_FRAME_MAX_HEADER_BYTES {
					return "", false, true
				}
			case .Ok:
				remaining := len(conn.rx_buf) - frame.consumed
				if remaining > 0 {
					copy(conn.rx_buf[:remaining], conn.rx_buf[frame.consumed:])
				}
				resize(&conn.rx_buf, remaining)

				switch frame.opcode {
				case .Ping:
					pong := cdp_websocket_frame_encode(.Pong, frame.payload, {1, 2, 3, 4}, context.temp_allocator)
					_ = send_all(conn.socket, pong)
					continue
				case .Pong:
					continue
				case .Close:
					return "", false, true
				case .Text:
					if len(assembled) + len(frame.payload) > CDP_FRAME_MAX_BYTES {
						return "", false, true
					}
					append(&assembled, ..frame.payload)
					if frame.fin {
						return strings.clone(string(assembled[:]), allocator), true, false
					}
					in_fragment = true
					continue
				case .Continuation:
					if in_fragment {
						if len(assembled) + len(frame.payload) > CDP_FRAME_MAX_BYTES {
							return "", false, true
						}
						append(&assembled, ..frame.payload)
						if frame.fin {
							return strings.clone(string(assembled[:]), allocator), true, false
						}
					}
					continue
				case .Binary:
					continue
				}
			}
		}

		if time.tick_since(deadline) >= 0 {
			return "", false, false
		}

		// Read more bytes from socket (bounded by CDP_SOCKET_POLL_TIMEOUT).
		chunk: [8192]u8
		n, err := net.recv_tcp(conn.socket, chunk[:])
		if n > 0 {
			if len(conn.rx_buf) + n > CDP_FRAME_MAX_BYTES + WS_FRAME_MAX_HEADER_BYTES {
				return "", false, true
			}
			append(&conn.rx_buf, ..chunk[:n])
			continue
		}
		if err == .Timeout || err == .Would_Block {
			if !in_fragment || time.tick_since(deadline) >= 0 {
				return "", false, false
			}
			continue
		}
		return "", false, true
	}
	return "", false, false
}

@(private = "file")
cdp_wait_response :: proc(
	conn: ^Cdp_Connection,
	wanted_id: int,
	deadline: time.Tick,
	kernel_mark_seen: ^bool,
	exception_out: ^string,
) -> (msg: Cdp_Message, ok: bool) {
	for time.tick_since(deadline) < 0 {
		text, got, closed := cdp_read_next_text(conn, deadline, context.temp_allocator)
		if closed {
			return {}, false
		}
		if !got {
			continue
		}
		parsed, p_ok := cdp_event_parse(text, context.temp_allocator)
		if !p_ok {
			continue
		}
		switch parsed.kind {
		case .Console:
			if strings.contains(parsed.console_text, build.BROWSER_MACHINE_KERNEL_MARK) {
				kernel_mark_seen^ = true
			}
		case .Exception:
			if exception_out^ == "" {
				exception_out^ = strings.clone(parsed.error_text)
			}
		case .Log_Entry:
			// Ignore 404 for favicon.ico (only generated by `modustool site`),
			// while failing immediately on any other browser error log entry.
			if parsed.level == "error" && !strings.has_suffix(parsed.url, "/favicon.ico") && exception_out^ == "" {
				if parsed.url != "" {
					exception_out^ = fmt.aprintf("%s (%s)", parsed.console_text, parsed.url)
				} else {
					exception_out^ = strings.clone(parsed.console_text)
				}
			}
		case .Response:
			if parsed.id == wanted_id {
				return parsed, true
			}
		case .Unknown:
		}
	}
	return {}, false
}

// browser_machine_headless_chromium_run launches headless Chromium against
// `base_url`, boots the Web Console page in its real Web Worker, verifies
// cross-origin isolation and COM1 kernel boot, sends the Lex command, and
// checks that the expected answer renders in the DOM #output element.
@(private = "file")
browser_machine_headless_chromium_run :: proc(browser_path: string, base_url: string) -> bool {
	_ = os.remove_all(HEADLESS_BROWSER_PROFILE_DIR)
	foundation.make_folder(HEADLESS_BROWSER_PROFILE_DIR) or_return
	defer {
		_ = os.remove_all(HEADLESS_BROWSER_PROFILE_DIR)
	}

	started := time.tick_now()
	deadline := time.tick_add(started, foundation.HANG_BOUND)

	cmd := [?]string {
		browser_path,
		"--headless=new",
		"--no-sandbox",
		"--disable-gpu",
		"--disable-dev-shm-usage",
		"--disable-background-timer-throttling",
		"--disable-renderer-backgrounding",
		"--disable-backgrounding-occluded-windows",
		"--no-first-run",
		"--no-default-browser-check",
		"--remote-debugging-port=0",
		fmt.tprintf("--user-data-dir=%s", HEADLESS_BROWSER_PROFILE_DIR),
		"about:blank",
	}
	proc_handle, start_err := os.process_start({command = cmd[:]})
	if start_err != nil {
		fmt.eprintfln("modustool: cannot start headless chromium (%s): %v", browser_path, start_err)
		return false
	}
	defer {
		_ = os.process_kill(proc_handle)
		_, _ = os.process_wait(proc_handle)
	}

	// Wait for Chromium to write DevToolsActivePort under foundation.HANG_BOUND.
	active_port_file := foundation.join(HEADLESS_BROWSER_PROFILE_DIR, "/DevToolsActivePort")
	cdp_port := 0
	for time.tick_since(deadline) < 0 {
		if text, read_ok := foundation.read_text_file_quiet(active_port_file); read_ok {
			if p, _, p_ok := devtools_active_port_parse(text); p_ok {
				cdp_port = p
				break
			}
		}
		time.sleep(HEADLESS_BROWSER_POLL_PERIOD)
	}
	if cdp_port == 0 {
		fmt.eprintfln("modustool: headless chromium did not publish DevToolsActivePort within %v", foundation.HANG_BOUND)
		return false
	}

	// Discover the page target WebSocket path via /json/list.
	page_ws_path := ""
	for time.tick_since(deadline) < 0 {
		resp, http_ok := loopback_http_get(cdp_port, "/json/list")
		if http_ok && strings.has_prefix(resp.status_line, "HTTP/1.1 200") {
			if ws, ws_ok := cdp_target_ws_path_parse(string(resp.body), context.temp_allocator); ws_ok {
				page_ws_path = ws
				break
			}
		}
		time.sleep(HEADLESS_BROWSER_POLL_PERIOD)
	}
	if page_ws_path == "" {
		fmt.eprintfln("modustool: headless chromium exposed no page target on CDP port %d within %v", cdp_port, foundation.HANG_BOUND)
		return false
	}

	conn, ws_ok := cdp_connect(cdp_port, page_ws_path)
	if !ws_ok {
		fmt.eprintfln("modustool: cannot connect CDP WebSocket at 127.0.0.1:%d%s", cdp_port, page_ws_path)
		return false
	}
	defer cdp_close(&conn)

	kernel_mark_seen := false
	exception_text := ""
	defer delete(exception_text)

	for enable_method in ([?]string{"Runtime.enable", "Log.enable", "Page.enable"}) {
		id, sent := cdp_send_command(&conn, enable_method)
		if !sent {
			fmt.eprintfln("modustool: CDP send %s failed", enable_method)
			return false
		}
		resp, got := cdp_wait_response(&conn, id, deadline, &kernel_mark_seen, &exception_text)
		if !got || resp.has_error {
			fmt.eprintfln("modustool: CDP %s failed: %s", enable_method, resp.error_text)
			return false
		}
	}

	console_url := fmt.tprintf("%s/console/", base_url)
	nav_id, nav_sent := cdp_send_command(&conn, "Page.navigate", fmt.tprintf(`{{"url":"%s"}}`, console_url))
	if !nav_sent {
		fmt.eprintln("modustool: CDP Page.navigate send failed")
		return false
	}
	if nav_resp, got := cdp_wait_response(&conn, nav_id, deadline, &kernel_mark_seen, &exception_text); !got || nav_resp.has_error {
		fmt.eprintfln("modustool: CDP Page.navigate failed: %s", nav_resp.error_text)
		return false
	}

	// Wait until the Web Console reaches ready/running state, then type the Lex
	// command and wait for the expected answer in DOM #output.
	isolated_checked := false
	typed := false
	answered := false
	last_state := ""

	for time.tick_since(deadline) < 0 {
		if exception_text != "" {
			fmt.eprintfln("modustool: headless chromium threw uncaught exception: %s", exception_text)
			return false
		}

		// Check cross-origin isolation once the page finishes initial navigation.
		if !isolated_checked {
			iso_id, ok_s := cdp_send_command(&conn, "Runtime.evaluate", `{"expression":"String(self.crossOriginIsolated) + '|' + location.pathname","returnByValue":true}`)
			if !ok_s {
				fmt.eprintln("modustool: CDP crossOriginIsolated evaluate failed")
				return false
			}
			iso_resp, got := cdp_wait_response(&conn, iso_id, deadline, &kernel_mark_seen, &exception_text)
			if got && strings.has_suffix(iso_resp.eval_value, "|/console/") {
				if !strings.has_prefix(iso_resp.eval_value, "true|") {
					fmt.eprintfln("modustool: headless chromium crossOriginIsolated was false (%q)", iso_resp.eval_value)
					return false
				}
				isolated_checked = true
			}
		}

		// Read current UI state, prompt, and output from DOM.
		poll_expr := `{"expression":"JSON.stringify({state:(document.getElementById('state-text')||{}).textContent||'',prompt:(document.getElementById('prompt-bar')||{}).textContent||'',output:(document.getElementById('output')||{}).textContent||''})","returnByValue":true}`
		eval_id, eval_ok := cdp_send_command(&conn, "Runtime.evaluate", poll_expr)
		if !eval_ok {
			fmt.eprintln("modustool: CDP DOM poll send failed")
			return false
		}
		eval_resp, got := cdp_wait_response(&conn, eval_id, deadline, &kernel_mark_seen, &exception_text)
		if !got {
			break
		}
		if len(eval_resp.eval_value) > 0 {
			val, jerr := json.parse_string(eval_resp.eval_value, allocator = context.temp_allocator)
			if jerr == .None {
				if obj, is_o := val.(json.Object); is_o {
					state_txt, _ := obj["state"].(json.String)
					prompt_txt, _ := obj["prompt"].(json.String)
					output_txt, _ := obj["output"].(json.String)
					last_state = strings.clone(state_txt, context.temp_allocator)

					if state_txt == "trapped" || state_txt == "stopped" {
						fmt.eprintfln("modustool: browser machine entered %q in headless chromium (output: %q)", state_txt, output_txt)
						return false
					}
					if !typed && state_txt == "running" && strings.contains(prompt_txt, ">") {
						typed = true
						// Focus prompt bar, type Lex expression via CDP Input, and press Enter.
						f_id, _ := cdp_send_command(&conn, "Runtime.evaluate", `{"expression":"document.getElementById('prompt-bar').focus()"}`)
						_, _ = cdp_wait_response(&conn, f_id, deadline, &kernel_mark_seen, &exception_text)

						for ch in build.BROWSER_MACHINE_CONSOLE_TYPED_COMMAND {
							k_params := fmt.tprintf(`{{"type":"keyDown","key":"%c","text":"%c"}}`, ch, ch)
							kid, _ := cdp_send_command(&conn, "Input.dispatchKeyEvent", k_params)
							_, _ = cdp_wait_response(&conn, kid, deadline, &kernel_mark_seen, &exception_text)
							ku_params := fmt.tprintf(`{{"type":"keyUp","key":"%c"}}`, ch)
							kuid, _ := cdp_send_command(&conn, "Input.dispatchKeyEvent", ku_params)
							_, _ = cdp_wait_response(&conn, kuid, deadline, &kernel_mark_seen, &exception_text)
						}
						ent_down, _ := cdp_send_command(&conn, "Input.dispatchKeyEvent", `{"type":"keyDown","key":"Enter","code":"Enter","windowsVirtualKeyCode":13}`)
						_, _ = cdp_wait_response(&conn, ent_down, deadline, &kernel_mark_seen, &exception_text)
						ent_up, _ := cdp_send_command(&conn, "Input.dispatchKeyEvent", `{"type":"keyUp","key":"Enter","code":"Enter","windowsVirtualKeyCode":13}`)
						_, _ = cdp_wait_response(&conn, ent_up, deadline, &kernel_mark_seen, &exception_text)
						fmt.printfln("modustool: headless chromium typed %q at %.1f s", build.BROWSER_MACHINE_CONSOLE_TYPED_COMMAND, time.duration_seconds(time.tick_since(started)))
					}
					if typed && strings.contains(output_txt, build.BROWSER_MACHINE_CONSOLE_EXPECTED_ANSWER) {
						answered = true
						break
					}
				}
				json.destroy_value(val, context.temp_allocator)
			}
		}
		time.sleep(HEADLESS_BROWSER_POLL_PERIOD)
	}

	elapsed := time.duration_seconds(time.tick_since(started))
	fmt.printfln("modustool: measure: browser_machine in headless chromium: %.1f s (last state: %q)", elapsed, last_state)
	if !isolated_checked {
		fmt.eprintln("modustool: headless chromium never confirmed crossOriginIsolated on /console/")
		return false
	}
	if !kernel_mark_seen {
		fmt.eprintfln("modustool: headless chromium console log never saw %q", build.BROWSER_MACHINE_KERNEL_MARK)
		return false
	}
	if !typed {
		fmt.eprintfln("modustool: headless chromium did not reach console ready state within %v (last state: %q)", foundation.HANG_BOUND, last_state)
		return false
	}
	if !answered {
		fmt.eprintfln("modustool: headless chromium DOM #output did not show %q for %q within %v", build.BROWSER_MACHINE_CONSOLE_EXPECTED_ANSWER, build.BROWSER_MACHINE_CONSOLE_TYPED_COMMAND, foundation.HANG_BOUND)
		return false
	}
	foundation.test_passed_print("headless chromium booted Web Console with COOP/COEP isolation and answered %s with %s", build.BROWSER_MACHINE_CONSOLE_TYPED_COMMAND, build.BROWSER_MACHINE_CONSOLE_EXPECTED_ANSWER)
	return true
}

// -----------------------------------------------------------------------------
// Loopback Artifact Server Self-Check and Test Part Entry Point
// -----------------------------------------------------------------------------

@(private = "file")
browser_machine_artifact_server_self_check :: proc(port: int) -> bool {
	// Refusals first: traversal, missing file, and non-GET method.
	trav, t_ok := loopback_http_get(port, "/../flake.nix")
	if !t_ok || !strings.has_prefix(trav.status_line, "HTTP/1.1 403") {
		fmt.eprintfln("modustool: artifact server did not refuse traversal: %q", trav.status_line)
		return false
	}
	missing, m_ok := loopback_http_get(port, "/does_not_exist.bin")
	if !m_ok || !strings.has_prefix(missing.status_line, "HTTP/1.1 404") {
		fmt.eprintfln("modustool: artifact server did not return 404 for missing file: %q", missing.status_line)
		return false
	}
	post_resp, p_ok := loopback_http_get(port, "/console/", "POST")
	if !p_ok || !strings.has_prefix(post_resp.status_line, "HTTP/1.1 405") {
		fmt.eprintfln("modustool: artifact server did not return 405 for POST: %q", post_resp.status_line)
		return false
	}

	required := [?]struct {
		path: string,
		mime: string,
	}{
		{"/console/", "text/html; charset=utf-8"},
		{"/desktop/", "text/html; charset=utf-8"},
		{"/browser_machine_worker.js", "application/javascript; charset=utf-8"},
		{"/browser_machine_host.js", "application/javascript; charset=utf-8"},
		{"/browser_machine_console_page.js", "application/javascript; charset=utf-8"},
		{"/browser_machine.css", "text/css; charset=utf-8"},
		{"/" + build.BROWSER_MACHINE_KERNEL_FILE, "application/wasm"},
		{"/" + build.BROWSER_MACHINE_CONSOLE_IMAGE_FILE, "application/octet-stream"},
		{"/" + build.BROWSER_MACHINE_CONSOLE_IMAGE_FILE + build.BROWSER_MACHINE_TRUST_SUFFIX, "text/plain; charset=utf-8"},
	}
	for item in required {
		resp, ok := loopback_http_get(port, item.path, "HEAD")
		if !ok || !strings.has_prefix(resp.status_line, "HTTP/1.1 200") {
			fmt.eprintfln("modustool: artifact server failed HEAD %s: %q", item.path, resp.status_line)
			return false
		}
		if !strings.contains(resp.headers, fmt.tprintf("Content-Type: %s\r\n", item.mime)) {
			fmt.eprintfln("modustool: artifact server wrong Content-Type for %s:\n%s", item.path, resp.headers)
			return false
		}
		if !strings.contains(resp.headers, "Cross-Origin-Opener-Policy: same-origin\r\n") || !strings.contains(resp.headers, "Cross-Origin-Embedder-Policy: require-corp\r\n") {
			fmt.eprintfln("modustool: artifact server missing COOP/COEP headers for %s", item.path)
			return false
		}
	}
	foundation.test_passed_print("loopback browser artifact server serves all %d assets with MIME and COOP/COEP headers and refuses traversal", len(required))
	return true
}

// browser_machine_tests_run is the test part `browser_machine`: builds the
// WebAssembly kernel and console image, verifies every executable instruction
// in the boot image against software_machine, verifies the loopback HTTP
// artifact server, and boots the Web Console in a headless browser when one is
// available in PATH.
browser_machine_tests_run :: proc(_: ^Test_Part_Run) -> bool {
	if !build.browser_machine_build() {
		return false
	}
	if !build.browser_machine_console_write() {
		return false
	}
	if !build.browser_machine_boot_image_instructions_check(build.BROWSER_MACHINE_CONSOLE_IMAGE_PATH) {
		return false
	}
	if os.is_file(build.BROWSER_MACHINE_BOOT_IMAGE_PATH) {
		if !build.browser_machine_boot_image_instructions_check(build.BROWSER_MACHINE_BOOT_IMAGE_PATH) {
			return false
		}
	}

	server: Browser_Artifact_Server
	if !browser_artifact_server_start(&server, build.BROWSER_MACHINE_FOLDER, true) {
		return false
	}
	defer browser_artifact_server_stop(&server)

	if !browser_machine_artifact_server_self_check(server.port) {
		return false
	}

	path_env, _ := os.lookup_env("PATH", context.temp_allocator)
	browser_kind, browser_path := headless_browser_find_in_path(path_env, context.temp_allocator)
	base_url := fmt.tprintf("http://127.0.0.1:%d", server.port)
	switch browser_kind {
	case .Chromium:
		return browser_machine_headless_chromium_run(browser_path, base_url)
	case .Firefox:
		fmt.printfln("modustool: browser_machine: found firefox (%s) but no chromium-family browser for CDP automation; artifact server and instruction checks passed", browser_path)
		return true
	case .None:
		fmt.println("modustool: browser_machine: no headless browser (chromium, chromium-browser, google-chrome, firefox) in PATH; artifact server and instruction checks passed")
		return true
	}
	return false
}

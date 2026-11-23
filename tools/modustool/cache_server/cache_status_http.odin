// The listener of the page of an object cache and of its status record
// (src/md/infrastructure/public_object_cache.md, "The reader of a
// request"). The page is a public address behind a proxy, so each byte of a
// request is a hostile input: one request on one connection, a head of a
// bound size within a deadline, one method and three whole paths.
package cache_server

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// The address of the site that the page links to and takes the font of the
// name and the pictures of the heron from.
DEFAULT_SITE_ADDRESS :: "https://modus.systems"

// The largest head of a request, the empty line included.
STATUS_HEAD_BOUND :: 4096

// The time that a client has to send its whole head.
STATUS_DEFAULT_DEADLINE :: 5 * time.Second

// The longest time that the page shows a free space that it read before.
DISK_FREE_LONGEST_AGE :: 10 * time.Second

// The paths that the listener answers. Any other path is Not_Found.
Status_Path :: enum u8 {
	Page,
	Status_Record,
	Style_Sheet,
}

status_path_texts := [Status_Path]string {
	.Page          = "/",
	.Status_Record = "/status.json",
	.Style_Sheet   = "/style.css",
}

// The answers that the listener gives. An answer other than Ok has no body,
// so no answer repeats a byte of the request.
Status_Answer :: enum u8 {
	Ok,
	Bad_Request,
	Not_Found,
	Method_Not_Allowed,
	Request_Timeout,
	Head_Too_Large,
}

// status_answer_line gives the code and the reason of an answer.
status_answer_line :: proc(answer: Status_Answer) -> string {
	switch answer {
	case .Ok:
		return "200 OK"
	case .Bad_Request:
		return "400 Bad Request"
	case .Not_Found:
		return "404 Not Found"
	case .Method_Not_Allowed:
		return "405 Method Not Allowed"
	case .Request_Timeout:
		return "408 Request Timeout"
	case .Head_Too_Large:
		return "431 Request Header Fields Too Large"
	}
	return "400 Bad Request"
}

// What the page shows that the store does not know.
Cache_Page_Settings :: struct {
	// The public address of the protocol, as a client names it.
	endpoint:     string,
	// The address of the site, with no final '/'.
	site_address: string,
}

// The state of the thread of the page. The free space is read and kept by
// this thread alone, so it needs no lock.
Cache_Status_Listener :: struct {
	server:              ^Cache_Server,
	page:                Cache_Page_Settings,
	style_sheet:         string,
	deadline:            time.Duration,
	disk_free_bytes:     u64,
	disk_free_known:     bool,
	disk_free_read_once: bool,
	disk_free_read_at:   time.Tick,
}

// cache_page_endpoint_valid accepts host:port with the bytes of a name, an
// IPv4 or an IPv6 address only, so that the value can stand in a page and
// in a header with no escape.
cache_page_endpoint_valid :: proc(text: string) -> bool {
	if len(text) == 0 || len(text) > 255 || strings.last_index_byte(text, ':') <= 0 {
		return false
	}
	for index in 0 ..< len(text) {
		character := text[index]
		switch character {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '-', ':', '[', ']':
		case:
			return false
		}
	}
	return true
}

// cache_page_site_address_valid accepts an address of http or https with a
// host and no byte that a header or an attribute must escape. The address
// goes into the policy of the page, so a ';' or a quote is refused.
cache_page_site_address_valid :: proc(text: string) -> bool {
	rest: string
	switch {
	case strings.has_prefix(text, "https://"):
		rest = text[len("https://"):]
	case strings.has_prefix(text, "http://"):
		rest = text[len("http://"):]
	case:
		return false
	}
	if len(rest) == 0 || rest[0] == '/' || len(text) > 255 {
		return false
	}
	for index in 0 ..< len(text) {
		character := text[index]
		if character <= ' ' || character >= 0x7F {
			return false
		}
		switch character {
		case '"', '\'', '<', '>', ';', '?', '#', '\\', '`', ',':
			return false
		}
	}
	return true
}

// status_request_parse reads one whole head, from the request line to the
// empty line included, and gives the path that it asks for. It refuses
// before it reads any field: a byte that no head holds, a line end that is
// not CR LF. Then the form of the request line, then each header line, then
// a header that announces a body, then the method, then the path.
status_request_parse :: proc(head: []u8) -> (path: Status_Path, answer: Status_Answer) {
	for index in 0 ..< len(head) {
		character := head[index]
		switch {
		case character == '\r':
			if index + 1 >= len(head) || head[index + 1] != '\n' {
				return .Page, .Bad_Request
			}
		case character == '\n':
			if index == 0 || head[index - 1] != '\r' {
				return .Page, .Bad_Request
			}
		case character == '\t':
		case character >= 0x20 && character <= 0x7E:
		case:
			return .Page, .Bad_Request
		}
	}
	text := string(head)
	end := strings.index(text, "\r\n\r\n")
	if end < 0 || end + 4 != len(text) {
		return .Page, .Bad_Request
	}
	text = text[:end]
	request_line := text
	header_lines := ""
	if line_end := strings.index(text, "\r\n"); line_end >= 0 {
		request_line = text[:line_end]
		header_lines = text[line_end + 2:]
	}

	first_space := strings.index_byte(request_line, ' ')
	if first_space <= 0 {
		return .Page, .Bad_Request
	}
	method := request_line[:first_space]
	after_method := request_line[first_space + 1:]
	second_space := strings.index_byte(after_method, ' ')
	if second_space <= 0 {
		return .Page, .Bad_Request
	}
	target := after_method[:second_space]
	version := after_method[second_space + 1:]
	if version != "HTTP/1.1" && version != "HTTP/1.0" {
		return .Page, .Bad_Request
	}
	for index in 0 ..< len(method) {
		if method[index] < 'A' || method[index] > 'Z' {
			return .Page, .Bad_Request
		}
	}
	if strings.index_byte(target, '\t') >= 0 {
		return .Page, .Bad_Request
	}

	remaining := header_lines
	for len(remaining) > 0 {
		line := remaining
		if line_end := strings.index(remaining, "\r\n"); line_end >= 0 {
			line = remaining[:line_end]
			remaining = remaining[line_end + 2:]
		} else {
			remaining = ""
		}
		// A line that starts with a space continues the line before: an old
		// form that two readers can split in two ways.
		if len(line) == 0 || line[0] == ' ' || line[0] == '\t' {
			return .Page, .Bad_Request
		}
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			return .Page, .Bad_Request
		}
		name := line[:colon]
		if strings.index_byte(name, ' ') >= 0 || strings.index_byte(name, '\t') >= 0 {
			return .Page, .Bad_Request
		}
		// A GET has no body. A body that the server does not read can hide a
		// second request from the proxy in front of it.
		if strings.equal_fold(name, "content-length") || strings.equal_fold(name, "transfer-encoding") {
			return .Page, .Bad_Request
		}
	}

	if method != "GET" {
		return .Page, .Method_Not_Allowed
	}
	// The path is compared whole: it is never decoded and never joined to a
	// folder, so '..', '%2e' and a query name no file.
	for candidate in Status_Path {
		if target == status_path_texts[candidate] {
			return candidate, .Ok
		}
	}
	return .Page, .Not_Found
}

// status_head_read reads the head of one request, at most len(buffer)
// bytes, within the deadline. closed says that the client closed or broke
// the connection, which gets no answer. A NUL or a byte past ASCII ends the
// read at once: no head holds one.
status_head_read :: proc(socket: net.TCP_Socket, buffer: []u8, deadline: time.Duration) -> (head_length: int, answer: Status_Answer, closed: bool) {
	start := time.tick_now()
	received := 0
	for {
		remaining := deadline - time.tick_since(start)
		if remaining <= 0 {
			return 0, .Request_Timeout, false
		}
		// A receive timeout of zero waits forever.
		_ = net.set_option(socket, .Receive_Timeout, max(remaining, time.Millisecond))
		count, receive_error := net.recv_tcp(socket, buffer[received:])
		if receive_error == .Timeout || receive_error == .Would_Block {
			return 0, .Request_Timeout, false
		}
		if receive_error != .None || count == 0 {
			return 0, .Ok, true
		}
		search_from := max(0, received - 3)
		received += count
		if end := strings.index(string(buffer[search_from:received]), "\r\n\r\n"); end >= 0 {
			return search_from + end + 4, .Ok, false
		}
		for index in received - count ..< received {
			character := buffer[index]
			if character == 0 || character >= 0x80 || (character == '\n' && (index == 0 || buffer[index - 1] != '\r')) {
				return 0, .Bad_Request, false
			}
		}
		if received == len(buffer) {
			return 0, .Head_Too_Large, false
		}
	}
}

// The thread of the page and what it owns, from its start to its stop.
Cache_Status_Running :: struct {
	status_listener: Cache_Status_Listener,
	socket:          net.TCP_Socket,
	worker:          ^thread.Thread,
}

// cache_status_start starts the thread of the page on a listening socket.
// The state lives on the heap until cache_status_stop, which joins the
// thread before it frees the state.
cache_status_start :: proc(server: ^Cache_Server, page: Cache_Page_Settings, socket: net.TCP_Socket, deadline := STATUS_DEFAULT_DEADLINE) -> ^Cache_Status_Running {
	running := new(Cache_Status_Running)
	cache_status_listener_init(&running.status_listener, server, page)
	running.status_listener.deadline = deadline
	running.socket = socket
	running.worker = thread.create_and_start_with_poly_data(running, proc(running: ^Cache_Status_Running) {
		cache_status_serve_listener(&running.status_listener, running.socket)
	})
	return running
}

// cache_status_stop closes the socket, which ends the wait of the thread
// for a connection, joins the thread, then frees its state.
cache_status_stop :: proc(running: ^Cache_Status_Running) {
	_ = net.shutdown(running.socket, .Both)
	net.close(running.socket)
	thread.join(running.worker)
	thread.destroy(running.worker)
	cache_status_listener_destroy(&running.status_listener)
	free(running)
}

// cache_status_listener_init fills the state of the thread of the page and
// makes the style sheet once.
cache_status_listener_init :: proc(status_listener: ^Cache_Status_Listener, server: ^Cache_Server, page: Cache_Page_Settings, allocator := context.allocator) {
	status_listener.server = server
	status_listener.page = Cache_Page_Settings {
		endpoint     = strings.clone(page.endpoint, allocator),
		site_address = strings.clone(page.site_address, allocator),
	}
	status_listener.style_sheet = cache_page_style_sheet(page.site_address, allocator)
	status_listener.deadline = STATUS_DEFAULT_DEADLINE
}

cache_status_listener_destroy :: proc(status_listener: ^Cache_Status_Listener, allocator := context.allocator) {
	delete(status_listener.page.endpoint, allocator)
	delete(status_listener.page.site_address, allocator)
	delete(status_listener.style_sheet, allocator)
	status_listener^ = {}
}

// cache_status_disk_free gives the free space, read again when the last
// read is older than DISK_FREE_LONGEST_AGE: a flood of requests makes at
// most one call to the system each DISK_FREE_LONGEST_AGE.
cache_status_disk_free :: proc(status_listener: ^Cache_Status_Listener) -> (bytes: u64, known: bool) {
	now := time.tick_now()
	if !status_listener.disk_free_read_once || time.tick_diff(status_listener.disk_free_read_at, now) > DISK_FREE_LONGEST_AGE {
		status_listener.disk_free_bytes, status_listener.disk_free_known = cache_disk_free_bytes(status_listener.server.root_directory)
		status_listener.disk_free_read_once = true
		status_listener.disk_free_read_at = now
	}
	return status_listener.disk_free_bytes, status_listener.disk_free_known
}

@(private = "file")
status_answer_write :: proc(socket: net.TCP_Socket, answer: Status_Answer, content_type: string, cache_control: string, security_policy: string, body: []u8) -> bool {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "HTTP/1.1 %s\r\nContent-Length: %d\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n", status_answer_line(answer), len(body))
	if answer == .Method_Not_Allowed {
		strings.write_string(&b, "Allow: GET\r\n")
	}
	if content_type != "" {
		fmt.sbprintf(&b, "Content-Type: %s\r\n", content_type)
	}
	if cache_control != "" {
		fmt.sbprintf(&b, "Cache-Control: %s\r\n", cache_control)
	}
	if security_policy != "" {
		fmt.sbprintf(&b, "Content-Security-Policy: %s\r\n", security_policy)
	}
	strings.write_string(&b, "\r\n")
	if !tcp_write_all(socket, b.buf[:]) {
		return false
	}
	return len(body) == 0 || tcp_write_all(socket, body)
}

// The bytes that the server reads and drops after its answer, at most.
STATUS_LINGER_BOUND :: 4 * STATUS_HEAD_BOUND

// status_linger ends the answer, then reads and drops what the client still
// sends, until it closes, for the deadline and STATUS_LINGER_BOUND bytes at
// most. A close with bytes unread makes the system send a reset, which can
// remove the answer before the client reads it.
@(private = "file")
status_linger :: proc(socket: net.TCP_Socket, deadline: time.Duration) {
	_ = net.shutdown(socket, .Send)
	start := time.tick_now()
	dropped := 0
	buffer: [512]u8
	for dropped < STATUS_LINGER_BOUND {
		remaining := deadline - time.tick_since(start)
		if remaining <= 0 {
			return
		}
		_ = net.set_option(socket, .Receive_Timeout, max(remaining, time.Millisecond))
		count, receive_error := net.recv_tcp(socket, buffer[:])
		if receive_error != .None || count == 0 {
			return
		}
		dropped += count
	}
}

// cache_status_serve_connection answers one request and returns: the
// caller closes the connection, so bytes after the first head get no
// answer.
cache_status_serve_connection :: proc(status_listener: ^Cache_Status_Listener, socket: net.TCP_Socket) {
	defer free_all(context.temp_allocator)
	defer status_linger(socket, status_listener.deadline)
	_ = net.set_option(socket, .Send_Timeout, status_listener.deadline)
	buffer: [STATUS_HEAD_BOUND]u8
	head_length, read_answer, closed := status_head_read(socket, buffer[:], status_listener.deadline)
	if closed {
		return
	}
	if read_answer != .Ok {
		_ = status_answer_write(socket, read_answer, "", "", "", nil)
		return
	}
	path, answer := status_request_parse(buffer[:head_length])
	if answer != .Ok {
		_ = status_answer_write(socket, answer, "", "", "", nil)
		return
	}
	switch path {
	case .Page:
		snapshot := cache_status_snapshot(&status_listener.server.status)
		disk_free, disk_free_known := cache_status_disk_free(status_listener)
		html := cache_page_html(status_listener.server, status_listener.page, snapshot, disk_free, disk_free_known)
		_ = status_answer_write(socket, .Ok, "text/html; charset=utf-8", "no-store", cache_page_security_policy(status_listener.page.site_address), transmute([]u8)html)
	case .Status_Record:
		snapshot := cache_status_snapshot(&status_listener.server.status)
		disk_free, disk_free_known := cache_status_disk_free(status_listener)
		record := cache_status_json(status_listener.server, status_listener.page, snapshot, disk_free, disk_free_known, time.now())
		_ = status_answer_write(socket, .Ok, "application/json", "no-store", "default-src 'none'; frame-ancestors 'none'", transmute([]u8)record)
	case .Style_Sheet:
		_ = status_answer_write(socket, .Ok, "text/css; charset=utf-8", "max-age=3600", "", transmute([]u8)status_listener.style_sheet)
	}
}

// cache_status_serve_listener answers one connection at a time until the
// server stops or the listener is closed. The page is a view, not the
// service: a slow client holds this thread for the deadline at most.
cache_status_serve_listener :: proc(status_listener: ^Cache_Status_Listener, listener: net.TCP_Socket) {
	for !sync.atomic_load(&status_listener.server.stop) {
		client, _, accept_error := net.accept_tcp(listener)
		if accept_error != nil {
			return
		}
		cache_status_serve_connection(status_listener, client)
		net.close(client)
	}
}

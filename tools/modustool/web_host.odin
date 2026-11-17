package modustool

import "core:strconv"

import "modus:support/calendar"

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "modus:support/web"

// The test of TCP against a stack that this project did not write
// (docs/NETWORK.md). The machine has QEMU user networking: its TCP talks
// to the TCP of libslirp, which comes from 4.4BSD. Two ways:
//
//   hostfwd   a port of the loopback of the host goes to the port 80 of the
//             machine: the tool connects with core:net (the TCP of the host)
//             and fetches the pages of `server` (forward_fetch).
//   guestfwd  the address 10.0.2.100 port 80 of the network of the machine
//             goes to a port where the tool listens with core:net: the
//             program `fetch` connects to it (Listener).
//
// The listener answers as `server` does: GET /hello, GET /large, and POST
// /sink, which gives the length and the hash of the body. A scenario can
// give it files too: GET of the path of a file answers its bytes (the
// module file that the module file service of the machine fetches).

GUEST_ADDRESS :: "10.0.2.100" // The address of the listener on the network of the machine.

Forward :: struct {
	host_port: int, // hostfwd: this port of the loopback of the host is the port 80 of the machine.
	listener:  ^Listener,
}

// A file that the listener serves: GET of its path answers its bytes.
Listener_File :: struct {
	path:  string,
	bytes: []u8,
}

Listener :: struct {
	socket:     net.TCP_Socket,
	client:     net.TCP_Socket, // The connection that the listener serves; 0: none.
	port:       int,
	thread:     ^thread.Thread,
	stop:       bool,
	requests:   int,
	sink_bytes: int,
	failure:    string,
	files:      []Listener_File, // Set before the thread starts, and never changed: the thread reads it with no lock.
}

// The ports of the loopback that this process gave to a QEMU, which binds
// each one itself after the tool closed its own socket. Between the close
// and the bind of QEMU, the system can give the same number to the next
// socket of another machine that runs at the same time: so the tool never
// gives a number again while it is in this list. Another program of the
// host can still take a port in that time; the system then refuses the
// bind of QEMU, and the machine fails at its start with that reason.
Given_Loopback_Ports :: struct {
	lock:  sync.Mutex,
	ports: [dynamic]int,
}

given_loopback_ports: Given_Loopback_Ports

// The sockets that one search for a free port holds open: each new socket
// gets a number that none of them has. A bound: the list of the given ports
// holds a few numbers for each machine that runs.
FREE_PORT_TRIES :: 16

// loopback_port_give adds a port to the given ports, and says if it was not
// there.
loopback_port_give :: proc(port: int) -> bool {
	sync.mutex_lock(&given_loopback_ports.lock)
	defer sync.mutex_unlock(&given_loopback_ports.lock)
	for given in given_loopback_ports.ports {
		if given == port {
			return false
		}
	}
	append(&given_loopback_ports.ports, port)
	return true
}

// loopback_port_take_back removes a port from the given ports, when the
// QEMU that bound it ended. 0 is no port.
loopback_port_take_back :: proc(port: int) {
	if port == 0 {
		return
	}
	sync.mutex_lock(&given_loopback_ports.lock)
	defer sync.mutex_unlock(&given_loopback_ports.lock)
	for given, place in given_loopback_ports.ports {
		if given == port {
			unordered_remove(&given_loopback_ports.ports, place)
			return
		}
	}
}

// free_port gives a TCP port of the loopback that no socket holds now and
// that this process gave to no QEMU that runs. The caller takes it back
// with loopback_port_take_back.
free_port :: proc() -> (port: int, ok: bool) {
	held := make([dynamic]net.TCP_Socket, context.temp_allocator)
	defer {
		for socket in held {
			net.close(socket)
		}
	}
	for _ in 0 ..< FREE_PORT_TRIES {
		socket, err := net.listen_tcp({net.IP4_Loopback, 0})
		if err != nil {
			return 0, false
		}
		append(&held, socket)
		bound, bound_err := net.bound_endpoint(socket)
		if bound_err != nil {
			return 0, false
		}
		if loopback_port_give(bound.port) {
			return bound.port, true
		}
	}
	return 0, false
}

// free_udp_port gives a UDP port of the loopback as free_port does.
free_udp_port :: proc() -> (endpoint: net.Endpoint, ok: bool) {
	held := make([dynamic]net.UDP_Socket, context.temp_allocator)
	defer {
		for socket in held {
			net.close(socket)
		}
	}
	for _ in 0 ..< FREE_PORT_TRIES {
		socket, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
		if err != nil {
			return {}, false
		}
		append(&held, socket)
		bound, bound_err := net.bound_endpoint(socket)
		if bound_err != nil {
			return {}, false
		}
		if loopback_port_give(bound.port) {
			return bound, true
		}
	}
	return {}, false
}

listener_start :: proc(listener: ^Listener, files: []Listener_File = nil) -> bool {
	socket, err := net.listen_tcp({net.IP4_Loopback, 0})
	if err != nil {
		fmt.eprintfln("modustool: the listener has no TCP socket: %v", err)
		return false
	}
	bound, bound_err := net.bound_endpoint(socket)
	if bound_err != nil {
		net.close(socket)
		return false
	}
	listener^ = {socket = socket, port = bound.port, files = files}
	listener.thread = thread.create_and_start_with_poly_data(listener, listener_run)
	return true
}

listener_stop :: proc(listener: ^Listener) {
	if listener.thread == nil {
		return
	}
	sync.atomic_store(&listener.stop, true)
	// A shutdown ends a receive that waits, and the accept.
	if client := net.TCP_Socket(sync.atomic_load((^int)(&listener.client))); client != 0 {
		_ = net.shutdown(client, .Both)
	}
	_ = net.shutdown(listener.socket, .Both)
	net.close(listener.socket)
	thread.join(listener.thread)
	thread.destroy(listener.thread)
	listener.thread = nil
}

listener_run :: proc(listener: ^Listener) {
	for !sync.atomic_load(&listener.stop) {
		client, _, err := net.accept_tcp(listener.socket)
		if err != nil {
			return
		}
		// QEMU connects when it starts, long before `fetch` sends a request:
		// the receive waits with no time limit.
		sync.atomic_store((^int)(&listener.client), int(client))
		listener_serve(listener, client)
		sync.atomic_store((^int)(&listener.client), 0)
		net.close(client)
	}
}

// listener_file_find gives the place of the file of a path, or -1.
listener_file_find :: proc(files: []Listener_File, path: string) -> int {
	for item, index in files {
		if item.path == path {
			return index
		}
	}
	return -1
}

// send_all sends each byte, or says that it could not.
send_all :: proc(socket: net.TCP_Socket, bytes: []u8) -> bool {
	for sent := 0; sent < len(bytes); {
		count, err := net.send_tcp(socket, bytes[sent:])
		if err != nil || count <= 0 {
			return false
		}
		sent += count
	}
	return true
}

// listener_serve answers the requests of one connection until its end.
listener_serve :: proc(listener: ^Listener, client: net.TCP_Socket) {
	buffer: [65536]u8
	length := 0
	for !sync.atomic_load(&listener.stop) {
		if web.head_end(buffer[:length]) == 0 {
			count, err := net.recv_tcp(client, buffer[length:])
			if err != nil || count == 0 {
				return
			}
			length += count
			continue
		}
		head, ok := web.head_read(buffer[:length])
		rest := buffer[head.size:length]
		if !ok {
			listener.failure = "a request that the listener cannot read"
			return
		}
		path := web.path(&head)
		answer: string
		switch {
		case head.method == .Get && path == "/hello":
			answer = "hello from the host\n"
		case head.method == .Get && path == "/large":
			head_text := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n", web.LARGE_SIZE)
			if !send_all(client, transmute([]u8)head_text) {
				return
			}
			chunk: [16384]u8
			for offset := 0; offset < web.LARGE_SIZE; offset += len(chunk) {
				web.pattern_fill(chunk[:], offset)
				if !send_all(client, chunk[:min(len(chunk), web.LARGE_SIZE - offset)]) {
					return
				}
			}
			sync.atomic_add(&listener.requests, 1)
			length = copy(buffer[:], rest)
			continue
		case head.method == .Post && path == "/sink" && head.content_length >= 0:
			hash := u64(web.FNV_START)
			taken := min(len(rest), head.content_length)
			hash = web.fnv(hash, rest[:taken])
			received := taken
			for received < head.content_length {
				count, err := net.recv_tcp(client, buffer[:min(len(buffer), head.content_length - received)])
				if err != nil || count == 0 {
					listener.failure = "the body of /sink ended early"
					return
				}
				hash = web.fnv(hash, buffer[:count])
				received += count
			}
			listener.sink_bytes = received
			answer = fmt.tprintf("received %d bytes, fnv1a64 %016x\n", received, hash)
			rest = nil
		case head.method == .Get && listener_file_find(listener.files, path) >= 0:
			served := listener.files[listener_file_find(listener.files, path)]
			head_text := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n", len(served.bytes))
			if !send_all(client, transmute([]u8)head_text) || !send_all(client, served.bytes) {
				return
			}
			sync.atomic_add(&listener.requests, 1)
			length = copy(buffer[:], rest)
			continue
		case:
			answer = "no such page\n"
		}
		text := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s", len(answer), answer)
		if !send_all(client, transmute([]u8)text) {
			return
		}
		sync.atomic_add(&listener.requests, 1)
		length = copy(buffer[:], rest)
		free_all(context.temp_allocator)
	}
}

// forward_fetch fetches a page of `server` through hostfwd, with the TCP of
// the host. "/sink" sends a body of LARGE_SIZE bytes. It prints one line
// with the result, and says if the result is the expected one.
forward_fetch :: proc(forward: Forward, path: string, clock_offset_seconds: i64) -> bool {
	socket, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, forward.host_port})
	if err != nil {
		fmt.eprintfln("modustool: test failed: the host cannot connect to the port %d (hostfwd to the port 80 of the machine): %v", forward.host_port, err)
		return false
	}
	defer net.close(socket)
	_ = net.set_option(socket, .Receive_Timeout, HTTP_HOST_WAIT_LIMIT)
	start := time.tick_now()
	request_unix := time.time_to_unix(time.now()) // No date in the answer is before it.
	request: string
	body := path == "/sink"
	if body {
		request = fmt.tprintf("POST /sink HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", web.LARGE_SIZE)
	} else {
		request = fmt.tprintf("GET %s HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: close\r\n\r\n", path)
	}
	if !send_all(socket, transmute([]u8)request) {
		fmt.eprintln("modustool: test failed: the host could not send its request")
		return false
	}
	if body {
		chunk: [16384]u8
		for offset := 0; offset < web.LARGE_SIZE; offset += len(chunk) {
			web.pattern_fill(chunk[:], offset)
			if !send_all(socket, chunk[:]) {
				fmt.eprintln("modustool: test failed: the host could not send the body of /sink")
				return false
			}
		}
	}
	// The response, to the end of the connection: the server closes it.
	response := make([dynamic]u8, context.temp_allocator)
	buffer: [65536]u8
	for {
		count, recv_err := net.recv_tcp(socket, buffer[:])
		if recv_err != nil || count == 0 {
			break
		}
		append(&response, ..buffer[:count])
	}
	took := time.tick_since(start)
	head, ok := web.head_read(response[:])
	if !ok || head.status != 200 || len(response) - head.size != head.content_length {
		fmt.eprintfln("modustool: test failed: the host fetched %s and read %d bytes, the status %d and the Content-Length %d", path, len(response), head.status, head.content_length)
		return false
	}
	content := response[head.size:]
	// RFC 9110 6.6.1: the server sends the date of the machine.
	head_text := string(response[:head.size])
	date_at := strings.index(head_text, "\r\nDate: ")
	if date_at < 0 {
		fmt.eprintfln("modustool: test failed: the answer of server to %s has no field Date", path)
		return false
	}
	date_line := head_text[date_at + 8:]
	date_line = date_line[:max(strings.index(date_line, "\r\n"), 0)]
	date_seconds, date_ok := http_date_parse(date_line)
	if !date_ok {
		fmt.eprintfln("modustool: test failed: the field Date of server is \"%s\": not the form of RFC 9110 5.6.7", date_line)
		return false
	}
	date_check(-1, date_seconds, fmt.tprintf("the field Date \"%s\" of the answer to %s", date_line, path), request_unix, clock_offset_seconds) or_return
	speed := f64(max(len(content), body ? web.LARGE_SIZE : 0)) / max(time.duration_seconds(took), 1e-9) / 1e6
	switch path {
	case "/large":
		hash := web.fnv(web.FNV_START, content)
		if len(content) != web.LARGE_SIZE || hash != web.pattern_hash(web.LARGE_SIZE) {
			fmt.eprintfln("modustool: test failed: /large from the machine has %d bytes and the hash %016x", len(content), hash)
			return false
		}
		test_passed_print("the TCP of the host fetched /large from server through libslirp: %d bytes, fnv1a64 %016x as expected, %.1f MB/s", len(content), hash, speed)
	case "/sink":
		wanted := fmt.tprintf("received %d bytes, fnv1a64 %016x", web.LARGE_SIZE, web.pattern_hash(web.LARGE_SIZE))
		if !strings.has_prefix(string(content), wanted) {
			fmt.eprintfln("modustool: test failed: server answered \"%s\" to /sink, not \"%s\"", string(content), wanted)
			return false
		}
		test_passed_print("the TCP of the host sent 1 MiB to server through libslirp, and server gave the same hash, %.1f MB/s", speed)
	case:
		test_passed_print("the TCP of the host fetched %s from server through libslirp: %d bytes in %.2f ms: \"%s\"", path, len(content), time.duration_milliseconds(took), strings.trim_space(strings.split_lines(string(content), context.temp_allocator)[0]))
	}
	return true
}

// The frames of the machine with libslirp, beside its log: two machines
// that run at the same time write two files. `run` has no log file.
FRAMES_OF_USER_NETWORK :: BUILD_FOLDER + "/frames_of_user_network.pcap"
FRAMES_OF_USER_NETWORK_SUFFIX :: "_frames_of_user_network.pcap"

frames_of_user_network_file :: proc(test_output: string) -> string {
	return test_output != "" ? machine_file(test_output, FRAMES_OF_USER_NETWORK_SUFFIX) : FRAMES_OF_USER_NETWORK
}

// frames_of_the_fetch_report reads the frames that QEMU wrote for the
// machine with libslirp (filter-dump, the pcap format) and prints the frames
// of `GET /hello` of `fetch`: from its request to the end of the answer,
// each with its time after the request, its direction, its flags and its
// bytes of data. It is a measure, not a check. test_output is the log of
// the machine.
frames_of_the_fetch_report :: proc(test_output: string) {
	bytes, err := os.read_entire_file(frames_of_user_network_file(test_output), context.temp_allocator)
	if err != nil || len(bytes) < 24 {
		fmt.println("modustool: no frames of the machine with libslirp")
		return
	}
	read_32_little :: proc(bytes: []u8, offset: int) -> u64 {
		return u64(bytes[offset]) | u64(bytes[offset + 1]) << 8 | u64(bytes[offset + 2]) << 16 | u64(bytes[offset + 3]) << 24
	}
	start: u64
	printed := 0
	after_answer := -1
	for offset := 24; offset + 16 <= len(bytes) && printed < 24; {
		time_of_frame := read_32_little(bytes, offset) * 1_000_000 + read_32_little(bytes, offset + 4)
		length := int(read_32_little(bytes, offset + 8))
		frame := bytes[offset + 16:][:min(length, len(bytes) - offset - 16)]
		offset += 16 + length
		if len(frame) < 54 || frame[12] != 0x08 || frame[13] != 0x00 || frame[23] != 6 {
			continue
		}
		ip := frame[14:]
		header := int(ip[0] & 15) * 4
		total := int(ip[2]) << 8 | int(ip[3])
		segment := ip[header:min(total, len(ip))]
		if len(segment) < 20 {
			continue
		}
		data := segment[int(segment[12] >> 4) * 4:]
		from_machine := ip[12] == 10 && ip[15] == 15
		other := from_machine ? ip[19] : ip[15]
		if other != 100 {
			continue // Only the connection of fetch to 10.0.2.100.
		}
		if start == 0 {
			if !from_machine || !strings.has_prefix(string(data), "GET /hello") {
				continue
			}
			start = time_of_frame
		}
		flags := segment[13]
		names := [6]string{"FIN", "SYN", "RST", "PSH", "ACK", "URG"}
		text := strings.builder_make(context.temp_allocator)
		for name, bit in names {
			if flags >> uint(bit) & 1 != 0 {
				strings.write_string(&text, name)
				strings.write_byte(&text, ' ')
			}
		}
		fmt.printfln("modustool: a frame of GET /hello through libslirp: +%d us, %s, %s%d bytes of data%s", time_of_frame - start, from_machine ? "fetch to libslirp" : "libslirp to fetch", strings.to_string(text), len(data), strings.has_prefix(string(data), "HTTP/1.1") ? " (the answer)" : "")
		printed += 1
		if !from_machine && strings.has_prefix(string(data), "HTTP/1.1") {
			after_answer = 2
		} else if after_answer > 0 {
			after_answer -= 1
		}
		if after_answer == 0 {
			break
		}
	}
}

// http_date_parse reads an IMF-fixdate (RFC 9110 5.6.7):
// "Sun, 06 Nov 1994 08:49:37 GMT".
http_date_parse :: proc(text: string) -> (seconds: i64, ok: bool) {
	if len(text) != 29 || text[3] != ',' || text[25:] != " GMT" {
		return 0, false
	}
	month := 0
	for name, index in calendar.MONTH_SHORT_NAMES {
		if text[8:11] == name {
			month = index + 1
		}
	}
	day, day_ok := strconv.parse_int(text[5:7])
	year, year_ok := strconv.parse_i64(text[12:16])
	hour, hour_ok := strconv.parse_int(text[17:19])
	minute, minute_ok := strconv.parse_int(text[20:22])
	second, second_ok := strconv.parse_int(text[23:25])
	if month == 0 || !day_ok || !year_ok || !hour_ok || !minute_ok || !second_ok {
		return 0, false
	}
	value := calendar.Civil{year = year, month = month, day = day, hour = hour, minute = minute, second = second}
	seconds = calendar.seconds_of(value)
	return seconds, calendar.WEEKDAY_SHORT_NAMES[calendar.civil(seconds).weekday] == text[:3]
}

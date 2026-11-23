package agent_runner

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"
import assistant_contract "modus:contract/assistant"

// One turn of the conversation that the model reads.
Turn_Role :: enum {
	Principal, // A request of the principal: the role user.
	Model, // A reply of the model that passed the border, with its acts as calls: the role assistant.
	Outcome, // The outcome of one act, as the window shows it: the role tool, never the principal.
}

// One act of a reply of the model, as a call that an outcome answers.
Turn_Call :: struct {
	id:   string,
	kind: assistant_contract.Act_Kind,
	line: string,
}

Turn :: struct {
	role:    Turn_Role,
	text:    string,
	calls:   []Turn_Call, // Model: the acts of the reply.
	call_id: string, // Outcome: the id of the call that it answers.
}

// A model: it gives the raw text of its reply to a conversation, which the
// runner reads at the border of model_reply_decode. problem is a sentence
// that names no secret.
Model :: struct {
	user_data: rawptr,
	reply:     proc(user_data: rawptr, conversation: []Turn, allocator: mem.Allocator) -> (text: string, problem: string),
}

// The fake model of the tests: a script of replies, given in their order,
// whatever the conversation. A reply can be any text, a malformed one too:
// the border of the runner is what a test checks.
Fake_Model :: struct {
	replies: []string,
	next:    int,
}

fake_model :: proc(fake: ^Fake_Model) -> Model {
	return {user_data = fake, reply = fake_model_reply}
}

@(private = "file")
fake_model_reply :: proc(user_data: rawptr, conversation: []Turn, allocator: mem.Allocator) -> (text: string, problem: string) {
	fake := (^Fake_Model)(user_data)
	if fake.next >= len(fake.replies) {
		return "", "the script of the fake model has no more replies"
	}
	fake.next += 1
	return fake.replies[fake.next - 1], ""
}

// fake_script_read gives the replies of a script: one reply on each line,
// in their order; an empty line is no reply.
fake_script_read :: proc(text: string, allocator := context.allocator) -> []string {
	replies := make([dynamic]string, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if len(strings.trim_space(line)) > 0 {
			append(&replies, strings.clone(line, allocator))
		}
	}
	return replies[:]
}

// The variables of the host that configure the model.
ENDPOINT_VARIABLE :: "MODUS_ASSISTANT_ENDPOINT"
KEY_VARIABLE :: "MODUS_ASSISTANT_KEY"
MODEL_NAME_VARIABLE :: "MODUS_ASSISTANT_MODEL"

// An endpoint of plain HTTP: the standard library of Odin has no TLS.
Endpoint :: struct {
	host: string,
	port: int,
	path: string,
}

// The option that lets the endpoint be another host than this one: plain
// HTTP then carries the key in clear on the network.
OFF_HOST_OPTION :: "--key-in-clear-off-host"

// endpoint_host_loopback says if a host is this machine: 127.0.0.0/8 as
// four numbers, localhost, or [::1].
endpoint_host_loopback :: proc(host: string) -> bool {
	if host == "localhost" || host == "[::1]" {
		return true
	}
	parts := strings.split(host, ".", context.temp_allocator)
	if len(parts) != 4 || parts[0] != "127" {
		return false
	}
	for part in parts {
		value, ok := strconv.parse_int(part, 10)
		if !ok || value < 0 || value > 255 || len(part) == 0 || len(part) > 3 {
			return false
		}
	}
	return true
}

// endpoint_host_bytes_valid says if each byte of a host is a letter, a
// digit, '.', '-', or the brackets and colons of an address of IPv6: no
// space, no control byte, no line end that would add a line to the head of
// the request.
@(private = "file")
endpoint_host_bytes_valid :: proc(host: string) -> bool {
	for character in transmute([]u8)host {
		switch character {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '-', '[', ']', ':':
		case:
			return false
		}
	}
	return len(host) > 0
}

// key_check refuses a key with a byte that is not visible ASCII: a space,
// a control byte, a line end would add a line to the head of the request.
// The problem never names the key.
key_check :: proc(key: string) -> (problem: string) {
	if len(key) == 0 {
		return "the key is empty"
	}
	for character in transmute([]u8)key {
		if character <= ' ' || character >= 0x7F {
			return "the key has a space, a control byte or a byte that is not ASCII"
		}
	}
	return ""
}

// endpoint_parse reads http://host:port/path. It refuses another scheme
// (https too: a local proxy reaches an endpoint of TLS), a user part, no
// host, a host with a byte that names no host, no port, a port out of 1 to
// 65535, a path that does not start with "/", and a host that is not this
// machine unless off_host_allowed, the option OFF_HOST_OPTION.
endpoint_parse :: proc(url: string, off_host_allowed := false) -> (endpoint: Endpoint, problem: string) {
	PREFIX :: "http://"
	if strings.has_prefix(url, "https://") {
		return {}, "the endpoint is https: the tool has no TLS; name a local proxy, http://127.0.0.1:port/path"
	}
	if !strings.has_prefix(url, PREFIX) {
		return {}, "the endpoint does not start with http://"
	}
	rest := url[len(PREFIX):]
	slash := strings.index_byte(rest, '/')
	if slash < 0 {
		return {}, "the endpoint has no path: http://host:port/path"
	}
	authority, path := rest[:slash], rest[slash:]
	if strings.index_byte(authority, '@') >= 0 {
		return {}, "the endpoint has a user part: give the key in the variable of the key"
	}
	colon := strings.last_index_byte(authority, ':')
	if colon <= 0 {
		return {}, "the endpoint has no host or no port: http://host:port/path"
	}
	host := authority[:colon]
	if !endpoint_host_bytes_valid(host) {
		return {}, "the host of the endpoint has a byte that names no host"
	}
	if !off_host_allowed && !endpoint_host_loopback(host) {
		return {}, "the host of the endpoint is not this machine: plain HTTP would carry the key in clear on the network; give " + OFF_HOST_OPTION + " to accept that risk"
	}
	port, port_ok := strconv.parse_int(authority[colon + 1:], 10)
	if !port_ok || port < 1 || port > 65535 {
		return {}, "the port of the endpoint is not 1 to 65535"
	}
	for character in transmute([]u8)path {
		if character <= ' ' || character >= 0x7F {
			return {}, "the path of the endpoint has a space or a byte that is no ASCII"
		}
	}
	return {host = host, port = port, path = path}, ""
}

// The time for one answer of the endpoint: the send and the receive
// together. A model that thinks answers within it; an endpoint that stalls
// fails the turn, and the window shows No_Answer.
MODEL_ANSWER_DEADLINE :: 120 * time.Second

// The model behind an endpoint of the chat completions form.
Http_Model :: struct {
	endpoint:        Endpoint,
	key:             string, // Never printed, never written: the problems name its variable only.
	model_name:      string,
	answer_deadline: time.Duration, // 0: MODEL_ANSWER_DEADLINE.
}

http_model :: proc(model: ^Http_Model) -> Model {
	return {user_data = model, reply = http_model_reply}
}

// The words that tell the model what it may reply.
SYSTEM_PROMPT :: "You are the assistant of a principal of the modus operating system. Reply with one JSON object and nothing else: {\"text\": \"words for the principal\", \"acts\": [{\"kind\": \"eval_lex\", \"line\": \"monitor.processes()\"}]}. The acts are optional, at most 4. An act is one call of Lex, service.export(arguments) with literal arguments. The calls that read run at once: log.records, monitor.processes, monitor.counts, monitor.count, compositor.windows, plans.status. Any other call waits for the principal on the trusted display, and you never answer it."

// http_request_build writes the request of a conversation: a POST with the
// key in the header Authorization and the conversation as JSON.
http_request_build :: proc(model: ^Http_Model, conversation: []Turn, allocator := context.temp_allocator) -> string {
	body := strings.builder_make(allocator)
	strings.write_string(&body, `{"model":`)
	json_string_write(&body, model.model_name)
	strings.write_string(&body, `,"messages":[{"role":"system","content":`)
	json_string_write(&body, SYSTEM_PROMPT)
	strings.write_string(&body, "}")
	for turn in conversation {
		switch turn.role {
		case .Principal:
			strings.write_string(&body, `,{"role":"user","content":`)
			json_string_write(&body, turn.text)
		case .Model:
			strings.write_string(&body, `,{"role":"assistant","content":`)
			json_string_write(&body, turn.text)
			if len(turn.calls) > 0 {
				strings.write_string(&body, `,"tool_calls":[`)
				for call, index in turn.calls {
					if index > 0 {
						strings.write_byte(&body, ',')
					}
					strings.write_string(&body, `{"id":`)
					json_string_write(&body, call.id)
					strings.write_string(&body, `,"type":"function","function":{"name":`)
					json_string_write(&body, assistant_contract.ACT_KIND_NAMES[call.kind])
					// The arguments of a call are a JSON object written as a
					// JSON string.
					arguments := strings.builder_make(allocator)
					strings.write_string(&arguments, `{"line":`)
					json_string_write(&arguments, call.line)
					strings.write_byte(&arguments, '}')
					strings.write_string(&body, `,"arguments":`)
					json_string_write(&body, strings.to_string(arguments))
					strings.write_string(&body, "}}")
				}
				strings.write_byte(&body, ']')
			}
		case .Outcome:
			strings.write_string(&body, `,{"role":"tool","tool_call_id":`)
			json_string_write(&body, turn.call_id)
			strings.write_string(&body, `,"content":`)
			json_string_write(&body, turn.text)
		}
		strings.write_string(&body, "}")
	}
	strings.write_string(&body, "]}")
	request := strings.builder_make(allocator)
	fmt.sbprintf(&request, "POST %s HTTP/1.1\r\nHost: %s:%d\r\nContent-Type: application/json\r\nAuthorization: Bearer %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", model.endpoint.path, model.endpoint.host, model.endpoint.port, model.key, strings.builder_len(body))
	strings.write_string(&request, strings.to_string(body))
	return strings.to_string(request)
}

// json_string_write writes a text as a JSON string.
json_string_write :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for character in transmute([]u8)text {
		switch character {
		case '"':
			strings.write_string(builder, "\\\"")
		case '\\':
			strings.write_string(builder, "\\\\")
		case '\n':
			strings.write_string(builder, "\\n")
		case '\r':
			strings.write_string(builder, "\\r")
		case '\t':
			strings.write_string(builder, "\\t")
		case:
			if character < 0x20 {
				fmt.sbprintf(builder, "\\u%04x", character)
			} else {
				strings.write_byte(builder, character)
			}
		}
	}
	strings.write_byte(builder, '"')
}

// The bytes of an answer of the endpoint at most.
HTTP_ANSWER_BYTES :: 256 * 1024

// http_answer_content reads an answer of the endpoint: the status 200, a
// body whole by its length, in chunks, or to the end of the connection, and
// the text of choices[0].message.content. The text then passes the border
// of the model reply.
http_answer_content :: proc(answer: []u8, allocator := context.temp_allocator) -> (content: string, problem: string) {
	text := string(answer)
	head_end := strings.index(text, "\r\n\r\n")
	if head_end < 0 {
		return "", "the answer of the endpoint has no whole head"
	}
	head, body := text[:head_end], text[head_end + 4:]
	lines := strings.split(head, "\r\n", context.temp_allocator)
	status_parts := strings.fields(lines[0], context.temp_allocator)
	if len(status_parts) < 2 || !strings.has_prefix(status_parts[0], "HTTP/1.") {
		return "", "the answer of the endpoint has no status line"
	}
	// The status is three digits: only such a token is printed, so an
	// answer never writes its own words in the problem.
	status := status_parts[1]
	if len(status) != 3 || !(status[0] >= '1' && status[0] <= '5') || !(status[1] >= '0' && status[1] <= '9') || !(status[2] >= '0' && status[2] <= '9') {
		return "", "the status of the answer of the endpoint is not three digits"
	}
	if status != "200" {
		return "", fmt.tprintf("the endpoint answered with the status %s", status)
	}
	chunked := false
	length := -1
	for line in lines[1:] {
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		name := strings.to_lower(strings.trim_space(line[:colon]), context.temp_allocator)
		value := strings.trim_space(line[colon + 1:])
		switch name {
		case "transfer-encoding":
			chunked = strings.contains(strings.to_lower(value, context.temp_allocator), "chunked")
		case "content-length":
			parsed, ok := strconv.parse_int(value, 10)
			if !ok || parsed < 0 {
				return "", "the answer of the endpoint has a length that is no number"
			}
			length = parsed
		}
	}
	switch {
	case chunked:
		whole, whole_ok := chunks_join(body, allocator)
		if !whole_ok {
			return "", "the chunks of the answer of the endpoint are not whole"
		}
		body = whole
	case length >= 0:
		if length > len(body) {
			return "", "the answer of the endpoint is shorter than its length"
		}
		body = body[:length]
	}
	// The parser of the standard library descends once for each level: a
	// body nested deeper than the bound is refused before it.
	if !json_depth_within(body, JSON_DEPTH_BOUND) {
		return "", "the body of the answer of the endpoint is nested deeper than the bound"
	}
	parsed, parse_error := json.parse_string(body, .JSON, true, allocator)
	if parse_error != .None {
		return "", "the body of the answer of the endpoint is no JSON"
	}
	root, root_ok := parsed.(json.Object)
	choices, choices_ok := root["choices"].(json.Array)
	if !root_ok || !choices_ok || len(choices) == 0 {
		return "", "the answer of the endpoint has no choices"
	}
	choice, choice_ok := choices[0].(json.Object)
	message, message_ok := choice["message"].(json.Object)
	if !choice_ok || !message_ok {
		return "", "the first choice of the answer has no message"
	}
	content_value, content_ok := message["content"].(json.String)
	if !content_ok {
		return "", "the message of the answer has no text content"
	}
	return string(content_value), ""
}

// The levels of arrays and objects of an answer of the endpoint at most:
// the chat completions form uses five.
JSON_DEPTH_BOUND :: 32

// json_depth_within says if no array or object of a JSON text is nested
// deeper than bound, counting the brackets outside the strings.
json_depth_within :: proc(text: string, bound: int) -> bool {
	depth := 0
	in_string, escaped := false, false
	for character in transmute([]u8)text {
		switch {
		case in_string && escaped:
			escaped = false
		case in_string && character == '\\':
			escaped = true
		case in_string && character == '"':
			in_string = false
		case in_string:
		case character == '"':
			in_string = true
		case character == '[' || character == '{':
			depth += 1
			if depth > bound {
				return false
			}
		case character == ']' || character == '}':
			depth -= 1
		}
	}
	return true
}

chunks_join :: proc(body: string, allocator: mem.Allocator) -> (whole: string, ok: bool) {
	builder := strings.builder_make(allocator)
	rest := body
	for {
		line_end := strings.index(rest, "\r\n")
		if line_end < 0 {
			return "", false
		}
		size_text := rest[:line_end]
		if semicolon := strings.index_byte(size_text, ';'); semicolon >= 0 {
			size_text = size_text[:semicolon]
		}
		size, size_ok := strconv.parse_int(strings.trim_space(size_text), 16)
		if !size_ok || size < 0 {
			return "", false
		}
		rest = rest[line_end + 2:]
		if size == 0 {
			return strings.to_string(builder), true
		}
		// size can be near the largest int: compare it with the room left,
		// never add to it.
		if len(rest) < 2 || size > len(rest) - 2 {
			return "", false
		}
		strings.write_string(&builder, rest[:size])
		rest = rest[size + 2:]
	}
}

@(private = "file")
http_model_reply :: proc(user_data: rawptr, conversation: []Turn, allocator: mem.Allocator) -> (text: string, problem: string) {
	model := (^Http_Model)(user_data)
	deadline := model.answer_deadline > 0 ? model.answer_deadline : MODEL_ANSWER_DEADLINE
	start := time.now()
	stalled := fmt.tprintf("the endpoint gave no whole answer within %v", deadline)
	// The connection to this machine is immediate; another host has the
	// bound of the operating system, as the standard library gives no
	// other.
	socket, dial_error := net.dial_tcp_from_hostname_with_port_override(model.endpoint.host, model.endpoint.port)
	if dial_error != nil {
		return "", fmt.tprintf("the endpoint %s:%d does not answer: %v", model.endpoint.host, model.endpoint.port, dial_error)
	}
	defer net.close(socket)
	// remaining_set gives the socket the time left of the deadline for its
	// next send or receive, and says false when none is left.
	remaining_set :: proc(socket: net.TCP_Socket, start: time.Time, deadline: time.Duration) -> bool {
		left := deadline - time.since(start)
		if left <= 0 {
			return false
		}
		// The timeout of a socket is at least a millisecond: 0 would wait
		// forever.
		left = max(left, time.Millisecond)
		return net.set_option(socket, .Send_Timeout, left) == nil && net.set_option(socket, .Receive_Timeout, left) == nil
	}
	request := http_request_build(model, conversation)
	for sent := 0; sent < len(request); {
		if !remaining_set(socket, start, deadline) {
			return "", stalled
		}
		count, send_error := net.send_tcp(socket, transmute([]u8)request[sent:])
		if send_error != nil || count <= 0 {
			if send_error == .Timeout || send_error == .Would_Block || time.since(start) >= deadline {
				return "", stalled
			}
			return "", "the request did not reach the endpoint"
		}
		sent += count
	}
	answer := make([]u8, HTTP_ANSWER_BYTES, context.temp_allocator)
	received := 0
	for received < len(answer) {
		if !remaining_set(socket, start, deadline) {
			return "", stalled
		}
		count, receive_error := net.recv_tcp(socket, answer[received:])
		if receive_error != nil {
			if receive_error == .Timeout || receive_error == .Would_Block || time.since(start) >= deadline {
				return "", stalled
			}
			return "", "the answer of the endpoint broke"
		}
		if count == 0 {
			break
		}
		received += count
	}
	if received == len(answer) {
		return "", fmt.tprintf("the answer of the endpoint is longer than %d bytes", HTTP_ANSWER_BYTES)
	}
	return http_answer_content(answer[:received], allocator)
}

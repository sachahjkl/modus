// Strict HTTP/1.1 request encoder and response parser (RFC 9110, RFC 9112).
// Pure freestanding contract package with zero heap allocations.
package http_client

import "modus:contract/enum_word"

MAX_HEADER_BLOCK_SIZE :: 8192
MAX_HEADERS :: 64
MAX_HEADER_NAME_LEN :: 128
MAX_HEADER_VALUE_LEN :: 1024
MAX_CHUNK_SIZE :: 16 * 1024 * 1024
MAX_BODY_SIZE :: 16 * 1024 * 1024

// Supported HTTP request methods. Zero is invalid and refused at the border.
Http_Method :: enum u8 {
	Get    = 1,
	Head   = 2,
	Post   = 3,
	Put    = 4,
	Delete = 5,
}

// Supported HTTP protocol versions.
Http_Version :: enum u8 {
	Http_1_0 = 1,
	Http_1_1 = 2,
	Http_3   = 3,
}

// Refusal codes for HTTP encoding, parsing, and framing.
Http_Parse_Refusal :: enum u8 {
	None                          = 0,
	Incomplete                    = 1,
	Invalid_Method                = 2,
	Invalid_Target                = 3,
	Invalid_Host                  = 4,
	Header_Injection              = 5,
	Invalid_Status_Line           = 6,
	Unsupported_Version           = 7,
	Invalid_Status_Code           = 8,
	Malformed_Header              = 9,
	Header_Too_Large              = 10,
	Too_Many_Headers              = 11,
	Smuggling_Cl_And_Te           = 12,
	Conflicting_Content_Length    = 13,
	Invalid_Content_Length        = 14,
	Unsupported_Transfer_Encoding = 15,
	Invalid_Chunk_Size            = 16,
	Chunk_Incomplete              = 17,
	Chunk_Missing_Crlf            = 18,
	Body_Too_Large                = 19,
	Buffer_Too_Small              = 20,
	Forbidden_H2_Frame            = 21,
	Malformed_Frame               = 22,
}

// A borrowed header name/value pair for request encoding.
Http_Header_Input :: struct {
	name:  string,
	value: string,
}

// A fixed-capacity parsed HTTP header stored inside Http_Response_Head.
Http_Parsed_Header :: struct {
	name:      [MAX_HEADER_NAME_LEN]u8,
	name_len:  u16,
	value:     [MAX_HEADER_VALUE_LEN]u8,
	value_len: u16,
}

// Parsed HTTP response head with smuggling-checked body framing metadata.
Http_Response_Head :: struct {
	version:            Http_Version,
	status_code:        u16,
	head_size:          int,
	has_content_length: bool,
	content_length:     u64,
	is_chunked:         bool,
	connection_close:   bool,
	header_count:       int,
	headers:            [MAX_HEADERS]Http_Parsed_Header,
}

// Strict wire-to-enum borders.

http_method_of_word :: proc "contextless" (word: u8) -> (method: Http_Method, ok: bool) {
	return enum_word.member_of_word(Http_Method, u64(word))
}

http_version_of_word :: proc "contextless" (word: u8) -> (ver: Http_Version, ok: bool) {
	return enum_word.member_of_word(Http_Version, u64(word))
}

http_method_name :: proc "contextless" (method: Http_Method) -> string {
	switch method {
	case .Get:
		return "GET"
	case .Head:
		return "HEAD"
	case .Post:
		return "POST"
	case .Put:
		return "PUT"
	case .Delete:
		return "DELETE"
	}
	return ""
}

// Token and character validation helpers (RFC 9110 section 5.6.2).

is_tchar :: proc "contextless" (b: u8) -> bool {
	if (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') {
		return true
	}
	switch b {
	case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', 0x60, '|', '~':
		return true
	}
	return false
}

is_valid_header_name :: proc "contextless" (name: []u8) -> bool {
	if len(name) == 0 || len(name) > MAX_HEADER_NAME_LEN {
		return false
	}
	for b in name {
		if !is_tchar(b) {
			return false
		}
	}
	return true
}

has_crlf_or_nul :: proc "contextless" (bytes: []u8) -> bool {
	for b in bytes {
		if b == '\r' || b == '\n' || b == 0 {
			return true
		}
	}
	return false
}

is_valid_header_value :: proc "contextless" (value: []u8) -> bool {
	if len(value) > MAX_HEADER_VALUE_LEN {
		return false
	}
	for b in value {
		if b == '\r' || b == '\n' || b == 0 {
			return false
		}
		// Reject other CTLs except HTAB (0x09).
		if (b < 0x20 && b != '\t') || b == 0x7F {
			return false
		}
	}
	return true
}

is_valid_target :: proc "contextless" (target: []u8) -> (ok: bool, injection: bool) {
	if len(target) == 0 {
		return false, false
	}
	for b in target {
		if b == '\r' || b == '\n' || b == 0 {
			return false, true
		}
		if b <= 0x20 || b >= 0x7F {
			return false, false
		}
	}
	if target[0] != '/' {
		return false, false
	}
	return true, false
}

is_valid_host :: proc "contextless" (host: []u8) -> (ok: bool, injection: bool) {
	if len(host) == 0 || len(host) > 255 {
		return false, false
	}
	for b in host {
		if b == '\r' || b == '\n' || b == 0 {
			return false, true
		}
		if b <= 0x20 || b >= 0x7F || b == '/' || b == '?' || b == '#' || b == '@' {
			return false, false
		}
	}
	return true, false
}

ascii_lower :: proc "contextless" (b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {
		return b + 32
	}
	return b
}

ascii_equal_ci :: proc "contextless" (a: []u8, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i += 1 {
		if ascii_lower(a[i]) != ascii_lower(b[i]) {
			return false
		}
	}
	return true
}

trim_ows :: proc "contextless" (s: []u8) -> []u8 {
	start := 0
	for start < len(s) && (s[start] == ' ' || s[start] == '\t') {
		start += 1
	}
	end := len(s)
	for end > start && (s[end - 1] == ' ' || s[end - 1] == '\t') {
		end -= 1
	}
	return s[start:end]
}

// append_bytes writes src into out[pos^:] with strict bounds checking.
@(private = "file")
append_bytes :: proc "contextless" (out: []u8, pos: ^int, src: []u8) -> bool {
	if pos^ + len(src) > len(out) {
		return false
	}
	copy(out[pos^:], src)
	pos^ += len(src)
	return true
}

@(private = "file")
append_str :: proc "contextless" (out: []u8, pos: ^int, s: string) -> bool {
	return append_bytes(out, pos, transmute([]u8)s)
}

@(private = "file")
append_u64_decimal :: proc "contextless" (out: []u8, pos: ^int, val: u64) -> bool {
	digits: [20]u8
	v := val
	count := 0
	if v == 0 {
		digits[0] = '0'
		count = 1
	} else {
		for v > 0 {
			digits[count] = u8('0' + (v % 10))
			v /= 10
			count += 1
		}
		for i := 0; i < count / 2; i += 1 {
			tmp := digits[i]
			digits[i] = digits[count - 1 - i]
			digits[count - 1 - i] = tmp
		}
	}
	return append_bytes(out, pos, digits[:count])
}

// encode_request encodes an HTTP/1.1 request into out with strict CR/LF injection and smuggling guards.
encode_request :: proc "contextless" (method: Http_Method, host: string, target: string, extra_headers: []Http_Header_Input, body: []u8, out: []u8) -> (written: int, refusal: Http_Parse_Refusal) {
	m, m_ok := http_method_of_word(u8(method))
	if !m_ok {
		return 0, .Invalid_Method
	}
	host_bytes := transmute([]u8)host
	host_ok, host_inj := is_valid_host(host_bytes)
	if host_inj {
		return 0, .Header_Injection
	}
	if !host_ok {
		return 0, .Invalid_Host
	}
	target_bytes := transmute([]u8)target
	target_ok, target_inj := is_valid_target(target_bytes)
	if target_inj {
		return 0, .Header_Injection
	}
	if !target_ok {
		return 0, .Invalid_Target
	}
	if len(extra_headers) > MAX_HEADERS {
		return 0, .Too_Many_Headers
	}
	if len(body) > MAX_BODY_SIZE {
		return 0, .Body_Too_Large
	}

	// Validate every caller header before writing a single byte.
	has_cl := len(body) > 0
	has_te := false
	for hdr in extra_headers {
		nbytes := transmute([]u8)hdr.name
		vbytes := transmute([]u8)hdr.value
		if has_crlf_or_nul(nbytes) || has_crlf_or_nul(vbytes) {
			return 0, .Header_Injection
		}
		if !is_valid_header_name(nbytes) || !is_valid_header_value(vbytes) {
			return 0, .Malformed_Header
		}
		if ascii_equal_ci(nbytes, "host") {
			return 0, .Malformed_Header
		}
		if ascii_equal_ci(nbytes, "content-length") {
			has_cl = true
		}
		if ascii_equal_ci(nbytes, "transfer-encoding") {
			has_te = true
		}
	}
	if has_cl && has_te {
		return 0, .Smuggling_Cl_And_Te
	}

	pos := 0
	if !append_str(out, &pos, http_method_name(m)) ||
	   !append_str(out, &pos, " ") ||
	   !append_bytes(out, &pos, target_bytes) ||
	   !append_str(out, &pos, " HTTP/1.1\r\nHost: ") ||
	   !append_bytes(out, &pos, host_bytes) ||
	   !append_str(out, &pos, "\r\n") {
		return 0, .Buffer_Too_Small
	}

	if len(body) > 0 {
		if !append_str(out, &pos, "Content-Length: ") ||
		   !append_u64_decimal(out, &pos, u64(len(body))) ||
		   !append_str(out, &pos, "\r\n") {
			return 0, .Buffer_Too_Small
		}
	}

	for hdr in extra_headers {
		if len(body) > 0 && ascii_equal_ci(transmute([]u8)hdr.name, "content-length") {
			return 0, .Conflicting_Content_Length
		}
		if !append_str(out, &pos, hdr.name) ||
		   !append_str(out, &pos, ": ") ||
		   !append_str(out, &pos, hdr.value) ||
		   !append_str(out, &pos, "\r\n") {
			return 0, .Buffer_Too_Small
		}
	}

	if !append_str(out, &pos, "\r\n") || !append_bytes(out, &pos, body) {
		return 0, .Buffer_Too_Small
	}
	return pos, .None
}

// parse_decimal_u64 parses strictly ASCII decimal digits into u64 with overflow checking.
parse_decimal_u64 :: proc "contextless" (bytes: []u8) -> (val: u64, ok: bool) {
	if len(bytes) == 0 {
		return 0, false
	}
	acc: u64 = 0
	for b in bytes {
		if b < '0' || b > '9' {
			return 0, false
		}
		d := u64(b - '0')
		if acc > (max(u64) - d) / 10 {
			return 0, false
		}
		acc = acc * 10 + d
	}
	return acc, true
}

// find_crlf locates the next CRLF in data[start:], refusing bare CR, bare LF, or NUL bytes.
@(private = "file")
find_crlf :: proc "contextless" (data: []u8, start: int) -> (line_end: int, refusal: Http_Parse_Refusal) {
	for i := start; i < len(data); i += 1 {
		b := data[i]
		if b == 0 {
			return 0, .Header_Injection
		}
		if b == '\r' {
			if i + 1 >= len(data) {
				return 0, .Incomplete
			}
			if data[i + 1] != '\n' {
				return 0, .Header_Injection
			}
			return i, .None
		}
		if b == '\n' {
			return 0, .Header_Injection
		}
	}
	return 0, .Incomplete
}

// parse_response_head parses an HTTP/1.1 or HTTP/1.0 response status line and headers strictly.
// Refuses CR/LF injection, obs-fold, CL+TE smuggling, conflicting Content-Length, and oversized heads.
parse_response_head :: proc "contextless" (raw: []u8, head_out: ^Http_Response_Head) -> Http_Parse_Refusal {
	head_out^ = {}
	if len(raw) == 0 {
		return .Incomplete
	}

	scan_limit := min(len(raw), MAX_HEADER_BLOCK_SIZE)
	line_end, line_ref := find_crlf(raw[:scan_limit], 0)
	if line_ref != .None {
		if line_ref == .Incomplete && len(raw) > MAX_HEADER_BLOCK_SIZE {
			return .Header_Too_Large
		}
		return line_ref
	}

	status_line := raw[0:line_end]
	if len(status_line) < 12 {
		return .Invalid_Status_Line
	}
	if status_line[0] != 'H' || status_line[1] != 'T' || status_line[2] != 'T' || status_line[3] != 'P' || status_line[4] != '/' {
		return .Invalid_Status_Line
	}
	if status_line[5] == '1' && status_line[6] == '.' && status_line[7] == '1' {
		head_out.version = .Http_1_1
	} else if status_line[5] == '1' && status_line[6] == '.' && status_line[7] == '0' {
		head_out.version = .Http_1_0
		head_out.connection_close = true
	} else {
		return .Unsupported_Version
	}
	if status_line[8] != ' ' {
		return .Invalid_Status_Line
	}
	if status_line[9] < '0' || status_line[9] > '9' || status_line[10] < '0' || status_line[10] > '9' || status_line[11] < '0' || status_line[11] > '9' {
		return .Invalid_Status_Code
	}
	code := u16(status_line[9] - '0') * 100 + u16(status_line[10] - '0') * 10 + u16(status_line[11] - '0')
	if code < 100 || code > 599 {
		return .Invalid_Status_Code
	}
	if len(status_line) > 12 && status_line[12] != ' ' {
		return .Invalid_Status_Line
	}
	head_out.status_code = code

	pos := line_end + 2
	has_te := false

	for {
		if pos > MAX_HEADER_BLOCK_SIZE {
			return .Header_Too_Large
		}
		if pos >= len(raw) {
			return .Incomplete
		}
		next_end, ref := find_crlf(raw[:scan_limit], pos)
		if ref != .None {
			if ref == .Incomplete && len(raw) > MAX_HEADER_BLOCK_SIZE {
				return .Header_Too_Large
			}
			return ref
		}
		if next_end == pos {
			head_out.head_size = pos + 2
			break
		}
		if head_out.header_count >= MAX_HEADERS {
			return .Too_Many_Headers
		}

		line := raw[pos:next_end]
		if line[0] == ' ' || line[0] == '\t' {
			return .Malformed_Header
		}
		colon := -1
		for i := 0; i < len(line); i += 1 {
			if line[i] == ':' {
				colon = i
				break
			}
		}
		if colon <= 0 {
			return .Malformed_Header
		}
		name := line[:colon]
		if !is_valid_header_name(name) {
			return .Malformed_Header
		}
		val := trim_ows(line[colon + 1:])
		if !is_valid_header_value(val) {
			return .Malformed_Header
		}

		slot := &head_out.headers[head_out.header_count]
		copy(slot.name[:len(name)], name)
		slot.name_len = u16(len(name))
		copy(slot.value[:len(val)], val)
		slot.value_len = u16(len(val))
		head_out.header_count += 1

		if ascii_equal_ci(name, "content-length") {
			if has_te {
				return .Smuggling_Cl_And_Te
			}
			cl_scan := val
			if len(cl_scan) == 0 {
				return .Invalid_Content_Length
			}
			for len(cl_scan) > 0 {
				comma := -1
				for j := 0; j < len(cl_scan); j += 1 {
					if cl_scan[j] == ',' {
						comma = j
						break
					}
				}
				part := cl_scan if comma < 0 else cl_scan[:comma]
				part = trim_ows(part)
				parsed_cl, cl_ok := parse_decimal_u64(part)
				if !cl_ok || parsed_cl > MAX_BODY_SIZE {
					return .Invalid_Content_Length
				}
				if head_out.has_content_length {
					if parsed_cl != head_out.content_length {
						return .Conflicting_Content_Length
					}
				} else {
					head_out.has_content_length = true
					head_out.content_length = parsed_cl
				}
				if comma < 0 {
					break
				}
				cl_scan = cl_scan[comma + 1:]
				if len(cl_scan) == 0 {
					return .Invalid_Content_Length
				}
			}
		} else if ascii_equal_ci(name, "transfer-encoding") {
			if head_out.has_content_length {
				return .Smuggling_Cl_And_Te
			}
			if has_te {
				return .Unsupported_Transfer_Encoding
			}
			if !ascii_equal_ci(val, "chunked") {
				return .Unsupported_Transfer_Encoding
			}
			has_te = true
			head_out.is_chunked = true
		} else if ascii_equal_ci(name, "connection") {
			if ascii_equal_ci(val, "close") {
				head_out.connection_close = true
			} else if ascii_equal_ci(val, "keep-alive") && head_out.version == .Http_1_0 {
				head_out.connection_close = false
			}
		}

		pos = next_end + 2
	}

	return .None
}

// response_header_get returns the first header value matching name (case-insensitive).
response_header_get :: proc "contextless" (head: ^Http_Response_Head, name: string) -> (value: []u8, found: bool) {
	for i := 0; i < head.header_count; i += 1 {
		h := &head.headers[i]
		if ascii_equal_ci(h.name[:h.name_len], name) {
			return h.value[:h.value_len], true
		}
	}
	return nil, false
}

// decode_chunked_body decodes an HTTP/1.1 Transfer-Encoding: chunked body with strict hex and overflow guards.
decode_chunked_body :: proc "contextless" (raw: []u8, out: []u8) -> (decoded_len: int, consumed_len: int, refusal: Http_Parse_Refusal) {
	pos := 0
	out_pos := 0

	for {
		if pos >= len(raw) {
			return 0, 0, .Chunk_Incomplete
		}
		line_end, line_ref := find_crlf(raw, pos)
		if line_ref != .None {
			if line_ref == .Incomplete {
				return 0, 0, .Chunk_Incomplete
			}
			return 0, 0, line_ref
		}
		size_line := raw[pos:line_end]
		semi := -1
		for i := 0; i < len(size_line); i += 1 {
			if size_line[i] == ';' {
				semi = i
				break
			}
		}
		hex_part := size_line if semi < 0 else size_line[:semi]
		if len(hex_part) == 0 || len(hex_part) > 16 {
			return 0, 0, .Invalid_Chunk_Size
		}

		chunk_size: u64 = 0
		for b in hex_part {
			digit: u64
			switch {
			case b >= '0' && b <= '9':
				digit = u64(b - '0')
			case b >= 'a' && b <= 'f':
				digit = u64(b - 'a' + 10)
			case b >= 'A' && b <= 'F':
				digit = u64(b - 'A' + 10)
			case:
				return 0, 0, .Invalid_Chunk_Size
			}
			if chunk_size > (max(u64) - digit) >> 4 {
				return 0, 0, .Invalid_Chunk_Size
			}
			chunk_size = (chunk_size << 4) | digit
		}
		if chunk_size > MAX_CHUNK_SIZE {
			return 0, 0, .Invalid_Chunk_Size
		}

		pos = line_end + 2
		if chunk_size == 0 {
			for {
				if pos >= len(raw) {
					return 0, 0, .Chunk_Incomplete
				}
				tr_end, tr_ref := find_crlf(raw, pos)
				if tr_ref != .None {
					if tr_ref == .Incomplete {
						return 0, 0, .Chunk_Incomplete
					}
					return 0, 0, tr_ref
				}
				if tr_end == pos {
					return out_pos, pos + 2, .None
				}
				pos = tr_end + 2
			}
		}

		csize := int(chunk_size)
		if csize > len(raw) - pos {
			return 0, 0, .Chunk_Incomplete
		}
		if out_pos + csize > MAX_BODY_SIZE {
			return 0, 0, .Body_Too_Large
		}
		if out_pos + csize > len(out) {
			return 0, 0, .Buffer_Too_Small
		}
		copy(out[out_pos:out_pos + csize], raw[pos:pos + csize])
		out_pos += csize
		pos += csize

		if pos + 2 > len(raw) {
			return 0, 0, .Chunk_Incomplete
		}
		if raw[pos] != '\r' || raw[pos + 1] != '\n' {
			return 0, 0, .Chunk_Missing_Crlf
		}
		pos += 2
	}
}

// parse_response parses an entire HTTP/1.1 response (head + Content-Length or chunked body).
parse_response :: proc "contextless" (raw: []u8, head_out: ^Http_Response_Head, body_out: []u8) -> (body_len: int, total_consumed: int, refusal: Http_Parse_Refusal) {
	if r := parse_response_head(raw, head_out); r != .None {
		return 0, 0, r
	}
	body_raw := raw[head_out.head_size:]
	if head_out.is_chunked {
		dlen, clen, cref := decode_chunked_body(body_raw, body_out)
		if cref != .None {
			return 0, 0, cref
		}
		return dlen, head_out.head_size + clen, .None
	}
	if head_out.has_content_length {
		cl := int(head_out.content_length)
		if len(body_raw) < cl {
			return 0, 0, .Incomplete
		}
		if cl > len(body_out) {
			return 0, 0, .Buffer_Too_Small
		}
		copy(body_out[:cl], body_raw[:cl])
		return cl, head_out.head_size + cl, .None
	}
	if len(body_raw) > MAX_BODY_SIZE {
		return 0, 0, .Body_Too_Large
	}
	if len(body_raw) > len(body_out) {
		return 0, 0, .Buffer_Too_Small
	}
	copy(body_out[:len(body_raw)], body_raw)
	return len(body_raw), len(raw), .None
}

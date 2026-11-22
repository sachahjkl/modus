// RFC 9114 HTTP/3 framing bridge (QUIC variable-length integers, HEADERS and DATA frames).
// Pure freestanding contract code reusing the same strict HTTP header validation rules.
package http_client

import "modus:contract/enum_word"

QUIC_VARINT_MAX :: u64((1 << 62) - 1)

// Known HTTP/3 frame types (RFC 9114 section 7.2).
Http3_Frame_Type :: enum u64 {
	Data         = 0x00,
	Headers      = 0x01,
	Cancel_Push  = 0x03,
	Settings     = 0x04,
	Push_Promise = 0x05,
	Goaway       = 0x07,
	Max_Push_Id  = 0x0D,
}

// Decoded HTTP/3 frame header and payload slice.
Http3_Frame :: struct {
	frame_type: Http3_Frame_Type,
	payload:    []u8,
	total_size: int,
}

http3_frame_type_of_word :: proc "contextless" (word: u64) -> (ft: Http3_Frame_Type, ok: bool) {
	return enum_word.member_of_word(Http3_Frame_Type, word)
}

// is_forbidden_h2_frame_type checks RFC 9114 section 7.2.8 reserved HTTP/2 frame identifiers.
is_forbidden_h2_frame_type :: proc "contextless" (ft_word: u64) -> bool {
	return ft_word == 0x02 || ft_word == 0x06 || ft_word == 0x08 || ft_word == 0x09
}

// quic_varint_encode encodes a 62-bit unsigned integer in RFC 9000 section 16 format.
quic_varint_encode :: proc "contextless" (val: u64, out: []u8) -> (written: int, ok: bool) {
	if val > QUIC_VARINT_MAX {
		return 0, false
	}
	switch {
	case val < (1 << 6):
		if len(out) < 1 {
			return 0, false
		}
		out[0] = u8(val)
		return 1, true
	case val < (1 << 14):
		if len(out) < 2 {
			return 0, false
		}
		out[0] = u8(0x40 | (val >> 8))
		out[1] = u8(val & 0xFF)
		return 2, true
	case val < (1 << 30):
		if len(out) < 4 {
			return 0, false
		}
		out[0] = u8(0x80 | (val >> 24))
		out[1] = u8((val >> 16) & 0xFF)
		out[2] = u8((val >> 8) & 0xFF)
		out[3] = u8(val & 0xFF)
		return 4, true
	case:
		if len(out) < 8 {
			return 0, false
		}
		out[0] = u8(0xC0 | (val >> 56))
		out[1] = u8((val >> 48) & 0xFF)
		out[2] = u8((val >> 40) & 0xFF)
		out[3] = u8((val >> 32) & 0xFF)
		out[4] = u8((val >> 24) & 0xFF)
		out[5] = u8((val >> 16) & 0xFF)
		out[6] = u8((val >> 8) & 0xFF)
		out[7] = u8(val & 0xFF)
		return 8, true
	}
}

// quic_varint_decode decodes an RFC 9000 section 16 variable-length integer.
quic_varint_decode :: proc "contextless" (data: []u8) -> (val: u64, consumed: int, ok: bool) {
	if len(data) == 0 {
		return 0, 0, false
	}
	prefix := data[0] >> 6
	length := 1 << prefix
	if len(data) < length {
		return 0, 0, false
	}
	acc := u64(data[0] & 0x3F)
	for i := 1; i < length; i += 1 {
		acc = (acc << 8) | u64(data[i])
	}
	return acc, length, true
}

// http3_write_frame writes one HTTP/3 frame (varint type + varint length + payload).
http3_write_frame :: proc "contextless" (ft: Http3_Frame_Type, payload: []u8, out: []u8) -> (written: int, refusal: Http_Parse_Refusal) {
	pos := 0
	n1, ok1 := quic_varint_encode(u64(ft), out[pos:])
	if !ok1 {
		return 0, .Buffer_Too_Small
	}
	pos += n1
	n2, ok2 := quic_varint_encode(u64(len(payload)), out[pos:])
	if !ok2 {
		return 0, .Buffer_Too_Small
	}
	pos += n2
	if pos + len(payload) > len(out) {
		return 0, .Buffer_Too_Small
	}
	copy(out[pos:], payload)
	pos += len(payload)
	return pos, .None
}

// http3_read_frame parses one HTTP/3 frame, refusing forbidden HTTP/2 frame types.
http3_read_frame :: proc "contextless" (data: []u8) -> (frame: Http3_Frame, refusal: Http_Parse_Refusal) {
	ft_word, n1, ok1 := quic_varint_decode(data)
	if !ok1 {
		return {}, .Incomplete
	}
	if is_forbidden_h2_frame_type(ft_word) {
		return {}, .Forbidden_H2_Frame
	}
	ft, ft_ok := http3_frame_type_of_word(ft_word)
	if !ft_ok {
		return {}, .Malformed_Frame
	}
	plen, n2, ok2 := quic_varint_decode(data[n1:])
	if !ok2 {
		return {}, .Incomplete
	}
	if plen > MAX_BODY_SIZE {
		return {}, .Body_Too_Large
	}
	rem := u64(len(data) - n1 - n2)
	if plen > rem {
		return {}, .Incomplete
	}
	total := n1 + n2 + int(plen)
	return Http3_Frame{
		frame_type = ft,
		payload    = data[n1 + n2 : total],
		total_size = total,
	}, .None
}

// Minimal static-zero QPACK literal field line encoder/decoder (RFC 9204 section 4.5.6: 001N H=0).
@(private = "file")
qpack_write_literal_field :: proc "contextless" (name: []u8, value: []u8, out: []u8, pos: ^int) -> bool {
	if pos^ + 1 > len(out) {
		return false
	}
	out[pos^] = 0x20
	pos^ += 1
	n1, ok1 := quic_varint_encode(u64(len(name)), out[pos^:])
	if !ok1 || pos^ + n1 + len(name) > len(out) {
		return false
	}
	pos^ += n1
	copy(out[pos^:], name)
	pos^ += len(name)
	n2, ok2 := quic_varint_encode(u64(len(value)), out[pos^:])
	if !ok2 || pos^ + n2 + len(value) > len(out) {
		return false
	}
	pos^ += n2
	copy(out[pos^:], value)
	pos^ += len(value)
	return true
}

@(private = "file")
has_uppercase_ascii :: proc "contextless" (bytes: []u8) -> bool {
	for b in bytes {
		if b >= 'A' && b <= 'Z' {
			return true
		}
	}
	return false
}

@(private = "file")
is_valid_http3_scheme :: proc "contextless" (scheme: []u8) -> (ok: bool, injection: bool) {
	if has_crlf_or_nul(scheme) {
		return false, true
	}
	if len(scheme) == 4 && scheme[0] == 'h' && scheme[1] == 't' && scheme[2] == 't' && scheme[3] == 'p' {
		return true, false
	}
	if len(scheme) == 5 && scheme[0] == 'h' && scheme[1] == 't' && scheme[2] == 't' && scheme[3] == 'p' && scheme[4] == 's' {
		return true, false
	}
	return false, false
}

// http3_encode_request encodes an HTTP request into HTTP/3 HEADERS (+ optional DATA) frames.
http3_encode_request :: proc "contextless" (method: Http_Method, scheme: string, authority: string, path: string, headers: []Http_Header_Input, body: []u8, out: []u8) -> (written: int, refusal: Http_Parse_Refusal) {
	m, m_ok := http_method_of_word(u8(method))
	if !m_ok {
		return 0, .Invalid_Method
	}
	scheme_ok, scheme_inj := is_valid_http3_scheme(transmute([]u8)scheme)
	if scheme_inj {
		return 0, .Header_Injection
	}
	if !scheme_ok {
		return 0, .Invalid_Scheme
	}
	auth_ok, auth_inj := is_valid_host(transmute([]u8)authority)
	if auth_inj {
		return 0, .Header_Injection
	}
	if !auth_ok {
		return 0, .Invalid_Host
	}
	path_ok, path_inj := is_valid_target(transmute([]u8)path)
	if path_inj {
		return 0, .Header_Injection
	}
	if !path_ok {
		return 0, .Invalid_Target
	}

	qpack_buf: [MAX_HEADER_BLOCK_SIZE]u8
	qpos := 2
	qpack_buf[0] = 0
	qpack_buf[1] = 0

	if !qpack_write_literal_field(transmute([]u8)string(":method"), transmute([]u8)http_method_name(m), qpack_buf[:], &qpos) ||
	   !qpack_write_literal_field(transmute([]u8)string(":scheme"), transmute([]u8)scheme, qpack_buf[:], &qpos) ||
	   !qpack_write_literal_field(transmute([]u8)string(":authority"), transmute([]u8)authority, qpack_buf[:], &qpos) ||
	   !qpack_write_literal_field(transmute([]u8)string(":path"), transmute([]u8)path, qpack_buf[:], &qpos) {
		return 0, .Header_Too_Large
	}

	for hdr in headers {
		nbytes := transmute([]u8)hdr.name
		vbytes := transmute([]u8)hdr.value
		if has_crlf_or_nul(nbytes) || has_crlf_or_nul(vbytes) {
			return 0, .Header_Injection
		}
		if !is_valid_header_name(nbytes) || has_uppercase_ascii(nbytes) || !is_valid_header_value(vbytes) {
			return 0, .Malformed_Header
		}
		if ascii_equal_ci(nbytes, "transfer-encoding") {
			return 0, .Unsupported_Transfer_Encoding
		}
		if !qpack_write_literal_field(nbytes, vbytes, qpack_buf[:], &qpos) {
			return 0, .Header_Too_Large
		}
	}

	pos := 0
	n_hdr, r_hdr := http3_write_frame(.Headers, qpack_buf[:qpos], out[pos:])
	if r_hdr != .None {
		return 0, r_hdr
	}
	pos += n_hdr

	if len(body) > 0 {
		n_data, r_data := http3_write_frame(.Data, body, out[pos:])
		if r_data != .None {
			return 0, r_data
		}
		pos += n_data
	}
	return pos, .None
}

// http3_encode_response encodes an HTTP response into HTTP/3 HEADERS (+ optional DATA) frames.
http3_encode_response :: proc "contextless" (status_code: u16, headers: []Http_Header_Input, body: []u8, out: []u8) -> (written: int, refusal: Http_Parse_Refusal) {
	if status_code < 100 || status_code > 599 {
		return 0, .Invalid_Status_Code
	}
	status_str := [3]u8{
		u8('0' + (status_code / 100)),
		u8('0' + ((status_code / 10) % 10)),
		u8('0' + (status_code % 10)),
	}
	qpack_buf: [MAX_HEADER_BLOCK_SIZE]u8
	qpos := 2
	qpack_buf[0] = 0
	qpack_buf[1] = 0
	if !qpack_write_literal_field(transmute([]u8)string(":status"), status_str[:], qpack_buf[:], &qpos) {
		return 0, .Header_Too_Large
	}
	for hdr in headers {
		nbytes := transmute([]u8)hdr.name
		vbytes := transmute([]u8)hdr.value
		if has_crlf_or_nul(nbytes) || has_crlf_or_nul(vbytes) {
			return 0, .Header_Injection
		}
		if !is_valid_header_name(nbytes) || has_uppercase_ascii(nbytes) || !is_valid_header_value(vbytes) {
			return 0, .Malformed_Header
		}
		if ascii_equal_ci(nbytes, "transfer-encoding") {
			return 0, .Unsupported_Transfer_Encoding
		}
		if !qpack_write_literal_field(nbytes, vbytes, qpack_buf[:], &qpos) {
			return 0, .Header_Too_Large
		}
	}

	pos := 0
	n_hdr, r_hdr := http3_write_frame(.Headers, qpack_buf[:qpos], out[pos:])
	if r_hdr != .None {
		return 0, r_hdr
	}
	pos += n_hdr
	if len(body) > 0 {
		n_data, r_data := http3_write_frame(.Data, body, out[pos:])
		if r_data != .None {
			return 0, r_data
		}
		pos += n_data
	}
	return pos, .None
}

// http3_decode_response decodes HTTP/3 HEADERS + DATA frames into Http_Response_Head and body_out.
http3_decode_response :: proc "contextless" (stream: []u8, head_out: ^Http_Response_Head, body_out: []u8) -> (body_len: int, refusal: Http_Parse_Refusal) {
	head_out^ = {}
	head_out.version = .Http_3

	hdr_frame, r1 := http3_read_frame(stream)
	if r1 != .None {
		return 0, r1
	}
	if hdr_frame.frame_type != .Headers {
		return 0, .Malformed_Frame
	}
	q := hdr_frame.payload
	if len(q) > MAX_HEADER_BLOCK_SIZE {
		return 0, .Header_Too_Large
	}
	if len(q) < 2 || q[0] != 0 || q[1] != 0 {
		return 0, .Malformed_Header
	}
	qpos := 2
	has_status := false
	seen_regular_header := false
	for qpos < len(q) {
		if q[qpos] != 0x20 {
			return 0, .Malformed_Header
		}
		qpos += 1
		nlen, c1, ok1 := quic_varint_decode(q[qpos:])
		if !ok1 || nlen == 0 || nlen > MAX_HEADER_NAME_LEN || nlen > u64(len(q) - qpos - c1) {
			return 0, .Malformed_Header
		}
		qpos += c1
		name := q[qpos:qpos + int(nlen)]
		qpos += int(nlen)

		vlen, c2, ok2 := quic_varint_decode(q[qpos:])
		if !ok2 || vlen > MAX_HEADER_VALUE_LEN || vlen > u64(len(q) - qpos - c2) {
			return 0, .Malformed_Header
		}
		qpos += c2
		val := q[qpos:qpos + int(vlen)]
		qpos += int(vlen)

		if has_crlf_or_nul(name) || has_crlf_or_nul(val) {
			return 0, .Header_Injection
		}
		// RFC 9114 section 4.2: field names and pseudo-headers must be strictly lowercase.
		if has_uppercase_ascii(name) {
			return 0, .Malformed_Header
		}
		if name[0] == ':' {
			if seen_regular_header || len(name) != 7 || string(name) != ":status" {
				return 0, .Malformed_Header
			}
			if has_status {
				return 0, .Malformed_Header
			}
			if len(val) != 3 {
				return 0, .Invalid_Status_Code
			}
			parsed, pok := parse_decimal_u64(val)
			if !pok || parsed < 100 || parsed > 599 {
				return 0, .Invalid_Status_Code
			}
			head_out.status_code = u16(parsed)
			has_status = true
			continue
		}
		seen_regular_header = true
		if !is_valid_header_name(name) || !is_valid_header_value(val) {
			return 0, .Malformed_Header
		}
		if ascii_equal_ci(name, "transfer-encoding") {
			return 0, .Unsupported_Transfer_Encoding
		}
		if ascii_equal_ci(name, "content-length") {
			cl_val, cl_ok := parse_decimal_u64(trim_ows(val))
			if !cl_ok || cl_val > MAX_BODY_SIZE {
				return 0, .Invalid_Content_Length
			}
			if head_out.has_content_length {
				if cl_val != head_out.content_length {
					return 0, .Conflicting_Content_Length
				}
			} else {
				head_out.has_content_length = true
				head_out.content_length = cl_val
			}
		}
		if head_out.header_count >= MAX_HEADERS {
			return 0, .Too_Many_Headers
		}
		slot := &head_out.headers[head_out.header_count]
		copy(slot.name[:len(name)], name)
		slot.name_len = u16(len(name))
		copy(slot.value[:len(val)], val)
		slot.value_len = u16(len(val))
		head_out.header_count += 1
	}
	if !has_status {
		return 0, .Invalid_Status_Code
	}

	// Only DATA frames may follow the response HEADERS frame on a request stream.
	pos := hdr_frame.total_size
	cumulative_data: u64 = 0
	out_pos := 0
	for pos < len(stream) {
		f, rf := http3_read_frame(stream[pos:])
		if rf != .None {
			return 0, rf
		}
		pos += f.total_size
		if f.frame_type != .Data {
			return 0, .Malformed_Frame
		}
		if u64(len(f.payload)) > MAX_BODY_SIZE - cumulative_data {
			return 0, .Body_Too_Large
		}
		cumulative_data += u64(len(f.payload))
		if out_pos + len(f.payload) > len(body_out) {
			return 0, .Buffer_Too_Small
		}
		copy(body_out[out_pos:], f.payload)
		out_pos += len(f.payload)
	}

	if head_out.has_content_length && !is_bodiless_status(head_out.status_code) && cumulative_data != head_out.content_length {
		return 0, .Content_Length_Mismatch
	}
	return out_pos, .None
}

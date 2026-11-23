package browser

import "modus:contract/http_client"

// The fetch of a page of HTTP or HTTPS: the request that the origin worker
// sends, and the policy that it applies to the answer before a byte of it
// reaches the HTML parser (src/md/features/desktop_to_browser.md, "The
// fetch of a page"). The framing of HTTP/1.1 is the one of
// modus:contract/http_client: its encoder refuses an injected header and
// its parser refuses a smuggled body; this file adds what a browser
// decides: the redirects, the type of the content, its encoding and its
// size.

// The bytes of a request: the request line, Host, Accept, Connection and
// a Cookie header of one origin.
REQUEST_CAPACITY :: 1024
// The redirects that one load follows: the sixth is refused.
REDIRECT_LIMIT :: 5
// The bytes of a body that a page takes.
FETCH_BODY_CAPACITY :: PAGE_SOURCE_CAPACITY

// Why a fetch gives no page.
Fetch_Problem :: enum u8 {
	None,
	Scheme_Not_Fetched, // modus: a page built into the browser.
	Request_Refused, // A byte of the address that a request cannot carry.
	Response_Incomplete,
	Response_Malformed,
	Body_Too_Large,
	Status_Refused,
	Redirect_Without_Location,
	Redirect_Location_Refused,
	Redirect_Scheme_Refused, // To a page of the system, or from HTTPS to HTTP.
	Too_Many_Redirects,
	Content_Type_Refused,
	Charset_Refused,
}

@(rodata)
FETCH_PROBLEM_SENTENCES := [Fetch_Problem]string {
	.None                      = "",
	.Scheme_Not_Fetched        = "a page of the browser comes from no network",
	.Request_Refused           = "the address holds a byte that a request cannot carry",
	.Response_Incomplete       = "the answer ends before its end",
	.Response_Malformed        = "the answer is not HTTP/1.1 that the browser reads",
	.Body_Too_Large            = "the page is longer than 1 MiB",
	.Status_Refused            = "the server answered with an error",
	.Redirect_Without_Location = "a redirect names no address",
	.Redirect_Location_Refused = "a redirect names an address that the browser refuses",
	.Redirect_Scheme_Refused   = "a redirect leaves HTTPS, or names a page of the system",
	.Too_Many_Redirects        = "more than 5 redirects",
	.Content_Type_Refused      = "the answer is not HTML",
	.Charset_Refused           = "the page is not UTF-8",
}

// What an answer gives.
Fetch_Outcome :: enum u8 {
	Refused,
	Document,
	Redirect,
}

COOKIE_TEXT_CAPACITY :: 128

Fetch_Result :: struct {
	outcome:        Fetch_Outcome,
	problem:        Fetch_Problem,
	status:         u16,
	// Document: the body, as UTF-8 with each broken sequence replaced.
	body_count:     int,
	replaced:       int,
	// Redirect: the next address.
	next:           Address,
	// The first Set-Cookie of the answer, as name=value.
	cookie:         [COOKIE_TEXT_CAPACITY]u8,
	cookie_count:   int,
}

// The head of an answer: its headers are large, so it lives in the memory
// of the module.
fetch_response_head: http_client.Http_Response_Head
fetch_raw_body: [FETCH_BODY_CAPACITY]u8

// request_target_write writes the target of the request line: the path,
// "/" for none, and the query. The fragment never leaves the browser.
request_target_write :: proc "contextless" (writer: ^Source_Writer, address: ^Address) {
	if address.path_count == 0 {
		put(writer, "/")
	} else {
		put(writer, address_path(address))
	}
	if address.query_count > 0 {
		put(writer, "?")
		put(writer, address_query(address))
	}
}

// fetch_request_write writes the GET request of an address, with the
// cookies of its origin. Nothing is written on a refusal.
fetch_request_write :: proc "contextless" (address: ^Address, cookie_header: string, output: []u8) -> (count: int, problem: Fetch_Problem) {
	switch address.scheme {
	case .Modus:
		return 0, .Scheme_Not_Fetched
	case .Http, .Https:
	}
	host_buffer: [HOST_CAPACITY + 8]u8
	host := Source_Writer{bytes = host_buffer[:]}
	put(&host, address_host(address))
	if address.port != SCHEME_PORTS[address.scheme] {
		put(&host, ":")
		put_number(&host, u64(address.port))
	}
	target_buffer: [PATH_CAPACITY + QUERY_CAPACITY + 2]u8
	target := Source_Writer{bytes = target_buffer[:]}
	request_target_write(&target, address)
	headers := [3]http_client.Http_Header_Input{{"Accept", "text/html"}, {"Connection", "close"}, {"Cookie", cookie_header}}
	header_count := 3 if len(cookie_header) > 0 else 2
	scratch: [REQUEST_CAPACITY]u8
	written, refusal := http_client.encode_request(.Get, writer_text(&host), writer_text(&target), headers[:header_count], nil, scratch[:])
	if refusal != .None || written > len(output) {
		return 0, .Request_Refused
	}
	return copy(output, scratch[:written]), .None
}

// content_type_check reads Content-Type: text/html, with no charset or
// the charset utf-8, in any case, quoted or not.
content_type_check :: proc "contextless" (value: []u8) -> Fetch_Problem {
	text := string(value)
	media_end := 0
	for media_end < len(text) && text[media_end] != ';' {
		media_end += 1
	}
	media := text_trim(text[:media_end])
	if !text_equal_ignoring_case(media, "text/html") {
		return .Content_Type_Refused
	}
	rest := text[media_end:]
	for len(rest) > 0 {
		rest = rest[1:]
		end := 0
		for end < len(rest) && rest[end] != ';' {
			end += 1
		}
		parameter := text_trim(rest[:end])
		rest = rest[end:]
		equal := 0
		for equal < len(parameter) && parameter[equal] != '=' {
			equal += 1
		}
		if equal >= len(parameter) || !text_equal_ignoring_case(text_trim(parameter[:equal]), "charset") {
			continue
		}
		charset := text_trim(parameter[equal + 1:])
		if len(charset) >= 2 && charset[0] == '"' && charset[len(charset) - 1] == '"' {
			charset = charset[1:len(charset) - 1]
		}
		if !text_equal_ignoring_case(charset, "utf-8") && !text_equal_ignoring_case(charset, "utf8") {
			return .Charset_Refused
		}
	}
	return .None
}

text_trim :: proc "contextless" (text: string) -> string {
	rest := text
	for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t') {
		rest = rest[1:]
	}
	for len(rest) > 0 && (rest[len(rest) - 1] == ' ' || rest[len(rest) - 1] == '\t') {
		rest = rest[:len(rest) - 1]
	}
	return rest
}

text_equal_ignoring_case :: proc "contextless" (text, other: string) -> bool {
	if len(text) != len(other) {
		return false
	}
	for index in 0 ..< len(text) {
		if lower(text[index]) != lower(other[index]) {
			return false
		}
	}
	return true
}

// is_redirect_status: the statuses whose Location the browser follows.
is_redirect_status :: proc "contextless" (status: u16) -> bool {
	return status == 301 || status == 302 || status == 303 || status == 307 || status == 308
}

// fetch_response_read reads the whole answer to a request for the address
// base, after redirects_followed redirects. A Document leaves its body in
// body_output, as UTF-8.
fetch_response_read :: proc "contextless" (base: ^Address, raw: []u8, redirects_followed: int, body_output: []u8) -> (result: Fetch_Result) {
	head := &fetch_response_head
	if problem := fetch_problem_of_refusal(http_client.parse_response_head(raw, head)); problem != .None {
		result.problem = problem
		return
	}
	result.status = head.status_code
	// The cap comes before a byte of the body: a length past it is refused
	// from the head alone.
	if head.has_content_length && head.content_length > u64(min(len(body_output), FETCH_BODY_CAPACITY)) {
		result.problem = .Body_Too_Large
		return
	}
	if is_redirect_status(head.status_code) {
		if redirects_followed >= REDIRECT_LIMIT {
			result.problem = .Too_Many_Redirects
			return
		}
		location, found := http_client.response_header_get(head, "location")
		if !found || len(location) == 0 {
			result.problem = .Redirect_Without_Location
			return
		}
		resolved_buffer: [ADDRESS_CAPACITY + 8]u8
		resolved := Source_Writer{bytes = resolved_buffer[:]}
		address_resolve(&resolved, base, string(location))
		next, problem := address_parse(writer_text(&resolved))
		if problem != .None || resolved.full {
			result.problem = .Redirect_Location_Refused
			return
		}
		if next.scheme == .Modus || base.scheme == .Https && next.scheme == .Http {
			result.problem = .Redirect_Scheme_Refused
			return
		}
		result.outcome = .Redirect
		result.next = next
		return
	}
	if head.status_code < 200 || head.status_code > 299 {
		result.problem = .Status_Refused
		return
	}
	content_type, typed := http_client.response_header_get(head, "content-type")
	if !typed {
		result.problem = .Content_Type_Refused
		return
	}
	if problem := content_type_check(content_type); problem != .None {
		result.problem = problem
		return
	}
	raw_capacity := min(len(body_output), FETCH_BODY_CAPACITY)
	body_count, _, body_refusal := http_client.parse_response(raw, head, fetch_raw_body[:raw_capacity])
	if problem := fetch_problem_of_refusal(body_refusal); problem != .None {
		result.problem = problem
		return
	}
	result.body_count, result.replaced = utf8_replace_invalid(fetch_raw_body[:body_count], body_output)
	if cookie, has_cookie := http_client.response_header_get(head, "set-cookie"); has_cookie {
		end := 0
		for end < len(cookie) && cookie[end] != ';' {
			end += 1
		}
		result.cookie_count = copy(result.cookie[:], cookie[:end])
	}
	result.outcome = .Document
	return
}

// fetch_problem_of_refusal: what a refusal of the HTTP/1.1 framing means
// for a page.
fetch_problem_of_refusal :: proc "contextless" (refusal: http_client.Http_Parse_Refusal) -> Fetch_Problem {
	switch refusal {
	case .None:
		return .None
	case .Incomplete, .Chunk_Incomplete:
		return .Response_Incomplete
	case .Buffer_Too_Small, .Body_Too_Large:
		return .Body_Too_Large
	case .Invalid_Method, .Invalid_Target, .Invalid_Host, .Header_Injection, .Invalid_Status_Line, .Unsupported_Version,
	     .Invalid_Status_Code, .Malformed_Header, .Header_Too_Large, .Too_Many_Headers, .Smuggling_Cl_And_Te,
	     .Conflicting_Content_Length, .Invalid_Content_Length, .Unsupported_Transfer_Encoding, .Invalid_Chunk_Size,
	     .Chunk_Missing_Crlf, .Forbidden_H2_Frame, .Malformed_Frame, .Invalid_Scheme, .Content_Length_Mismatch:
		return .Response_Malformed
	}
	return .Response_Malformed
}

// utf8_replace_invalid copies text and writes U+FFFD for each byte that
// starts no UTF-8 sequence: a stray continuation, a cut sequence, an
// overlong form, a surrogate, a value past U+10FFFF. A character that does
// not fit whole is not written.
utf8_replace_invalid :: proc "contextless" (source: []u8, output: []u8) -> (count: int, replaced: int) {
	REPLACEMENT :: "\xEF\xBF\xBD"
	index := 0
	for index < len(source) {
		lead := source[index]
		size := 0
		least: u32 = 0
		code: u32 = 0
		switch {
		case lead < 0x80:
			size, code = 1, u32(lead)
		case lead >= 0xC2 && lead <= 0xDF:
			size, least, code = 2, 0x80, u32(lead & 0x1F)
		case lead >= 0xE0 && lead <= 0xEF:
			size, least, code = 3, 0x800, u32(lead & 0x0F)
		case lead >= 0xF0 && lead <= 0xF4:
			size, least, code = 4, 0x10000, u32(lead & 0x07)
		}
		valid := size > 0 && index + size <= len(source)
		for part := 1; valid && part < size; part += 1 {
			continuation := source[index + part]
			if continuation & 0xC0 != 0x80 {
				valid = false
				break
			}
			code = code << 6 | u32(continuation & 0x3F)
		}
		if valid && size > 1 && (code < least || code > 0x10FFFF || code >= 0xD800 && code <= 0xDFFF) {
			valid = false
		}
		if !valid {
			if count + len(REPLACEMENT) > len(output) {
				return
			}
			count += copy(output[count:], REPLACEMENT)
			replaced += 1
			index += 1
			continue
		}
		if count + size > len(output) {
			return
		}
		count += copy(output[count:], source[index:index + size])
		index += size
	}
	return
}

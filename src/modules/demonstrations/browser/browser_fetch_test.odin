#+build !freestanding
package browser

import "core:strings"
import "core:testing"
import "modus:contract/html_css"

// The tests of the fetch: the request that the browser writes, and the
// policy that it applies to each answer, edge by edge.

@(private = "file")
address_of :: proc(text: string) -> Address {
	address, problem := address_parse(text)
	assert(problem == .None)
	return address
}

@(private = "file")
answer_read :: proc(base_text: string, raw: string, redirects: int = 0) -> (result: Fetch_Result, body: string) {
	base := address_of(base_text)
	output := make([]u8, FETCH_BODY_CAPACITY, context.temp_allocator)
	result = fetch_response_read(&base, transmute([]u8)raw, redirects, output)
	return result, string(output[:result.body_count])
}

HTML_HEAD :: "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"

// The request: the target with no fragment, the port in Host only when it
// is not the one of the scheme, the cookies of the origin.
@(test)
fetch_request_lines :: proc(t: ^testing.T) {
	globals_hold()
	output: [REQUEST_CAPACITY]u8
	Case :: struct {
		address, cookie, request: string,
	}
	cases := [?]Case {
		{"http://example.org:8080/a?b=c#frag", "", "GET /a?b=c HTTP/1.1\r\nHost: example.org:8080\r\nAccept: text/html\r\nConnection: close\r\n\r\n"},
		{"https://example.org", "", "GET / HTTP/1.1\r\nHost: example.org\r\nAccept: text/html\r\nConnection: close\r\n\r\n"},
		{"https://example.org:443/x", "sid=1; b=2", "GET /x HTTP/1.1\r\nHost: example.org\r\nAccept: text/html\r\nConnection: close\r\nCookie: sid=1; b=2\r\n\r\n"},
		{"http://example.org:443/", "", "GET / HTTP/1.1\r\nHost: example.org:443\r\nAccept: text/html\r\nConnection: close\r\n\r\n"},
	}
	for item in cases {
		address := address_of(item.address)
		count, problem := fetch_request_write(&address, item.cookie, output[:])
		testing.expect_value(t, problem, Fetch_Problem.None)
		testing.expect_value(t, string(output[:count]), item.request)
	}
	// Refusals write nothing: a page of the browser, a byte that a request
	// cannot carry, a cookie that injects a header, a buffer too small.
	modus := address_of("modus://guide")
	count, problem := fetch_request_write(&modus, "", output[:])
	testing.expect(t, count == 0 && problem == .Scheme_Not_Fetched)
	for text in ([?]string{"http://h/a b", "http://h/a\r\nX: y", "http://h/\x7f", "http://h/\xff"}) {
		address := address_of(text)
		count, problem = fetch_request_write(&address, "", output[:])
		testing.expectf(t, count == 0 && problem == .Request_Refused, "%q: %v", text, problem)
	}
	plain := address_of("http://h")
	count, problem = fetch_request_write(&plain, "a=1\r\nEvil: 1", output[:])
	testing.expect(t, count == 0 && problem == .Request_Refused, "an injected cookie header")
	small: [20]u8
	count, problem = fetch_request_write(&plain, "", small[:])
	testing.expect(t, count == 0 && problem == .Request_Refused, "a buffer too small")
	testing.expect(t, small == {}, "nothing written on a refusal")
}

// A page with a length or chunked, in its bounds.
@(test)
fetch_response_documents :: proc(t: ^testing.T) {
	globals_hold()
	result, body := answer_read("http://h", HTML_HEAD + "Content-Length: 5\r\n\r\nhello")
	testing.expect_value(t, result.outcome, Fetch_Outcome.Document)
	testing.expect_value(t, body, "hello")
	result, body = answer_read("http://h", HTML_HEAD + "Transfer-Encoding: chunked\r\nSet-Cookie: sid=42; Path=/; HttpOnly\r\n\r\n5;ext=1\r\nhello\r\n1\r\n \r\nA\r\n0123456789\r\n0\r\nTrailer: x\r\n\r\n")
	testing.expect_value(t, result.outcome, Fetch_Outcome.Document)
	testing.expect_value(t, body, "hello 0123456789")
	testing.expect_value(t, string(result.cookie[:result.cookie_count]), "sid=42")
	// The edge of the cap: a body of exactly the cap is taken.
	at_cap := strings.repeat("a", FETCH_BODY_CAPACITY, context.temp_allocator)
	result, body = answer_read("http://h", strings.concatenate({HTML_HEAD, "Content-Length: 16384\r\n\r\n", at_cap}, context.temp_allocator))
	testing.expect_value(t, result.outcome, Fetch_Outcome.Document)
	testing.expect_value(t, len(body), FETCH_BODY_CAPACITY)
	// The media type and the charset in any case, quoted.
	result, _ = answer_read("http://h", "HTTP/1.1 200 OK\r\nContent-Type: TEXT/HTML ; Charset=\"UTF-8\"\r\nContent-Length: 0\r\n\r\n")
	testing.expect_value(t, result.outcome, Fetch_Outcome.Document)
	result, _ = answer_read("http://h", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 0\r\n\r\n")
	testing.expect_value(t, result.outcome, Fetch_Outcome.Document)
}

// Chunked bodies that break the framing, and bodies past the cap, are
// refused, and give no body.
@(test)
fetch_chunked_edge_cases :: proc(t: ^testing.T) {
	globals_hold()
	CHUNKED :: HTML_HEAD + "Transfer-Encoding: chunked\r\n\r\n"
	Case :: struct {
		body:    string,
		problem: Fetch_Problem,
	}
	over_cap := strings.concatenate({"4001\r\n", strings.repeat("a", FETCH_BODY_CAPACITY + 1, context.temp_allocator), "\r\n0\r\n\r\n"}, context.temp_allocator)
	split_over_cap := strings.concatenate({"4000\r\n", strings.repeat("a", FETCH_BODY_CAPACITY, context.temp_allocator), "\r\n1\r\nb\r\n0\r\n\r\n"}, context.temp_allocator)
	cases := [?]Case {
		{"", .Response_Incomplete},
		{"5\r\nhel", .Response_Incomplete},
		{"5\r\nhello\r\n", .Response_Incomplete},
		{"5\r\nhello\r\n0\r\n", .Response_Incomplete},
		{"5\r\nhelloXX0\r\n\r\n", .Response_Malformed},
		{"g\r\nx\r\n0\r\n\r\n", .Response_Malformed},
		{"\r\n0\r\n\r\n", .Response_Malformed},
		{"-1\r\nx\r\n0\r\n\r\n", .Response_Malformed},
		{"10000000000000000\r\n", .Response_Malformed},
		{"FFFFFFFFFFFFFFFF\r\n", .Response_Malformed},
		{"5\nhello\r\n0\r\n\r\n", .Response_Malformed},
		{over_cap, .Body_Too_Large},
		{split_over_cap, .Body_Too_Large},
	}
	for item in cases {
		result, body := answer_read("http://h", strings.concatenate({CHUNKED, item.body}, context.temp_allocator))
		testing.expectf(t, result.outcome == .Refused && result.problem == item.problem, "%q: %v %v", item.body, result.outcome, result.problem)
		testing.expectf(t, body == "", "%q gave a body", item.body)
	}
	// A NUL byte inside a chunk is data: the HTML parser makes it U+FFFD.
	result, body := answer_read("http://h", strings.concatenate({CHUNKED, "5\r\nhe\x00lo\r\n0\r\n\r\n"}, context.temp_allocator))
	testing.expect_value(t, result.outcome, Fetch_Outcome.Document)
	testing.expect_value(t, body, "he\x00lo")
	// A length and chunked together is a smuggled body.
	result, _ = answer_read("http://h", HTML_HEAD + "Content-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
	testing.expect_value(t, result.problem, Fetch_Problem.Response_Malformed)
	// A length past the cap is refused from the head alone, before its body.
	result, _ = answer_read("http://h", HTML_HEAD + "Content-Length: 16385\r\n\r\n")
	testing.expect_value(t, result.problem, Fetch_Problem.Body_Too_Large)
	result, _ = answer_read("http://h", HTML_HEAD + "Content-Length: 18446744073709551616\r\n\r\n")
	testing.expect_value(t, result.problem, Fetch_Problem.Response_Malformed)
	result, _ = answer_read("http://h", HTML_HEAD + "Content-Length: 5\r\n\r\nhel")
	testing.expect_value(t, result.problem, Fetch_Problem.Response_Incomplete)
}

// The heads that the browser refuses: not HTTP/1.1, an error status, a
// type that is not HTML, a charset that is not UTF-8.
@(test)
fetch_refuses_heads :: proc(t: ^testing.T) {
	globals_hold()
	Case :: struct {
		raw:     string,
		problem: Fetch_Problem,
	}
	cases := [?]Case {
		{"", .Response_Incomplete},
		{"HTTP/1.1 200 OK\r\n", .Response_Incomplete},
		{"HTTP/2 200 OK\r\n\r\n", .Response_Malformed},
		{"HTTP/1.1 999 X\r\n\r\n", .Response_Malformed},
		{"HTTP/1.1 200 OK\nContent-Type: text/html\n\n", .Response_Malformed},
		{"HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: 0\r\n\r\n", .Status_Refused},
		{"HTTP/1.1 500 Error\r\nContent-Length: 0\r\n\r\n", .Status_Refused},
		{"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", .Content_Type_Refused},
		{"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 0\r\n\r\n", .Content_Type_Refused},
		{"HTTP/1.1 200 OK\r\nContent-Type: text/htmlx\r\nContent-Length: 0\r\n\r\n", .Content_Type_Refused},
		{"HTTP/1.1 200 OK\r\nContent-Type: application/xhtml+xml\r\nContent-Length: 0\r\n\r\n", .Content_Type_Refused},
		{"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=iso-8859-1\r\nContent-Length: 0\r\n\r\n", .Charset_Refused},
		{"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=\r\nContent-Length: 0\r\n\r\n", .Charset_Refused},
		{"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-16\r\nContent-Length: 0\r\n\r\n", .Charset_Refused},
	}
	for item in cases {
		result, body := answer_read("http://h", item.raw)
		testing.expectf(t, result.outcome == .Refused && result.problem == item.problem, "%q: %v", item.raw, result.problem)
		testing.expect_value(t, body, "")
	}
}

// Redirects: resolved against the page, at most 5, never to a page of
// the system, never from HTTPS down to HTTP.
@(test)
fetch_redirects :: proc(t: ^testing.T) {
	globals_hold()
	redirect :: proc(location: string) -> string {
		return strings.concatenate({"HTTP/1.1 302 Found\r\nLocation: ", location, "\r\nContent-Length: 0\r\n\r\n"}, context.temp_allocator)
	}
	result, _ := answer_read("https://a.example/dir/page", redirect("/next?x=1"))
	testing.expect_value(t, result.outcome, Fetch_Outcome.Redirect)
	testing.expect_value(t, address_host(&result.next), "a.example")
	testing.expect_value(t, address_path(&result.next), "/next")
	testing.expect_value(t, result.next.scheme, html_css.Document_Scheme.Https)
	result, _ = answer_read("https://a.example", redirect("//b.example/x"))
	testing.expect_value(t, address_host(&result.next), "b.example")
	testing.expect_value(t, result.next.scheme, html_css.Document_Scheme.Https)
	result, _ = answer_read("http://a.example", redirect("https://b.example"))
	testing.expect_value(t, result.outcome, Fetch_Outcome.Redirect)
	for status in ([?]string{"301", "303", "307", "308"}) {
		result, _ = answer_read("http://a.example", strings.concatenate({"HTTP/1.1 ", status, " X\r\nLocation: /y\r\nContent-Length: 0\r\n\r\n"}, context.temp_allocator))
		testing.expectf(t, result.outcome == .Redirect, "%s is a redirect", status)
	}
	// The bound: the fifth redirect is followed, the sixth refused.
	result, _ = answer_read("http://a.example", redirect("/y"), REDIRECT_LIMIT - 1)
	testing.expect_value(t, result.outcome, Fetch_Outcome.Redirect)
	result, _ = answer_read("http://a.example", redirect("/y"), REDIRECT_LIMIT)
	testing.expect_value(t, result.problem, Fetch_Problem.Too_Many_Redirects)
	Case :: struct {
		base, raw: string,
		problem:   Fetch_Problem,
	}
	cases := [?]Case {
		{"http://a.example", "HTTP/1.1 302 Found\r\nContent-Length: 0\r\n\r\n", .Redirect_Without_Location},
		{"http://a.example", redirect(""), .Redirect_Without_Location},
		{"http://a.example", redirect("modus://welcome"), .Redirect_Scheme_Refused},
		{"https://a.example", redirect("http://a.example"), .Redirect_Scheme_Refused},
		{"https://a.example", redirect("ftp://a.example"), .Redirect_Location_Refused},
		{"https://a.example", redirect("https://a b"), .Redirect_Location_Refused},
		{"https://a.example", redirect(strings.concatenate({"https://", strings.repeat("h", HOST_CAPACITY + 1, context.temp_allocator)}, context.temp_allocator)), .Redirect_Location_Refused},
	}
	for item in cases {
		result, _ = answer_read(item.base, item.raw)
		testing.expectf(t, result.outcome == .Refused && result.problem == item.problem, "%q: %v", item.raw, result.problem)
	}
}

// Each broken sequence of UTF-8 becomes U+FFFD; a character never ends cut.
@(test)
fetch_body_utf8_replacement :: proc(t: ^testing.T) {
	globals_hold()
	output: [64]u8
	Case :: struct {
		source, text: string,
		replaced:     int,
	}
	cases := [?]Case {
		{"plain \xC3\xA9 \xF0\x9F\x98\x80", "plain \xC3\xA9 \xF0\x9F\x98\x80", 0},
		{"\xFF", "�", 1},
		{"\x80", "�", 1},
		{"\xC0\xAF", "��", 2},
		{"\xE0\x80\x80", "���", 3},
		{"\xED\xA0\x80", "���", 3},
		{"\xF4\x90\x80\x80", "����", 4},
		{"\xE2\x82", "��", 2},
		{"a\xC3", "a�", 1},
		{"\xF4\x8F\xBF\xBF", "\xF4\x8F\xBF\xBF", 0},
	}
	for item in cases {
		count, replaced := utf8_replace_invalid(transmute([]u8)item.source, output[:])
		testing.expectf(t, string(output[:count]) == item.text && replaced == item.replaced, "%q gives %q", item.source, string(output[:count]))
	}
	small: [5]u8
	count, _ := utf8_replace_invalid(transmute([]u8)string("ab\xF0\x9F\x98\x80"), small[:])
	testing.expect_value(t, string(small[:count]), "ab")
	count, _ = utf8_replace_invalid(transmute([]u8)string("abc\xFF"), small[:3 + 2])
	testing.expect_value(t, string(small[:count]), "abc")
	result, body := answer_read("http://h", HTML_HEAD + "Content-Length: 3\r\n\r\na\xFFb")
	testing.expect_value(t, result.replaced, 1)
	testing.expect_value(t, body, "a�b")
}

// The fragment: kept in the address, never in its origin, never sent; a
// fragment past its capacity is refused.
@(test)
address_fragments :: proc(t: ^testing.T) {
	globals_hold()
	address, problem := address_parse("https://h.example:8443/p?q=1#part/with?marks")
	testing.expect_value(t, problem, Address_Problem.None)
	testing.expect_value(t, address_fragment(&address), "part/with?marks")
	testing.expect_value(t, address_path(&address), "/p")
	testing.expect_value(t, address_query(&address), "q=1")
	buffer: [256]u8
	writer := Source_Writer{bytes = buffer[:]}
	address_write(&writer, &address)
	testing.expect_value(t, writer_text(&writer), "https://h.example:8443/p?q=1#part/with?marks")
	plain, _ := address_parse("https://h.example:8443/other")
	origin_a, origin_b := origin_of(&address), origin_of(&plain)
	testing.expect(t, html_css.origins_equal(&origin_a, &origin_b), "the fragment is not part of the origin")
	address, problem = address_parse("modus://guide#")
	testing.expect_value(t, problem, Address_Problem.None)
	testing.expect_value(t, address.fragment_count, 0)
	address, problem = address_parse(strings.concatenate({"modus://guide#", strings.repeat("f", FRAGMENT_CAPACITY, context.temp_allocator)}, context.temp_allocator))
	testing.expect_value(t, problem, Address_Problem.None)
	address, problem = address_parse(strings.concatenate({"modus://guide#", strings.repeat("f", FRAGMENT_CAPACITY + 1, context.temp_allocator)}, context.temp_allocator))
	testing.expect_value(t, problem, Address_Problem.Fragment_Too_Long)
	testing.expect(t, address == {}, "a refused address gives no part")
	address, problem = address_parse("https://#x")
	testing.expect_value(t, problem, Address_Problem.Host_Empty)
	address, problem = address_parse("https://h:80#x")
	testing.expect_value(t, problem, Address_Problem.None)
	testing.expect_value(t, address.port, u16(80))
	// A reference of a fragment keeps the path and the query of its page.
	base, _ := address_parse("http://h/a?b=1#old")
	writer = {bytes = buffer[:]}
	address_resolve(&writer, &base, "#new")
	testing.expect_value(t, writer_text(&writer), "http://h/a?b=1#new")
	writer = {bytes = buffer[:]}
	address_resolve(&writer, &base, "//other.example/x")
	testing.expect_value(t, writer_text(&writer), "http://other.example/x")
}

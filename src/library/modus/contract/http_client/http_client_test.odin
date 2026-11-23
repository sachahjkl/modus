#+build !freestanding
package http_client

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_request_encoder_and_injection_refusals :: proc(t: ^testing.T) {
	buf := make([]u8, 1024)
	defer delete(buf)

	// Valid GET request.
	hdrs := [?]Http_Header_Input{{name = "Accept", value = "text/html"}}
	n, ref := encode_request(.Get, "example.com", "/index.html", hdrs[:], nil, buf)
	testing.expect_value(t, ref, Http_Parse_Refusal.None)
	testing.expect_value(t, string(buf[:n]), "GET /index.html HTTP/1.1\r\nHost: example.com\r\nAccept: text/html\r\n\r\n")

	// Valid POST request with body.
	body := transmute([]u8)string("hello=world")
	n, ref = encode_request(.Post, "api.example.com", "/submit", nil, body, buf)
	testing.expect_value(t, ref, Http_Parse_Refusal.None)
	testing.expect_value(t, string(buf[:n]), "POST /submit HTTP/1.1\r\nHost: api.example.com\r\nContent-Length: 11\r\n\r\nhello=world")

	// Invalid method enum word (0 and 99).
	_, ref = encode_request(Http_Method(0), "example.com", "/", nil, nil, buf)
	testing.expect_value(t, ref, Http_Parse_Refusal.Invalid_Method)
	_, ref = encode_request(Http_Method(99), "example.com", "/", nil, nil, buf)
	testing.expect_value(t, ref, Http_Parse_Refusal.Invalid_Method)

	// CR/LF/NUL header injection in target, host, header name, header value.
	_, ref = encode_request(.Get, "example.com", "/a\r\nX-Evil: 1", nil, nil, buf)
	testing.expect_value(t, ref, Http_Parse_Refusal.Header_Injection)
	_, ref = encode_request(.Get, "example.com\r\nX-Evil: 1", "/", nil, nil, buf)
	testing.expect_value(t, ref, Http_Parse_Refusal.Header_Injection)
	bad_hdr1 := [?]Http_Header_Input{{name = "X-Test\r\nInjected", value = "1"}}
	_, ref = encode_request(.Get, "example.com", "/", bad_hdr1[:], nil, buf)
	testing.expect_value(t, ref, Http_Parse_Refusal.Header_Injection)
	bad_hdr2 := [?]Http_Header_Input{{name = "X-Test", value = "ok\nInjected: 1"}}
	_, ref = encode_request(.Get, "example.com", "/", bad_hdr2[:], nil, buf)
	testing.expect_value(t, ref, Http_Parse_Refusal.Header_Injection)
	bad_hdr3 := [?]Http_Header_Input{{name = "X-Test", value = "a\x00b"}}
	_, ref = encode_request(.Get, "example.com", "/", bad_hdr3[:], nil, buf)
	testing.expect_value(t, ref, Http_Parse_Refusal.Header_Injection)

	// Client-side CL + TE smuggling refused.
	smuggle_hdr := [?]Http_Header_Input{{name = "Transfer-Encoding", value = "chunked"}}
	_, ref = encode_request(.Post, "example.com", "/x", smuggle_hdr[:], body, buf)
	testing.expect_value(t, ref, Http_Parse_Refusal.Smuggling_Cl_And_Te)
}

@(test)
test_response_parser_smuggling_refusals :: proc(t: ^testing.T) {
	head := new(Http_Response_Head)
	defer free(head)

	// 1. Simultaneous Content-Length + Transfer-Encoding (CL before TE).
	r1 := transmute([]u8)string("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
	testing.expect_value(t, parse_response_head(r1, head), Http_Parse_Refusal.Smuggling_Cl_And_Te)

	// 2. Simultaneous Transfer-Encoding + Content-Length (TE before CL).
	r2 := transmute([]u8)string("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n0\r\n\r\n")
	testing.expect_value(t, parse_response_head(r2, head), Http_Parse_Refusal.Smuggling_Cl_And_Te)

	// 3. Duplicate conflicting Content-Length headers.
	r3 := transmute([]u8)string("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 10\r\n\r\nhello")
	testing.expect_value(t, parse_response_head(r3, head), Http_Parse_Refusal.Conflicting_Content_Length)

	// 4. Comma-separated conflicting Content-Length values.
	r4 := transmute([]u8)string("HTTP/1.1 200 OK\r\nContent-Length: 5, 10\r\n\r\nhello")
	testing.expect_value(t, parse_response_head(r4, head), Http_Parse_Refusal.Conflicting_Content_Length)

	// 5. Bare LF injection refused.
	r5 := transmute([]u8)string("HTTP/1.1 200 OK\nContent-Length: 0\r\n\r\n")
	testing.expect_value(t, parse_response_head(r5, head), Http_Parse_Refusal.Header_Injection)

	// 6. Bare CR injection refused.
	r6 := transmute([]u8)string("HTTP/1.1 200 OK\r\nX-A: 1\rX-B: 2\r\n\r\n")
	testing.expect_value(t, parse_response_head(r6, head), Http_Parse_Refusal.Header_Injection)

	// 7. Obsolete header line folding (obs-fold) refused.
	r7 := transmute([]u8)string("HTTP/1.1 200 OK\r\nX-A: 1\r\n continued\r\n\r\n")
	testing.expect_value(t, parse_response_head(r7, head), Http_Parse_Refusal.Malformed_Header)

	// 8. Space before colon refused.
	r8 := transmute([]u8)string("HTTP/1.1 200 OK\r\nContent-Length : 0\r\n\r\n")
	testing.expect_value(t, parse_response_head(r8, head), Http_Parse_Refusal.Malformed_Header)

	// 9. Oversized header block (> 8192 bytes) refused.
	huge := make([]u8, MAX_HEADER_BLOCK_SIZE + 64)
	defer delete(huge)
	prefix := "HTTP/1.1 200 OK\r\nX-Big: "
	copy(huge[:len(prefix)], prefix)
	for i := len(prefix); i < len(huge) - 4; i += 1 {
		huge[i] = 'a'
	}
	copy(huge[len(huge) - 4:], "\r\n\r\n")
	testing.expect_value(t, parse_response_head(huge, head), Http_Parse_Refusal.Header_Too_Large)

	// 10. Unsupported HTTP version refused.
	r10 := transmute([]u8)string("HTTP/2.0 200 OK\r\n\r\n")
	testing.expect_value(t, parse_response_head(r10, head), Http_Parse_Refusal.Unsupported_Version)
}

@(test)
test_chunked_decoding_and_edge_cases :: proc(t: ^testing.T) {
	head := new(Http_Response_Head)
	defer free(head)
	body_out := make([]u8, 256)
	defer delete(body_out)

	// Valid multi-chunk response with chunk extension and trailer.
	resp := transmute([]u8)string("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nHello\r\n7\r\n, World\r\n0\r\nX-Trailer: ok\r\n\r\n")
	blen, consumed, ref := parse_response(resp, head, body_out)
	testing.expect_value(t, ref, Http_Parse_Refusal.None)
	testing.expect_value(t, head.status_code, u16(200))
	testing.expect_value(t, string(body_out[:blen]), "Hello, World")
	testing.expect_value(t, consumed, len(resp))

	// Hex overflow (17 hex digits) refused.
	_, _, cref := decode_chunked_body(transmute([]u8)string("10000000000000000\r\n"), body_out)
	testing.expect_value(t, cref, Http_Parse_Refusal.Invalid_Chunk_Size)

	// Chunk size exceeding MAX_CHUNK_SIZE (0x1000001 = 16 MiB + 1) refused.
	_, _, cref = decode_chunked_body(transmute([]u8)string("1000001\r\n"), body_out)
	testing.expect_value(t, cref, Http_Parse_Refusal.Invalid_Chunk_Size)

	// Invalid hex digit refused.
	_, _, cref = decode_chunked_body(transmute([]u8)string("5z\r\nhello\r\n0\r\n\r\n"), body_out)
	testing.expect_value(t, cref, Http_Parse_Refusal.Invalid_Chunk_Size)

	// Missing CRLF after chunk payload refused.
	_, _, cref = decode_chunked_body(transmute([]u8)string("5\r\nhelloXX0\r\n\r\n"), body_out)
	testing.expect_value(t, cref, Http_Parse_Refusal.Chunk_Missing_Crlf)

	// Truncated chunk refused.
	_, _, cref = decode_chunked_body(transmute([]u8)string("5\r\nhel"), body_out)
	testing.expect_value(t, cref, Http_Parse_Refusal.Chunk_Incomplete)
}

@(test)
test_http3_framing_bridge_and_h2_refusals :: proc(t: ^testing.T) {
	// QUIC varint boundary values.
	varint_buf: [8]u8
	for v in ([]u64{0, 1, 63, 64, 16383, 16384, (1 << 30) - 1, 1 << 30, QUIC_VARINT_MAX}) {
		w, wok := quic_varint_encode(v, varint_buf[:])
		testing.expect(t, wok, "valid varint must encode")
		dec, dlen, dok := quic_varint_decode(varint_buf[:w])
		testing.expect(t, dok && dlen == w && dec == v, "varint must round-trip")
	}
	_, over_ok := quic_varint_encode(QUIC_VARINT_MAX + 1, varint_buf[:])
	testing.expect(t, !over_ok, "varint past 2^62-1 must be refused")

	// HTTP/3 request + response framing round-trip.
	wire := make([]u8, 2048)
	body_out := make([]u8, 256)
	head := new(Http_Response_Head)
	defer delete(wire)
	defer delete(body_out)
	defer free(head)

	req_hdrs := [?]Http_Header_Input{{name = "accept", value = "text/html"}}
	rn, rref := http3_encode_request(.Get, "https", "modus.example", "/page", req_hdrs[:], nil, wire)
	testing.expect_value(t, rref, Http_Parse_Refusal.None)
	f, fref := http3_read_frame(wire[:rn])
	testing.expect_value(t, fref, Http_Parse_Refusal.None)
	testing.expect_value(t, f.frame_type, Http3_Frame_Type.Headers)

	resp_hdrs := [?]Http_Header_Input{{name = "content-type", value = "text/plain"}}
	sn, sref := http3_encode_response(200, resp_hdrs[:], transmute([]u8)string("http3 ok"), wire)
	testing.expect_value(t, sref, Http_Parse_Refusal.None)

	blen, dref := http3_decode_response(wire[:sn], head, body_out)
	testing.expect_value(t, dref, Http_Parse_Refusal.None)
	testing.expect_value(t, head.version, Http_Version.Http_3)
	testing.expect_value(t, head.status_code, u16(200))
	testing.expect_value(t, string(body_out[:blen]), "http3 ok")

	// Forbidden HTTP/2 frame types (0x02, 0x06, 0x08, 0x09) refused per RFC 9114.
	for bad_ft in ([]u8{0x02, 0x06, 0x08, 0x09}) {
		bad_frame := [2]u8{bad_ft, 0x00}
		_, bad_ref := http3_read_frame(bad_frame[:])
		testing.expect_value(t, bad_ref, Http_Parse_Refusal.Forbidden_H2_Frame)
	}
}

@(test)
test_cookie_attributes_and_secure_enforcement :: proc(t: ^testing.T) {
	jar := store_test_jar_make()
	defer free(jar)
	out := make([]u8, 512)
	defer delete(out)

	https_origin, oref := origin_key_make(0, .Https, "app.example.com", 443)
	testing.expect_value(t, oref, Store_Refusal.None)
	http_origin, oref2 := origin_key_make(0, .Http, "app.example.com", 443)
	testing.expect_value(t, oref2, Store_Refusal.None)
	sub_https, _ := origin_key_make(0, .Https, "sub.app.example.com", 443)

	now: i64 = 1_700_000_000

	// Secure + HttpOnly + SameSite=Strict cookie.
	testing.expect_value(t, cookie_jar_set_from_header(jar, &https_origin, "/panel/home", "sid=secret123; Secure; HttpOnly; SameSite=Strict; Max-Age=300", now), Store_Refusal.None)

	// NEVER sent over plain HTTP!
	n, ref := cookie_jar_format_header(jar, &http_origin, "/panel/home", true, true, false, now + 10, out)
	testing.expect_value(t, ref, Store_Refusal.None)
	testing.expect_value(t, n, 0)

	// Sent over HTTPS on matching path (/panel and /panel/x), NOT on /panel2!
	n, ref = cookie_jar_format_header(jar, &https_origin, "/panel/settings", true, true, false, now + 10, out)
	testing.expect_value(t, ref, Store_Refusal.None)
	testing.expect_value(t, string(out[:n]), "sid=secret123")

	n, ref = cookie_jar_format_header(jar, &https_origin, "/panel2", true, true, false, now + 10, out)
	testing.expect_value(t, ref, Store_Refusal.None)
	testing.expect_value(t, n, 0)

	// HttpOnly hidden from script access!
	n, ref = cookie_jar_format_header(jar, &https_origin, "/panel/home", true, true, true, now + 10, out)
	testing.expect_value(t, ref, Store_Refusal.None)
	testing.expect_value(t, n, 0)

	// SameSite=Strict hidden on cross-site request!
	n, ref = cookie_jar_format_header(jar, &https_origin, "/panel/home", false, true, false, now + 10, out)
	testing.expect_value(t, ref, Store_Refusal.None)
	testing.expect_value(t, n, 0)

	// Expired after Max-Age=300!
	n, ref = cookie_jar_format_header(jar, &https_origin, "/panel/home", true, true, false, now + 300, out)
	testing.expect_value(t, ref, Store_Refusal.None)
	testing.expect_value(t, n, 0)

	// SameSite=None without Secure is refused!
	testing.expect_value(t, cookie_jar_set_from_header(jar, &https_origin, "/", "x=1; SameSite=None", now), Store_Refusal.Secure_Required)

	// Cross-domain cookie injection refused!
	testing.expect_value(t, cookie_jar_set_from_header(jar, &https_origin, "/", "evil=1; Domain=other.com", now), Store_Refusal.Domain_Mismatch)
	testing.expect_value(t, cookie_jar_set_from_header(jar, &https_origin, "/", "tld=1; Domain=com", now), Store_Refusal.Domain_Mismatch)

	// Valid Domain cookie shared with subdomain.
	testing.expect_value(t, cookie_jar_set_from_header(jar, &https_origin, "/", "theme=dark; Domain=app.example.com; Path=/; Secure", now), Store_Refusal.None)
	n, ref = cookie_jar_format_header(jar, &sub_https, "/any", true, true, false, now, out)
	testing.expect_value(t, ref, Store_Refusal.None)
	testing.expect_value(t, string(out[:n]), "theme=dark")

	// IMF-fixdate Expires parsing.
	ts, ts_ok := parse_http_date_imf(transmute([]u8)string("Thu, 01 Jan 1970 00:01:00 GMT"))
	testing.expect(t, ts_ok && ts == 60, "IMF-fixdate must parse to exact Unix seconds")
}

@(test)
test_strict_per_principal_isolation_cookies_and_cache :: proc(t: ^testing.T) {
	jar := store_test_jar_make()
	cache := store_test_cache_make()
	defer free(jar)
	defer free(cache)

	out := make([]u8, 1024)
	body_out := make([]u8, 1024)
	defer delete(out)
	defer delete(body_out)

	p0, _ := origin_key_make(0, .Https, "bank.example", 443)
	p1, _ := origin_key_make(1, .Https, "bank.example", 443)
	now: i64 = 1_700_000_000

	// Principal 0 stores cookie and cached response for https://bank.example:443/account.
	testing.expect_value(t, cookie_jar_set_from_header(jar, &p0, "/", "session=P0_SECRET; Secure; Path=/; Max-Age=600", now), Store_Refusal.None)
	testing.expect_value(t, response_cache_store(cache, &p0, "/account", 200, "max-age=600", transmute([]u8)string("BALANCE_P0=$9999"), now), Store_Refusal.None)

	// Principal 1 queries the EXACT SAME URL: MUST see ZERO cookies and cache MISS!
	n, ref := cookie_jar_format_header(jar, &p1, "/account", true, true, false, now + 1, out)
	testing.expect_value(t, ref, Store_Refusal.None)
	testing.expect_value(t, n, 0)

	_, _, hit := response_cache_lookup(cache, &p1, "/account", now + 1, body_out)
	testing.expect(t, !hit, "Principal 1 must never hit Principal 0's cached page")

	// Principal 1 stores its own cookie and cached page for the exact same URL.
	testing.expect_value(t, cookie_jar_set_from_header(jar, &p1, "/", "session=P1_OWN; Secure; Path=/; Max-Age=600", now), Store_Refusal.None)
	testing.expect_value(t, response_cache_store(cache, &p1, "/account", 200, "max-age=600", transmute([]u8)string("BALANCE_P1=$10"), now), Store_Refusal.None)

	// Eviction isolation attack: Principal 1 floods 2x cookie quota and 4x cache quota!
	jar.cookies_of_a_principal, cache.entries_of_a_principal = 32, 8
	for i := 0; i < jar.cookies_of_a_principal * 2; i += 1 {
		hdr := fmt.tprintf("flood%d=v%d; Secure; Path=/; Max-Age=600", i, i)
		testing.expect_value(t, cookie_jar_set_from_header(jar, &p1, "/", hdr, now), Store_Refusal.None)
	}
	for i := 0; i < cache.entries_of_a_principal * 4; i += 1 {
		path := fmt.tprintf("/flood/%d", i)
		testing.expect_value(t, response_cache_store(cache, &p1, path, 200, "max-age=600", transmute([]u8)string("flood"), now), Store_Refusal.None)
	}

	// Principal 0's cookie and cached response MUST remain 100% intact and un-evicted!
	n, ref = cookie_jar_format_header(jar, &p0, "/account", true, true, false, now + 5, out)
	testing.expect_value(t, ref, Store_Refusal.None)
	testing.expect_value(t, string(out[:n]), "session=P0_SECRET")

	st, blen, hit0 := response_cache_lookup(cache, &p0, "/account", now + 5, body_out)
	testing.expect(t, hit0, "Principal 0's cached entry must survive Principal 1's flood")
	testing.expect_value(t, st, u16(200))
	testing.expect_value(t, string(body_out[:blen]), "BALANCE_P0=$9999")

	// Cache-Control: no-store refuses storing and purges ONLY the calling principal's entry.
	testing.expect_value(t, response_cache_store(cache, &p1, "/secret", 200, "no-store, max-age=600", transmute([]u8)string("nope"), now), Store_Refusal.Not_Cacheable)
	_, _, hit_ns := response_cache_lookup(cache, &p1, "/secret", now + 1, body_out)
	testing.expect(t, !hit_ns, "no-store response must never be cached")

	// Principal 1 sending no-store on /account must NOT purge Principal 0's /account cache!
	testing.expect_value(t, response_cache_store(cache, &p1, "/account", 200, "no-store", transmute([]u8)string("x"), now), Store_Refusal.Not_Cacheable)
	_, blen, hit0 = response_cache_lookup(cache, &p0, "/account", now + 6, body_out)
	testing.expect(t, hit0 && string(body_out[:blen]) == "BALANCE_P0=$9999", "Principal 1 no-store must not purge Principal 0 cache")
}

// The jar and the cache hold what their memory holds, past each fixed
// count of before: 100 principals with 40 cookies each, a cookie value of
// 4000 bytes, and a cached body of 64 KiB (16 times the 4 KiB of before).
// A memory that cannot grow keeps its own: a principal with no entry is
// refused, never given the place of another, and a body that the bodies do
// not hold is refused with no entry; the places of replaced bodies come
// back by a compaction, and the bodies read back whole.
@(test)
test_jar_and_cache_grow_with_their_memory :: proc(t: ^testing.T) {
	jar := store_test_jar_make()
	cache := store_test_cache_make()
	defer free(jar)
	defer free(cache)
	now: i64 = 1_700_000_000
	out := make([]u8, 8192)
	defer delete(out)
	for principal in 0 ..< 100 {
		origin, _ := origin_key_make(u64(principal), .Https, "site.example", 443)
		for cookie in 0 ..< 40 {
			testing.expect_value(t, cookie_jar_set_from_header(jar, &origin, "/", fmt.tprintf("c%d=v; Secure; Path=/", cookie), now), Store_Refusal.None)
		}
	}
	last, _ := origin_key_make(99, .Https, "site.example", 443)
	n, _ := cookie_jar_format_header(jar, &last, "/", true, true, false, now, out)
	testing.expect(t, n > 0 && strings.count(string(out[:n]), "=") == 40, "each cookie of the last principal is kept")
	long_value := strings.repeat("v", 4000, context.temp_allocator)
	testing.expect_value(t, cookie_jar_set_from_header(jar, &last, "/", fmt.tprintf("long=%s; Secure; Path=/", long_value), now), Store_Refusal.None)

	big := make([]u8, 64 << 10)
	defer delete(big)
	for &b, i in big {
		b = u8(i)
	}
	body_out := make([]u8, 64 << 10)
	defer delete(body_out)
	testing.expect_value(t, response_cache_store(cache, &last, "/big", 200, "max-age=600", big, now), Store_Refusal.None)
	_, blen, hit := response_cache_lookup(cache, &last, "/big", now + 1, body_out)
	testing.expect(t, hit && blen == len(big) && string(body_out[:blen]) == string(big), "a body of 64 KiB reads back whole")

	// A fixed memory: four entries and 32 bytes of bodies.
	entries := make([]Cache_Entry, 4)
	defer delete(entries)
	bodies := make([]u8, 32)
	defer delete(bodies)
	fixed := Response_Cache{entries = entries, bodies = bodies}
	other, _ := origin_key_make(5, .Https, "site.example", 443)
	for i in 0 ..< 4 {
		testing.expect_value(t, response_cache_store(&fixed, &last, fmt.tprintf("/p%d", i), 200, "max-age=600", transmute([]u8)string("12345678"), now), Store_Refusal.None)
	}
	testing.expect_value(t, response_cache_store(&fixed, &other, "/x", 200, "max-age=600", transmute([]u8)string("1"), now), Store_Refusal.Principal_Quota_Exceeded)
	testing.expect_value(t, response_cache_store(&fixed, &last, "/p0", 200, "max-age=600", make([]u8, 33, context.temp_allocator), now), Store_Refusal.Body_Too_Large)
	_, _, hit = response_cache_lookup(&fixed, &last, "/p0", now + 1, body_out)
	testing.expect(t, !hit, "a refused body leaves no entry")
	// Each replacement frees the place of the body before it: the bodies stay
	// within their 32 bytes by compaction.
	for round in 0 ..< 8 {
		text := fmt.tprintf("r%d-abcd", round)
		testing.expect_value(t, response_cache_store(&fixed, &last, "/p1", 200, "max-age=600", transmute([]u8)text, now), Store_Refusal.None)
		_, blen, hit = response_cache_lookup(&fixed, &last, "/p1", now + 1, body_out)
		testing.expect(t, hit && string(body_out[:blen]) == text)
	}
	_, blen, hit = response_cache_lookup(&fixed, &last, "/p2", now + 1, body_out)
	testing.expect(t, hit && string(body_out[:blen]) == "12345678", "a moved body reads back whole")
}

#+build !freestanding
#+build !modus
package origin_browser

import "core:fmt"
import "core:testing"

@(test)
origin_browser_border_words :: proc(t: ^testing.T) {
	_, ok := url_scheme_of_word(0)
	testing.expect_value(t, ok, false)
	_, ok = url_scheme_of_word(3)
	testing.expect_value(t, ok, false)
	sc, sc_ok := url_scheme_of_word(u64(Url_Scheme.Https))
	testing.expect_value(t, sc_ok, true)
	testing.expect_value(t, sc, Url_Scheme.Https)

	_, ok = form_method_of_word(0)
	testing.expect_value(t, ok, false)
	m, m_ok := form_method_of_word(u64(Form_Method.Post))
	testing.expect_value(t, m_ok, true)
	testing.expect_value(t, m, Form_Method.Post)
}

@(test)
origin_parse_and_rfc6454_equality :: proc(t: ^testing.T) {
	// Refusals first: empty, control bytes, unsupported schemes, credentials, bad host, bad port.
	_, ref := origin_parse_url("")
	testing.expect_value(t, ref, Origin_Browser_Refusal.Empty_Url)

	_, ref = origin_parse_url("https://example.com/\r\nX-Inject: 1")
	testing.expect_value(t, ref, Origin_Browser_Refusal.Bad_Control_Byte)

	_, ref = origin_parse_url("javascript:alert(1)")
	testing.expect_value(t, ref, Origin_Browser_Refusal.Unsupported_Scheme)

	_, ref = origin_parse_url("file:///etc/passwd")
	testing.expect_value(t, ref, Origin_Browser_Refusal.Unsupported_Scheme)

	_, ref = origin_parse_url("https://user:pass@example.com/path")
	testing.expect_value(t, ref, Origin_Browser_Refusal.Credentials_Refused)

	_, ref = origin_parse_url("https:///only-path")
	testing.expect_value(t, ref, Origin_Browser_Refusal.Missing_Host)

	_, ref = origin_parse_url("https://bad..host.com/")
	testing.expect_value(t, ref, Origin_Browser_Refusal.Bad_Host_Byte)

	_, ref = origin_parse_url("https://example.com:0/")
	testing.expect_value(t, ref, Origin_Browser_Refusal.Bad_Port)

	_, ref = origin_parse_url("https://example.com:65536/")
	testing.expect_value(t, ref, Origin_Browser_Refusal.Bad_Port)

	_, ref = origin_parse_url("https://example.com:abc/")
	testing.expect_value(t, ref, Origin_Browser_Refusal.Bad_Port)

	// Canonical RFC 6454 origin parsing and equality.
	http_a, r1 := origin_parse_url("http://a.example/page1")
	https_a, r2 := origin_parse_url("HTTPS://A.EXAMPLE:443/page2?q=1")
	https_a_default, r3 := origin_parse_url("https://a.example/other")
	https_b, r4 := origin_parse_url("https://b.example/")
	https_a_alt_port, r5 := origin_parse_url("https://a.example:8443/")
	ipv6, r6 := origin_parse_url("https://[::1]:8443/api")

	testing.expect_value(t, r1, Origin_Browser_Refusal.None)
	testing.expect_value(t, r2, Origin_Browser_Refusal.None)
	testing.expect_value(t, r3, Origin_Browser_Refusal.None)
	testing.expect_value(t, r4, Origin_Browser_Refusal.None)
	testing.expect_value(t, r5, Origin_Browser_Refusal.None)
	testing.expect_value(t, r6, Origin_Browser_Refusal.None)

	testing.expect_value(t, origin_host(&https_a), "a.example")
	testing.expect_value(t, https_a.port, HTTPS_DEFAULT_PORT)
	testing.expect_value(t, origin_host(&ipv6), "[::1]")
	testing.expect_value(t, ipv6.port, u16(8443))

	// Explicit vs default port and case-folded host match; different scheme/host/port do not.
	testing.expect_value(t, origin_equal(&https_a, &https_a_default), true)
	testing.expect_value(t, origin_equal(&http_a, &https_a), false)
	testing.expect_value(t, origin_equal(&https_a, &https_b), false)
	testing.expect_value(t, origin_equal(&https_a, &https_a_alt_port), false)
}

@(test)
origin_process_table_strict_isolation :: proc(t: ^testing.T) {
	table: Origin_Process_Table
	orig_a, _ := origin_parse_url("https://alpha.example/")
	orig_b, _ := origin_parse_url("https://beta.example/")
	orig_a_http, _ := origin_parse_url("http://alpha.example/")

	// Null table refused.
	_, _, ref := origin_table_acquire(nil, orig_a)
	testing.expect_value(t, ref, Origin_Browser_Refusal.Null_State)

	// Acquire distinct slots for distinct origins; same origin reuses its slot.
	pid_a, reused_a, r1 := origin_table_acquire(&table, orig_a)
	testing.expect_value(t, r1, Origin_Browser_Refusal.None)
	testing.expect_value(t, reused_a, false)
	testing.expect(t, pid_a > 0)

	pid_a_again, reused_a2, r2 := origin_table_acquire(&table, orig_a)
	testing.expect_value(t, r2, Origin_Browser_Refusal.None)
	testing.expect_value(t, reused_a2, true)
	testing.expect_value(t, pid_a_again, pid_a)

	pid_b, reused_b, r3 := origin_table_acquire(&table, orig_b)
	testing.expect_value(t, r3, Origin_Browser_Refusal.None)
	testing.expect_value(t, reused_b, false)
	testing.expect(t, pid_b != pid_a)

	pid_a_http, reused_ah, r4 := origin_table_acquire(&table, orig_a_http)
	testing.expect_value(t, r4, Origin_Browser_Refusal.None)
	testing.expect_value(t, reused_ah, false)
	testing.expect(t, pid_a_http != pid_a)

	// Cross-origin DOM/storage access is strictly denied.
	testing.expect_value(t, origin_table_may_access(&table, pid_a, orig_a), Origin_Browser_Refusal.None)
	testing.expect_value(t, origin_table_may_access(&table, pid_a, orig_b), Origin_Browser_Refusal.Cross_Origin_Denied)
	testing.expect_value(t, origin_table_may_access(&table, pid_a, orig_a_http), Origin_Browser_Refusal.Cross_Origin_Denied)
	testing.expect_value(t, origin_table_may_access(&table, 99999, orig_a), Origin_Browser_Refusal.Process_Not_Found)

	// Release frees slot; subsequent access fails with Process_Not_Found.
	testing.expect_value(t, origin_table_release(&table, pid_b), Origin_Browser_Refusal.None)
	testing.expect_value(t, origin_table_may_access(&table, pid_b, orig_b), Origin_Browser_Refusal.Process_Not_Found)

	// Fill table to capacity and verify Table_Full refusal without mutation.
	full: Origin_Process_Table
	for i in 0 ..< ORIGIN_PROCESS_CAPACITY {
		u := fmt.tprintf("https://site%03d.example/", i)
		o, _ := origin_parse_url(u)
		_, _, acq_ref := origin_table_acquire(&full, o)
		testing.expect_value(t, acq_ref, Origin_Browser_Refusal.None)
	}
	overflow_origin, _ := origin_parse_url("https://overflow.example/")
	_, _, ov_ref := origin_table_acquire(&full, overflow_origin)
	testing.expect_value(t, ov_ref, Origin_Browser_Refusal.Table_Full)
}

@(test)
history_stack_navigation_and_form_encoding :: proc(t: ^testing.T) {
	stack := new(History_Stack)
	defer free(stack)
	stack^ = history_init()
	_, ref := history_back(stack)
	testing.expect_value(t, ref, Origin_Browser_Refusal.No_Back_Entry)
	_, ref = history_forward(stack)
	testing.expect_value(t, ref, Origin_Browser_Refusal.No_Forward_Entry)

	// Malformed URL refused without mutating history.
	_, nav_ref := history_navigate(stack, "javascript:void(0)")
	testing.expect_value(t, nav_ref, Origin_Browser_Refusal.Unsupported_Scheme)
	testing.expect_value(t, stack.count, u16(0))

	// Navigate 3 pages, go back, navigate new branch (truncates forward history).
	_, nav_ref = history_navigate(stack, "https://one.example/")
	testing.expect_value(t, nav_ref, Origin_Browser_Refusal.None)
	_, nav_ref = history_navigate(stack, "https://two.example/a")
	testing.expect_value(t, nav_ref, Origin_Browser_Refusal.None)
	_, nav_ref = history_navigate(stack, "https://three.example/b")
	testing.expect_value(t, nav_ref, Origin_Browser_Refusal.None)

	prev, back_ref := history_back(stack)
	testing.expect_value(t, back_ref, Origin_Browser_Refusal.None)
	testing.expect_value(t, history_entry_url(prev), "https://two.example/a")

	fwd, fwd_ref := history_forward(stack)
	testing.expect_value(t, fwd_ref, Origin_Browser_Refusal.None)
	testing.expect_value(t, history_entry_url(fwd), "https://three.example/b")

	_, _ = history_back(stack)
	_, nav_ref = history_navigate(stack, "https://four.example/c")
	testing.expect_value(t, nav_ref, Origin_Browser_Refusal.None)
	_, fwd_ref = history_forward(stack)
	testing.expect_value(t, fwd_ref, Origin_Browser_Refusal.No_Forward_Entry)

	cur, has_cur := history_current(stack)
	testing.expect_value(t, has_cur, true)
	testing.expect_value(t, history_entry_url(cur), "https://four.example/c")

	// application/x-www-form-urlencoded safe percent-encoding and zero-mutation refusal.
	fields := [2]Form_Field{
		{name = "q", value = "hello world & 100%"},
		{name = "tag", value = "a+b=c"},
	}
	buf: [64]u8
	n, enc_ref := form_encode_urlencoded(fields[:], buf[:])
	testing.expect_value(t, enc_ref, Origin_Browser_Refusal.None)
	testing.expect_value(t, string(buf[:n]), "q=hello+world+%26+100%25&tag=a%2Bb%3Dc")

	tiny := [4]u8{'X', 'Y', 'Z', 'W'}
	n, enc_ref = form_encode_urlencoded(fields[:], tiny[:])
	testing.expect_value(t, enc_ref, Origin_Browser_Refusal.Buffer_Too_Small)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, tiny[0], u8('X'))
}

@(test)
zero_init_history_and_corrupt_count_refusal :: proc(t: ^testing.T) {
	// Zero-initialized History_Stack{} must land cleanly at entries[0] with count == 1.
	zero_stack := new(History_Stack)
	defer free(zero_stack)
	_, ref := history_navigate(zero_stack, "https://first.example/")
	testing.expect_value(t, ref, Origin_Browser_Refusal.None)
	testing.expect_value(t, zero_stack.count, u16(1))
	testing.expect_value(t, zero_stack.current_index, i32(0))
	cur, ok := history_current(zero_stack)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, history_entry_url(cur), "https://first.example/")

	// Corrupt count past HISTORY_CAPACITY is refused without mutation.
	corrupt := new(History_Stack)
	defer free(corrupt)
	corrupt.count = HISTORY_CAPACITY + 1
	_, cref := history_navigate(corrupt, "https://second.example/")
	testing.expect_value(t, cref, Origin_Browser_Refusal.Table_Full)
	testing.expect_value(t, corrupt.count, u16(HISTORY_CAPACITY + 1))
}

@(test)
ipv6_rfc4291_refusals_and_rfc5952_canonical_equivalence :: proc(t: ^testing.T) {
	bad_ipv6_urls := [?]string{
		"https://[::::]/",
		"https://[:::]/",
		"https://[...]/",
		"https://[1.2.3.4]/",
		"https://[::1::2]/",
		"https://[1:2:3:4:5:6:7]/",
		"https://[1:2:3:4:5:6:7:8:9]/",
		"https://[1:2:3:4:5:6:7:8::]/",
		"https://[12345::1]/",
		"https://[:1]/",
		"https://[1:]/",
		"https://[::g]/",
	}
	for u in bad_ipv6_urls {
		_, ref := origin_parse_url(u)
		testing.expect_value(t, ref, Origin_Browser_Refusal.Bad_Host_Byte)
	}

	// RFC 5952 canonicalization: expanded loopback == compressed loopback.
	a, r1 := origin_parse_url("https://[::1]:443/a")
	b, r2 := origin_parse_url("https://[0000:0000:0000:0000:0000:0000:0000:0001]/b")
	testing.expect_value(t, r1, Origin_Browser_Refusal.None)
	testing.expect_value(t, r2, Origin_Browser_Refusal.None)
	testing.expect_value(t, origin_host(&a), "[::1]")
	testing.expect_value(t, origin_host(&b), "[::1]")
	testing.expect_value(t, origin_equal(&a, &b), true)

	// Unspecified all-zeros address compresses to `[::]`.
	unspec, r3 := origin_parse_url("http://[0:0:0:0:0:0:0:0]/")
	testing.expect_value(t, r3, Origin_Browser_Refusal.None)
	testing.expect_value(t, origin_host(&unspec), "[::]")

	// Leftmost longest run wins tie, uppercase folds to lowercase, leading zeros stripped.
	tie, r4 := origin_parse_url("https://[2001:0DB8:0000:0000:0001:0000:0000:0001]/")
	testing.expect_value(t, r4, Origin_Browser_Refusal.None)
	testing.expect_value(t, origin_host(&tie), "[2001:db8::1:0:0:1]")

	// Single zero group is never compressed to `::` (RFC 5952 section 4.2.2).
	single_zero, r5 := origin_parse_url("https://[2001:db8:0:1:1:1:1:1]/")
	testing.expect_value(t, r5, Origin_Browser_Refusal.None)
	testing.expect_value(t, origin_host(&single_zero), "[2001:db8:0:1:1:1:1:1]")
}

@(test)
origin_table_max_pid_and_non_canonical_host_refusals :: proc(t: ^testing.T) {
	// Refuse max(u64) process ID wraparound to sentinel 0.
	table: Origin_Process_Table
	table.next_process_id = max(u64)
	orig, _ := origin_parse_url("https://wrap.example/")
	pid, reused, ref := origin_table_acquire(&table, orig)
	testing.expect_value(t, ref, Origin_Browser_Refusal.Table_Full)
	testing.expect_value(t, pid, u64(0))
	testing.expect_value(t, reused, false)
	testing.expect_value(t, table.next_process_id, max(u64))

	// Refuse hand-constructed non-canonical hosts (uppercase DNS or non-canonical IPv6).
	fresh: Origin_Process_Table
	bad_dns := Web_Origin{scheme = .Https, port = 443, host_len = 7}
	copy(bad_dns.host[:7], "Bad.COM")
	_, _, ref = origin_table_acquire(&fresh, bad_dns)
	testing.expect_value(t, ref, Origin_Browser_Refusal.Bad_Host_Byte)

	bad_v6 := Web_Origin{scheme = .Https, port = 443, host_len = 6}
	copy(bad_v6.host[:6], "[::::]")
	_, _, ref = origin_table_acquire(&fresh, bad_v6)
	testing.expect_value(t, ref, Origin_Browser_Refusal.Bad_Host_Byte)

	non_canon_v6 := Web_Origin{scheme = .Https, port = 443, host_len = 17}
	copy(non_canon_v6.host[:17], "[0:0:0:0:0:0:0:1]")
	_, _, ref = origin_table_acquire(&fresh, non_canon_v6)
	testing.expect_value(t, ref, Origin_Browser_Refusal.Bad_Host_Byte)
}

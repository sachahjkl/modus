#+build !freestanding
package browser

import "core:strings"
import "core:sync"
import "core:testing"
import "modus:contract/html_css"

// The tests share the globals of the module: the workspace of the
// document, the states of the origins, the head of an answer. One test at
// a time holds them, as the test runner runs the tests on several threads.
@(private)
browser_globals_lock: sync.Mutex

@(deferred_none = globals_release)
globals_hold :: proc() {
	sync.mutex_lock(&browser_globals_lock)
}

globals_release :: proc() {
	sync.mutex_unlock(&browser_globals_lock)
}

// The parser of the address field refuses each address that it cannot
// read, with its problem, and gives nothing of it.
@(test)
address_parse_refuses_each_broken_address :: proc(t: ^testing.T) {
	globals_hold()
	long_host := strings.repeat("a", HOST_CAPACITY + 1, context.temp_allocator)
	long_path := strings.concatenate({"modus://guide/", strings.repeat("p", PATH_CAPACITY, context.temp_allocator)}, context.temp_allocator)
	long_query := strings.concatenate({"modus://guide?", strings.repeat("q", QUERY_CAPACITY + 1, context.temp_allocator)}, context.temp_allocator)
	too_long := strings.repeat("a", ADDRESS_CAPACITY + 1, context.temp_allocator)
	Case :: struct {
		text:    string,
		problem: Address_Problem,
	}
	cases := [?]Case {
		{"", .Empty},
		{"   \t ", .Empty},
		{too_long, .Too_Long},
		{"ftp://example.org", .Scheme_Unknown},
		{"://example.org", .Scheme_Unknown},
		{"httpss://example.org", .Scheme_Unknown},
		{"modus://", .Host_Empty},
		{"modus:///guide", .Host_Empty},
		{"http://:80", .Host_Empty},
		{strings.concatenate({"https://", long_host}, context.temp_allocator), .Host_Too_Long},
		{"modus://we lcome", .Host_Byte_Refused},
		{"modus://a_b", .Host_Byte_Refused},
		{"modus://a<b", .Host_Byte_Refused},
		{"http://example.org:", .Port_Refused},
		{"http://example.org:0", .Port_Refused},
		{"http://example.org:65536", .Port_Refused},
		{"http://example.org:99999999999999999999", .Port_Refused},
		{"http://example.org:80x", .Port_Refused},
		{"http://example.org:-1", .Port_Refused},
		{long_path, .Path_Too_Long},
		{long_query, .Query_Too_Long},
	}
	for item in cases {
		address, problem := address_parse(item.text)
		testing.expectf(t, problem == item.problem, "%q: the problem %v, not %v", item.text, problem, item.problem)
		testing.expectf(t, address == {}, "%q: a refused address gives no part", item.text)
	}
}

// The edges that the parser takes: the longest host, the ports 1 and
// 65535, the longest path and query, the case of a scheme and a host.
@(test)
address_parse_takes_the_edges :: proc(t: ^testing.T) {
	globals_hold()
	host := strings.repeat("h", HOST_CAPACITY, context.temp_allocator)
	address, problem := address_parse(strings.concatenate({"https://", host}, context.temp_allocator))
	testing.expect_value(t, problem, Address_Problem.None)
	testing.expect_value(t, address_host(&address), host)
	testing.expect_value(t, address.port, u16(443))
	address, problem = address_parse("HTTP://Example.ORG:65535/A?b=C")
	testing.expect_value(t, problem, Address_Problem.None)
	testing.expect_value(t, address.scheme, html_css.Document_Scheme.Http)
	testing.expect_value(t, address_host(&address), "example.org")
	testing.expect_value(t, address.port, u16(65535))
	testing.expect_value(t, address_path(&address), "/A")
	testing.expect_value(t, address_query(&address), "b=C")
	address, problem = address_parse("http://h:1")
	testing.expect_value(t, problem, Address_Problem.None)
	testing.expect_value(t, address.port, u16(1))
	// A text with no scheme: a page of the browser with no dot, HTTPS with one.
	address, problem = address_parse("  guide ")
	testing.expect_value(t, problem, Address_Problem.None)
	testing.expect_value(t, address.scheme, html_css.Document_Scheme.Modus)
	testing.expect_value(t, address_host(&address), "guide")
	address, problem = address_parse("example.org")
	testing.expect_value(t, address.scheme, html_css.Document_Scheme.Https)
	// The root path is no path.
	address, problem = address_parse("modus://guide/")
	testing.expect_value(t, address.path_count, 0)
}

// The text of an address names its port only when it is not the port of
// its scheme, and a resolve keeps a reference in the origin of its base.
@(test)
address_write_and_resolve :: proc(t: ^testing.T) {
	globals_hold()
	buffer: [256]u8
	base, _ := address_parse("http://example.org:8080/a/b?x=1")
	writer := Source_Writer{bytes = buffer[:]}
	address_write(&writer, &base)
	testing.expect_value(t, writer_text(&writer), "http://example.org:8080/a/b?x=1")
	Case :: struct {
		reference, resolved: string,
	}
	cases := [?]Case {
		{"modus://guide", "modus://guide"},
		{"/result", "http://example.org:8080/result"},
		{"result", "http://example.org:8080/result"},
		{"?q=1", "http://example.org:8080?q=1"},
		{"", "http://example.org:8080/a/b"},
	}
	for item in cases {
		writer = {bytes = buffer[:]}
		address_resolve(&writer, &base, item.reference)
		testing.expect_value(t, writer_text(&writer), item.resolved)
	}
}

// A writer past its bound keeps the bytes that fit and says that it is
// full; at the bound exactly it is not full.
@(test)
source_writer_bound :: proc(t: ^testing.T) {
	globals_hold()
	buffer: [4]u8
	writer := Source_Writer{bytes = buffer[:]}
	put(&writer, "abcd")
	testing.expect(t, !writer.full)
	testing.expect_value(t, writer_text(&writer), "abcd")
	put(&writer, "e")
	testing.expect(t, writer.full)
	testing.expect_value(t, writer.count, 4)
	writer = {bytes = buffer[:]}
	put(&writer, "abcdef")
	testing.expect(t, writer.full)
	testing.expect_value(t, writer_text(&writer), "abcd")
}

// A text of the reader never becomes markup.
@(test)
escape_refuses_markup :: proc(t: ^testing.T) {
	globals_hold()
	buffer: [128]u8
	writer := Source_Writer{bytes = buffer[:]}
	put_escaped(&writer, "<script>a&b\"c'd</script>")
	testing.expect_value(t, writer_text(&writer), "&lt;script&gt;a&amp;b&quot;c&#39;d&lt;/script&gt;")
}

// The query decoder: '+', %XX, a broken escape kept as its bytes, a name
// that is a prefix of another name, a missing name, and the bound of its
// buffer.
@(test)
query_value_decodes_and_refuses :: proc(t: ^testing.T) {
	globals_hold()
	buffer: [16]u8
	value, found := query_value("name=a+b%41%2b&query=x", "name", buffer[:])
	testing.expect(t, found)
	testing.expect_value(t, value, "a bA+")
	value, found = query_value("q=%G1%4", "q", buffer[:])
	testing.expect(t, found)
	testing.expect_value(t, value, "%G1%4")
	value, found = query_value("queryx=1&query=2", "query", buffer[:])
	testing.expect_value(t, value, "2")
	value, found = query_value("query", "query", buffer[:])
	testing.expect(t, found)
	testing.expect_value(t, value, "")
	_, found = query_value("a=1&b=2", "c", buffer[:])
	testing.expect(t, !found)
	_, found = query_value("", "c", buffer[:])
	testing.expect(t, !found)
	small: [3]u8
	value, found = query_value("q=abcdef", "q", small[:])
	testing.expect_value(t, value, "abc")
	// The encoder and the decoder agree on each byte.
	original := "a b&c=d%e<f>\x01\xff"
	encoded: [128]u8
	writer := Source_Writer{bytes = encoded[:]}
	put(&writer, "v=")
	put_query_encoded(&writer, original)
	decoded: [64]u8
	value, found = query_value(writer_text(&writer), "v", decoded[:])
	testing.expect_value(t, value, original)
}

// The state of an origin goes to a reader of that origin only: another
// host, another scheme, another port and another principal are each
// refused, and learn nothing.
@(test)
origin_state_is_refused_to_each_other_origin :: proc(t: ^testing.T) {
	globals_hold()
	origin_states = {}
	forms, _ := address_parse("modus://forms")
	owner := origin_of(&forms)
	testing.expect_value(t, origin_storage_write(&owner, QUERY_STORAGE_KEY, "kept"), Origin_Reply_Status.Done)
	buffer: [ORIGIN_VALUE_CAPACITY]u8
	others := [?]string{"modus://welcome", "https://forms", "modus://forms:1", "modus://form"}
	for text in others {
		address, _ := address_parse(text)
		reader := origin_of(&address)
		value, status := origin_storage_read(&reader, &owner, QUERY_STORAGE_KEY, buffer[:])
		testing.expectf(t, status == .Refused_Other_Origin && value == "", "%s read the state of modus://forms", text)
	}
	other_principal := owner
	other_principal.principal_id += 1
	value, status := origin_storage_read(&other_principal, &owner, QUERY_STORAGE_KEY, buffer[:])
	testing.expect(t, status == .Refused_Other_Origin && value == "")
	value, status = origin_storage_read(&owner, &owner, QUERY_STORAGE_KEY, buffer[:])
	testing.expect_value(t, status, Origin_Reply_Status.Done)
	testing.expect_value(t, value, "kept")
	// The reader of an origin with no state is told so only for its own.
	guide, _ := address_parse("modus://guide")
	guide_origin := origin_of(&guide)
	_, status = origin_storage_read(&guide_origin, &guide_origin, QUERY_STORAGE_KEY, buffer[:])
	testing.expect_value(t, status, Origin_Reply_Status.Nothing_Kept)
	// A read creates no state.
	testing.expect(t, origin_state_find(&guide_origin, false) == nil, "a read made a state")
}

// A full table of states gives the state used least to a new origin,
// wiped: the evicted origin, back later, finds nothing.
@(test)
origin_state_table_full :: proc(t: ^testing.T) {
	globals_hold()
	origin_states = {}
	hosts := [ORIGIN_STATE_CAPACITY + 1]string{"a", "b", "c", "d", "e", "f", "g", "h", "i"}
	origins: [ORIGIN_STATE_CAPACITY + 1]html_css.Document_Origin
	for host, index in hosts {
		address, _ := address_parse(strings.concatenate({"modus://", host}, context.temp_allocator))
		origins[index] = origin_of(&address)
	}
	for index in 0 ..< ORIGIN_STATE_CAPACITY {
		origin_storage_write(&origins[index], "k", hosts[index])
		// Each origin but the first is used twice: the first is used least.
		if index > 0 {
			origin_storage_write(&origins[index], "k", hosts[index])
		}
	}
	origin_storage_write(&origins[ORIGIN_STATE_CAPACITY], "k", "new")
	buffer: [ORIGIN_VALUE_CAPACITY]u8
	_, status := origin_storage_read(&origins[0], &origins[0], "k", buffer[:])
	testing.expect_value(t, status, Origin_Reply_Status.Nothing_Kept)
	value, new_status := origin_storage_read(&origins[ORIGIN_STATE_CAPACITY], &origins[ORIGIN_STATE_CAPACITY], "k", buffer[:])
	testing.expect_value(t, new_status, Origin_Reply_Status.Done)
	testing.expect_value(t, value, "new")
	value, status = origin_storage_read(&origins[1], &origins[1], "k", buffer[:])
	testing.expect_value(t, value, "b")
	// A value longer than a slot keeps the bytes that fit.
	long := strings.repeat("v", ORIGIN_VALUE_CAPACITY + 5, context.temp_allocator)
	origin_storage_write(&origins[1], "k", long)
	value, _ = origin_storage_read(&origins[1], &origins[1], "k", buffer[:])
	testing.expect_value(t, len(value), ORIGIN_VALUE_CAPACITY)
}

// The answer to a form escapes the values of the reader, and the read of
// another origin is refused in the page.
@(test)
pages_escape_and_refuse :: proc(t: ^testing.T) {
	globals_hold()
	origin_states = {}
	buffer: [PAGE_SOURCE_CAPACITY]u8
	address, _ := address_parse("modus://forms/result?name=%3Cb%3E&query=%3Cscript%3E")
	writer := Source_Writer{bytes = buffer[:]}
	testing.expect_value(t, page_write(&writer, &address), Page_Kind.Form_Result)
	page := writer_text(&writer)
	testing.expect(t, strings.contains(page, "&lt;script&gt;"))
	testing.expect(t, !strings.contains(page, "<script>"))
	testing.expect(t, !strings.contains(page, "<b>"))
	peek, _ := address_parse("modus://welcome/peek")
	writer = {bytes = buffer[:]}
	testing.expect_value(t, page_write(&writer, &peek), Page_Kind.Cross_Origin_Read)
	testing.expect(t, strings.contains(writer_text(&writer), "Refused"))
	testing.expect(t, !strings.contains(writer_text(&writer), "WRONG"))
	network, _ := address_parse("https://example.org/a?b=1#top")
	writer = {bytes = buffer[:]}
	testing.expect_value(t, page_write(&writer, &network), Page_Kind.No_Network)
	// The page shows the request that the worker of the origin wrote,
	// escaped, with no fragment.
	testing.expect(t, strings.contains(writer_text(&writer), "GET /a?b=1 HTTP/1.1"))
	testing.expect(t, strings.contains(writer_text(&writer), "Host: example.org"))
	testing.expect(t, !strings.contains(writer_text(&writer), "#top"))
	refused, _ := address_parse("http://example.org/a b")
	writer = {bytes = buffer[:]}
	testing.expect_value(t, page_write(&writer, &refused), Page_Kind.No_Network)
	testing.expect(t, strings.contains(writer_text(&writer), FETCH_PROBLEM_SENTENCES[.Request_Refused]))
	missing, _ := address_parse("modus://nothing")
	writer = {bytes = buffer[:]}
	testing.expect_value(t, page_write(&writer, &missing), Page_Kind.Not_Found)
	for page in Built_In_Page {
		page_address, _ := address_parse(strings.concatenate({"modus://", BUILT_IN_HOSTS[page]}, context.temp_allocator))
		writer = {bytes = buffer[:]}
		testing.expect_value(t, page_write(&writer, &page_address), Page_Kind.Built_In)
		testing.expectf(t, !writer.full, "the page %v is longer than its buffer", page)
	}
}

// The lines of a text: at the last space when one is there, at the width
// when none is, and one line for a text that fits.
@(test)
wrap_line_edges :: proc(t: ^testing.T) {
	globals_hold()
	line, rest := wrap_line("abcd", 4, true)
	testing.expect_value(t, line, "abcd")
	testing.expect_value(t, rest, "")
	line, rest = wrap_line("ab cd ef", 5, true)
	testing.expect_value(t, line, "ab cd")
	testing.expect_value(t, rest, "ef")
	line, rest = wrap_line("abcdefgh", 3, true)
	testing.expect_value(t, line, "abc")
	testing.expect_value(t, rest, "defgh")
	line, rest = wrap_line("ab cd", 3, false)
	testing.expect_value(t, line, "ab ")
	testing.expect_value(t, rest, "cd")
	testing.expect_value(t, wrapped_line_count("", 4, true), 0)
	testing.expect_value(t, wrapped_line_count("abcdefgh", 1, false), 8)
}

// Each page built into the browser parses, lays out and paints: its links
// are targets at the place of their boxes, and the forms page has its two
// fields with their boxes.
@(test)
built_in_pages_lay_out_with_their_targets :: proc(t: ^testing.T) {
	globals_hold()
	origin_states = {}
	for page in Built_In_Page {
		address, _ := address_parse(strings.concatenate({"modus://", BUILT_IN_HOSTS[page]}, context.temp_allocator))
		current = address
		writer := Source_Writer{bytes = page_source[:]}
		page_write(&writer, &current)
		document_build(writer_text(&writer))
		document_lay_out(800, 600)
		testing.expectf(t, current_render.status == .Done, "%v: the worker refused the render", page)
		testing.expectf(t, !current_render.truncated && !document_tree.truncated, "%v: the document is cut", page)
		testing.expectf(t, current_render.node_count == document_tree.node_count, "%v: the render tree counts other nodes", page)
		testing.expectf(t, document_record_count > 0 && document_height > 0, "%v: nothing is painted", page)
		links := 0
		for index in 0 ..< int(document_layout.box_count) {
			box := &document_layout.boxes[index]
			if !box.is_text || node_targets[box.node_index].kind != .Link {
				continue
			}
			links += 1
			target := target_at(int(box.x), int(box.y))
			testing.expectf(t, target.kind == .Link, "%v: a link box is not a target at its place", page)
		}
		testing.expectf(t, links >= 4, "%v: %d links", page, links)
		// No target outside the document.
		testing.expect_value(t, target_at(-1, -1).kind, Target_Kind.None)
		if page == .Forms {
			testing.expect_value(t, form_field_count, 2)
			for &field in form_fields[:form_field_count] {
				testing.expect(t, field.box != html_css.NO_NODE)
				testing.expect(t, field.form != html_css.NO_NODE)
			}
			testing.expect_value(t, string(form_fields[0].text[:form_fields[0].count]), "modus")
		}
	}
}

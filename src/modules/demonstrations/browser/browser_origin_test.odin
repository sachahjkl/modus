#+build !freestanding
package browser

import "core:strings"
import "core:testing"
import "modus:contract/html_css"

// The tests of the origin worker: the border of its messages, and the
// proof that a page of one origin reads nothing of another.

@(private = "file")
origin_of_text :: proc(text: string) -> html_css.Document_Origin {
	address, problem := address_parse(text)
	assert(problem == .None)
	return origin_of(&address)
}

// bytes_hold: whether a part appears anywhere in the bytes.
@(private = "file")
bytes_hold :: proc(bytes: []u8, part: string) -> bool {
	return strings.contains(string(bytes), part)
}

// Each message crosses the border and comes back the same.
@(test)
origin_messages_round_trip :: proc(t: ^testing.T) {
	globals_hold()
	a := origin_of_text("https://a.example:8443")
	b := origin_of_text("http://b.example")
	request := origin_request_make(.Storage_Write, &a, &b, "key", "value")
	request.view_width = LARGEST_WIDTH
	bytes: [ORIGIN_REQUEST_BYTES]u8
	testing.expect_value(t, origin_request_encode(&request, bytes[:]), ORIGIN_REQUEST_BYTES)
	decoded, problem := origin_request_decode(bytes[:])
	testing.expect_value(t, problem, Message_Problem.None)
	testing.expect(t, decoded == request, "the request comes back the same")

	reply := Origin_Reply{status = .Done}
	reply.value_count = copy(reply.value[:], "v")
	reply_bytes: [ORIGIN_REPLY_BYTES]u8
	testing.expect_value(t, origin_reply_encode(&reply, reply_bytes[:]), ORIGIN_REPLY_BYTES)
	reply_back, reply_problem := origin_reply_decode(reply_bytes[:])
	testing.expect_value(t, reply_problem, Message_Problem.None)
	testing.expect(t, reply_back == reply, "the reply comes back the same")

	tree := Origin_Render_Tree{status = .Done, origin = a, node_count = html_css.MAX_DOM_NODES, rule_count = html_css.MAX_CSS_RULES, box_count = 3, record_count = DOCUMENT_RECORD_CAPACITY, text_count = html_css.MAX_TEXT_POOL, document_height = max(i32), truncated = true, style_reused = true}
	tree.title_count = copy(tree.title[:], strings.repeat("t", TITLE_CAPACITY, context.temp_allocator))
	tree_bytes: [ORIGIN_RENDER_TREE_BYTES]u8
	testing.expect_value(t, origin_render_tree_encode(&tree, tree_bytes[:]), ORIGIN_RENDER_TREE_BYTES)
	tree_back, tree_problem := origin_render_tree_decode(tree_bytes[:])
	testing.expect_value(t, tree_problem, Message_Problem.None)
	testing.expect(t, tree_back == tree, "the render tree comes back the same")
	// A buffer one byte short takes nothing.
	short: [ORIGIN_REQUEST_BYTES - 1]u8
	testing.expect_value(t, origin_request_encode(&request, short[:]), 0)
}

// The border refuses each word that names no member, each count past its
// capacity and each size but the exact one, and gives no part of what it
// refuses.
@(test)
origin_messages_refuse_broken_bytes :: proc(t: ^testing.T) {
	globals_hold()
	a := origin_of_text("https://a.example")
	request := origin_request_make(.Render, &a, &a)
	good: [ORIGIN_REQUEST_BYTES]u8
	origin_request_encode(&request, good[:])
	// The places of the fields, as the encoding writes them.
	KIND :: 0
	REQUESTER_SCHEME :: 1 + 8
	REQUESTER_HOST_LENGTH :: 1 + 8 + 1 + 2
	OWNER_SCHEME :: 1 + ORIGIN_WIRE_BYTES + 8
	WIDTH :: 1 + 2 * ORIGIN_WIRE_BYTES
	KEY_COUNT :: WIDTH + 4
	VALUE_COUNT :: KEY_COUNT + 2 + ORIGIN_KEY_CAPACITY
	Case :: struct {
		place:   int,
		bytes:   []u8,
		problem: Message_Problem,
	}
	cases := [?]Case {
		{KIND, {0}, .Kind_Unknown},
		{KIND, {u8(max(Origin_Request_Kind)) + 1}, .Kind_Unknown},
		{KIND, {255}, .Kind_Unknown},
		{REQUESTER_SCHEME, {0}, .Scheme_Unknown},
		{OWNER_SCHEME, {u8(max(html_css.Document_Scheme)) + 1}, .Scheme_Unknown},
		{REQUESTER_HOST_LENGTH, {html_css.MAX_ORIGIN_HOST_LEN + 1, 0}, .Host_Too_Long},
		{REQUESTER_HOST_LENGTH, {0xFF, 0xFF}, .Host_Too_Long},
		{WIDTH, {0xFF, 0xFF, 0xFF, 0xFF}, .Width_Refused},
		{WIDTH, {u8((LARGEST_WIDTH + 1) & 0xFF), u8((LARGEST_WIDTH + 1) >> 8), 0, 0}, .Width_Refused},
		{KEY_COUNT, {u8((ORIGIN_KEY_CAPACITY + 1) & 0xFF), u8((ORIGIN_KEY_CAPACITY + 1) >> 8)}, .Count_Too_Large},
		{KEY_COUNT, {0xFF, 0xFF}, .Count_Too_Large},
		{VALUE_COUNT, {ORIGIN_VALUE_CAPACITY + 1}, .Count_Too_Large},
		{VALUE_COUNT, {255}, .Count_Too_Large},
	}
	for item in cases {
		broken := good
		copy(broken[item.place:], item.bytes)
		decoded, problem := origin_request_decode(broken[:])
		testing.expectf(t, problem == item.problem, "place %d: %v, not %v", item.place, problem, item.problem)
		testing.expect(t, decoded == {}, "a refused request gives no part")
	}
	// The edges that the border takes: the width 0 and the largest, a key
	// and a value at their capacity.
	edge := good
	copy(edge[WIDTH:], []u8{0, 0, 0, 0})
	edge[KEY_COUNT], edge[KEY_COUNT + 1] = u8(ORIGIN_KEY_CAPACITY & 0xFF), u8(ORIGIN_KEY_CAPACITY >> 8)
	edge[VALUE_COUNT] = ORIGIN_VALUE_CAPACITY
	_, problem := origin_request_decode(edge[:])
	testing.expect_value(t, problem, Message_Problem.None)
	for size in ([?]int{0, 1, ORIGIN_REQUEST_BYTES - 1}) {
		_, size_problem := origin_request_decode(good[:size])
		testing.expect_value(t, size_problem, Message_Problem.Size_Wrong)
	}
	longer: [ORIGIN_REQUEST_BYTES + 1]u8
	_, longer_problem := origin_request_decode(longer[:])
	testing.expect_value(t, longer_problem, Message_Problem.Size_Wrong)

	reply_bytes: [ORIGIN_REPLY_BYTES]u8
	for status in ([?]u8{0, u8(max(Origin_Reply_Status)) + 1, 255}) {
		reply_bytes[0] = status
		_, reply_problem := origin_reply_decode(reply_bytes[:])
		testing.expect_value(t, reply_problem, Message_Problem.Status_Unknown)
	}
	reply_bytes[0] = u8(Origin_Reply_Status.Done)
	reply_bytes[1] = ORIGIN_VALUE_CAPACITY + 1
	_, reply_problem := origin_reply_decode(reply_bytes[:])
	testing.expect_value(t, reply_problem, Message_Problem.Count_Too_Large)

	tree := Origin_Render_Tree{status = .Done, origin = a}
	tree_bytes: [ORIGIN_RENDER_TREE_BYTES]u8
	origin_render_tree_encode(&tree, tree_bytes[:])
	NODE_COUNT :: 1 + ORIGIN_WIRE_BYTES
	TRUNCATED :: NODE_COUNT + 3 * 2 + 3 * 4
	over_nodes := tree_bytes
	over_nodes[NODE_COUNT] = u8((html_css.MAX_DOM_NODES + 1) & 0xFF)
	over_nodes[NODE_COUNT + 1] = u8((html_css.MAX_DOM_NODES + 1) >> 8)
	_, tree_problem := origin_render_tree_decode(over_nodes[:])
	testing.expect_value(t, tree_problem, Message_Problem.Count_Too_Large)
	bad_flag := tree_bytes
	bad_flag[TRUNCATED] = 2
	_, tree_problem = origin_render_tree_decode(bad_flag[:])
	testing.expect_value(t, tree_problem, Message_Problem.Flag_Refused)
	negative_height := tree_bytes
	copy(negative_height[TRUNCATED - 4:], []u8{0xFF, 0xFF, 0xFF, 0xFF})
	_, tree_problem = origin_render_tree_decode(negative_height[:])
	testing.expect_value(t, tree_problem, Message_Problem.Count_Too_Large)
}

// Bytes that are no request make the worker answer Refused_Malformed, and
// make no state.
@(test)
origin_worker_refuses_malformed_bytes :: proc(t: ^testing.T) {
	globals_hold()
	origin_states = {}
	reply_bytes: [ORIGIN_RENDER_TREE_BYTES]u8
	garbage: [ORIGIN_REQUEST_BYTES]u8
	for index in 0 ..< len(garbage) {
		garbage[index] = u8(index * 31 + 7)
	}
	inputs := [?][]u8{nil, garbage[:1], garbage[:], garbage[:ORIGIN_REQUEST_BYTES - 1]}
	for input in inputs {
		count := origin_worker_serve(input, nil, reply_bytes[:])
		reply, problem := origin_reply_decode(reply_bytes[:count])
		testing.expect_value(t, problem, Message_Problem.None)
		testing.expect_value(t, reply.status, Origin_Reply_Status.Refused_Malformed)
	}
	for state in origin_states {
		testing.expect(t, !state.used, "a malformed request made a state")
	}
}

// The proof of isolation: origin A writes its storage, a cookie and the
// values of a form, and renders a page with a secret; origin B, then each
// origin that differs from A by one part, reads nothing of it, through
// each kind of request, and its workspace holds no byte of A.
@(test)
cross_origin_state_is_isolated :: proc(t: ^testing.T) {
	globals_hold()
	origin_states = {}
	SECRET :: "secret-of-a"
	a := origin_of_text("https://a.example")
	testing.expect_value(t, origin_storage_write(&a, "k", SECRET), Origin_Reply_Status.Done)
	cookie := origin_request_make(.Cookie_Store, &a, &a, "sid", SECRET)
	testing.expect_value(t, origin_ask(&cookie).status, Origin_Reply_Status.Done)
	page_a := "<title>" + SECRET + "</title><style>.s { color: red }</style><form><input name=field value=" + SECRET + "></form>"
	rendered := origin_render_ask(&a, transmute([]u8)string(page_a), 640)
	testing.expect_value(t, rendered.status, Origin_Reply_Status.Done)
	testing.expect_value(t, string(rendered.title[:rendered.title_count]), SECRET)
	testing.expect_value(t, form_field_count, 1)
	save := origin_request_make(.Forms_Save, &a, &a, "/f")
	testing.expect_value(t, origin_ask(&save).status, Origin_Reply_Status.Done)

	others := [?]string{"https://b.example", "http://a.example", "https://a.example:444", "modus://a.example", "https://a.example.evil"}
	for text in others {
		b := origin_of_text(text)
		buffer: [ORIGIN_VALUE_CAPACITY]u8
		// Its own state holds nothing of A.
		value, status := origin_storage_read(&b, &b, "k", buffer[:])
		testing.expectf(t, status == .Nothing_Kept && value == "", "%s read the storage of A", text)
		header := origin_request_make(.Cookie_Header, &b, &b)
		header_reply := origin_ask(&header)
		testing.expectf(t, header_reply.status == .Nothing_Kept && header_reply.value_count == 0, "%s got the cookies of A", text)
		// A request that names the state of A is refused, with no byte.
		value, status = origin_storage_read(&b, &a, "k", buffer[:])
		testing.expectf(t, status == .Refused_Other_Origin && value == "", "%s read A by naming it", text)
		named_cookie := origin_request_make(.Cookie_Header, &b, &a)
		named_reply := origin_ask(&named_cookie)
		testing.expectf(t, named_reply.status == .Refused_Other_Origin && named_reply.value_count == 0, "%s read the cookies of A by naming them", text)
		write := origin_request_make(.Storage_Write, &b, &a, "k", "overwritten")
		testing.expectf(t, origin_ask(&write).status == .Refused_Other_Origin, "%s wrote the storage of A", text)
		render := origin_render_ask(&b, nil, 640)
		_ = render
		foreign_render := origin_request_make(.Render, &b, &a)
		request_bytes: [ORIGIN_REQUEST_BYTES]u8
		origin_request_encode(&foreign_render, request_bytes[:])
		reply_bytes: [ORIGIN_RENDER_TREE_BYTES]u8
		count := origin_worker_serve(request_bytes[:], transmute([]u8)string("<p>x"), reply_bytes[:])
		foreign_tree, _ := origin_render_tree_decode(reply_bytes[:count])
		testing.expectf(t, foreign_tree.status == .Refused_Other_Origin, "%s rendered under the origin of A", text)
		// A page of B with a field of the same name, on the same path,
		// gets back no value of A.
		page_b := "<form><input name=field value=own></form>"
		origin_render_ask(&b, transmute([]u8)string(page_b), 640)
		restore := origin_request_make(.Forms_Restore, &b, &b, "/f")
		testing.expectf(t, origin_ask(&restore).status == .Nothing_Kept, "%s restored the forms of A", text)
		testing.expect_value(t, string(form_fields[0].text[:form_fields[0].count]), "own")
		// The workspace holds no byte of the page of A.
		testing.expectf(t, !bytes_hold(document_tree.text_pool[:], SECRET), "%s: the tree holds a byte of A", text)
		testing.expectf(t, !bytes_hold(document_text[:], SECRET), "%s: the text of the records holds a byte of A", text)
		for &field in form_fields {
			testing.expectf(t, !bytes_hold(field.text[:], SECRET), "%s: a field holds a byte of A", text)
		}
	}
	// Another principal on the same origin is another origin too.
	other_principal := a
	other_principal.principal_id += 1
	buffer: [ORIGIN_VALUE_CAPACITY]u8
	value, status := origin_storage_read(&other_principal, &other_principal, "k", buffer[:])
	testing.expect(t, status == .Nothing_Kept && value == "", "another principal read A")
	// A still has all of its state.
	value, status = origin_storage_read(&a, &a, "k", buffer[:])
	testing.expect_value(t, value, SECRET)
	origin_render_ask(&a, transmute([]u8)string("<form><input name=field value=fresh></form>"), 640)
	restore := origin_request_make(.Forms_Restore, &a, &a, "/f")
	testing.expect_value(t, origin_ask(&restore).status, Origin_Reply_Status.Done)
	testing.expect_value(t, string(form_fields[0].text[:form_fields[0].count]), SECRET)
	header := origin_request_make(.Cookie_Header, &a, &a)
	header_reply := origin_ask(&header)
	testing.expect_value(t, string(header_reply.value[:header_reply.value_count]), "sid=" + SECRET)
}

// The fields of the workspace belong to the origin of its document: a
// worker of another origin cannot keep them as its own, nor fill them.
@(test)
forms_of_the_workspace_belong_to_its_origin :: proc(t: ^testing.T) {
	globals_hold()
	origin_states = {}
	a := origin_of_text("https://a.example")
	b := origin_of_text("https://b.example")
	origin_render_ask(&a, transmute([]u8)string("<form><input name=n value=from-a></form>"), 640)
	save := origin_request_make(.Forms_Save, &b, &b, "/")
	testing.expect_value(t, origin_ask(&save).status, Origin_Reply_Status.Refused_Other_Origin)
	restore := origin_request_make(.Forms_Restore, &b, &b, "/")
	testing.expect_value(t, origin_ask(&restore).status, Origin_Reply_Status.Refused_Other_Origin)
	// Nothing of the page of A was kept under B.
	state := origin_state_find(&b, false)
	if state != nil {
		for memory in state.forms {
			testing.expect(t, !memory.used, "the fields of A were kept for B")
		}
	}
}

// The style sheet is reused only for the origin that parsed it and the
// same style text: the same style under another origin is parsed again.
@(test)
cached_style_sheets_are_partitioned :: proc(t: ^testing.T) {
	globals_hold()
	origin_states = {}
	sheet_valid = false
	a := origin_of_text("https://a.example")
	b := origin_of_text("https://b.example")
	page := transmute([]u8)string("<style>p { color: red } .x { margin: 1px }</style><p class=x>t")
	other := transmute([]u8)string("<style>p { color: blue }</style><p>t")
	testing.expect(t, !origin_render_ask(&a, page, 640).style_reused, "the first render of A parses its sheet")
	testing.expect(t, origin_render_ask(&a, page, 640).style_reused, "the same text of the same origin is reused")
	testing.expect(t, !origin_render_ask(&b, page, 640).style_reused, "B reused the sheet of A")
	testing.expect(t, !origin_render_ask(&a, page, 640).style_reused, "A reused the sheet that B parsed")
	testing.expect(t, !origin_render_ask(&a, other, 640).style_reused, "another text is parsed again")
	tree := origin_render_ask(&a, page, 640)
	testing.expect_value(t, tree.rule_count, u16(2))
	state := origin_state_find(&a, false)
	testing.expect(t, state != nil && state.style.reuses == 1, "one reuse for A")
}

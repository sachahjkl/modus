package browser

import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/html_css"

// The origin worker: the state of each document origin, and the parse of
// its pages, behind one border of messages (src/md/features/
// desktop_to_browser.md, "The origin worker").
//
// - **The border is bytes.** The window encodes an Origin_Request, the
//   worker decodes it, checks each word of it, and answers with the bytes
//   of an Origin_Render_Tree or an Origin_Reply. The messages hold no
//   pointer, so the same bytes cross a process border when the worker of
//   each origin becomes its own process.
// - **A request names its own origin only.** requester is the origin of
//   the document that asks, owner the origin whose state the request
//   names. The worker refuses a request whose two origins differ before it
//   reads any state: the refusal says nothing of what the owner keeps.
// - **The state is partitioned.** Each origin has its own Origin_State:
//   its storage, its cookies, the values of its forms, and the key of its
//   cached style sheet. A worker reaches the state of the owner of the
//   request only.
// - **The workspace is wiped.** The tree, the boxes, the records and the
//   fields of the document are one workspace; each render clears it before
//   it parses the page of an origin, so a page reads no byte of the page
//   before it. The style sheet is reused only for the same origin and the
//   same style text.

ORIGIN_STATE_CAPACITY :: 8
STORAGE_SLOT_CAPACITY :: 4
COOKIE_SLOT_CAPACITY :: 4
FORM_MEMORY_CAPACITY :: 4
// The bytes of a key (a storage key, a cookie name, a path) and of a value.
ORIGIN_KEY_CAPACITY :: 64
ORIGIN_VALUE_CAPACITY :: 128
TITLE_CAPACITY :: 64

// The bytes of each message on the border.
ORIGIN_WIRE_BYTES :: 8 + 1 + 2 + 2 + html_css.MAX_ORIGIN_HOST_LEN
ORIGIN_REQUEST_BYTES :: 1 + 2 * ORIGIN_WIRE_BYTES + 4 + 1 + ORIGIN_KEY_CAPACITY + 1 + ORIGIN_VALUE_CAPACITY
ORIGIN_REPLY_BYTES :: 1 + 1 + ORIGIN_VALUE_CAPACITY
ORIGIN_RENDER_TREE_BYTES :: 1 + ORIGIN_WIRE_BYTES + 3 * 2 + 2 * 4 + 4 + 1 + 1 + 1 + TITLE_CAPACITY
#assert(ORIGIN_KEY_CAPACITY <= int(max(u8)) && ORIGIN_VALUE_CAPACITY <= int(max(u8)) && TITLE_CAPACITY <= int(max(u8)))
#assert(PATH_CAPACITY <= ORIGIN_KEY_CAPACITY)

// The state of one origin.

Key_Value :: struct {
	used:        bool,
	key:         [ORIGIN_KEY_CAPACITY]u8,
	key_count:   int,
	value:       [ORIGIN_VALUE_CAPACITY]u8,
	value_count: int,
}

Remembered_Field :: struct {
	name:       [FIELD_NAME_CAPACITY]u8,
	name_count: int,
	text:       [FIELD_TEXT_CAPACITY]u8,
	count:      int,
}

// The values of the fields of the forms of one page of the origin, kept
// when the window leaves the page and given back when it comes back.
Form_Memory :: struct {
	used:        bool,
	path:        [PATH_CAPACITY]u8,
	path_count:  int,
	fields:      [FORM_FIELD_CAPACITY]Remembered_Field,
	field_count: int,
}

// The key of the style sheet that the origin parsed last.
Style_Cache :: struct {
	valid:       bool,
	source_hash: u64,
	rule_count:  u16,
	reuses:      u64,
}

Origin_State :: struct {
	used:    bool,
	origin:  html_css.Document_Origin,
	uses:    u64, // The requests served: a full table gives the state used least to a new origin.
	storage: [STORAGE_SLOT_CAPACITY]Key_Value,
	cookies: [COOKIE_SLOT_CAPACITY]Key_Value,
	forms:   [FORM_MEMORY_CAPACITY]Form_Memory,
	style:   Style_Cache,
}

origin_states: [ORIGIN_STATE_CAPACITY]Origin_State

// The messages.

Origin_Request_Kind :: enum u8 {
	Render        = 1, // Parse, style and lay out the document of the source.
	Storage_Write = 2,
	Storage_Read  = 3,
	Forms_Save    = 4, // Keep the values of the fields of the document, under the path of the key.
	Forms_Restore = 5,
	Cookie_Store  = 6, // Keep a cookie: the key is its name.
	Cookie_Header = 7, // The value of the Cookie header of a request of the origin.
}

Origin_Request :: struct {
	kind:        Origin_Request_Kind,
	requester:   html_css.Document_Origin,
	owner:       html_css.Document_Origin,
	view_width:  i32,
	key:         [ORIGIN_KEY_CAPACITY]u8,
	key_count:   int,
	value:       [ORIGIN_VALUE_CAPACITY]u8,
	value_count: int,
}

Origin_Reply_Status :: enum u8 {
	Done                 = 1,
	Nothing_Kept         = 2,
	Refused_Other_Origin = 3, // The requester is not the owner: it learns nothing, not even whether a state exists.
	Refused_Malformed    = 4, // The bytes of the request break the contract.
}

Origin_Reply :: struct {
	status:      Origin_Reply_Status,
	value:       [ORIGIN_VALUE_CAPACITY]u8,
	value_count: int,
}

// The answer to a render: what the window shows of the document. The draw
// records and their text are in the lent buffers of the document.
Origin_Render_Tree :: struct {
	status:          Origin_Reply_Status,
	origin:          html_css.Document_Origin,
	node_count:      u16,
	rule_count:      u16,
	box_count:       u16,
	record_count:    u32,
	text_count:      u32,
	document_height: i32,
	truncated:       bool,
	style_reused:    bool,
	title:           [TITLE_CAPACITY]u8,
	title_count:     int,
}

// Why the bytes of a message are refused.
Message_Problem :: enum u8 {
	None,
	Size_Wrong,
	Kind_Unknown,
	Status_Unknown,
	Scheme_Unknown,
	Host_Too_Long,
	Count_Too_Large,
	Flag_Refused,
	Width_Refused,
}

// The encoding: little endian, each field at a fixed place, each array at
// its capacity with zero bytes after its count.

Message_Writer :: struct {
	bytes: []u8,
	count: int,
}

Message_Reader :: struct {
	bytes:    []u8,
	position: int,
}

@(private = "file")
put_u8 :: proc "contextless" (writer: ^Message_Writer, value: u8) {
	writer.bytes[writer.count] = value
	writer.count += 1
}

@(private = "file")
put_u16 :: proc "contextless" (writer: ^Message_Writer, value: u16) {
	byte_order.write_u16_little_endian(writer.bytes, writer.count, value)
	writer.count += 2
}

@(private = "file")
put_u32 :: proc "contextless" (writer: ^Message_Writer, value: u32) {
	byte_order.write_u32_little_endian(writer.bytes, writer.count, value)
	writer.count += 4
}

@(private = "file")
put_u64 :: proc "contextless" (writer: ^Message_Writer, value: u64) {
	byte_order.write_u64_little_endian(writer.bytes, writer.count, value)
	writer.count += 8
}

// put_array writes count bytes of an array then zero bytes up to its capacity.
@(private = "file")
put_array :: proc "contextless" (writer: ^Message_Writer, array: []u8, count: int) {
	written := copy(writer.bytes[writer.count:writer.count + len(array)], array[:clamp(count, 0, len(array))])
	for index in written ..< len(array) {
		writer.bytes[writer.count + index] = 0
	}
	writer.count += len(array)
}

@(private = "file")
put_origin :: proc "contextless" (writer: ^Message_Writer, origin: ^html_css.Document_Origin) {
	put_u64(writer, origin.principal_id)
	put_u8(writer, u8(origin.scheme))
	put_u16(writer, origin.port)
	put_u16(writer, origin.host_len)
	put_array(writer, origin.host[:], int(origin.host_len))
}

@(private = "file")
take_u8 :: proc "contextless" (reader: ^Message_Reader) -> u8 {
	value := reader.bytes[reader.position]
	reader.position += 1
	return value
}

@(private = "file")
take_u16 :: proc "contextless" (reader: ^Message_Reader) -> u16 {
	value := byte_order.read_u16_little_endian(reader.bytes, reader.position)
	reader.position += 2
	return value
}

@(private = "file")
take_u32 :: proc "contextless" (reader: ^Message_Reader) -> u32 {
	value := byte_order.read_u32_little_endian(reader.bytes, reader.position)
	reader.position += 4
	return value
}

@(private = "file")
take_u64 :: proc "contextless" (reader: ^Message_Reader) -> u64 {
	value := byte_order.read_u64_little_endian(reader.bytes, reader.position)
	reader.position += 8
	return value
}

@(private = "file")
take_array :: proc "contextless" (reader: ^Message_Reader, array: []u8) {
	copy(array, reader.bytes[reader.position:reader.position + len(array)])
	reader.position += len(array)
}

// take_count reads a count of bytes and refuses one past its capacity.
@(private = "file")
take_count :: proc "contextless" (reader: ^Message_Reader, capacity: int, problem: ^Message_Problem) -> int {
	count := int(take_u8(reader))
	if count > capacity && problem^ == .None {
		problem^ = .Count_Too_Large
	}
	return min(count, capacity)
}

@(private = "file")
take_flag :: proc "contextless" (reader: ^Message_Reader, problem: ^Message_Problem) -> bool {
	word := take_u8(reader)
	if word > 1 && problem^ == .None {
		problem^ = .Flag_Refused
	}
	return word == 1
}

@(private = "file")
take_origin :: proc "contextless" (reader: ^Message_Reader, problem: ^Message_Problem) -> (origin: html_css.Document_Origin) {
	origin.principal_id = take_u64(reader)
	scheme, known := html_css.document_scheme_of_word(take_u8(reader))
	if !known && problem^ == .None {
		problem^ = .Scheme_Unknown
	}
	origin.scheme = scheme
	origin.port = take_u16(reader)
	origin.host_len = take_u16(reader)
	take_array(reader, origin.host[:])
	if int(origin.host_len) > html_css.MAX_ORIGIN_HOST_LEN && problem^ == .None {
		problem^ = .Host_Too_Long
	}
	return
}

origin_request_encode :: proc "contextless" (request: ^Origin_Request, bytes: []u8) -> int {
	if len(bytes) < ORIGIN_REQUEST_BYTES {
		return 0
	}
	writer := Message_Writer{bytes = bytes[:ORIGIN_REQUEST_BYTES]}
	put_u8(&writer, u8(request.kind))
	put_origin(&writer, &request.requester)
	put_origin(&writer, &request.owner)
	put_u32(&writer, u32(request.view_width))
	put_u8(&writer, u8(clamp(request.key_count, 0, ORIGIN_KEY_CAPACITY)))
	put_array(&writer, request.key[:], request.key_count)
	put_u8(&writer, u8(clamp(request.value_count, 0, ORIGIN_VALUE_CAPACITY)))
	put_array(&writer, request.value[:], request.value_count)
	return writer.count
}

// origin_request_decode reads the bytes of a request. A request of
// another size, a kind or a scheme that names no member, a host or a count
// past its capacity, and a width out of the window are refused, with no
// request.
origin_request_decode :: proc "contextless" (bytes: []u8) -> (request: Origin_Request, problem: Message_Problem) {
	if len(bytes) != ORIGIN_REQUEST_BYTES {
		return {}, .Size_Wrong
	}
	reader := Message_Reader{bytes = bytes}
	kind, known := enum_word.member_of_word(Origin_Request_Kind, u64(take_u8(&reader)))
	if !known {
		return {}, .Kind_Unknown
	}
	request.kind = kind
	request.requester = take_origin(&reader, &problem)
	request.owner = take_origin(&reader, &problem)
	request.view_width = i32(take_u32(&reader))
	if (request.view_width < 0 || request.view_width > LARGEST_WIDTH) && problem == .None {
		problem = .Width_Refused
	}
	request.key_count = take_count(&reader, ORIGIN_KEY_CAPACITY, &problem)
	take_array(&reader, request.key[:])
	request.value_count = take_count(&reader, ORIGIN_VALUE_CAPACITY, &problem)
	take_array(&reader, request.value[:])
	if problem != .None {
		return {}, problem
	}
	return
}

origin_reply_encode :: proc "contextless" (reply: ^Origin_Reply, bytes: []u8) -> int {
	if len(bytes) < ORIGIN_REPLY_BYTES {
		return 0
	}
	writer := Message_Writer{bytes = bytes[:ORIGIN_REPLY_BYTES]}
	put_u8(&writer, u8(reply.status))
	put_u8(&writer, u8(clamp(reply.value_count, 0, ORIGIN_VALUE_CAPACITY)))
	put_array(&writer, reply.value[:], reply.value_count)
	return writer.count
}

origin_reply_decode :: proc "contextless" (bytes: []u8) -> (reply: Origin_Reply, problem: Message_Problem) {
	if len(bytes) != ORIGIN_REPLY_BYTES {
		return {}, .Size_Wrong
	}
	reader := Message_Reader{bytes = bytes}
	status, known := enum_word.member_of_word(Origin_Reply_Status, u64(take_u8(&reader)))
	if !known {
		return {}, .Status_Unknown
	}
	reply.status = status
	reply.value_count = take_count(&reader, ORIGIN_VALUE_CAPACITY, &problem)
	take_array(&reader, reply.value[:])
	if problem != .None {
		return {}, problem
	}
	return
}

origin_render_tree_encode :: proc "contextless" (tree: ^Origin_Render_Tree, bytes: []u8) -> int {
	if len(bytes) < ORIGIN_RENDER_TREE_BYTES {
		return 0
	}
	writer := Message_Writer{bytes = bytes[:ORIGIN_RENDER_TREE_BYTES]}
	put_u8(&writer, u8(tree.status))
	put_origin(&writer, &tree.origin)
	put_u16(&writer, tree.node_count)
	put_u16(&writer, tree.rule_count)
	put_u16(&writer, tree.box_count)
	put_u32(&writer, tree.record_count)
	put_u32(&writer, tree.text_count)
	put_u32(&writer, u32(tree.document_height))
	put_u8(&writer, 1 if tree.truncated else 0)
	put_u8(&writer, 1 if tree.style_reused else 0)
	put_u8(&writer, u8(clamp(tree.title_count, 0, TITLE_CAPACITY)))
	put_array(&writer, tree.title[:], tree.title_count)
	return writer.count
}

// origin_render_tree_decode reads the bytes of a render tree. A count past
// the pools of the document is refused as a count past its capacity.
origin_render_tree_decode :: proc "contextless" (bytes: []u8) -> (tree: Origin_Render_Tree, problem: Message_Problem) {
	if len(bytes) != ORIGIN_RENDER_TREE_BYTES {
		return {}, .Size_Wrong
	}
	reader := Message_Reader{bytes = bytes}
	status, known := enum_word.member_of_word(Origin_Reply_Status, u64(take_u8(&reader)))
	if !known {
		return {}, .Status_Unknown
	}
	tree.status = status
	tree.origin = take_origin(&reader, &problem)
	tree.node_count = take_u16(&reader)
	tree.rule_count = take_u16(&reader)
	tree.box_count = take_u16(&reader)
	tree.record_count = take_u32(&reader)
	tree.text_count = take_u32(&reader)
	tree.document_height = i32(take_u32(&reader))
	if (int(tree.node_count) > html_css.MAX_DOM_NODES || int(tree.rule_count) > html_css.MAX_CSS_RULES || int(tree.box_count) > html_css.MAX_DOM_NODES || int(tree.record_count) > DOCUMENT_RECORD_CAPACITY || int(tree.text_count) > html_css.MAX_TEXT_POOL || tree.document_height < 0) && problem == .None {
		problem = .Count_Too_Large
	}
	tree.truncated = take_flag(&reader, &problem)
	tree.style_reused = take_flag(&reader, &problem)
	tree.title_count = take_count(&reader, TITLE_CAPACITY, &problem)
	take_array(&reader, tree.title[:])
	if problem != .None {
		return {}, problem
	}
	return
}

// The worker side of the border.

// origin_state_find gives the state of an origin, made when create is
// true. A full table gives the state used least to the new origin, wiped
// first: an origin never reads what another left.
origin_state_find :: proc "contextless" (origin: ^html_css.Document_Origin, create: bool) -> ^Origin_State {
	for &state in origin_states {
		if state.used && html_css.origins_equal(&state.origin, origin) {
			return &state
		}
	}
	if !create {
		return nil
	}
	chosen := &origin_states[0]
	for &state in origin_states {
		if !state.used {
			chosen = &state
			break
		}
		if state.uses < chosen.uses {
			chosen = &state
		}
	}
	chosen^ = {}
	chosen.used = true
	chosen.origin = origin^
	return chosen
}

@(private = "file")
key_value_find :: proc "contextless" (slots: []Key_Value, key: []u8) -> ^Key_Value {
	for &slot in slots {
		if slot.used && string(slot.key[:slot.key_count]) == string(key) {
			return &slot
		}
	}
	return nil
}

// key_value_put keeps a value under a key: in its slot, else in a free
// slot, else in place of the oldest, the first, whose slots move down.
@(private = "file")
key_value_put :: proc "contextless" (slots: []Key_Value, key, value: []u8) {
	slot := key_value_find(slots, key)
	if slot == nil {
		for &candidate in slots {
			if !candidate.used {
				slot = &candidate
				break
			}
		}
	}
	if slot == nil {
		copy(slots[:len(slots) - 1], slots[1:])
		slot = &slots[len(slots) - 1]
	}
	slot^ = {used = true}
	slot.key_count = copy(slot.key[:], key)
	slot.value_count = copy(slot.value[:], value)
}

// style_source_hash: FNV-1a of the text of the style blocks of the tree,
// each block closed by a zero byte.
style_source_hash :: proc "contextless" (tree: ^html_css.Dom_Tree) -> u64 {
	hash: u64 = 0xCBF29CE484222325
	for index in 0 ..< int(tree.node_count) {
		node := &tree.nodes[index]
		if node.kind != .Element || node.tag != .Style {
			continue
		}
		child := node.first_child
		for child != html_css.NO_NODE {
			for byte in html_css.dom_node_text(tree, child) {
				hash = (hash ~ u64(byte)) * 0x100000001B3
			}
			child = tree.nodes[child].next_sibling
		}
		hash = (hash ~ 0) * 0x100000001B3
	}
	return hash
}

// origin_render parses, styles and lays out a document of the owner of
// the request in the wiped workspace.
@(private = "file")
origin_render :: proc "contextless" (state: ^Origin_State, request: ^Origin_Request, source: []u8) -> (tree: Origin_Render_Tree) {
	document_workspace_clear()
	html_css.parse_html(&document_tree, request.owner, source)
	hash := style_source_hash(&document_tree)
	reused := state.style.valid && state.style.source_hash == hash && sheet_valid && sheet_source_hash == hash && html_css.origins_equal(&sheet_origin, &request.owner)
	if reused {
		state.style.reuses += 1
	} else {
		sheet = {}
		html_css.parse_document_styles(&document_tree, &sheet)
		sheet_valid = true
		sheet_origin = request.owner
		sheet_source_hash = hash
		state.style = {valid = true, source_hash = hash, rule_count = sheet.rule_count, reuses = state.style.reuses}
	}
	document_targets_read()
	document_lay_out(request.view_width, 0)
	tree = {
		status          = .Done,
		origin          = request.owner,
		node_count      = document_tree.node_count,
		rule_count      = sheet.rule_count,
		box_count       = document_layout.box_count,
		record_count    = u32(document_record_count),
		text_count      = u32(document_text_count),
		document_height = i32(clamp(document_height, 0, int(max(i32)))),
		truncated       = document_tree.truncated,
		style_reused    = reused,
	}
	tree.title_count = copy(tree.title[:], document_title())
	return
}

// origin_worker_serve reads the bytes of a request and writes the bytes of
// its reply: an Origin_Render_Tree for a render, an Origin_Reply for each
// other kind and for each refused request.
origin_worker_serve :: proc "contextless" (request_bytes: []u8, source: []u8, reply_bytes: []u8) -> int {
	request, problem := origin_request_decode(request_bytes)
	reply: Origin_Reply
	if problem != .None {
		reply.status = .Refused_Malformed
		return origin_reply_encode(&reply, reply_bytes)
	}
	if !html_css.origins_equal(&request.requester, &request.owner) {
		reply.status = .Refused_Other_Origin
		if request.kind == .Render {
			refused := Origin_Render_Tree{status = .Refused_Other_Origin, origin = request.requester}
			return origin_render_tree_encode(&refused, reply_bytes)
		}
		return origin_reply_encode(&reply, reply_bytes)
	}
	key := request.key[:request.key_count]
	value := request.value[:request.value_count]
	reads := request.kind == .Storage_Read || request.kind == .Forms_Restore || request.kind == .Cookie_Header
	state := origin_state_find(&request.owner, !reads)
	reply.status = .Nothing_Kept
	if state != nil {
		state.uses += 1
	}
	switch request.kind {
	case .Render:
		tree := origin_render(state, &request, source)
		return origin_render_tree_encode(&tree, reply_bytes)
	case .Storage_Write:
		key_value_put(state.storage[:], key, value)
		reply.status = .Done
	case .Storage_Read:
		if state != nil {
			if slot := key_value_find(state.storage[:], key); slot != nil {
				reply.value_count = copy(reply.value[:], slot.value[:slot.value_count])
				reply.status = .Done
			}
		}
	case .Cookie_Store:
		key_value_put(state.cookies[:], key, value)
		reply.status = .Done
	case .Cookie_Header:
		if state != nil {
			writer := Source_Writer{bytes = reply.value[:]}
			for &cookie in state.cookies {
				if !cookie.used {
					continue
				}
				if writer.count > 0 {
					put(&writer, "; ")
				}
				put(&writer, string(cookie.key[:cookie.key_count]))
				put(&writer, "=")
				put(&writer, string(cookie.value[:cookie.value_count]))
			}
			reply.value_count = writer.count
			if writer.count > 0 {
				reply.status = .Done
			}
		}
	case .Forms_Save, .Forms_Restore:
		// The fields of the workspace are those of the document of one
		// origin: the owner of the request, or the request is refused.
		if !html_css.origins_equal(&document_tree.origin, &request.owner) {
			reply.status = .Refused_Other_Origin
			break
		}
		if request.kind == .Forms_Save {
			forms_save(state, key)
			reply.status = .Done
		} else if state != nil && forms_restore(state, key) {
			reply.status = .Done
		}
	}
	return origin_reply_encode(&reply, reply_bytes)
}

@(private = "file")
forms_save :: proc "contextless" (state: ^Origin_State, path: []u8) {
	memory: ^Form_Memory
	for &candidate in state.forms {
		if candidate.used && string(candidate.path[:candidate.path_count]) == string(path) {
			memory = &candidate
			break
		}
	}
	if memory == nil {
		for &candidate in state.forms {
			if !candidate.used {
				memory = &candidate
				break
			}
		}
	}
	if memory == nil {
		copy(state.forms[:FORM_MEMORY_CAPACITY - 1], state.forms[1:])
		memory = &state.forms[FORM_MEMORY_CAPACITY - 1]
	}
	memory^ = {used = true}
	memory.path_count = copy(memory.path[:], path)
	for &field in form_fields[:form_field_count] {
		remembered := &memory.fields[memory.field_count]
		remembered.name_count = copy(remembered.name[:], field.name[:field.name_count])
		remembered.count = copy(remembered.text[:], field.text[:field.count])
		memory.field_count += 1
	}
}

@(private = "file")
forms_restore :: proc "contextless" (state: ^Origin_State, path: []u8) -> bool {
	for &memory in state.forms {
		if !memory.used || string(memory.path[:memory.path_count]) != string(path) {
			continue
		}
		for &field in form_fields[:form_field_count] {
			for &remembered in memory.fields[:memory.field_count] {
				if string(remembered.name[:remembered.name_count]) == string(field.name[:field.name_count]) {
					field.count = copy(field.text[:], remembered.text[:remembered.count])
				}
			}
		}
		return true
	}
	return false
}

// The window side of the border.

origin_request_make :: proc "contextless" (kind: Origin_Request_Kind, requester, owner: ^html_css.Document_Origin, key: string = "", value: string = "") -> (request: Origin_Request) {
	request.kind = kind
	request.requester = requester^
	request.owner = owner^
	request.key_count = copy(request.key[:], key)
	request.value_count = copy(request.value[:], value)
	return
}

// origin_ask sends a request that is not a render, and reads its reply.
origin_ask :: proc "contextless" (request: ^Origin_Request) -> Origin_Reply {
	request_bytes: [ORIGIN_REQUEST_BYTES]u8
	reply_bytes: [max(ORIGIN_REPLY_BYTES, ORIGIN_RENDER_TREE_BYTES)]u8
	sent := origin_request_encode(request, request_bytes[:])
	count := origin_worker_serve(request_bytes[:sent], nil, reply_bytes[:])
	reply, problem := origin_reply_decode(reply_bytes[:count])
	if problem != .None {
		return {status = .Refused_Malformed}
	}
	return reply
}

// origin_render_ask sends the source of a document of an origin to its
// worker, and reads the render tree that it gives.
origin_render_ask :: proc "contextless" (origin: ^html_css.Document_Origin, source: []u8, view_width: i32) -> Origin_Render_Tree {
	request := origin_request_make(.Render, origin, origin)
	request.view_width = clamp(view_width, 0, LARGEST_WIDTH)
	request_bytes: [ORIGIN_REQUEST_BYTES]u8
	reply_bytes: [max(ORIGIN_REPLY_BYTES, ORIGIN_RENDER_TREE_BYTES)]u8
	sent := origin_request_encode(&request, request_bytes[:])
	count := origin_worker_serve(request_bytes[:sent], source, reply_bytes[:])
	tree, problem := origin_render_tree_decode(reply_bytes[:count])
	if problem != .None {
		return {status = .Refused_Malformed}
	}
	return tree
}

// origin_storage_read reads a value of the state of owner for a document
// of requester.
origin_storage_read :: proc "contextless" (requester, owner: ^html_css.Document_Origin, key: string, buffer: []u8) -> (value: string, status: Origin_Reply_Status) {
	request := origin_request_make(.Storage_Read, requester, owner, key)
	reply := origin_ask(&request)
	return string(buffer[:copy(buffer, reply.value[:reply.value_count])]), reply.status
}

origin_storage_write :: proc "contextless" (writer: ^html_css.Document_Origin, key, value: string) -> Origin_Reply_Status {
	request := origin_request_make(.Storage_Write, writer, writer, key, value)
	return origin_ask(&request).status
}

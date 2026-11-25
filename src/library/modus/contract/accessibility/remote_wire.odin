// Remote viewer semantic tree wire format, focus traversal, and assistive
// session state (src/md/features/accessibility.md, "2. The assistive role").
//
// Extends package accessibility directly over Semantic_Tree and
// element_action_authorize so local assistive holders and remote viewers share
// one semantic model with zero duplicate types. Protected fields never leak
// value text onto the wire. All procedures are contextless and leave caller
// outputs untouched on refusal.
package accessibility

import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/text_encoding"

// Format property: deterministic little-endian wire header ("MST1", version 1)
// and fixed per-node record byte size for remote semantic tree delivery.
REMOTE_TREE_WIRE_MAGIC :: u32(0x4D53_5431)
REMOTE_TREE_WIRE_VERSION :: u16(1)
REMOTE_TREE_WIRE_HEADER_SIZE :: 16
REMOTE_TREE_WIRE_NODE_SIZE :: 60

// Plan value: up to 4 concurrent assistive holders (screen reader, magnifier,
// switch input, and semantic test probe).
ASSISTIVE_READER_CAPACITY :: 4

// Closed focus traversal directions across focusable nodes in tree order.
Focus_Direction :: enum u8 {
	Next     = 1,
	Previous = 2,
	First    = 3,
	Last     = 4,
}

// Closed refusal set for remote semantic tree encoding, decoding, and focus.
Remote_Tree_Wire_Refusal :: enum u8 {
	None                     = 0,
	Null_Tree                = 1,
	Node_Capacity_Exceeded   = 2,
	Text_Capacity_Exceeded   = 3,
	Unknown_Role             = 4,
	Unknown_Live_Mode        = 5,
	Unknown_Toggle_State     = 6,
	Unknown_Expanded_State   = 7,
	Unknown_States           = 8,
	Unknown_Actions          = 9,
	Invalid_Box              = 10,
	Invalid_Parent           = 11,
	Cycle_Detected           = 12,
	Duplicate_Element        = 13,
	Multiple_Focused_Nodes   = 14,
	Text_Range_Out_Of_Bounds = 15,
	Text_Invalid             = 16,
	Protected_Leak           = 17,
	Buffer_Too_Small         = 18,
	Wire_Malformed           = 19,
	Wire_Bad_Magic           = 20,
	Wire_Unsupported_Version = 21,
	Invalid_Direction        = 22,
	No_Focusable_Node        = 23,
}

// Closed refusal set for assistive session attachment and action dispatch.
Assistive_Session_Refusal :: enum u8 {
	None                = 0,
	Null_Session        = 1,
	Invalid_Reader_Id   = 2,
	Duplicate_Reader_Id = 3,
	Reader_Limit        = 4,
	Reader_Not_Attached = 5,
	Action_Refused      = 6,
}

// Tracks attached assistive holders, the visible desktop bar indicator flag,
// and action authorization counters.
Assistive_Session_State :: struct {
	active_reader_ids:   [ASSISTIVE_READER_CAPACITY]u32,
	active_reader_count: int,
	indicator_visible:   bool,
	actions_dispatched:  u64,
	actions_refused:     u64,
}

focus_direction_of_word :: proc "contextless" (word: u64) -> (dir: Focus_Direction, ok: bool) {
	return enum_word.member_of_word(Focus_Direction, word)
}

@(private = "file")
validate_text_range :: proc "contextless" (tree: ^Semantic_Tree, first: u32, count: u16) -> Remote_Tree_Wire_Refusal {
	if count == 0 {
		return .None
	}
	end := u64(first) + u64(count)
	if end > u64(tree.text_count) || end > u64(SEMANTIC_TREE_TEXT_CAPACITY) {
		return .Text_Range_Out_Of_Bounds
	}
	if !text_encoding.text_valid(tree.text_buffer[first:u32(end)]) {
		return .Text_Invalid
	}
	return .None
}

// validate_tree_for_wire checks every node invariant and computes the compacted
// non-protected text byte count that remote_tree_encode will emit.
@(private = "file")
validate_tree_for_wire :: proc "contextless" (tree: ^Semantic_Tree) -> (wire_text_bytes: int, refusal: Remote_Tree_Wire_Refusal) {
	if tree == nil {
		return 0, .Null_Tree
	}
	if tree.node_count < 0 || tree.node_count > SEMANTIC_TREE_NODE_CAPACITY {
		return 0, .Node_Capacity_Exceeded
	}
	if tree.text_count < 0 || tree.text_count > SEMANTIC_TREE_TEXT_CAPACITY {
		return 0, .Text_Capacity_Exceeded
	}
	focused_count := 0
	for index in 0 ..< tree.node_count {
		node := tree.nodes[index]
		if _, ok := element_role_of_word(u8(node.role)); !ok {
			return 0, .Unknown_Role
		}
		if _, ok := live_mode_of_word(u8(node.live)); !ok {
			return 0, .Unknown_Live_Mode
		}
		if _, ok := toggle_state_of_word(u8(node.toggle)); !ok {
			return 0, .Unknown_Toggle_State
		}
		if _, ok := expanded_state_of_word(u8(node.expanded)); !ok {
			return 0, .Unknown_Expanded_State
		}
		if _, ok := element_states_of_word(transmute(u32)node.states); !ok {
			return 0, .Unknown_States
		}
		if _, ok := element_actions_of_word(transmute(u64)node.actions); !ok {
			return 0, .Unknown_Actions
		}
		if node.box.left > node.box.right || node.box.top > node.box.bottom {
			return 0, .Invalid_Box
		}
		if node.parent < -1 || int(node.parent) >= tree.node_count {
			return 0, .Invalid_Parent
		}
		if node.element != 0 {
			for earlier in 0 ..< index {
				if tree.nodes[earlier].element == node.element {
					return 0, .Duplicate_Element
				}
			}
		}
		if .Focused in node.states {
			focused_count += 1
			if focused_count > 1 {
				return 0, .Multiple_Focused_Nodes
			}
		}
		if r := validate_text_range(tree, node.name_first, node.name_count); r != .None {
			return 0, r
		}
		if r := validate_text_range(tree, node.description_first, node.description_count); r != .None {
			return 0, r
		}
		wire_text_bytes += int(node.name_count) + int(node.description_count)
		if .Protected not_in node.states {
			if r := validate_text_range(tree, node.value_text_first, node.value_text_count); r != .None {
				return 0, r
			}
			wire_text_bytes += int(node.value_text_count)
		}
		if wire_text_bytes > SEMANTIC_TREE_TEXT_CAPACITY {
			return 0, .Text_Capacity_Exceeded
		}
	}
	// Parent chain acyclicity check.
	for index in 0 ..< tree.node_count {
		cursor := tree.nodes[index].parent
		steps := 0
		for cursor != -1 {
			if int(cursor) == index || steps >= tree.node_count {
				return 0, .Cycle_Detected
			}
			if cursor < 0 || int(cursor) >= tree.node_count {
				return 0, .Invalid_Parent
			}
			cursor = tree.nodes[cursor].parent
			steps += 1
		}
	}
	return wire_text_bytes, .None
}

// remote_tree_encoded_size returns the exact wire byte length of tree.
remote_tree_encoded_size :: proc "contextless" (tree: ^Semantic_Tree) -> (size: int, refusal: Remote_Tree_Wire_Refusal) {
	wire_text_bytes, r := validate_tree_for_wire(tree)
	if r != .None {
		return 0, r
	}
	return REMOTE_TREE_WIRE_HEADER_SIZE + tree.node_count * REMOTE_TREE_WIRE_NODE_SIZE + wire_text_bytes, .None
}

// remote_tree_encode serializes a validated Semantic_Tree for a remote viewer.
// Protected fields never serialize value_text or .Insert_Text onto the wire.
// Writes zero bytes on refusal.
remote_tree_encode :: proc "contextless" (
	tree: ^Semantic_Tree,
	generation: u32,
	out: []u8,
) -> (
	written: int,
	refusal: Remote_Tree_Wire_Refusal,
) {
	wire_text_bytes, r := validate_tree_for_wire(tree)
	if r != .None {
		return 0, r
	}
	needed := REMOTE_TREE_WIRE_HEADER_SIZE + tree.node_count * REMOTE_TREE_WIRE_NODE_SIZE + wire_text_bytes
	if len(out) < needed {
		return 0, .Buffer_Too_Small
	}
	byte_order.write_u32_little_endian(out, 0, REMOTE_TREE_WIRE_MAGIC)
	byte_order.write_u16_little_endian(out, 4, REMOTE_TREE_WIRE_VERSION)
	byte_order.write_u16_little_endian(out, 6, u16(tree.node_count))
	byte_order.write_u32_little_endian(out, 8, u32(wire_text_bytes))
	byte_order.write_u32_little_endian(out, 12, generation)

	text_base := REMOTE_TREE_WIRE_HEADER_SIZE + tree.node_count * REMOTE_TREE_WIRE_NODE_SIZE
	text_cursor := 0
	offset := REMOTE_TREE_WIRE_HEADER_SIZE

	for index in 0 ..< tree.node_count {
		node := tree.nodes[index]
		name_first: u32 = 0
		name_count := node.name_count
		if name_count > 0 {
			name_first = u32(text_cursor)
			copy(out[text_base + text_cursor:][:name_count], tree.text_buffer[node.name_first:][:name_count])
			text_cursor += int(name_count)
		}
		desc_first: u32 = 0
		desc_count := node.description_count
		if desc_count > 0 {
			desc_first = u32(text_cursor)
			copy(out[text_base + text_cursor:][:desc_count], tree.text_buffer[node.description_first:][:desc_count])
			text_cursor += int(desc_count)
		}
		val_first: u32 = 0
		val_count: u16 = 0
		actions := node.actions
		if .Protected in node.states {
			actions -= {.Insert_Text}
		} else if node.value_text_count > 0 {
			val_first = u32(text_cursor)
			val_count = node.value_text_count
			copy(out[text_base + text_cursor:][:val_count], tree.text_buffer[node.value_text_first:][:val_count])
			text_cursor += int(val_count)
		}
		byte_order.write_u32_little_endian(out, offset + 0, node.element)
		byte_order.write_u32_little_endian(out, offset + 4, u32(node.parent))
		byte_order.write_u32_little_endian(out, offset + 8, u32(node.box.left))
		byte_order.write_u32_little_endian(out, offset + 12, u32(node.box.top))
		byte_order.write_u32_little_endian(out, offset + 16, u32(node.box.right))
		byte_order.write_u32_little_endian(out, offset + 20, u32(node.box.bottom))
		out[offset + 24] = u8(node.role)
		out[offset + 25] = u8(node.live)
		out[offset + 26] = u8(node.toggle)
		out[offset + 27] = u8(node.expanded)
		byte_order.write_u32_little_endian(out, offset + 28, transmute(u32)node.states)
		byte_order.write_u64_little_endian(out, offset + 32, transmute(u64)actions)
		byte_order.write_u32_little_endian(out, offset + 40, name_first)
		byte_order.write_u16_little_endian(out, offset + 44, name_count)
		byte_order.write_u16_little_endian(out, offset + 46, desc_count)
		byte_order.write_u32_little_endian(out, offset + 48, desc_first)
		byte_order.write_u32_little_endian(out, offset + 52, val_first)
		byte_order.write_u16_little_endian(out, offset + 56, val_count)
		byte_order.write_u16_little_endian(out, offset + 58, 0)
		offset += REMOTE_TREE_WIRE_NODE_SIZE
	}
	return needed, .None
}

// remote_tree_decode validates and decodes a wire snapshot into a staging
// Semantic_Tree, rebuilding parent/child/sibling links and focus indices.
// On any refusal, out is not modified.
remote_tree_decode :: proc "contextless" (
	wire: []u8,
	out: ^Semantic_Tree,
) -> (
	generation: u32,
	refusal: Remote_Tree_Wire_Refusal,
) {
	if out == nil {
		return 0, .Null_Tree
	}
	if len(wire) < REMOTE_TREE_WIRE_HEADER_SIZE {
		return 0, .Wire_Malformed
	}
	magic := byte_order.read_u32_little_endian(wire, 0)
	if magic != REMOTE_TREE_WIRE_MAGIC {
		return 0, .Wire_Bad_Magic
	}
	version := byte_order.read_u16_little_endian(wire, 4)
	if version != REMOTE_TREE_WIRE_VERSION {
		return 0, .Wire_Unsupported_Version
	}
	node_count := int(byte_order.read_u16_little_endian(wire, 6))
	text_count := int(byte_order.read_u32_little_endian(wire, 8))
	gen := byte_order.read_u32_little_endian(wire, 12)
	if node_count > SEMANTIC_TREE_NODE_CAPACITY {
		return 0, .Node_Capacity_Exceeded
	}
	if text_count > SEMANTIC_TREE_TEXT_CAPACITY {
		return 0, .Text_Capacity_Exceeded
	}
	expected_len := REMOTE_TREE_WIRE_HEADER_SIZE + node_count * REMOTE_TREE_WIRE_NODE_SIZE + text_count
	if len(wire) != expected_len {
		return 0, .Wire_Malformed
	}

	decoded: Semantic_Tree
	decoded.node_count = node_count
	decoded.text_count = text_count
	decoded.first_root = -1
	decoded.focused_node = -1

	text_base := REMOTE_TREE_WIRE_HEADER_SIZE + node_count * REMOTE_TREE_WIRE_NODE_SIZE
	if text_count > 0 {
		copy(decoded.text_buffer[:text_count], wire[text_base:text_base + text_count])
	}

	offset := REMOTE_TREE_WIRE_HEADER_SIZE
	for index in 0 ..< node_count {
		if byte_order.read_u16_little_endian(wire, offset + 58) != 0 {
			return 0, .Wire_Malformed
		}
		role, role_ok := element_role_of_word(wire[offset + 24])
		if !role_ok {
			return 0, .Unknown_Role
		}
		live, live_ok := live_mode_of_word(wire[offset + 25])
		if !live_ok {
			return 0, .Unknown_Live_Mode
		}
		toggle, toggle_ok := toggle_state_of_word(wire[offset + 26])
		if !toggle_ok {
			return 0, .Unknown_Toggle_State
		}
		expanded, expanded_ok := expanded_state_of_word(wire[offset + 27])
		if !expanded_ok {
			return 0, .Unknown_Expanded_State
		}
		states, states_ok := element_states_of_word(byte_order.read_u32_little_endian(wire, offset + 28))
		if !states_ok {
			return 0, .Unknown_States
		}
		actions, actions_ok := element_actions_of_word(byte_order.read_u64_little_endian(wire, offset + 32))
		if !actions_ok {
			return 0, .Unknown_Actions
		}
		val_first := byte_order.read_u32_little_endian(wire, offset + 52)
		val_count := byte_order.read_u16_little_endian(wire, offset + 56)
		if .Protected in states && (val_count != 0 || val_first != 0 || .Insert_Text in actions) {
			return 0, .Protected_Leak
		}
		decoded.nodes[index] = Semantic_Node {
			element           = byte_order.read_u32_little_endian(wire, offset + 0),
			parent            = i32(byte_order.read_u32_little_endian(wire, offset + 4)),
			first_child       = -1,
			next_sibling      = -1,
			record_index      = i32(index),
			box               = Semantic_Box {
				left   = i32(byte_order.read_u32_little_endian(wire, offset + 8)),
				top    = i32(byte_order.read_u32_little_endian(wire, offset + 12)),
				right  = i32(byte_order.read_u32_little_endian(wire, offset + 16)),
				bottom = i32(byte_order.read_u32_little_endian(wire, offset + 20)),
			},
			role              = role,
			live              = live,
			explicit_live     = live,
			toggle            = toggle,
			expanded          = expanded,
			states            = states,
			actions           = actions,
			name_first        = byte_order.read_u32_little_endian(wire, offset + 40),
			name_count        = byte_order.read_u16_little_endian(wire, offset + 44),
			description_first = byte_order.read_u32_little_endian(wire, offset + 48),
			description_count = byte_order.read_u16_little_endian(wire, offset + 46),
			value_text_first  = val_first,
			value_text_count  = val_count,
		}
		offset += REMOTE_TREE_WIRE_NODE_SIZE
	}

	if _, val_r := validate_tree_for_wire(&decoded); val_r != .None {
		return 0, val_r
	}

	// Rebuild first_root, first_child, next_sibling, focused_node, and focusable_count.
	last_root := i32(-1)
	last_child: [SEMANTIC_TREE_NODE_CAPACITY]i32
	for i in 0 ..< node_count {
		last_child[i] = -1
	}
	for index in 0 ..< node_count {
		idx := i32(index)
		node := &decoded.nodes[index]
		if .Focusable in node.states || .Focus in node.actions {
			decoded.focusable_count += 1
		}
		if .Focused in node.states {
			decoded.focused_node = idx
		}
		if node.parent == -1 {
			if decoded.first_root == -1 {
				decoded.first_root = idx
			} else {
				decoded.nodes[last_root].next_sibling = idx
			}
			last_root = idx
		} else {
			p := node.parent
			if decoded.nodes[p].first_child == -1 {
				decoded.nodes[p].first_child = idx
			} else {
				decoded.nodes[last_child[p]].next_sibling = idx
			}
			last_child[p] = idx
		}
	}

	out^ = decoded
	return gen, .None
}

// semantic_tree_move_focus advances focus among enabled, visible focusable
// nodes in tree order and updates tree.focused_node and .Focused states.
semantic_tree_move_focus :: proc "contextless" (
	tree: ^Semantic_Tree,
	direction: Focus_Direction,
) -> (
	focused_element: u32,
	refusal: Remote_Tree_Wire_Refusal,
) {
	checked_dir, dir_ok := focus_direction_of_word(u64(direction))
	if !dir_ok {
		return 0, .Invalid_Direction
	}
	if _, val_r := validate_tree_for_wire(tree); val_r != .None {
		return 0, val_r
	}
	focusable: [SEMANTIC_TREE_NODE_CAPACITY]int
	count := 0
	current_pos := -1
	for index in 0 ..< tree.node_count {
		node := tree.nodes[index]
		if node.element == 0 || .Disabled in node.states || .Hidden in node.states {
			continue
		}
		if .Focusable in node.states || .Focus in node.actions {
			if .Focused in node.states {
				current_pos = count
			}
			focusable[count] = index
			count += 1
		}
	}
	if count == 0 {
		return 0, .No_Focusable_Node
	}
	next_pos := 0
	switch checked_dir {
	case .First:
		next_pos = 0
	case .Last:
		next_pos = count - 1
	case .Next:
		if current_pos < 0 {
			next_pos = 0
		} else {
			next_pos = (current_pos + 1) % count
		}
	case .Previous:
		if current_pos < 0 {
			next_pos = count - 1
		} else {
			next_pos = (current_pos + count - 1) % count
		}
	}
	for index in 0 ..< tree.node_count {
		tree.nodes[index].states -= {.Focused}
	}
	target := focusable[next_pos]
	tree.nodes[target].states += {.Focused}
	tree.focused_node = i32(target)
	return tree.nodes[target].element, .None
}

// assistive_session_attach registers an active assistive holder and turns on
// the visible bar indicator required while any holder reads semantic trees.
assistive_session_attach :: proc "contextless" (session: ^Assistive_Session_State, reader_id: u32) -> Assistive_Session_Refusal {
	if session == nil || session.active_reader_count < 0 || session.active_reader_count > ASSISTIVE_READER_CAPACITY {
		return .Null_Session
	}
	if reader_id == 0 {
		return .Invalid_Reader_Id
	}
	for index in 0 ..< session.active_reader_count {
		if session.active_reader_ids[index] == reader_id {
			return .Duplicate_Reader_Id
		}
	}
	if session.active_reader_count >= ASSISTIVE_READER_CAPACITY {
		return .Reader_Limit
	}
	session.active_reader_ids[session.active_reader_count] = reader_id
	session.active_reader_count += 1
	session.indicator_visible = true
	return .None
}

// assistive_session_detach removes an active assistive holder and turns off
// the bar indicator once the last holder leaves.
assistive_session_detach :: proc "contextless" (session: ^Assistive_Session_State, reader_id: u32) -> Assistive_Session_Refusal {
	if session == nil || session.active_reader_count < 0 || session.active_reader_count > ASSISTIVE_READER_CAPACITY {
		return .Null_Session
	}
	if reader_id == 0 {
		return .Invalid_Reader_Id
	}
	found := -1
	for index in 0 ..< session.active_reader_count {
		if session.active_reader_ids[index] == reader_id {
			found = index
			break
		}
	}
	if found < 0 {
		return .Reader_Not_Attached
	}
	for index := found; index + 1 < session.active_reader_count; index += 1 {
		session.active_reader_ids[index] = session.active_reader_ids[index + 1]
	}
	session.active_reader_count -= 1
	session.active_reader_ids[session.active_reader_count] = 0
	session.indicator_visible = session.active_reader_count > 0
	return .None
}

// assistive_session_authorize_action verifies that reader_id is attached and
// delegates to element_action_authorize on tree, updating session counters.
assistive_session_authorize_action :: proc "contextless" (
	session: ^Assistive_Session_State,
	tree: ^Semantic_Tree,
	reader_id: u32,
	element: u32,
	action_word: u8,
) -> (
	action: Element_Action,
	node_index: i32,
	session_refusal: Assistive_Session_Refusal,
	action_refusal: Element_Action_Refusal,
) {
	if session == nil || session.active_reader_count < 0 || session.active_reader_count > ASSISTIVE_READER_CAPACITY {
		return {}, -1, .Null_Session, .None
	}
	attached := false
	for index in 0 ..< session.active_reader_count {
		if session.active_reader_ids[index] == reader_id && reader_id != 0 {
			attached = true
			break
		}
	}
	if !attached {
		session.actions_refused += 1
		return {}, -1, .Reader_Not_Attached, .None
	}
	member, idx, act_r := element_action_authorize(tree, element, action_word)
	if act_r != .None {
		session.actions_refused += 1
		return {}, -1, .Action_Refused, act_r
	}
	session.actions_dispatched += 1
	return member, idx, .None, .None
}

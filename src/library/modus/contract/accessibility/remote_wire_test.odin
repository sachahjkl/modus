#+build !freestanding
#+build !modus
package accessibility

import "core:testing"
import "modus:contract/byte_order"

@(private = "file")
append_tree_text :: proc(tree: ^Semantic_Tree, s: string) -> (first: u32, count: u16) {
	first = u32(tree.text_count)
	count = u16(len(s))
	copy(tree.text_buffer[tree.text_count:][:len(s)], transmute([]u8)s)
	tree.text_count += len(s)
	return first, count
}

@(private = "file")
sample_semantic_tree :: proc() -> Semantic_Tree {
	tree: Semantic_Tree
	tree.first_root = 0
	tree.focused_node = 1

	root_name_f, root_name_c := append_tree_text(&tree, "Settings")
	btn_name_f, btn_name_c := append_tree_text(&tree, "Apply")
	btn_desc_f, btn_desc_c := append_tree_text(&tree, "Save changes")
	txt_name_f, txt_name_c := append_tree_text(&tree, "Host name")
	txt_val_f, txt_val_c := append_tree_text(&tree, "modus-box")
	pwd_name_f, pwd_name_c := append_tree_text(&tree, "Passphrase")
	pwd_val_f, pwd_val_c := append_tree_text(&tree, "top-secret-never-sent")

	tree.nodes[0] = Semantic_Node {
		element      = 10,
		parent       = -1,
		first_child  = 1,
		next_sibling = -1,
		box          = {0, 0, 800, 600},
		role         = .Region,
		name_first   = root_name_f,
		name_count   = root_name_c,
	}
	tree.nodes[1] = Semantic_Node {
		element           = 20,
		parent            = 0,
		first_child       = -1,
		next_sibling      = 2,
		box               = {16, 16, 136, 48},
		role              = .Button,
		states            = {.Focusable, .Focused},
		actions           = {.Focus, .Press},
		name_first        = btn_name_f,
		name_count        = btn_name_c,
		description_first = btn_desc_f,
		description_count = btn_desc_c,
	}
	tree.nodes[2] = Semantic_Node {
		element          = 30,
		parent           = 0,
		first_child      = -1,
		next_sibling     = 3,
		box              = {16, 64, 256, 96},
		role             = .Text_Box,
		states           = {.Focusable},
		actions          = {.Focus, .Insert_Text},
		name_first       = txt_name_f,
		name_count       = txt_name_c,
		value_text_first = txt_val_f,
		value_text_count = txt_val_c,
	}
	tree.nodes[3] = Semantic_Node {
		element          = 40,
		parent           = 0,
		first_child      = -1,
		next_sibling     = -1,
		box              = {16, 112, 256, 144},
		role             = .Text_Box,
		states           = {.Focusable, .Protected},
		actions          = {.Focus, .Insert_Text},
		name_first       = pwd_name_f,
		name_count       = pwd_name_c,
		value_text_first = pwd_val_f,
		value_text_count = pwd_val_c,
	}
	tree.node_count = 4
	tree.focusable_count = 3
	return tree
}

@(test)
remote_tree_wire_round_trip_strips_protected_and_refuses_corruption :: proc(t: ^testing.T) {
	tree := sample_semantic_tree()
	needed, size_r := remote_tree_encoded_size(&tree)
	testing.expect_value(t, size_r, Remote_Tree_Wire_Refusal.None)

	// Buffer too small writes nothing.
	tiny: [REMOTE_TREE_WIRE_HEADER_SIZE]u8
	written, enc_r := remote_tree_encode(&tree, 42, tiny[:])
	testing.expect_value(t, enc_r, Remote_Tree_Wire_Refusal.Buffer_Too_Small)
	testing.expect_value(t, written, 0)

	wire := make([]u8, needed, context.temp_allocator)
	written, enc_r = remote_tree_encode(&tree, 42, wire)
	testing.expect_value(t, enc_r, Remote_Tree_Wire_Refusal.None)
	testing.expect_value(t, written, needed)

	// Decode back and verify exact fields + protected value stripping.
	decoded: Semantic_Tree
	gen, dec_r := remote_tree_decode(wire, &decoded)
	testing.expect_value(t, dec_r, Remote_Tree_Wire_Refusal.None)
	testing.expect_value(t, gen, u32(42))
	testing.expect_value(t, decoded.node_count, 4)
	testing.expect_value(t, decoded.first_root, i32(0))
	testing.expect_value(t, decoded.focused_node, i32(1))
	testing.expect_value(t, decoded.nodes[0].first_child, i32(1))
	testing.expect_value(t, decoded.nodes[1].next_sibling, i32(2))
	testing.expect_value(t, semantic_node_name(&decoded, &decoded.nodes[1]), "Apply")
	testing.expect_value(t, semantic_node_description(&decoded, &decoded.nodes[1]), "Save changes")
	testing.expect_value(t, semantic_node_value_text(&decoded, &decoded.nodes[2]), "modus-box")
	// Protected node must carry neither value_text nor .Insert_Text on wire.
	testing.expect_value(t, decoded.nodes[3].value_text_count, u16(0))
	testing.expect(t, .Insert_Text not_in decoded.nodes[3].actions)

	// Corrupt wire cases must leave decoded untouched.
	saved_count := decoded.node_count
	_, dec_r = remote_tree_decode(wire[:REMOTE_TREE_WIRE_HEADER_SIZE - 1], &decoded)
	testing.expect_value(t, dec_r, Remote_Tree_Wire_Refusal.Wire_Malformed)
	_, dec_r = remote_tree_decode(wire[:needed - 1], &decoded)
	testing.expect_value(t, dec_r, Remote_Tree_Wire_Refusal.Wire_Malformed)
	testing.expect_value(t, decoded.node_count, saved_count)

	// Bad magic & unsupported version.
	bad_magic := make([]u8, needed, context.temp_allocator)
	copy(bad_magic, wire)
	bad_magic[0] ~= 0xFF
	_, dec_r = remote_tree_decode(bad_magic, &decoded)
	testing.expect_value(t, dec_r, Remote_Tree_Wire_Refusal.Wire_Bad_Magic)

	bad_ver := make([]u8, needed, context.temp_allocator)
	copy(bad_ver, wire)
	byte_order.write_u16_little_endian(bad_ver, 4, 99)
	_, dec_r = remote_tree_decode(bad_ver, &decoded)
	testing.expect_value(t, dec_r, Remote_Tree_Wire_Refusal.Wire_Unsupported_Version)

	// Protected leak crafted in wire node 3 (non-zero value_text_count) -> refused.
	leak := make([]u8, needed, context.temp_allocator)
	copy(leak, wire)
	node3_off := REMOTE_TREE_WIRE_HEADER_SIZE + 3 * REMOTE_TREE_WIRE_NODE_SIZE
	byte_order.write_u16_little_endian(leak, node3_off + 56, 1)
	_, dec_r = remote_tree_decode(leak, &decoded)
	testing.expect_value(t, dec_r, Remote_Tree_Wire_Refusal.Protected_Leak)

	// Cycle crafted in wire: node 0 parent = 1, node 1 parent = 0 -> Cycle_Detected.
	cycled := make([]u8, needed, context.temp_allocator)
	copy(cycled, wire)
	byte_order.write_u32_little_endian(cycled, REMOTE_TREE_WIRE_HEADER_SIZE + 4, 1)
	_, dec_r = remote_tree_decode(cycled, &decoded)
	testing.expect_value(t, dec_r, Remote_Tree_Wire_Refusal.Cycle_Detected)

	// Unknown action bit in wire -> Unknown_Actions.
	bad_act := make([]u8, needed, context.temp_allocator)
	copy(bad_act, wire)
	byte_order.write_u64_little_endian(bad_act, REMOTE_TREE_WIRE_HEADER_SIZE + 32, u64(1) << 60)
	_, dec_r = remote_tree_decode(bad_act, &decoded)
	testing.expect_value(t, dec_r, Remote_Tree_Wire_Refusal.Unknown_Actions)

	// Trailing extra byte -> Wire_Malformed.
	trailing := make([]u8, needed + 1, context.temp_allocator)
	copy(trailing, wire)
	_, dec_r = remote_tree_decode(trailing, &decoded)
	testing.expect_value(t, dec_r, Remote_Tree_Wire_Refusal.Wire_Malformed)
}

@(test)
assistive_session_bar_indicator_focus_and_action_authorization :: proc(t: ^testing.T) {
	tree := sample_semantic_tree()
	session: Assistive_Session_State

	// Unattached reader is refused and counted.
	_, _, sr, _ := assistive_session_authorize_action(&session, &tree, 1, 20, u8(Element_Action.Press))
	testing.expect_value(t, sr, Assistive_Session_Refusal.Reader_Not_Attached)
	testing.expect_value(t, session.actions_refused, u64(1))
	testing.expect(t, !session.indicator_visible)

	// Attach reader 1 -> bar indicator turns on.
	testing.expect_value(t, assistive_session_attach(&session, 0), Assistive_Session_Refusal.Invalid_Reader_Id)
	testing.expect_value(t, assistive_session_attach(&session, 1), Assistive_Session_Refusal.None)
	testing.expect(t, session.indicator_visible)
	testing.expect_value(t, assistive_session_attach(&session, 1), Assistive_Session_Refusal.Duplicate_Reader_Id)

	// Declared action succeeds; undeclared & protected Insert_Text refused.
	act, idx, sr2, ar2 := assistive_session_authorize_action(&session, &tree, 1, 20, u8(Element_Action.Press))
	testing.expect(t, sr2 == .None && ar2 == .None && act == .Press && idx == 1)
	testing.expect_value(t, session.actions_dispatched, u64(1))

	_, _, sr3, ar3 := assistive_session_authorize_action(&session, &tree, 1, 20, u8(Element_Action.Expand))
	testing.expect(t, sr3 == .Action_Refused && ar3 == .Action_Not_Declared)

	_, _, sr4, ar4 := assistive_session_authorize_action(&session, &tree, 1, 40, u8(Element_Action.Insert_Text))
	testing.expect(t, sr4 == .Action_Refused && ar4 == .Protected_Text)

	// Focus traversal cycles [20, 30, 40].
	el, fr := semantic_tree_move_focus(&tree, .Next)
	testing.expect(t, fr == .None && el == 30)
	el, fr = semantic_tree_move_focus(&tree, .Next)
	testing.expect(t, fr == .None && el == 40)
	el, fr = semantic_tree_move_focus(&tree, .Next)
	testing.expect(t, fr == .None && el == 20)
	el, fr = semantic_tree_move_focus(&tree, .Previous)
	testing.expect(t, fr == .None && el == 40)
	el, fr = semantic_tree_move_focus(&tree, .First)
	testing.expect(t, fr == .None && el == 20)
	el, fr = semantic_tree_move_focus(&tree, .Last)
	testing.expect(t, fr == .None && el == 40)
	_, fr = semantic_tree_move_focus(&tree, Focus_Direction(99))
	testing.expect_value(t, fr, Remote_Tree_Wire_Refusal.Invalid_Direction)

	// Capacity bound + detach turns off indicator only when last reader detaches.
	for id: u32 = 2; id <= ASSISTIVE_READER_CAPACITY; id += 1 {
		testing.expect_value(t, assistive_session_attach(&session, id), Assistive_Session_Refusal.None)
	}
	testing.expect_value(t, assistive_session_attach(&session, 99), Assistive_Session_Refusal.Reader_Limit)
	for id: u32 = 1; id < ASSISTIVE_READER_CAPACITY; id += 1 {
		testing.expect_value(t, assistive_session_detach(&session, id), Assistive_Session_Refusal.None)
		testing.expect(t, session.indicator_visible)
	}
	testing.expect_value(t, assistive_session_detach(&session, ASSISTIVE_READER_CAPACITY), Assistive_Session_Refusal.None)
	testing.expect(t, !session.indicator_visible)
}

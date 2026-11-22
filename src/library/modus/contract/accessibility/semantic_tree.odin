// Flat semantic tree reconstruction, auditing, and snapshot diffing directly
// from a draw table (src/md/features/accessibility.md, "1. The semantic tree").
//
// Because the semantic tree is reconstructed directly from the draw records
// and byte table of a frame, the drawn pixels and the semantic description
// cannot drift. All structures are fixed-capacity and require no allocator.
package accessibility

import "modus:contract/draw_record"
import "modus:contract/text_encoding"

// Fixed capacities of one frame's flat semantic tree.
SEMANTIC_TREE_NODE_CAPACITY :: 256
SEMANTIC_TREE_TEXT_CAPACITY :: 8192
SEMANTIC_NODE_RELATION_CAPACITY :: 8
SEMANTIC_FOCUS_LIMIT :: 64

// Why semantic_tree_extract refuses a draw table.
Semantic_Tree_Refusal :: enum u8 {
	None                       = 0,  // The table is well formed and extracted into the tree.
	Record_Invalid             = 1,  // A record failed draw_record.read (invalid kind, role, state, box, or reserved byte).
	Pop_Without_Push           = 2,  // An Element_Pop or Clip_Pop with no matching push open.
	Push_Past_Depth_Limit      = 3,  // Nesting depth exceeded ELEMENT_DEPTH_LIMIT or CLIP_DEPTH_LIMIT.
	Push_Without_Pop           = 4,  // The table ended with an Element_Push or Clip_Push still open.
	Pop_Wrong_Kind             = 5,  // A Clip_Pop tried to close an Element_Push, or vice versa.
	Element_Word_Zero          = 6,  // An Element_Push carried element word 0.
	Element_Word_Mismatch      = 7,  // A record under an open Element_Push carried another element's word.
	Name_Range_Out_Of_Bounds   = 8,  // An Element_Push name range exceeded the byte table.
	Name_Invalid_Text          = 9,  // An Element_Push name was not valid UTF-8 without controls.
	Detail_Range_Out_Of_Bounds = 10, // An Element_Push detail range exceeded the byte table or alignment.
	Detail_Invalid             = 11, // A 16-byte detail record had an unknown kind, non-zero reserved field, or invalid value.
	Node_Capacity_Exceeded     = 12, // The table holds more element pushes than SEMANTIC_TREE_NODE_CAPACITY.
	Text_Capacity_Exceeded     = 13, // The tree text buffer could not hold all resolved names and values.
}

// Bounding rectangle of a semantic node, in whole logical pixels.
Semantic_Box :: struct {
	left, top, right, bottom: i32,
}

// One relation attached to a semantic node, naming another element word in
// the same frame.
Semantic_Relation :: struct {
	kind:     Element_Detail_Kind,
	target:   u32,
	resolved: bool,
}

// One flat node in a Semantic_Tree, linked by integer indices into tree.nodes.
Semantic_Node :: struct {
	element:                u32, // Element word from the push, or 0 if converted to anonymous group on duplicate identity.
	parent:                 i32, // Index of parent node, or -1 at top level.
	first_child:            i32, // Index of first child node, or -1.
	next_sibling:           i32, // Index of next sibling node, or -1.
	record_index:           i32, // Index of the Element_Push record in the draw table.
	box:                    Semantic_Box,
	clipped:                bool, // True when active clips reduce box to empty.
	role:                   Element_Role,
	live:                   Live_Mode, // Effective politeness (explicit or role default).
	explicit_live:          Live_Mode,
	toggle:                 Toggle_State,
	expanded:               Expanded_State,
	states:                 Element_States,
	actions:                Element_Actions,
	name_first:             u32,
	name_count:             u16,
	description_first:      u32,
	description_count:      u16,
	placeholder_first:      u32,
	placeholder_count:      u16,
	key_shortcuts_first:    u32,
	key_shortcuts_count:    u16,
	value_text_first:       u32,
	value_text_count:       u16,
	live_text_first:        u32,
	live_text_count:        u16,
	has_value_now:          bool,
	value_now:              i64,
	has_value_minimum:      bool,
	value_minimum:          i64,
	has_value_maximum:      bool,
	value_maximum:          i64,
	has_caret:              bool,
	caret:                  u64,
	has_selection:          bool,
	selection_start:        u64,
	selection_end:          u64,
	level:                  u16,
	position_in_set:        u32,
	set_size:               u32,
	row_index:              u32,
	row_count:              u32,
	column_index:           u32,
	column_count:           u32,
	orientation:            Element_Orientation,
	sort:                   Element_Sort,
	current:                Element_Current,
	has_popup:              Element_Popup,
	auto_complete:          Element_Auto_Complete,
	relevant:               Element_Relevant_Set,
	labelled_by:            u32,
	described_by:           u32,
	controls:               u32,
	active_descendant:      u32,
	relations:              [SEMANTIC_NODE_RELATION_CAPACITY]Semantic_Relation,
	relation_count:         u8,
	unresolved_relations:   u32,
	protected_value_leaked: bool, // True if a Protected push tried to attach value/caret/selection (value is still withheld).
}

// Snapshot of the semantic tree reconstructed from one frame's draw table.
Semantic_Tree :: struct {
	nodes:                 [SEMANTIC_TREE_NODE_CAPACITY]Semantic_Node,
	node_count:            int,
	first_root:            i32, // Index of first top-level node, or -1.
	focused_node:          i32, // Index of the focused node, or -1.
	focusable_count:       int,
	duplicate_identities:  u32, // Count of Element_Push records that repeated an earlier element word.
	unresolved_relations:  u32, // Total unresolved relation references across all nodes.
	protected_value_leaks: u32, // Count of Protected nodes that attempted to publish value/caret/selection.
	text_buffer:           [SEMANTIC_TREE_TEXT_CAPACITY]u8,
	text_count:            int,
}

// Text field accessors on an extracted Semantic_Tree.

semantic_text_slice :: proc "contextless" (tree: ^Semantic_Tree, first: u32, count: u16) -> string {
	if count == 0 || int(first) + int(count) > tree.text_count || int(first) + int(count) > len(tree.text_buffer) {
		return ""
	}
	return string(tree.text_buffer[first:][:count])
}

semantic_node_name :: proc "contextless" (tree: ^Semantic_Tree, node: ^Semantic_Node) -> string {
	return semantic_text_slice(tree, node.name_first, node.name_count)
}

semantic_node_description :: proc "contextless" (tree: ^Semantic_Tree, node: ^Semantic_Node) -> string {
	return semantic_text_slice(tree, node.description_first, node.description_count)
}

semantic_node_placeholder :: proc "contextless" (tree: ^Semantic_Tree, node: ^Semantic_Node) -> string {
	return semantic_text_slice(tree, node.placeholder_first, node.placeholder_count)
}

semantic_node_key_shortcuts :: proc "contextless" (tree: ^Semantic_Tree, node: ^Semantic_Node) -> string {
	return semantic_text_slice(tree, node.key_shortcuts_first, node.key_shortcuts_count)
}

semantic_node_value_text :: proc "contextless" (tree: ^Semantic_Tree, node: ^Semantic_Node) -> string {
	if .Protected in node.states {
		return ""
	}
	return semantic_text_slice(tree, node.value_text_first, node.value_text_count)
}

semantic_node_live_text :: proc "contextless" (tree: ^Semantic_Tree, node: ^Semantic_Node) -> string {
	if .Protected in node.states {
		return ""
	}
	return semantic_text_slice(tree, node.live_text_first, node.live_text_count)
}

// semantic_tree_find_by_element returns the index of the node with the given
// non-zero element word, or -1 if absent.
semantic_tree_find_by_element :: proc "contextless" (tree: ^Semantic_Tree, element: u32) -> i32 {
	if element == 0 {
		return -1
	}
	for index in 0 ..< tree.node_count {
		if tree.nodes[index].element == element {
			return i32(index)
		}
	}
	return -1
}

@(private = "file")
semantic_text_append :: proc "contextless" (tree: ^Semantic_Tree, text: []u8) -> (first: u32, count: u16, ok: bool) {
	if len(text) == 0 {
		return 0, 0, true
	}
	if len(text) > int(max(u16)) || tree.text_count + len(text) > len(tree.text_buffer) {
		return 0, 0, false
	}
	first = u32(tree.text_count)
	copy(tree.text_buffer[tree.text_count:], text)
	tree.text_count += len(text)
	return first, u16(len(text)), true
}

@(private = "file")
semantic_box_intersect :: proc "contextless" (a, b: Semantic_Box) -> Semantic_Box {
	return {
		left   = max(a.left, b.left),
		top    = max(a.top, b.top),
		right  = min(a.right, b.right),
		bottom = min(a.bottom, b.bottom),
	}
}

@(private = "file")
semantic_box_empty :: proc "contextless" (box: Semantic_Box) -> bool {
	return box.left >= box.right || box.top >= box.bottom
}

@(private = "file")
Extract_Stack_Kind :: enum u8 {
	Clip,
	Element,
}

@(private = "file")
Extract_Stack_Entry :: struct {
	kind:           Extract_Stack_Kind,
	element_word:   u32,
	node_index:     i32,
	element_slot:   int, // 0 ..< ELEMENT_DEPTH_LIMIT for .Element entries.
	is_protected:   bool,
}

@(private = "file")
append_joined_text :: proc "contextless" (buffer: []u8, length: ^u16, piece: []u8) {
	if len(piece) == 0 {
		return
	}
	used := int(length^)
	if used > 0 {
		if used + 1 > len(buffer) {
			return
		}
		buffer[used] = ' '
		used += 1
	}
	room := len(buffer) - used
	if room <= 0 {
		return
	}
	take := min(len(piece), room)
	if take < len(piece) {
		take = text_encoding.complete_characters(piece[:take])
	}
	if take == 0 {
		return
	}
	copy(buffer[used:], piece[:take])
	length^ = u16(used + take)
}

// semantic_tree_extract reconstructs the semantic tree directly from a draw
// table and its byte table. Each draw record and detail record is read once
// through volatile loads and checked at its border. On any refusal, tree is
// cleared to empty and problem_index identifies the offending record.
semantic_tree_extract :: proc "contextless" (records: []draw_record.Draw_Record, byte_table: []u8, tree: ^Semantic_Tree) -> (refusal: Semantic_Tree_Refusal, problem_index: int) {
	tree^ = {first_root = -1, focused_node = -1}

	fail :: proc "contextless" (t: ^Semantic_Tree, r: Semantic_Tree_Refusal, idx: int) -> (Semantic_Tree_Refusal, int) {
		t^ = {first_root = -1, focused_node = -1}
		return r, idx
	}

	stack: [draw_record.CLIP_DEPTH_LIMIT + ELEMENT_DEPTH_LIMIT]Extract_Stack_Entry
	stack_depth := 0
	clip_depth := 0
	element_depth := 0
	protected_depth := 0
	current_element: u32 = 0
	outermost_open := 0

	clip_boxes: [draw_record.CLIP_DEPTH_LIMIT]Semantic_Box
	element_node_stack: [ELEMENT_DEPTH_LIMIT]i32
	last_child_of: [SEMANTIC_TREE_NODE_CAPACITY]i32
	for &slot in last_child_of {
		slot = -1
	}
	last_root: i32 = -1

	// Buffers for accumulating content-derived names and live-region text
	// while elements are open.
	content_buffers: [ELEMENT_DEPTH_LIMIT][ELEMENT_NAME_LIMIT]u8
	content_lengths: [ELEMENT_DEPTH_LIMIT]u16
	live_buffers: [ELEMENT_DEPTH_LIMIT][ELEMENT_NAME_LIMIT]u8
	live_lengths: [ELEMENT_DEPTH_LIMIT]u16

	for record_index in 0 ..< len(records) {
		record := draw_record.copy_once(&records[record_index])
		kind, known := draw_record.draw_kind_of_word(record.kind)
		if !known {
			return fail(tree, .Record_Invalid, record_index)
		}

		// Check structural push/pop order and zero-element push before generic read.
		switch kind {
		case .Clip_Push:
			if clip_depth >= draw_record.CLIP_DEPTH_LIMIT {
				return fail(tree, .Push_Past_Depth_Limit, record_index)
			}
		case .Clip_Pop:
			if stack_depth == 0 {
				return fail(tree, .Pop_Without_Push, record_index)
			}
			if stack[stack_depth - 1].kind != .Clip {
				return fail(tree, .Pop_Wrong_Kind, record_index)
			}
		case .Element_Push:
			if record.element == 0 {
				return fail(tree, .Element_Word_Zero, record_index)
			}
			if element_depth >= ELEMENT_DEPTH_LIMIT {
				return fail(tree, .Push_Past_Depth_Limit, record_index)
			}
		case .Element_Pop:
			if stack_depth == 0 {
				return fail(tree, .Pop_Without_Push, record_index)
			}
			if stack[stack_depth - 1].kind != .Element {
				return fail(tree, .Pop_Wrong_Kind, record_index)
			}
		case .None, .Rectangle, .Text, .Picture, .Text_Grid, .Gradient, .Path:
		}

		primitive, problem := draw_record.read(record)
		if problem != .None {
			return fail(tree, .Record_Invalid, record_index)
		}

		// Enforce the element-word binding invariant for every record under an open push.
		if kind != .Element_Push && element_depth > 0 && record.element != 0 && record.element != current_element {
			return fail(tree, .Element_Word_Mismatch, record_index)
		}

		switch fields in primitive {
		case draw_record.Draw_Clip_Push:
			if stack_depth == 0 {
				outermost_open = record_index
			}
			box := Semantic_Box{
				left   = i32(draw_record.pixels_floor(record.left)),
				top    = i32(draw_record.pixels_floor(record.top)),
				right  = i32(draw_record.pixels_ceiling(record.right)),
				bottom = i32(draw_record.pixels_ceiling(record.bottom)),
			}
			clip_boxes[clip_depth] = clip_depth == 0 ? box : semantic_box_intersect(clip_boxes[clip_depth - 1], box)
			stack[stack_depth] = {kind = .Clip}
			stack_depth += 1
			clip_depth += 1

		case draw_record.Draw_Clip_Pop:
			stack_depth -= 1
			clip_depth -= 1

		case draw_record.Draw_Element_Push:
			if tree.node_count >= SEMANTIC_TREE_NODE_CAPACITY {
				return fail(tree, .Node_Capacity_Exceeded, record_index)
			}
			// Validate explicit accessible name bytes if present.
			if fields.name_count > 0 {
				if u64(fields.name_first) + u64(fields.name_count) > u64(len(byte_table)) {
					return fail(tree, .Name_Range_Out_Of_Bounds, record_index)
				}
				if !text_encoding.text_valid(byte_table[fields.name_first:][:fields.name_count]) {
					return fail(tree, .Name_Invalid_Text, record_index)
				}
			}
			// Validate detail range bounds and 4-byte offset alignment.
			if fields.detail_count > 0 {
				detail_bytes := u64(fields.detail_count) * ELEMENT_DETAIL_RECORD_SIZE
				if fields.detail_first % 4 != 0 || u64(fields.detail_first) + detail_bytes > u64(len(byte_table)) {
					return fail(tree, .Detail_Range_Out_Of_Bounds, record_index)
				}
			}

			node_index := i32(tree.node_count)
			tree.node_count += 1
			node := &tree.nodes[node_index]
			parent_index: i32 = element_depth > 0 ? element_node_stack[element_depth - 1] : -1

			box := Semantic_Box{
				left   = i32(draw_record.pixels_floor(record.left)),
				top    = i32(draw_record.pixels_floor(record.top)),
				right  = i32(draw_record.pixels_ceiling(record.right)),
				bottom = i32(draw_record.pixels_ceiling(record.bottom)),
			}
			clipped := clip_depth > 0 && semantic_box_empty(semantic_box_intersect(clip_boxes[clip_depth - 1], box))

			duplicate := semantic_tree_find_by_element(tree, record.element) >= 0
			effective_element := record.element
			effective_role := fields.role
			effective_states := fields.states
			if duplicate {
				// Second push with the same element word becomes an anonymous
				// group that takes no focus and no action.
				tree.duplicate_identities += 1
				effective_element = 0
				effective_role = .Group
				effective_states -= {.Focusable, .Focused}
			}

			effective_live := fields.live != .Off ? fields.live : element_role_default_live_mode(effective_role)

			node^ = {
				element       = effective_element,
				parent        = parent_index,
				first_child   = -1,
				next_sibling  = -1,
				record_index  = i32(record_index),
				box           = box,
				clipped       = clipped,
				role          = effective_role,
				live          = effective_live,
				explicit_live = fields.live,
				toggle        = fields.toggle,
				expanded      = fields.expanded,
				states        = effective_states,
			}

			if fields.name_count > 0 {
				nf, nc, ok := semantic_text_append(tree, byte_table[fields.name_first:][:fields.name_count])
				if !ok {
					return fail(tree, .Text_Capacity_Exceeded, record_index)
				}
				node.name_first, node.name_count = nf, nc
			}

			// Parse and attach each 16-byte detail record through its border.
			if fields.detail_count > 0 {
				for i in 0 ..< int(fields.detail_count) {
					offset := int(fields.detail_first) + i * ELEMENT_DETAIL_RECORD_SIZE
					raw := detail_record_copy_from_bytes(byte_table[offset:][:ELEMENT_DETAIL_RECORD_SIZE])
					detail, detail_refusal := element_detail_read(raw, byte_table)
					if detail_refusal != .None {
						return fail(tree, detail_refusal, record_index)
					}
					is_protected := .Protected in node.states
					switch detail.kind {
					case .Value_Now:
						if is_protected {
							node.protected_value_leaked = true
						} else {
							node.has_value_now = true
							node.value_now = i64(detail.value)
						}
					case .Value_Minimum:
						node.has_value_minimum = true
						node.value_minimum = i64(detail.value)
					case .Value_Maximum:
						node.has_value_maximum = true
						node.value_maximum = i64(detail.value)
					case .Value_Text:
						if is_protected {
							node.protected_value_leaked = true
						} else if detail.count > 0 {
							vf, vc, ok := semantic_text_append(tree, byte_table[detail.first:][:detail.count])
							if !ok {
								return fail(tree, .Text_Capacity_Exceeded, record_index)
							}
							node.value_text_first, node.value_text_count = vf, vc
						}
					case .Caret:
						if is_protected {
							node.protected_value_leaked = true
						} else {
							node.has_caret = true
							node.caret = detail.value
						}
					case .Selection_Start:
						if is_protected {
							node.protected_value_leaked = true
						} else {
							node.has_selection = true
							node.selection_start = detail.value
						}
					case .Selection_End:
						if is_protected {
							node.protected_value_leaked = true
						} else {
							node.has_selection = true
							node.selection_end = detail.value
						}
					case .Description:
						if detail.count > 0 {
							df, dc, ok := semantic_text_append(tree, byte_table[detail.first:][:detail.count])
							if !ok {
								return fail(tree, .Text_Capacity_Exceeded, record_index)
							}
							node.description_first, node.description_count = df, dc
						}
					case .Placeholder:
						if detail.count > 0 {
							pf, pc, ok := semantic_text_append(tree, byte_table[detail.first:][:detail.count])
							if !ok {
								return fail(tree, .Text_Capacity_Exceeded, record_index)
							}
							node.placeholder_first, node.placeholder_count = pf, pc
						}
					case .Key_Shortcuts:
						if detail.count > 0 {
							kf, kc, ok := semantic_text_append(tree, byte_table[detail.first:][:detail.count])
							if !ok {
								return fail(tree, .Text_Capacity_Exceeded, record_index)
							}
							node.key_shortcuts_first, node.key_shortcuts_count = kf, kc
						}
					case .Level:
						node.level = u16(min(detail.value, u64(max(u16))))
					case .Position_In_Set:
						node.position_in_set = u32(min(detail.value, u64(max(u32))))
					case .Set_Size:
						node.set_size = u32(min(detail.value, u64(max(u32))))
					case .Row_Index:
						node.row_index = u32(min(detail.value, u64(max(u32))))
					case .Row_Count:
						node.row_count = u32(min(detail.value, u64(max(u32))))
					case .Column_Index:
						node.column_index = u32(min(detail.value, u64(max(u32))))
					case .Column_Count:
						node.column_count = u32(min(detail.value, u64(max(u32))))
					case .Row_Span, .Column_Span, .Language:
						// Validated at the border; stored when a reader needs them.
					case .Orientation:
						node.orientation, _ = element_orientation_of_word(detail.value)
					case .Sort:
						node.sort, _ = element_sort_of_word(detail.value)
					case .Current:
						node.current, _ = element_current_of_word(detail.value)
					case .Has_Popup:
						node.has_popup, _ = element_popup_of_word(detail.value)
					case .Auto_Complete:
						node.auto_complete, _ = element_auto_complete_of_word(detail.value)
					case .Relevant:
						node.relevant, _ = element_relevant_of_word(detail.value)
					case .Actions:
						if !duplicate {
							actions, _ := element_actions_of_word(detail.value)
							if is_protected {
								actions -= {.Insert_Text}
							}
							node.actions = actions
						}
					case .Labelled_By, .Described_By, .Controls, .Details, .Error_Message, .Flow_To, .Active_Descendant:
						target := u32(detail.value)
						if int(node.relation_count) < SEMANTIC_NODE_RELATION_CAPACITY {
							node.relations[node.relation_count] = {kind = detail.kind, target = target}
							node.relation_count += 1
						}
						#partial switch detail.kind {
						case .Labelled_By:
							if node.labelled_by == 0 {
								node.labelled_by = target
							}
						case .Described_By:
							if node.described_by == 0 {
								node.described_by = target
							}
						case .Controls:
							if node.controls == 0 {
								node.controls = target
							}
						case .Active_Descendant:
							if node.active_descendant == 0 {
								node.active_descendant = target
							}
						}
					}
				}
			}

			if node.protected_value_leaked {
				tree.protected_value_leaks += 1
			}

			// Link node into tree hierarchy.
			if parent_index < 0 {
				if tree.first_root < 0 {
					tree.first_root = node_index
				} else {
					tree.nodes[last_root].next_sibling = node_index
				}
				last_root = node_index
			} else {
				if tree.nodes[parent_index].first_child < 0 {
					tree.nodes[parent_index].first_child = node_index
				} else {
					tree.nodes[last_child_of[parent_index]].next_sibling = node_index
				}
				last_child_of[parent_index] = node_index
			}

			if stack_depth == 0 {
				outermost_open = record_index
			}
			slot := element_depth
			content_lengths[slot] = 0
			live_lengths[slot] = 0
			is_protected := .Protected in node.states
			if is_protected {
				protected_depth += 1
			}
			stack[stack_depth] = {
				kind         = .Element,
				element_word = record.element,
				node_index   = node_index,
				element_slot = slot,
				is_protected = is_protected,
			}
			element_node_stack[element_depth] = node_index
			stack_depth += 1
			element_depth += 1
			current_element = record.element

		case draw_record.Draw_Element_Pop:
			entry := stack[stack_depth - 1]
			stack_depth -= 1
			element_depth -= 1
			if entry.is_protected {
				protected_depth -= 1
			}
			node := &tree.nodes[entry.node_index]
			slot := entry.element_slot
			if node.name_count == 0 && element_role_takes_name_from_content(node.role) && content_lengths[slot] > 0 {
				nf, nc, ok := semantic_text_append(tree, content_buffers[slot][:content_lengths[slot]])
				if !ok {
					return fail(tree, .Text_Capacity_Exceeded, record_index)
				}
				node.name_first, node.name_count = nf, nc
			}
			if node.live != .Off && live_lengths[slot] > 0 && .Protected not_in node.states {
				lf, lc, ok := semantic_text_append(tree, live_buffers[slot][:live_lengths[slot]])
				if !ok {
					return fail(tree, .Text_Capacity_Exceeded, record_index)
				}
				node.live_text_first, node.live_text_count = lf, lc
			}
			// Restore innermost open element word.
			current_element = 0
			for i := stack_depth - 1; i >= 0; i -= 1 {
				if stack[i].kind == .Element {
					current_element = stack[i].element_word
					break
				}
			}

		case draw_record.Draw_Text:
			if element_depth > 0 && protected_depth == 0 && fields.count > 0 {
				if u64(fields.first) + u64(fields.count) <= u64(len(byte_table)) {
					run := byte_table[fields.first:][:fields.count]
					if text_encoding.text_valid(run) {
						inner_slot := element_depth - 1
						inner_node := &tree.nodes[element_node_stack[inner_slot]]
						if inner_node.name_count == 0 && element_role_takes_name_from_content(inner_node.role) {
							append_joined_text(content_buffers[inner_slot][:], &content_lengths[inner_slot], run)
						}
						for slot in 0 ..< element_depth {
							ancestor := &tree.nodes[element_node_stack[slot]]
							if ancestor.live != .Off {
								append_joined_text(live_buffers[slot][:], &live_lengths[slot], run)
							}
						}
					}
				}
			}

		case draw_record.Draw_Nothing, draw_record.Draw_Rectangle, draw_record.Draw_Gradient, draw_record.Draw_Picture, draw_record.Draw_Text_Grid, draw_record.Draw_Path:
		}
	}

	if stack_depth != 0 {
		return fail(tree, .Push_Without_Pop, outermost_open)
	}

	// Pass 2: resolve same-frame relations, derive Labelled_By/Described_By
	// text, and record focus summary.
	for index in 0 ..< tree.node_count {
		node := &tree.nodes[index]
		if .Focusable in node.states {
			tree.focusable_count += 1
		}
		if .Focused in node.states && tree.focused_node < 0 {
			tree.focused_node = i32(index)
		}
		for r in 0 ..< int(node.relation_count) {
			target_index := semantic_tree_find_by_element(tree, node.relations[r].target)
			if target_index >= 0 {
				node.relations[r].resolved = true
			} else {
				node.unresolved_relations += 1
				tree.unresolved_relations += 1
			}
		}
	}

	// Resolve accessible name from Labelled_By and description from Described_By.
	for index in 0 ..< tree.node_count {
		node := &tree.nodes[index]
		if node.name_count == 0 && node.labelled_by != 0 {
			if target_index := semantic_tree_find_by_element(tree, node.labelled_by); target_index >= 0 {
				target := &tree.nodes[target_index]
				if target.name_count > 0 {
					node.name_first, node.name_count = target.name_first, target.name_count
				}
			}
		}
		if node.description_count == 0 && node.described_by != 0 {
			if target_index := semantic_tree_find_by_element(tree, node.described_by); target_index >= 0 {
				target := &tree.nodes[target_index]
				if target.name_count > 0 {
					node.description_first, node.description_count = target.name_first, target.name_count
				}
			}
		}
	}

	return .None, 0
}

// Semantic tree audit: checks structural validity and accessibility invariants.

Audit_Problem :: enum u8 {
	None                       = 0,
	Table_Refused              = 1, // Unmatched push/pop, depth past bound, invalid role/state/record word.
	Focusable_Without_Name     = 2, // A focusable node has an empty accessible name.
	Pressable_Without_Keyboard = 3, // A clickable/pressable node lacks a declared action or keyboard reachability.
	Focus_Count_Past_Limit     = 4, // More than SEMANTIC_FOCUS_LIMIT focusable nodes in one tree.
	Unresolved_Relation        = 5, // A relation detail named an element word absent from the frame.
	Protected_Field_Has_Value  = 6, // A Protected node attempted to publish a value, caret, or selection.
	Duplicate_Element_Identity = 7, // Two Element_Push records in one frame shared the same element word.
}

Audit_Finding :: struct {
	problem:      Audit_Problem,
	refusal:      Semantic_Tree_Refusal, // Non-None when problem == .Table_Refused.
	node_index:   i32,                   // Node index in Semantic_Tree, or -1.
	record_index: i32,                   // Draw record index, or -1.
	element:      u32,                   // Element word, or 0.
	role:         Element_Role,
}

@(private = "file")
audit_finding_emit :: proc "contextless" (findings: []Audit_Finding, total: ^int, finding: Audit_Finding) {
	if total^ < len(findings) {
		findings[total^] = finding
	}
	total^ += 1
}

@(private = "file")
has_focusable_composite_ancestor :: proc "contextless" (tree: ^Semantic_Tree, node_index: i32) -> bool {
	parent := tree.nodes[node_index].parent
	for steps := 0; parent >= 0 && parent < i32(tree.node_count) && steps < ELEMENT_DEPTH_LIMIT; steps += 1 {
		ancestor := &tree.nodes[parent]
		if element_role_is_composite(ancestor.role) && (.Focusable in ancestor.states || ancestor.key_shortcuts_count > 0) {
			return true
		}
		parent = ancestor.parent
	}
	return false
}

// semantic_tree_audit_nodes runs accessibility checks on an already-extracted
// Semantic_Tree and writes up to len(findings) findings, returning both the
// written count and total finding count.
semantic_tree_audit_nodes :: proc "contextless" (tree: ^Semantic_Tree, findings: []Audit_Finding) -> (written: int, total: int) {
	if tree.focusable_count > SEMANTIC_FOCUS_LIMIT {
		audit_finding_emit(findings, &total, {
			problem      = .Focus_Count_Past_Limit,
			node_index   = -1,
			record_index = -1,
		})
	}
	for index in 0 ..< tree.node_count {
		node := &tree.nodes[index]
		if node.element == 0 && tree.duplicate_identities > 0 {
			audit_finding_emit(findings, &total, {
				problem      = .Duplicate_Element_Identity,
				node_index   = i32(index),
				record_index = node.record_index,
				role         = node.role,
			})
		}
		if .Focusable in node.states && .Hidden not_in node.states && node.name_count == 0 {
			audit_finding_emit(findings, &total, {
				problem      = .Focusable_Without_Name,
				node_index   = i32(index),
				record_index = node.record_index,
				element      = node.element,
				role         = node.role,
			})
		}
		is_pressable := element_role_is_pressable(node.role) || (.Press in node.actions)
		if is_pressable && .Disabled not_in node.states && .Hidden not_in node.states {
			has_action := node.actions != {}
			has_keyboard := (.Focusable in node.states) || node.key_shortcuts_count > 0 || has_focusable_composite_ancestor(tree, i32(index))
			if !has_action || !has_keyboard {
				audit_finding_emit(findings, &total, {
					problem      = .Pressable_Without_Keyboard,
					node_index   = i32(index),
					record_index = node.record_index,
					element      = node.element,
					role         = node.role,
				})
			}
		}
		if node.unresolved_relations > 0 {
			audit_finding_emit(findings, &total, {
				problem      = .Unresolved_Relation,
				node_index   = i32(index),
				record_index = node.record_index,
				element      = node.element,
				role         = node.role,
			})
		}
		if node.protected_value_leaked {
			audit_finding_emit(findings, &total, {
				problem      = .Protected_Field_Has_Value,
				node_index   = i32(index),
				record_index = node.record_index,
				element      = node.element,
				role         = node.role,
			})
		}
	}
	return min(total, len(findings)), total
}

// semantic_tree_audit_into extracts the semantic tree from a draw table and
// audits both structural integrity and accessibility invariants into caller-
// provided storage.
semantic_tree_audit_into :: proc "contextless" (records: []draw_record.Draw_Record, byte_table: []u8, tree: ^Semantic_Tree, findings: []Audit_Finding) -> (written: int, total: int) {
	refusal, problem_index := semantic_tree_extract(records, byte_table, tree)
	if refusal != .None {
		audit_finding_emit(findings, &total, {
			problem      = .Table_Refused,
			refusal      = refusal,
			node_index   = -1,
			record_index = i32(problem_index),
		})
		return min(total, len(findings)), total
	}
	return semantic_tree_audit_nodes(tree, findings)
}

// Snapshot diffing: compares two semantic trees by element identity and
// produces typed assistive events.

Semantic_Event_Kind :: enum u8 {
	None              = 0,
	Focus_Changed     = 1,
	Name_Changed      = 2,
	State_Changed     = 3,
	Value_Changed     = 4,
	Live_Announcement = 5,
	Tree_Changed      = 6,
}

Semantic_Event :: struct {
	kind:         Semantic_Event_Kind,
	element:      u32,
	previous:     u32, // Previous focus element for Focus_Changed, or previous parent element for Tree_Changed.
	node_index:   i32, // Index in `now`, or -1.
	before_index: i32, // Index in `before`, or -1.
	role:         Element_Role,
	live:         Live_Mode,
	old_states:   Element_States,
	new_states:   Element_States,
	old_toggle:   Toggle_State,
	new_toggle:   Toggle_State,
	old_expanded: Expanded_State,
	new_expanded: Expanded_State,
}

@(private = "file")
event_emit :: proc "contextless" (events: []Semantic_Event, total: ^int, event: Semantic_Event) {
	if total^ < len(events) {
		events[total^] = event
	}
	total^ += 1
}

@(private = "file")
parent_element_of :: proc "contextless" (tree: ^Semantic_Tree, node: ^Semantic_Node) -> u32 {
	if node.parent < 0 || int(node.parent) >= tree.node_count {
		return 0
	}
	return tree.nodes[node.parent].element
}

@(private = "file")
effective_live_text :: proc "contextless" (tree: ^Semantic_Tree, node: ^Semantic_Node) -> string {
	if .Protected in node.states {
		return ""
	}
	if text := semantic_node_live_text(tree, node); len(text) > 0 {
		return text
	}
	return semantic_node_name(tree, node)
}

// semantic_tree_diff compares two Semantic_Tree snapshots by element identity
// and emits typed assistive events into events, returning (written, total).
semantic_tree_diff :: proc "contextless" (before, now: ^Semantic_Tree, events: []Semantic_Event) -> (written: int, total: int) {
	// Nodes removed since the previous frame.
	for i in 0 ..< before.node_count {
		old := &before.nodes[i]
		if old.element == 0 {
			continue
		}
		if semantic_tree_find_by_element(now, old.element) < 0 {
			event_emit(events, &total, {
				kind         = .Tree_Changed,
				element      = old.element,
				previous     = parent_element_of(before, old),
				node_index   = -1,
				before_index = i32(i),
				role         = old.role,
			})
		}
	}

	// Nodes added or updated in the new frame.
	for j in 0 ..< now.node_count {
		cur := &now.nodes[j]
		if cur.element == 0 {
			continue
		}
		old_index := semantic_tree_find_by_element(before, cur.element)
		if old_index < 0 {
			event_emit(events, &total, {
				kind         = .Tree_Changed,
				element      = cur.element,
				node_index   = i32(j),
				before_index = -1,
				role         = cur.role,
			})
			if cur.live != .Off && .Protected not_in cur.states && len(effective_live_text(now, cur)) > 0 {
				event_emit(events, &total, {
					kind         = .Live_Announcement,
					element      = cur.element,
					node_index   = i32(j),
					before_index = -1,
					role         = cur.role,
					live         = cur.live,
				})
			}
			continue
		}

		old := &before.nodes[old_index]
		old_parent := parent_element_of(before, old)
		cur_parent := parent_element_of(now, cur)
		if old_parent != cur_parent || old.role != cur.role {
			event_emit(events, &total, {
				kind         = .Tree_Changed,
				element      = cur.element,
				previous     = old_parent,
				node_index   = i32(j),
				before_index = old_index,
				role         = cur.role,
			})
		}

		if semantic_node_name(before, old) != semantic_node_name(now, cur) {
			event_emit(events, &total, {
				kind         = .Name_Changed,
				element      = cur.element,
				node_index   = i32(j),
				before_index = old_index,
				role         = cur.role,
			})
		}

		if old.states != cur.states || old.toggle != cur.toggle || old.expanded != cur.expanded {
			event_emit(events, &total, {
				kind         = .State_Changed,
				element      = cur.element,
				node_index   = i32(j),
				before_index = old_index,
				role         = cur.role,
				old_states   = old.states,
				new_states   = cur.states,
				old_toggle   = old.toggle,
				new_toggle   = cur.toggle,
				old_expanded = old.expanded,
				new_expanded = cur.expanded,
			})
		}

		if .Protected not_in old.states && .Protected not_in cur.states {
			value_changed := (old.has_value_now != cur.has_value_now) ||
				(old.has_value_now && old.value_now != cur.value_now) ||
				(semantic_node_value_text(before, old) != semantic_node_value_text(now, cur)) ||
				(old.has_caret != cur.has_caret) ||
				(old.has_caret && old.caret != cur.caret) ||
				(old.has_selection != cur.has_selection) ||
				(old.has_selection && (old.selection_start != cur.selection_start || old.selection_end != cur.selection_end))
			if value_changed {
				event_emit(events, &total, {
					kind         = .Value_Changed,
					element      = cur.element,
					node_index   = i32(j),
					before_index = old_index,
					role         = cur.role,
				})
			}
		}

		if cur.live != .Off && .Protected not_in cur.states {
			old_text := effective_live_text(before, old)
			cur_text := effective_live_text(now, cur)
			if len(cur_text) > 0 && old_text != cur_text {
				event_emit(events, &total, {
					kind         = .Live_Announcement,
					element      = cur.element,
					node_index   = i32(j),
					before_index = old_index,
					role         = cur.role,
					live         = cur.live,
				})
			}
		}
	}

	// Focus transition between snapshots.
	before_focus := before.focused_node >= 0 && int(before.focused_node) < before.node_count ? before.nodes[before.focused_node].element : 0
	now_focus := now.focused_node >= 0 && int(now.focused_node) < now.node_count ? now.nodes[now.focused_node].element : 0
	if before_focus != now_focus {
		role := Element_Role.None
		if now.focused_node >= 0 && int(now.focused_node) < now.node_count {
			role = now.nodes[now.focused_node].role
		}
		event_emit(events, &total, {
			kind         = .Focus_Changed,
			element      = now_focus,
			previous     = before_focus,
			node_index   = now.focused_node,
			before_index = before.focused_node,
			role         = role,
		})
	}

	return min(total, len(events)), total
}

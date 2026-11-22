// Freestanding semantic tree checker and widget query directly over a
// draw_record v20 draw table (src/md/features/accessibility.md, "6. The tests").
//
// Walks every Element_Push and Element_Pop subtree with fixed stack storage
// and zero allocations, reporting structured accessibility violations and
// supporting exact role/name/state widget queries directly against draw tables.
package accessibility

import "base:intrinsics"
import "modus:contract/draw_record"
import "modus:contract/enum_word"
import "modus:contract/text_encoding"

// Maximum structured audit violations stored inline in one Semantic_Audit_Report.
SEMANTIC_AUDIT_VIOLATION_CAPACITY :: 32

// Closed set of structured accessibility violations reported by
// semantic_tree_audit_table. Value 0 names no issue.
Semantic_Audit_Issue :: enum u8 {
	None                      = 0,
	Unbalanced_Element_Stack  = 1, // Unmatched Element_Pop/Clip_Pop, interleaved clip/element pop, depth past bound, or unclosed push.
	Missing_Focusable_Name    = 2, // A visible focusable element has an empty or whitespace-only accessible name.
	Missing_Keyboard_Action   = 3, // An enabled visible pressable element lacks a declared action or keyboard activation path.
	Duplicate_Focused_Element = 4, // More than one element in the same draw table carries Element_State.Focused.
	Invalid_Role_Word         = 5, // An Element_Push carried a role byte outside Element_Role.
	Invalid_State_Bits        = 6, // An Element_Push carried unknown bits outside ELEMENT_STATES_VALID_MASK.
}

// semantic_audit_issue_of_word is the single border converting a transport
// word into a Semantic_Audit_Issue member.
semantic_audit_issue_of_word :: proc "contextless" (word: u8) -> (issue: Semantic_Audit_Issue, ok: bool) {
	return enum_word.member_of_word(Semantic_Audit_Issue, u64(word))
}

// One structured violation discovered while inspecting a draw table.
Semantic_Audit_Violation :: struct {
	issue:        Semantic_Audit_Issue,
	record_index: i32,
	element:      u32,
	role:         Element_Role,
	raw_word:     u32, // Offending role byte or raw states bitmask when Invalid_Role_Word or Invalid_State_Bits.
}

// Fixed-capacity report returned by semantic_tree_audit_table.
Semantic_Audit_Report :: struct {
	violations:       [SEMANTIC_AUDIT_VIOLATION_CAPACITY]Semantic_Audit_Violation,
	violation_count:  int, // Number of violations stored in violations[:violation_count].
	total_violations: int, // Total violations discovered, even if exceeding SEMANTIC_AUDIT_VIOLATION_CAPACITY.
	element_count:    int,
	focused_count:    int,
}

// semantic_audit_report_ok reports whether the draw table passed with zero
// violations.
semantic_audit_report_ok :: proc "contextless" (report: ^Semantic_Audit_Report) -> bool {
	if report == nil {
		return false
	}
	return report.total_violations == 0
}

// semantic_audit_report_has_issue reports whether a stored violation in report
// carries the given issue.
semantic_audit_report_has_issue :: proc "contextless" (report: ^Semantic_Audit_Report, issue: Semantic_Audit_Issue) -> bool {
	if report == nil {
		return false
	}
	limit := min(report.violation_count, SEMANTIC_AUDIT_VIOLATION_CAPACITY)
	for index in 0 ..< limit {
		if report.violations[index].issue == issue {
			return true
		}
	}
	return false
}

// semantic_tree_audit dispatches both the full-tree caller-storage audit
// (semantic_tree_audit_into) and the direct zero-allocation table audit
// (semantic_tree_audit_table).
semantic_tree_audit :: proc {
	semantic_tree_audit_into,
	semantic_tree_audit_table,
}

// Exact match returned by semantic_query_element.
Semantic_Query_Match :: struct {
	found:        bool,
	element:      u32,
	record_index: i32,
	role:         Element_Role,
	states:       Element_States,
	toggle:       Toggle_State,
	expanded:     Expanded_State,
	live:         Live_Mode,
	actions:      Element_Actions,
	box:          Semantic_Box,
	clipped:      bool,
	name_bytes:   [ELEMENT_NAME_LIMIT]u8,
	name_len:     u16,
}

// semantic_query_match_name returns the matched element's accessible name as a
// string slice backed by match.name_bytes.
semantic_query_match_name :: proc "contextless" (match: ^Semantic_Query_Match) -> string {
	if match == nil || !match.found || int(match.name_len) > len(match.name_bytes) {
		return ""
	}
	return string(match.name_bytes[:match.name_len])
}

@(private = "file")
Check_Stack_Kind :: enum u8 {
	Clip    = 0,
	Element = 1,
}

@(private = "file")
Check_Stack_Frame :: struct {
	kind:         Check_Stack_Kind,
	record_index: i32,
	node_index:   i32,
	element_word: u32,
	is_protected: bool,
}

@(private = "file")
Audit_Node_Summary :: struct {
	element:                   u32,
	parent:                    i32,
	record_index:              i32,
	role:                      Element_Role,
	role_valid:                bool,
	states:                    Element_States,
	states_valid:              bool,
	actions:                   Element_Actions,
	has_explicit_name_field:   bool,
	has_non_whitespace_name:   bool,
	has_content_non_whitespace: bool,
	has_key_shortcuts:         bool,
	labelled_by:               u32,
}

@(private = "file")
audit_violation_emit :: proc "contextless" (report: ^Semantic_Audit_Report, violation: Semantic_Audit_Violation) {
	if report.violation_count < SEMANTIC_AUDIT_VIOLATION_CAPACITY {
		report.violations[report.violation_count] = violation
		report.violation_count += 1
	}
	report.total_violations += 1
}

@(private = "file")
text_has_non_whitespace :: proc "contextless" (bytes: []u8) -> bool {
	index := 0
	for index < len(bytes) {
		b := bytes[index]
		if b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == 0x0B || b == 0x0C {
			index += 1
			continue
		}
		// UTF-8 NBSP (U+00A0: C2 A0).
		if b == 0xC2 && index + 1 < len(bytes) && bytes[index + 1] == 0xA0 {
			index += 2
			continue
		}
		// UTF-8 ideographic space (U+3000: E3 80 80).
		if b == 0xE3 && index + 2 < len(bytes) && bytes[index + 1] == 0x80 && bytes[index + 2] == 0x80 {
			index += 3
			continue
		}
		return true
	}
	return false
}

@(private = "file")
raw_element_push_fields :: proc "contextless" (record: ^draw_record.Draw_Record) -> (fields: draw_record.Element_Push_Fields) {
	intrinsics.mem_copy_non_overlapping(&fields, &record.fields[0], size_of(draw_record.Element_Push_Fields))
	return fields
}

@(private = "file")
audit_has_focusable_composite_ancestor :: proc "contextless" (nodes: []Audit_Node_Summary, node_index: i32) -> bool {
	parent := nodes[node_index].parent
	for steps := 0; parent >= 0 && int(parent) < len(nodes) && steps < ELEMENT_DEPTH_LIMIT; steps += 1 {
		ancestor := &nodes[parent]
		if ancestor.role_valid && ancestor.states_valid && element_role_is_composite(ancestor.role) {
			if .Focusable in ancestor.states || ancestor.has_key_shortcuts {
				return true
			}
		}
		parent = ancestor.parent
	}
	return false
}

// semantic_tree_audit_table walks every Element_Push and Element_Pop subtree
// in a draw_record v20 table directly, returning structured accessibility
// violations with zero heap allocation.
semantic_tree_audit_table :: proc "contextless" (table: []draw_record.Draw_Record, text_bytes: []u8) -> (report: Semantic_Audit_Report) {
	stack: [draw_record.CLIP_DEPTH_LIMIT + ELEMENT_DEPTH_LIMIT]Check_Stack_Frame
	stack_depth := 0
	clip_depth := 0
	element_depth := 0
	protected_depth := 0

	nodes: [SEMANTIC_TREE_NODE_CAPACITY]Audit_Node_Summary
	node_count := 0
	element_node_stack: [ELEMENT_DEPTH_LIMIT]i32

	for record_index in 0 ..< len(table) {
		record := draw_record.copy_once(&table[record_index])
		kind, known := draw_record.draw_kind_of_word(record.kind)
		if !known {
			continue
		}

		switch kind {
		case .Clip_Push:
			if clip_depth >= draw_record.CLIP_DEPTH_LIMIT || stack_depth >= len(stack) {
				audit_violation_emit(&report, {
					issue        = .Unbalanced_Element_Stack,
					record_index = i32(record_index),
					element      = record.element,
				})
				continue
			}
			stack[stack_depth] = {
				kind         = .Clip,
				record_index = i32(record_index),
				node_index   = -1,
			}
			stack_depth += 1
			clip_depth += 1

		case .Clip_Pop:
			if stack_depth == 0 || stack[stack_depth - 1].kind != .Clip {
				audit_violation_emit(&report, {
					issue        = .Unbalanced_Element_Stack,
					record_index = i32(record_index),
					element      = record.element,
				})
				continue
			}
			stack_depth -= 1
			clip_depth -= 1

		case .Element_Push:
			raw := raw_element_push_fields(&record)
			role, role_ok := element_role_of_word(raw.role)
			if !role_ok {
				audit_violation_emit(&report, {
					issue        = .Invalid_Role_Word,
					record_index = i32(record_index),
					element      = record.element,
					raw_word     = u32(raw.role),
				})
			}
			states, states_ok := element_states_of_word(raw.states)
			if !states_ok {
				audit_violation_emit(&report, {
					issue        = .Invalid_State_Bits,
					record_index = i32(record_index),
					element      = record.element,
					role         = role_ok ? role : .None,
					raw_word     = raw.states,
				})
			}

			if element_depth >= ELEMENT_DEPTH_LIMIT || stack_depth >= len(stack) {
				audit_violation_emit(&report, {
					issue        = .Unbalanced_Element_Stack,
					record_index = i32(record_index),
					element      = record.element,
					role         = role_ok ? role : .None,
				})
				continue
			}

			report.element_count += 1
			if states_ok && (.Focused in states) {
				report.focused_count += 1
				if report.focused_count > 1 {
					audit_violation_emit(&report, {
						issue        = .Duplicate_Focused_Element,
						record_index = i32(record_index),
						element      = record.element,
						role         = role_ok ? role : .None,
					})
				}
			}

			node_index: i32 = -1
			if node_count < SEMANTIC_TREE_NODE_CAPACITY {
				node_index = i32(node_count)
				node_count += 1
				parent_index: i32 = element_depth > 0 ? element_node_stack[element_depth - 1] : -1
				summary := &nodes[node_index]
				summary^ = {
					element                 = record.element,
					parent                  = parent_index,
					record_index            = i32(record_index),
					role                    = role_ok ? role : .None,
					role_valid              = role_ok,
					states                  = states_ok ? states : {},
					states_valid            = states_ok,
					has_explicit_name_field = raw.name_count > 0,
				}

				if raw.name_count > 0 && raw.name_count <= ELEMENT_NAME_LIMIT {
					if u64(raw.name_first) + u64(raw.name_count) <= u64(len(text_bytes)) {
						slice := text_bytes[raw.name_first:][:raw.name_count]
						if text_encoding.text_valid(slice) && text_has_non_whitespace(slice) {
							summary.has_non_whitespace_name = true
						}
					}
				}

				if raw.detail_count > 0 && raw.detail_count <= ELEMENT_DETAIL_LIMIT && raw.detail_first % 4 == 0 {
					detail_bytes := u64(raw.detail_count) * ELEMENT_DETAIL_RECORD_SIZE
					if u64(raw.detail_first) + detail_bytes <= u64(len(text_bytes)) {
						for i in 0 ..< int(raw.detail_count) {
							offset := int(raw.detail_first) + i * ELEMENT_DETAIL_RECORD_SIZE
							raw_detail := detail_record_copy_from_bytes(text_bytes[offset:][:ELEMENT_DETAIL_RECORD_SIZE])
							detail, refusal := element_detail_read(raw_detail, text_bytes)
							if refusal != .None {
								continue
							}
							#partial switch detail.kind {
							case .Actions:
								actions, actions_ok := element_actions_of_word(detail.value)
								if actions_ok {
									if states_ok && (.Protected in states) {
										actions -= {.Insert_Text}
									}
									summary.actions = actions
								}
							case .Key_Shortcuts:
								if detail.count > 0 && text_has_non_whitespace(text_bytes[detail.first:][:detail.count]) {
									summary.has_key_shortcuts = true
								}
							case .Labelled_By:
								if summary.labelled_by == 0 {
									summary.labelled_by = u32(detail.value)
								}
							}
						}
					}
				}
			}

			is_protected := states_ok && (.Protected in states)
			if is_protected {
				protected_depth += 1
			}
			stack[stack_depth] = {
				kind         = .Element,
				record_index = i32(record_index),
				node_index   = node_index,
				element_word = record.element,
				is_protected = is_protected,
			}
			element_node_stack[element_depth] = node_index
			stack_depth += 1
			element_depth += 1

		case .Element_Pop:
			if stack_depth == 0 || stack[stack_depth - 1].kind != .Element {
				audit_violation_emit(&report, {
					issue        = .Unbalanced_Element_Stack,
					record_index = i32(record_index),
					element      = record.element,
				})
				continue
			}
			frame := stack[stack_depth - 1]
			stack_depth -= 1
			element_depth -= 1
			if frame.is_protected {
				protected_depth -= 1
			}
			if frame.node_index >= 0 {
				summary := &nodes[frame.node_index]
				if !summary.has_explicit_name_field && summary.role_valid && element_role_takes_name_from_content(summary.role) && summary.has_content_non_whitespace {
					summary.has_non_whitespace_name = true
				}
			}

		case .Text:
			if element_depth > 0 && protected_depth == 0 {
				primitive, problem := draw_record.read(record)
				if problem == .None {
					if text_prim, is_text := primitive.(draw_record.Draw_Text); is_text && text_prim.count > 0 {
						if u64(text_prim.first) + u64(text_prim.count) <= u64(len(text_bytes)) {
							run := text_bytes[text_prim.first:][:text_prim.count]
							if text_encoding.text_valid(run) && text_has_non_whitespace(run) {
								inner_idx := element_node_stack[element_depth - 1]
								if inner_idx >= 0 {
									nodes[inner_idx].has_content_non_whitespace = true
								}
							}
						}
					}
				}
			}

		case .None, .Rectangle, .Picture, .Text_Grid, .Gradient, .Path:
		}
	}

	// Report every unclosed Element_Push or Clip_Push still open at table end.
	for i in 0 ..< stack_depth {
		audit_violation_emit(&report, {
			issue        = .Unbalanced_Element_Stack,
			record_index = stack[i].record_index,
			element      = stack[i].element_word,
		})
	}

	// Resolve Labelled_By references before evaluating name and keyboard rules.
	for index in 0 ..< node_count {
		summary := &nodes[index]
		if !summary.has_non_whitespace_name && !summary.has_explicit_name_field && summary.labelled_by != 0 {
			for candidate in 0 ..< node_count {
				if nodes[candidate].element == summary.labelled_by && nodes[candidate].has_non_whitespace_name {
					summary.has_non_whitespace_name = true
					break
				}
			}
		}
	}

	// Evaluate per-element semantic invariants.
	for index in 0 ..< node_count {
		summary := &nodes[index]
		if !summary.role_valid || !summary.states_valid {
			continue
		}
		if .Hidden in summary.states {
			continue
		}
		if .Focusable in summary.states && !summary.has_non_whitespace_name {
			audit_violation_emit(&report, {
				issue        = .Missing_Focusable_Name,
				record_index = summary.record_index,
				element      = summary.element,
				role         = summary.role,
			})
		}
		is_pressable := element_role_is_pressable(summary.role) || (.Press in summary.actions)
		if is_pressable && .Disabled not_in summary.states {
			has_action := summary.actions != {}
			has_keyboard := (.Focusable in summary.states) || summary.has_key_shortcuts || audit_has_focusable_composite_ancestor(nodes[:node_count], i32(index))
			if !has_action || !has_keyboard {
				audit_violation_emit(&report, {
					issue        = .Missing_Keyboard_Action,
					record_index = summary.record_index,
					element      = summary.element,
					role         = summary.role,
				})
			}
		}
	}

	return report
}

@(private = "file")
QUERY_TEXT_BUFFER_CAPACITY :: 4096

@(private = "file")
Query_Node :: struct {
	element:      u32,
	record_index: i32,
	role:         Element_Role,
	live:         Live_Mode,
	toggle:       Toggle_State,
	expanded:     Expanded_State,
	states:       Element_States,
	actions:      Element_Actions,
	box:          Semantic_Box,
	clipped:      bool,
	name_first:   u32,
	name_count:   u16,
	labelled_by:  u32,
}

@(private = "file")
query_box_intersect :: proc "contextless" (a, b: Semantic_Box) -> Semantic_Box {
	return {
		left   = max(a.left, b.left),
		top    = max(a.top, b.top),
		right  = min(a.right, b.right),
		bottom = min(a.bottom, b.bottom),
	}
}

@(private = "file")
query_box_empty :: proc "contextless" (box: Semantic_Box) -> bool {
	return box.left >= box.right || box.top >= box.bottom
}

@(private = "file")
query_append_joined :: proc "contextless" (buffer: []u8, length: ^u16, piece: []u8) {
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

@(private = "file")
query_text_store :: proc "contextless" (text_buf: []u8, text_used: ^int, slice: []u8) -> (first: u32, count: u16, ok: bool) {
	if len(slice) == 0 {
		return 0, 0, true
	}
	if len(slice) > ELEMENT_NAME_LIMIT || text_used^ + len(slice) > len(text_buf) {
		return 0, 0, false
	}
	first = u32(text_used^)
	copy(text_buf[text_used^:], slice)
	text_used^ += len(slice)
	return first, u16(len(slice)), true
}

// semantic_query_element locates the first semantic element in a valid
// draw_record v20 table matching role, exact accessible name, required_states
// (subset check), and optional required_toggle (when non-None). Any malformed
// draw table (unbalanced stack, invalid role/state/record, out-of-bounds name
// or detail, element-word mismatch) is refused with ok == false.
semantic_query_element :: proc "contextless" (
	table: []draw_record.Draw_Record,
	text_bytes: []u8,
	role: Element_Role,
	name: string,
	required_states: Element_States = {},
	required_toggle: Toggle_State = .None,
) -> (match: Semantic_Query_Match, ok: bool) {
	if _, role_ok := element_role_of_word(u8(role)); !role_ok {
		return {}, false
	}
	if _, states_ok := element_states_of_word(transmute(u32)required_states); !states_ok {
		return {}, false
	}
	if _, toggle_ok := toggle_state_of_word(u8(required_toggle)); !toggle_ok {
		return {}, false
	}

	stack: [draw_record.CLIP_DEPTH_LIMIT + ELEMENT_DEPTH_LIMIT]Check_Stack_Frame
	stack_depth := 0
	clip_depth := 0
	element_depth := 0
	protected_depth := 0
	current_element: u32 = 0

	clip_boxes: [draw_record.CLIP_DEPTH_LIMIT]Semantic_Box
	element_node_stack: [ELEMENT_DEPTH_LIMIT]i32
	content_buffers: [ELEMENT_DEPTH_LIMIT][ELEMENT_NAME_LIMIT]u8
	content_lengths: [ELEMENT_DEPTH_LIMIT]u16

	nodes: [SEMANTIC_TREE_NODE_CAPACITY]Query_Node
	node_count := 0
	query_text: [QUERY_TEXT_BUFFER_CAPACITY]u8
	query_text_used := 0

	for record_index in 0 ..< len(table) {
		record := draw_record.copy_once(&table[record_index])
		kind, known := draw_record.draw_kind_of_word(record.kind)
		if !known {
			return {}, false
		}

		switch kind {
		case .Clip_Push:
			if clip_depth >= draw_record.CLIP_DEPTH_LIMIT {
				return {}, false
			}
		case .Clip_Pop:
			if stack_depth == 0 || stack[stack_depth - 1].kind != .Clip {
				return {}, false
			}
		case .Element_Push:
			if record.element == 0 || element_depth >= ELEMENT_DEPTH_LIMIT {
				return {}, false
			}
		case .Element_Pop:
			if stack_depth == 0 || stack[stack_depth - 1].kind != .Element {
				return {}, false
			}
		case .None, .Rectangle, .Text, .Picture, .Text_Grid, .Gradient, .Path:
		}

		primitive, problem := draw_record.read(record)
		if problem != .None {
			return {}, false
		}
		if kind != .Element_Push && element_depth > 0 && record.element != 0 && record.element != current_element {
			return {}, false
		}

		switch fields in primitive {
		case draw_record.Draw_Clip_Push:
			box := Semantic_Box{
				left   = i32(draw_record.pixels_floor(record.left)),
				top    = i32(draw_record.pixels_floor(record.top)),
				right  = i32(draw_record.pixels_ceiling(record.right)),
				bottom = i32(draw_record.pixels_ceiling(record.bottom)),
			}
			clip_boxes[clip_depth] = clip_depth == 0 ? box : query_box_intersect(clip_boxes[clip_depth - 1], box)
			stack[stack_depth] = {kind = .Clip, record_index = i32(record_index), node_index = -1}
			stack_depth += 1
			clip_depth += 1

		case draw_record.Draw_Clip_Pop:
			stack_depth -= 1
			clip_depth -= 1

		case draw_record.Draw_Element_Push:
			if node_count >= SEMANTIC_TREE_NODE_CAPACITY {
				return {}, false
			}
			if fields.name_count > 0 {
				if u64(fields.name_first) + u64(fields.name_count) > u64(len(text_bytes)) {
					return {}, false
				}
				if !text_encoding.text_valid(text_bytes[fields.name_first:][:fields.name_count]) {
					return {}, false
				}
			}
			if fields.detail_count > 0 {
				detail_bytes := u64(fields.detail_count) * ELEMENT_DETAIL_RECORD_SIZE
				if fields.detail_first % 4 != 0 || u64(fields.detail_first) + detail_bytes > u64(len(text_bytes)) {
					return {}, false
				}
			}

			duplicate := false
			for existing in 0 ..< node_count {
				if nodes[existing].element == record.element {
					duplicate = true
					break
				}
			}

			effective_element := duplicate ? u32(0) : record.element
			effective_role := duplicate ? Element_Role.Group : fields.role
			effective_states := duplicate ? (fields.states - {.Focusable, .Focused}) : fields.states
			effective_live := fields.live != .Off ? fields.live : element_role_default_live_mode(effective_role)

			box := Semantic_Box{
				left   = i32(draw_record.pixels_floor(record.left)),
				top    = i32(draw_record.pixels_floor(record.top)),
				right  = i32(draw_record.pixels_ceiling(record.right)),
				bottom = i32(draw_record.pixels_ceiling(record.bottom)),
			}
			clipped := clip_depth > 0 && query_box_empty(query_box_intersect(clip_boxes[clip_depth - 1], box))

			node_index := i32(node_count)
			node_count += 1
			node := &nodes[node_index]
			node^ = {
				element      = effective_element,
				record_index = i32(record_index),
				role         = effective_role,
				live         = effective_live,
				toggle       = fields.toggle,
				expanded     = fields.expanded,
				states       = effective_states,
				box          = box,
				clipped      = clipped,
			}

			if fields.name_count > 0 {
				nf, nc, stored := query_text_store(query_text[:], &query_text_used, text_bytes[fields.name_first:][:fields.name_count])
				if !stored {
					return {}, false
				}
				node.name_first, node.name_count = nf, nc
			}

			if fields.detail_count > 0 {
				is_protected := .Protected in node.states
				for i in 0 ..< int(fields.detail_count) {
					offset := int(fields.detail_first) + i * ELEMENT_DETAIL_RECORD_SIZE
					raw_detail := detail_record_copy_from_bytes(text_bytes[offset:][:ELEMENT_DETAIL_RECORD_SIZE])
					detail, refusal := element_detail_read(raw_detail, text_bytes)
					if refusal != .None {
						return {}, false
					}
					#partial switch detail.kind {
					case .Actions:
						if !duplicate {
							actions, _ := element_actions_of_word(detail.value)
							if is_protected {
								actions -= {.Insert_Text}
							}
							node.actions = actions
						}
					case .Labelled_By:
						if node.labelled_by == 0 {
							node.labelled_by = u32(detail.value)
						}
					}
				}
			}

			slot := element_depth
			content_lengths[slot] = 0
			is_protected := .Protected in node.states
			if is_protected {
				protected_depth += 1
			}
			stack[stack_depth] = {
				kind         = .Element,
				record_index = i32(record_index),
				node_index   = node_index,
				element_word = record.element,
				is_protected = is_protected,
			}
			element_node_stack[element_depth] = node_index
			stack_depth += 1
			element_depth += 1
			current_element = record.element

		case draw_record.Draw_Element_Pop:
			frame := stack[stack_depth - 1]
			stack_depth -= 1
			element_depth -= 1
			if frame.is_protected {
				protected_depth -= 1
			}
			node := &nodes[frame.node_index]
			slot := element_depth
			if node.name_count == 0 && element_role_takes_name_from_content(node.role) && content_lengths[slot] > 0 {
				nf, nc, stored := query_text_store(query_text[:], &query_text_used, content_buffers[slot][:content_lengths[slot]])
				if !stored {
					return {}, false
				}
				node.name_first, node.name_count = nf, nc
			}
			current_element = 0
			for i := stack_depth - 1; i >= 0; i -= 1 {
				if stack[i].kind == .Element {
					current_element = stack[i].element_word
					break
				}
			}

		case draw_record.Draw_Text:
			if element_depth > 0 && protected_depth == 0 && fields.count > 0 {
				if u64(fields.first) + u64(fields.count) <= u64(len(text_bytes)) {
					run := text_bytes[fields.first:][:fields.count]
					if text_encoding.text_valid(run) {
						inner_slot := element_depth - 1
						inner_node := &nodes[element_node_stack[inner_slot]]
						if inner_node.name_count == 0 && element_role_takes_name_from_content(inner_node.role) {
							query_append_joined(content_buffers[inner_slot][:], &content_lengths[inner_slot], run)
						}
					}
				}
			}

		case draw_record.Draw_Nothing, draw_record.Draw_Rectangle, draw_record.Draw_Gradient, draw_record.Draw_Picture, draw_record.Draw_Text_Grid, draw_record.Draw_Path:
		}
	}

	if stack_depth != 0 {
		return {}, false
	}

	// Resolve Labelled_By names within this frame.
	for index in 0 ..< node_count {
		node := &nodes[index]
		if node.name_count == 0 && node.labelled_by != 0 {
			for target in 0 ..< node_count {
				if nodes[target].element == node.labelled_by && nodes[target].name_count > 0 {
					node.name_first, node.name_count = nodes[target].name_first, nodes[target].name_count
					break
				}
			}
		}
	}

	// Find first node matching role, exact accessible name, required states,
	// and optional toggle state.
	for index in 0 ..< node_count {
		node := &nodes[index]
		if node.role != role {
			continue
		}
		if !(required_states <= node.states) {
			continue
		}
		if required_toggle != .None && node.toggle != required_toggle {
			continue
		}
		node_name := node.name_count > 0 ? string(query_text[node.name_first:][:node.name_count]) : ""
		if node_name != name {
			continue
		}
		result := Semantic_Query_Match{
			found        = true,
			element      = node.element,
			record_index = node.record_index,
			role         = node.role,
			states       = node.states,
			toggle       = node.toggle,
			expanded     = node.expanded,
			live         = node.live,
			actions      = node.actions,
			box          = node.box,
			clipped      = node.clipped,
			name_len     = node.name_count,
		}
		if node.name_count > 0 {
			copy(result.name_bytes[:node.name_count], query_text[node.name_first:][:node.name_count])
		}
		return result, true
	}

	return {}, false
}

// Semantic element push and pop writers for the interface package
// (src/md/features/accessibility.md, "1. The semantic tree").
//
// Each interactive or structural widget wraps its own draw calls with
// draw_element_push and draw_element_pop so the drawn pixels and the semantic
// tree come from one single pass over the draw table.
package interface

import "modus:contract/accessibility"
import "modus:contract/draw_record"
import "modus:contract/text_encoding"

// Options for draw_element_push: optional WAI-ARIA 1.2 states, explicit name,
// value/range, text caret, structural indices, and same-frame relations.
Element_Push_Options :: struct {
	live:              accessibility.Live_Mode,
	toggle:            accessibility.Toggle_State,
	expanded:          accessibility.Expanded_State,
	states:            accessibility.Element_States,
	actions:           accessibility.Element_Actions,
	name:              string, // Explicit accessible name; empty derives name from content or Labelled_By.
	description:       string,
	placeholder:       string,
	key_shortcuts:     string,
	value_text:        string, // Omitted automatically when .Protected is in states.
	has_value_now:     bool,
	value_now:         i64,
	has_value_minimum: bool,
	value_minimum:     i64,
	has_value_maximum: bool,
	value_maximum:     i64,
	has_caret:         bool,
	caret:             u64,
	level:             u16,
	position_in_set:   u32,
	set_size:          u32,
	row_index:         u32,
	row_count:         u32,
	column_index:      u32,
	column_count:      u32,
	orientation:       accessibility.Element_Orientation,
	has_popup:         accessibility.Element_Popup,
	labelled_by:       u32,
	described_by:      u32,
	controls:          u32,
	active_descendant: u32,
}

@(private = "file")
semantic_text_copy :: proc "contextless" (table: ^Draw_Table, text: string, limit: int) -> (first, count: u32, ok: bool) {
	if len(text) == 0 {
		return 0, 0, true
	}
	bytes := transmute([]u8)text
	take := min(len(bytes), limit)
	if take < len(bytes) {
		take = text_encoding.complete_characters(bytes[:take])
	}
	if take == 0 {
		return 0, 0, true
	}
	if !text_encoding.text_valid(bytes[:take]) {
		// Copy into a temporary buffer and replace invalid bytes with '?' so
		// the border always accepts the text cleanly.
		if table.text_count + take > len(table.text) {
			table.full = true
			return 0, 0, false
		}
		first = u32(table.text_count)
		copy(table.text[table.text_count:][:take], bytes[:take])
		text_encoding.invalid_sequences_replace(table.text[table.text_count:][:take])
		table.text_count += take
		return first, u32(take), true
	}
	if table.text_count + take > len(table.text) {
		table.full = true
		return 0, 0, false
	}
	first = u32(table.text_count)
	copy(table.text[table.text_count:][:take], bytes[:take])
	table.text_count += take
	return first, u32(take), true
}

// draw_element_push appends an Element_Push record for one semantic element.
// Its pop must be closed with draw_element_pop in strict LIFO order with any
// clips opened inside it. If element is 0, or nesting exceeds
// ELEMENT_DEPTH_LIMIT, or the table lacks room for both the push and its pop,
// nothing is written and the matching draw_element_pop is skipped safely.
draw_element_push :: proc "contextless" (table: ^Draw_Table, area: Area, element: u32, role: accessibility.Element_Role, options: Element_Push_Options = {}) {
	if table == nil {
		return
	}
	if element == 0 {
		table.refused = true
		table.element_pushes_not_written += 1
		return
	}
	if table.clip_pushes_not_written > 0 {
		table.refused = true
		table.element_pushes_not_written += 1
		return
	}
	if table.element_depth >= draw_record.ELEMENT_DEPTH_LIMIT {
		table.refused = true
		table.element_pushes_not_written += 1
		return
	}
	if table.element_pushes_not_written > 0 {
		table.element_pushes_not_written += 1
		return
	}
	// Reserve room for the push, its pop, and all currently open pops.
	if table.record_count + table.push_depth + 2 > len(table.records) {
		table.full = true
		table.element_pushes_not_written += 1
		return
	}

	saved_text_count := table.text_count
	rollback :: proc "contextless" (table: ^Draw_Table, saved: int) {
		table.text_count = saved
		table.element_pushes_not_written += 1
	}

	// Copy explicit accessible name if provided.
	name_first, name_count: u32
	if len(options.name) > 0 {
		ok: bool
		name_first, name_count, ok = semantic_text_copy(table, options.name, accessibility.ELEMENT_NAME_LIMIT)
		if !ok {
			rollback(table, saved_text_count)
			return
		}
	}

	// Assemble 16-byte detail records on the stack.
	details: [accessibility.ELEMENT_DETAIL_LIMIT]accessibility.Element_Detail_Record
	detail_count := 0
	detail_add :: proc "contextless" (details: ^[accessibility.ELEMENT_DETAIL_LIMIT]accessibility.Element_Detail_Record, count: ^int, record: accessibility.Element_Detail_Record) {
		if count^ < len(details) {
			details[count^] = record
			count^ += 1
		}
	}

	is_protected := .Protected in options.states
	actions := options.actions
	if is_protected {
		actions -= {.Insert_Text}
	}
	if actions != {} {
		detail_add(&details, &detail_count, accessibility.detail_actions_record(actions))
	}
	if !is_protected {
		if options.has_value_now {
			detail_add(&details, &detail_count, accessibility.detail_integer_record(.Value_Now, options.value_now))
		}
		if len(options.value_text) > 0 {
			vf, vc, ok := semantic_text_copy(table, options.value_text, accessibility.ELEMENT_DETAIL_TEXT_LIMIT)
			if !ok {
				rollback(table, saved_text_count)
				return
			}
			if vc > 0 {
				detail_add(&details, &detail_count, accessibility.detail_range_record(.Value_Text, vf, vc))
			}
		}
		if options.has_caret {
			detail_add(&details, &detail_count, accessibility.detail_unsigned_record(.Caret, options.caret))
		}
	}
	if options.has_value_minimum {
		detail_add(&details, &detail_count, accessibility.detail_integer_record(.Value_Minimum, options.value_minimum))
	}
	if options.has_value_maximum {
		detail_add(&details, &detail_count, accessibility.detail_integer_record(.Value_Maximum, options.value_maximum))
	}
	if len(options.description) > 0 {
		df, dc, ok := semantic_text_copy(table, options.description, accessibility.ELEMENT_DETAIL_TEXT_LIMIT)
		if !ok {
			rollback(table, saved_text_count)
			return
		}
		if dc > 0 {
			detail_add(&details, &detail_count, accessibility.detail_range_record(.Description, df, dc))
		}
	}
	if len(options.placeholder) > 0 {
		pf, pc, ok := semantic_text_copy(table, options.placeholder, accessibility.ELEMENT_DETAIL_TEXT_LIMIT)
		if !ok {
			rollback(table, saved_text_count)
			return
		}
		if pc > 0 {
			detail_add(&details, &detail_count, accessibility.detail_range_record(.Placeholder, pf, pc))
		}
	}
	if len(options.key_shortcuts) > 0 {
		kf, kc, ok := semantic_text_copy(table, options.key_shortcuts, accessibility.ELEMENT_DETAIL_TEXT_LIMIT)
		if !ok {
			rollback(table, saved_text_count)
			return
		}
		if kc > 0 {
			detail_add(&details, &detail_count, accessibility.detail_range_record(.Key_Shortcuts, kf, kc))
		}
	}
	if options.level > 0 {
		detail_add(&details, &detail_count, accessibility.detail_unsigned_record(.Level, u64(options.level)))
	}
	if options.position_in_set > 0 {
		detail_add(&details, &detail_count, accessibility.detail_unsigned_record(.Position_In_Set, u64(options.position_in_set)))
	}
	if options.set_size > 0 {
		detail_add(&details, &detail_count, accessibility.detail_unsigned_record(.Set_Size, u64(options.set_size)))
	}
	if options.row_index > 0 {
		detail_add(&details, &detail_count, accessibility.detail_unsigned_record(.Row_Index, u64(options.row_index)))
	}
	if options.row_count > 0 {
		detail_add(&details, &detail_count, accessibility.detail_unsigned_record(.Row_Count, u64(options.row_count)))
	}
	if options.column_index > 0 {
		detail_add(&details, &detail_count, accessibility.detail_unsigned_record(.Column_Index, u64(options.column_index)))
	}
	if options.column_count > 0 {
		detail_add(&details, &detail_count, accessibility.detail_unsigned_record(.Column_Count, u64(options.column_count)))
	}
	if options.orientation != .None {
		detail_add(&details, &detail_count, accessibility.detail_orientation_record(options.orientation))
	}
	if options.has_popup != .False {
		detail_add(&details, &detail_count, accessibility.detail_popup_record(options.has_popup))
	}
	if options.labelled_by != 0 {
		detail_add(&details, &detail_count, accessibility.detail_relation_record(.Labelled_By, options.labelled_by))
	}
	if options.described_by != 0 {
		detail_add(&details, &detail_count, accessibility.detail_relation_record(.Described_By, options.described_by))
	}
	if options.controls != 0 {
		detail_add(&details, &detail_count, accessibility.detail_relation_record(.Controls, options.controls))
	}
	if options.active_descendant != 0 {
		detail_add(&details, &detail_count, accessibility.detail_relation_record(.Active_Descendant, options.active_descendant))
	}

	detail_first: u32 = 0
	if detail_count > 0 {
		aligned := (table.text_count + 3) & ~int(3)
		bytes_needed := detail_count * accessibility.ELEMENT_DETAIL_RECORD_SIZE
		if aligned + bytes_needed > len(table.text) {
			table.full = true
			rollback(table, saved_text_count)
			return
		}
		src := ([^]u8)(&details[0])[:bytes_needed]
		copy(table.text[aligned:][:bytes_needed], src)
		table.text_count = aligned + bytes_needed
		detail_first = u32(aligned)
	}

	primitive := draw_record.Draw_Element_Push{
		role         = role,
		live         = options.live,
		toggle       = options.toggle,
		expanded     = options.expanded,
		states       = options.states,
		name_first   = name_first,
		name_count   = u16(name_count),
		detail_first = detail_first,
		detail_count = u16(detail_count),
	}
	table.records[table.record_count] = placed_record(primitive, element, area.x, area.y, max(area.width, 0), max(area.height, 0))
	table.record_count += 1
	table.element_depth += 1
	table.push_stack[table.push_depth] = .Element
	table.push_depth += 1
}

// draw_element_pop closes the innermost open Element_Push. A pop with no
// open Element_Push, or while a Clip_Push opened after it is still open, is
// not written and sets refused.
draw_element_pop :: proc "contextless" (table: ^Draw_Table) {
	if table == nil {
		return
	}
	if table.element_pushes_not_written > 0 {
		table.element_pushes_not_written -= 1
		return
	}
	if table.element_depth == 0 || table.push_depth == 0 || table.push_stack[table.push_depth - 1] != .Element {
		table.refused = true
		return
	}
	if table.record_count >= len(table.records) {
		table.full = true
		table.element_depth -= 1
		table.push_depth -= 1
		return
	}
	table.records[table.record_count] = draw_record.record_of(draw_record.Draw_Element_Pop{}, 0, 0, 0, 0, 0)
	table.record_count += 1
	table.element_depth -= 1
	table.push_depth -= 1
}

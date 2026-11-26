#+build !freestanding
#+build !modus
package draw_record

import "core:testing"

@(private = "file")
element_push_record :: proc(element: u32, role: Element_Role = .Button, left := 0, top := 0, right := 80, bottom := 24) -> Draw_Record {
	return record_of(Draw_Element_Push{role = role}, element, units_of_pixels(left), units_of_pixels(top), units_of_pixels(right), units_of_pixels(bottom))
}

@(private = "file")
element_pop_record :: proc(element: u32 = 0) -> Draw_Record {
	return record_of(Draw_Element_Pop{}, element, 0, 0, 0, 0)
}

@(private = "file")
clip_push_record :: proc(left, top, right, bottom: int, element: u32 = 0) -> Draw_Record {
	return record_of(Draw_Clip_Push{}, element, units_of_pixels(left), units_of_pixels(top), units_of_pixels(right), units_of_pixels(bottom))
}

@(private = "file")
clip_pop_record :: proc(element: u32 = 0) -> Draw_Record {
	return record_of(Draw_Clip_Pop{}, element, 0, 0, 0, 0)
}

@(private = "file")
solid_rectangle_record :: proc(element: u32 = 0) -> Draw_Record {
	return record_of(Draw_Rectangle{color = opaque(0x00102030)}, element, 0, 0, units_of_pixels(10), units_of_pixels(10))
}

// Every enum word past its bound is refused by the border converters; every
// valid member round-trips.
@(test)
element_border_converters_refuse_every_unknown_word :: proc(t: ^testing.T) {
	// Element_Role: 0..=max(Element_Role) valid, max+1..=255 refused.
	for word in 0 ..= 255 {
		role, ok := element_role_of_word(u8(word))
		if word <= int(max(Element_Role)) {
			testing.expectf(t, ok && u8(role) == u8(word), "valid role word %d was refused", word)
		} else {
			testing.expectf(t, !ok, "unknown role word %d was accepted as %v", word, role)
		}
	}
	// Live_Mode: 0..=2 valid, 3..=255 refused.
	for word in 0 ..= 255 {
		mode, ok := live_mode_of_word(u8(word))
		if word <= int(max(Live_Mode)) {
			testing.expectf(t, ok && u8(mode) == u8(word), "valid live mode %d was refused", word)
		} else {
			testing.expectf(t, !ok, "unknown live mode %d was accepted as %v", word, mode)
		}
	}
	// Toggle_State: 0..=3 valid, 4..=255 refused.
	for word in 0 ..= 255 {
		state, ok := toggle_state_of_word(u8(word))
		if word <= int(max(Toggle_State)) {
			testing.expectf(t, ok && u8(state) == u8(word), "valid toggle state %d was refused", word)
		} else {
			testing.expectf(t, !ok, "unknown toggle state %d was accepted as %v", word, state)
		}
	}
	// Expanded_State: 0..=2 valid, 3..=255 refused.
	for word in 0 ..= 255 {
		state, ok := expanded_state_of_word(u8(word))
		if word <= int(max(Expanded_State)) {
			testing.expectf(t, ok && u8(state) == u8(word), "valid expanded state %d was refused", word)
		} else {
			testing.expectf(t, !ok, "unknown expanded state %d was accepted as %v", word, state)
		}
	}
	// Element_States: every bit past max(Element_State) is refused.
	for bit in u32(max(Element_State)) + 1 ..< 32 {
		bad := u32(1) << bit
		_, ok := element_states_of_word(bad)
		testing.expectf(t, !ok, "unknown state bit %d (0x%08x) was accepted", bit, bad)
		_, ok = element_states_of_word(ELEMENT_STATES_VALID_MASK | bad)
		testing.expectf(t, !ok, "valid mask with unknown bit %d was accepted", bit)
	}
	_, all_ok := element_states_of_word(ELEMENT_STATES_VALID_MASK)
	testing.expect(t, all_ok, "valid state mask was refused")
	_, zero_ok := element_states_of_word(0)
	testing.expect(t, zero_ok, "empty state mask was refused")
}

// Element_Push refuses element == 0, unknown role/live/toggle/expanded/states,
// name_count > ELEMENT_NAME_LIMIT, detail_count > ELEMENT_DETAIL_LIMIT,
// non-zero first with zero count, unaligned detail_first, non-zero reserved
// bytes, and subpixel boxes.
@(test)
element_push_border_refuses_hostile_fields :: proc(t: ^testing.T) {
	base := element_push_record(1)
	kept := base
	_, base_problem := read(base)
	testing.expect_value(t, base_problem, Problem.None)
	testing.expect_value(t, base, kept)

	// Element word 0 is refused.
	zero_element := base
	zero_element.element = 0
	primitive, problem := read(zero_element)
	testing.expect(t, problem == .Field_Past_Bound && primitive == nil, "element word 0 must be refused")

	// Unknown role, live, toggle, expanded, and state bits are refused.
	bad_role := base
	bad_role.fields[offset_of(Element_Push_Fields, role)] = u8(max(Element_Role)) + 1
	primitive, problem = read(bad_role)
	testing.expect(t, problem == .Field_Past_Bound && primitive == nil, "unknown role word must be refused")

	bad_live := base
	bad_live.fields[offset_of(Element_Push_Fields, live)] = u8(max(Live_Mode)) + 1
	primitive, problem = read(bad_live)
	testing.expect(t, problem == .Field_Past_Bound && primitive == nil, "unknown live mode word must be refused")

	bad_toggle := base
	bad_toggle.fields[offset_of(Element_Push_Fields, toggle)] = u8(max(Toggle_State)) + 1
	primitive, problem = read(bad_toggle)
	testing.expect(t, problem == .Field_Past_Bound && primitive == nil, "unknown toggle word must be refused")

	bad_expanded := base
	bad_expanded.fields[offset_of(Element_Push_Fields, expanded)] = u8(max(Expanded_State)) + 1
	primitive, problem = read(bad_expanded)
	testing.expect(t, problem == .Field_Past_Bound && primitive == nil, "unknown expanded word must be refused")

	bad_states := base
	fields := transmute(Element_Push_Fields)bad_states.fields
	fields.states = u32(1) << (u32(max(Element_State)) + 1)
	bad_states.fields = transmute([FIELDS_SIZE]u8)fields
	primitive, problem = read(bad_states)
	testing.expect(t, problem == .Field_Past_Bound && primitive == nil, "unknown state bit must be refused")

	// Name count bounds and canonical zero first when count == 0.
	name_past := record_of(Draw_Element_Push{role = .Button, name_first = 0, name_count = ELEMENT_NAME_LIMIT + 1}, 1, 0, 0, units_of_pixels(10), units_of_pixels(10))
	primitive, problem = read(name_past)
	testing.expect(t, problem == .Field_Past_Bound && primitive == nil, "name_count past bound must be refused")

	name_nonzero_first := record_of(Draw_Element_Push{role = .Button, name_first = 4, name_count = 0}, 1, 0, 0, units_of_pixels(10), units_of_pixels(10))
	primitive, problem = read(name_nonzero_first)
	testing.expect(t, problem == .Field_Past_Bound && primitive == nil, "non-zero name_first with zero name_count must be refused")

	// Detail count bounds, alignment, and canonical zero first when count == 0.
	detail_past := record_of(Draw_Element_Push{role = .Button, detail_first = 0, detail_count = ELEMENT_DETAIL_LIMIT + 1}, 1, 0, 0, units_of_pixels(10), units_of_pixels(10))
	primitive, problem = read(detail_past)
	testing.expect(t, problem == .Field_Past_Bound && primitive == nil, "detail_count past bound must be refused")

	detail_nonzero_first := record_of(Draw_Element_Push{role = .Button, detail_first = 4, detail_count = 0}, 1, 0, 0, units_of_pixels(10), units_of_pixels(10))
	primitive, problem = read(detail_nonzero_first)
	testing.expect(t, problem == .Field_Past_Bound && primitive == nil, "non-zero detail_first with zero detail_count must be refused")

	for unaligned in ([3]u32{1, 2, 3}) {
		detail_bad_align := record_of(Draw_Element_Push{role = .Button, detail_first = unaligned, detail_count = 1}, 1, 0, 0, units_of_pixels(10), units_of_pixels(10))
		primitive, problem = read(detail_bad_align)
		testing.expectf(t, problem == .Field_Past_Bound && primitive == nil, "unaligned detail_first %d must be refused", unaligned)
	}

	// Exact bounds are accepted.
	at_bounds := record_of(Draw_Element_Push{
		role         = max(Element_Role),
		live         = max(Live_Mode),
		toggle       = max(Toggle_State),
		expanded     = max(Expanded_State),
		states       = transmute(Element_States)ELEMENT_STATES_VALID_MASK,
		name_first   = 7,
		name_count   = ELEMENT_NAME_LIMIT,
		detail_first = 12,
		detail_count = ELEMENT_DETAIL_LIMIT,
	}, max(u32), 0, 0, units_of_pixels(10), units_of_pixels(10))
	primitive, problem = read(at_bounds)
	_, is_push := primitive.(Draw_Element_Push)
	testing.expect(t, problem == .None && is_push, "valid Element_Push at exact bounds must be accepted")
}

// Element_Pop refuses any non-zero box edge or field byte, matching Clip_Pop.
@(test)
element_pop_border_refuses_nonzero_box_or_fields :: proc(t: ^testing.T) {
	values := [?]i32{1, UNITS_PER_PIXEL, COORDINATE_UNIT_LIMIT}
	for value in values {
		for side in 0 ..< 4 {
			record := element_pop_record()
			switch side {
			case 0:
				record.left, record.right = -value, 0
			case 1:
				record.top, record.bottom = -value, 0
			case 2:
				record.right = value
			case 3:
				record.bottom = value
			}
			primitive, problem := read(record)
			expected := on_whole_pixel(value) ? Problem.Reserved_Not_Zero : Problem.Box_Not_On_Whole_Pixels
			testing.expectf(t, problem == expected && primitive == nil, "Element_Pop edge %d at %d: %v", side, value, problem)
		}
	}
	bad_field := element_pop_record()
	bad_field.fields[23] = 1
	primitive, problem := read(bad_field)
	testing.expect(t, problem == .Reserved_Not_Zero && primitive == nil, "Element_Pop with non-zero field must be refused")

	primitive, problem = read(element_pop_record())
	_, is_pop := primitive.(Draw_Element_Pop)
	testing.expect(t, problem == .None && is_pop, "valid Element_Pop must be accepted")
}

// table_order_check refuses stray pop, unclosed push, depth past limit,
// interleaved clip/element pop, element word 0 on push, and mismatched element
// word under an open push, while accepting valid nested clip/element tables up
// to the exact depth limits.
@(test)
table_order_check_refuses_every_order_fault :: proc(t: ^testing.T) {
	// Stray Element_Pop at index 0.
	stray_pop := [1]Draw_Record{element_pop_record()}
	problem, index := table_order_check(stray_pop[:])
	testing.expect_value(t, problem, Table_Order_Problem.Pop_Without_Push)
	testing.expect_value(t, index, 0)

	// Unclosed Element_Push reports outermost open push.
	unclosed := [4]Draw_Record{
		element_push_record(10),
		element_pop_record(),
		element_push_record(20),
		solid_rectangle_record(20),
	}
	kept := unclosed
	problem, index = table_order_check(unclosed[:])
	testing.expect_value(t, problem, Table_Order_Problem.Push_Without_Pop)
	testing.expect_value(t, index, 2)
	testing.expect(t, unclosed == kept, "table_order_check must not mutate records")

	// Element_Push with element word 0 is refused.
	zero_word := [2]Draw_Record{element_push_record(0), element_pop_record()}
	problem, index = table_order_check(zero_word[:])
	testing.expect_value(t, problem, Table_Order_Problem.Element_Word_Zero)
	testing.expect_value(t, index, 0)

	// Depth past ELEMENT_DEPTH_LIMIT is refused at the overflowing push.
	too_deep: [ELEMENT_DEPTH_LIMIT + 1]Draw_Record
	for i in 0 ..= ELEMENT_DEPTH_LIMIT {
		too_deep[i] = element_push_record(u32(i + 1))
	}
	problem, index = table_order_check(too_deep[:])
	testing.expect_value(t, problem, Table_Order_Problem.Push_Past_Depth_Limit)
	testing.expect_value(t, index, ELEMENT_DEPTH_LIMIT)

	// Interleaved Element_Push -> Clip_Push -> Element_Pop -> Clip_Pop is refused.
	interleaved_a := [4]Draw_Record{
		element_push_record(1),
		clip_push_record(0, 0, 50, 50),
		element_pop_record(),
		clip_pop_record(),
	}
	problem, index = table_order_check(interleaved_a[:])
	testing.expect_value(t, problem, Table_Order_Problem.Pop_Wrong_Kind)
	testing.expect_value(t, index, 2)

	// Interleaved Clip_Push -> Element_Push -> Clip_Pop -> Element_Pop is refused.
	interleaved_b := [4]Draw_Record{
		clip_push_record(0, 0, 50, 50),
		element_push_record(1),
		clip_pop_record(),
		element_pop_record(),
	}
	problem, index = table_order_check(interleaved_b[:])
	testing.expect_value(t, problem, Table_Order_Problem.Pop_Wrong_Kind)
	testing.expect_value(t, index, 2)

	// Record carrying wrong element word under an open Element_Push is refused.
	mismatch := [3]Draw_Record{
		element_push_record(11),
		solid_rectangle_record(22),
		element_pop_record(),
	}
	problem, index = table_order_check(mismatch[:])
	testing.expect_value(t, problem, Table_Order_Problem.Element_Word_Mismatch)
	testing.expect_value(t, index, 1)

	// Nested child push followed by parent-tagged record inside child is refused.
	child_mismatch := [5]Draw_Record{
		element_push_record(11),
		element_push_record(22),
		solid_rectangle_record(11),
		element_pop_record(),
		element_pop_record(),
	}
	problem, index = table_order_check(child_mismatch[:])
	testing.expect_value(t, problem, Table_Order_Problem.Element_Word_Mismatch)
	testing.expect_value(t, index, 2)

	// Valid nested clips + elements up to exact depth bounds pass.
	valid: [2 * (ELEMENT_DEPTH_LIMIT + CLIP_DEPTH_LIMIT) + 3]Draw_Record
	count := 0
	for i in 0 ..< ELEMENT_DEPTH_LIMIT {
		valid[count] = element_push_record(u32(i + 1))
		count += 1
	}
	for _ in 0 ..< CLIP_DEPTH_LIMIT {
		valid[count] = clip_push_record(0, 0, 80, 24)
		count += 1
	}
	valid[count] = solid_rectangle_record(u32(ELEMENT_DEPTH_LIMIT))
	count += 1
	valid[count] = solid_rectangle_record(0)
	count += 1
	for _ in 0 ..< CLIP_DEPTH_LIMIT {
		valid[count] = clip_pop_record()
		count += 1
	}
	for _ in 0 ..< ELEMENT_DEPTH_LIMIT {
		valid[count] = element_pop_record()
		count += 1
	}
	problem, index = table_order_check(valid[:count])
	testing.expect_value(t, problem, Table_Order_Problem.None)
	testing.expect_value(t, index, 0)
}

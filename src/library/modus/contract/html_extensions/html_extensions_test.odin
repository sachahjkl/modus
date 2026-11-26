#+build !freestanding
#+build !modus
package html_extensions

import "core:testing"

@(test)
html_extensions_border_words :: proc(t: ^testing.T) {
	_, ok := html_namespace_of_word(3)
	testing.expect_value(t, ok, false)
	ns, ns_ok := html_namespace_of_word(u64(Html_Namespace.Svg))
	testing.expect_value(t, ns_ok, true)
	testing.expect_value(t, ns, Html_Namespace.Svg)

	_, ok = html_insertion_mode_of_word(99)
	testing.expect_value(t, ok, false)
	mode, mode_ok := html_insertion_mode_of_word(u64(Html_Insertion_Mode.In_Template))
	testing.expect_value(t, mode_ok, true)
	testing.expect_value(t, mode, Html_Insertion_Mode.In_Template)

	_, ok = html_quirks_mode_of_word(3)
	testing.expect_value(t, ok, false)
	q, q_ok := html_quirks_mode_of_word(u64(Html_Quirks_Mode.Limited_Quirks))
	testing.expect_value(t, q_ok, true)
	testing.expect_value(t, q, Html_Quirks_Mode.Limited_Quirks)
}

@(test)
doctype_quirks_classification :: proc(t: ^testing.T) {
	// Standard HTML5 DOCTYPE -> No_Quirks.
	testing.expect_value(t, doctype_classify_quirks({name = "html"}), Html_Quirks_Mode.No_Quirks)
	testing.expect_value(t, doctype_classify_quirks({name = "HTML"}), Html_Quirks_Mode.No_Quirks)

	// Force quirks or non-html name -> Quirks.
	testing.expect_value(t, doctype_classify_quirks({name = "html", force_quirks = true}), Html_Quirks_Mode.Quirks)
	testing.expect_value(t, doctype_classify_quirks({name = "svg"}), Html_Quirks_Mode.Quirks)
	testing.expect_value(t, doctype_classify_quirks({name = ""}), Html_Quirks_Mode.Quirks)

	// Legacy public and system IDs -> Quirks.
	testing.expect_value(t, doctype_classify_quirks({
		name          = "html",
		public_id     = "-//W3C//DTD HTML 4.0 Transitional//EN",
		has_public_id = true,
	}), Html_Quirks_Mode.Quirks)
	testing.expect_value(t, doctype_classify_quirks({
		name          = "html",
		system_id     = "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd",
		has_system_id = true,
	}), Html_Quirks_Mode.Quirks)

	// HTML 4.01 Transitional without system ID -> Quirks; with system ID -> Limited_Quirks.
	testing.expect_value(t, doctype_classify_quirks({
		name          = "html",
		public_id     = "-//W3C//DTD HTML 4.01 Transitional//EN",
		has_public_id = true,
		has_system_id = false,
	}), Html_Quirks_Mode.Quirks)
	testing.expect_value(t, doctype_classify_quirks({
		name          = "html",
		public_id     = "-//W3C//DTD HTML 4.01 Transitional//EN",
		has_public_id = true,
		system_id     = "http://www.w3.org/TR/html4/loose.dtd",
		has_system_id = true,
	}), Html_Quirks_Mode.Limited_Quirks)

	// XHTML 1.0 Transitional -> Limited_Quirks.
	testing.expect_value(t, doctype_classify_quirks({
		name          = "html",
		public_id     = "-//W3C//DTD XHTML 1.0 Transitional//EN",
		has_public_id = true,
	}), Html_Quirks_Mode.Limited_Quirks)
}

@(test)
insertion_mode_transitions_and_bounds :: proc(t: ^testing.T) {
	// Null state refusals.
	testing.expect_value(t, html_mode_on_doctype(nil, {name = "html"}), Html_Extension_Refusal.Null_State)
	testing.expect_value(t, html_mode_enter_template(nil), Html_Extension_Refusal.Null_State)
	testing.expect_value(t, html_mode_leave_template(nil), Html_Extension_Refusal.Null_State)
	testing.expect_value(t, html_mode_is_inert(nil), false)

	s := html_mode_init()
	testing.expect_value(t, s.mode, Html_Insertion_Mode.Initial)
	testing.expect_value(t, html_mode_enter_select(&s), Html_Extension_Refusal.Bad_Mode)
	testing.expect_value(t, html_mode_enter_foreign(&s, .Svg), Html_Extension_Refusal.Bad_Mode)
	testing.expect_value(t, html_mode_enter_frameset(&s), Html_Extension_Refusal.Bad_Mode)

	// DOCTYPE enters In_Body.
	testing.expect_value(t, html_mode_on_doctype(&s, {name = "html"}), Html_Extension_Refusal.None)
	testing.expect_value(t, s.mode, Html_Insertion_Mode.In_Body)
	testing.expect_value(t, html_mode_on_doctype(&s, {name = "html"}), Html_Extension_Refusal.Bad_Mode)

	// <frameset> allowed while frameset_ok is true.
	fs := s
	testing.expect_value(t, html_mode_enter_frameset(&fs), Html_Extension_Refusal.None)
	testing.expect_value(t, fs.mode, Html_Insertion_Mode.In_Frameset)
	testing.expect_value(t, html_mode_enter_select(&fs), Html_Extension_Refusal.Bad_Mode)

	// <template> nesting up to capacity + overflow refusal + clean pop back.
	for _ in 0 ..< TEMPLATE_MODE_STACK_CAPACITY {
		testing.expect_value(t, html_mode_enter_template(&s), Html_Extension_Refusal.None)
		testing.expect_value(t, html_mode_is_inert(&s), true)
	}
	testing.expect_value(t, html_mode_enter_template(&s), Html_Extension_Refusal.Stack_Overflow)
	testing.expect_value(t, s.template_depth, u16(TEMPLATE_MODE_STACK_CAPACITY))
	for _ in 0 ..< TEMPLATE_MODE_STACK_CAPACITY {
		testing.expect_value(t, html_mode_leave_template(&s), Html_Extension_Refusal.None)
	}
	testing.expect_value(t, html_mode_is_inert(&s), false)
	testing.expect_value(t, s.mode, Html_Insertion_Mode.In_Body)
	testing.expect_value(t, html_mode_leave_template(&s), Html_Extension_Refusal.Stack_Underflow)

	// <select> enter/leave disables frameset_ok and restores mode.
	testing.expect_value(t, html_mode_enter_select(&s), Html_Extension_Refusal.None)
	testing.expect_value(t, s.mode, Html_Insertion_Mode.In_Select)
	testing.expect_value(t, html_mode_leave_select(&s), Html_Extension_Refusal.None)
	testing.expect_value(t, s.mode, Html_Insertion_Mode.In_Body)
	testing.expect_value(t, html_mode_leave_select(&s), Html_Extension_Refusal.Stack_Underflow)
	testing.expect_value(t, html_mode_enter_frameset(&s), Html_Extension_Refusal.Bad_Mode)

	// Foreign content (SVG / MathML) transitions and refusals.
	testing.expect_value(t, html_mode_enter_foreign(&s, .Html), Html_Extension_Refusal.Bad_Namespace)
	testing.expect_value(t, html_mode_enter_foreign(&s, Html_Namespace(9)), Html_Extension_Refusal.Bad_Namespace)
	testing.expect_value(t, html_mode_enter_foreign(&s, .Svg), Html_Extension_Refusal.None)
	testing.expect_value(t, s.mode, Html_Insertion_Mode.In_Foreign_Content)
	testing.expect_value(t, s.ns, Html_Namespace.Svg)
	testing.expect_value(t, html_mode_leave_foreign(&s), Html_Extension_Refusal.None)
	testing.expect_value(t, s.mode, Html_Insertion_Mode.In_Body)
	testing.expect_value(t, s.ns, Html_Namespace.Html)
	testing.expect_value(t, html_mode_leave_foreign(&s), Html_Extension_Refusal.Bad_Mode)
}

@(test)
svg_mathml_case_adjustments_and_breakout :: proc(t: ^testing.T) {
	testing.expect_value(t, adjust_svg_tag_name("lineargradient"), "linearGradient")
	testing.expect_value(t, adjust_svg_tag_name("fegaussianblur"), "feGaussianBlur")
	testing.expect_value(t, adjust_svg_tag_name("foreignobject"), "foreignObject")
	testing.expect_value(t, adjust_svg_tag_name("path"), "path")

	testing.expect_value(t, adjust_svg_attribute_name("viewbox"), "viewBox")
	testing.expect_value(t, adjust_svg_attribute_name("preserveaspectratio"), "preserveAspectRatio")
	testing.expect_value(t, adjust_svg_attribute_name("fill"), "fill")

	testing.expect_value(t, adjust_mathml_attribute_name("definitionurl"), "definitionURL")
	testing.expect_value(t, adjust_mathml_attribute_name("mathvariant"), "mathvariant")

	testing.expect_value(t, html_foreign_breakout_tag("div"), true)
	testing.expect_value(t, html_foreign_breakout_tag("table"), true)
	testing.expect_value(t, html_foreign_breakout_tag("path"), false)
}

@(test)
script_data_escaped_and_double_escaped :: proc(t: ^testing.T) {
	// Plain script body.
	body1 := "var x = 1;</script>rest"
	cend, aend, st, ref := script_data_scan_end(body1)
	testing.expect_value(t, ref, Html_Extension_Refusal.None)
	testing.expect_value(t, st, Script_Data_State.Data)
	testing.expect_value(t, body1[:cend], "var x = 1;")
	testing.expect_value(t, body1[aend:], "rest")

	// Double-escaped nested <script>...</script> inside <!-- ... --> does NOT close outer script!
	body2 := "<!-- <script>var s = '</script>'; --> alert(1); </SCRIPT >after"
	cend, aend, st, ref = script_data_scan_end(body2)
	testing.expect_value(t, ref, Html_Extension_Refusal.None)
	testing.expect_value(t, st, Script_Data_State.Data)
	testing.expect_value(t, body2[:cend], "<!-- <script>var s = '</script>'; --> alert(1); ")
	testing.expect_value(t, body2[aend:], "after")

	// Truncated script inside escaped comment returns Script_Unterminated.
	body3 := "<!-- <script>var s = '</script>'"
	_, _, st, ref = script_data_scan_end(body3)
	testing.expect_value(t, ref, Html_Extension_Refusal.Script_Unterminated)
	testing.expect_value(t, st, Script_Data_State.Escaped)
}

@(test)
named_entities_sorted_and_decoded :: proc(t: ^testing.T) {
	// Verify table is strictly sorted so binary search can never miss an entry.
	for i in 1 ..< len(NAMED_ENTITIES) {
		testing.expect(t, NAMED_ENTITIES[i - 1].name < NAMED_ENTITIES[i].name)
	}

	// Every table entry must round-trip via binary search.
	for e in NAMED_ENTITIES {
		buf: [32]u8
		buf[0] = '&'
		copy(buf[1:], e.name)
		buf[1 + len(e.name)] = ';'
		r1, r2, ref := decode_named_entity(string(buf[:len(e.name) + 2]))
		testing.expect_value(t, ref, Html_Extension_Refusal.None)
		testing.expect_value(t, r1, e.codepoint)
		testing.expect_value(t, r2, e.second_codepoint)
	}

	// Spot-check key WHATWG entities and UTF-8 encoding.
	utf8_buf: [8]u8
	n, ref := decode_entity_to_utf8("&euro;", utf8_buf[:])
	testing.expect_value(t, ref, Html_Extension_Refusal.None)
	testing.expect_value(t, string(utf8_buf[:n]), "€")

	n, ref = decode_entity_to_utf8("&mdash;", utf8_buf[:])
	testing.expect_value(t, ref, Html_Extension_Refusal.None)
	testing.expect_value(t, string(utf8_buf[:n]), "—")

	// Undersized output buffer refuses without mutating caller buffer.
	tiny := [2]u8{0xAA, 0xBB}
	n, ref = decode_entity_to_utf8("&euro;", tiny[:])
	testing.expect_value(t, ref, Html_Extension_Refusal.Buffer_Too_Small)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, tiny[0], u8(0xAA))
	testing.expect_value(t, tiny[1], u8(0xBB))

	// Malformed and unknown entity refusals.
	_, _, ref = decode_named_entity("")
	testing.expect_value(t, ref, Html_Extension_Refusal.Entity_Malformed)
	_, _, ref = decode_named_entity("&;")
	testing.expect_value(t, ref, Html_Extension_Refusal.Entity_Malformed)
	_, _, ref = decode_named_entity("&amp")
	testing.expect_value(t, ref, Html_Extension_Refusal.Entity_Malformed)
	_, _, ref = decode_named_entity("amp;")
	testing.expect_value(t, ref, Html_Extension_Refusal.Entity_Malformed)
	_, _, ref = decode_named_entity("&a-b;")
	testing.expect_value(t, ref, Html_Extension_Refusal.Entity_Malformed)
	_, _, ref = decode_named_entity("&notanentity;")
	testing.expect_value(t, ref, Html_Extension_Refusal.Entity_Unknown)
}

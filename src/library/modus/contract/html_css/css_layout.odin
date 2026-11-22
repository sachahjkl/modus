// CSS subset parser, cascade and inheritance resolver, block/inline/flex layout engine,
// and modus draw_record emitter. Pure freestanding zero-allocation contract code.
package html_css

import "modus:contract/draw_record"

MAX_CSS_RULES :: 128
MAX_SELECTORS_PER_RULE :: 8
MAX_SELECTOR_NAME_LEN :: 64
MAX_LAYOUT_COORD :: 65536
DEFAULT_FONT_SIZE :: i32(16)
DEFAULT_TEXT_COLOR :: draw_record.Draw_Color(0xFF000000)

// CSS display modes supported by the layout engine.
Display_Mode :: enum u8 {
	Block  = 1,
	Inline = 2,
	Flex   = 3,
	None   = 4,
}

// CSS flex-direction options.
Flex_Direction :: enum u8 {
	Row    = 1,
	Column = 2,
}

// Compound simple selector (optional tag + optional class + optional id).
Css_Selector :: struct {
	has_tag:     bool,
	tag:         Html_Tag,
	class_name:  [MAX_SELECTOR_NAME_LEN]u8,
	class_len:   u8,
	id_name:     [MAX_SELECTOR_NAME_LEN]u8,
	id_len:      u8,
	specificity: u32,
	valid:       bool,
}

// Sparse set of CSS declarations from one rule or inline style attribute.
Css_Declarations :: struct {
	has_display:          bool,
	display:              Display_Mode,
	has_flex_direction:   bool,
	flex_direction:       Flex_Direction,
	has_gap:              bool,
	gap:                  i32,
	has_width:            bool,
	width:                i32,
	has_height:           bool,
	height:               i32,
	has_margin_top:       bool,
	margin_top:           i32,
	has_margin_right:     bool,
	margin_right:         i32,
	has_margin_bottom:    bool,
	margin_bottom:        i32,
	has_margin_left:      bool,
	margin_left:          i32,
	has_padding_top:      bool,
	padding_top:          i32,
	has_padding_right:    bool,
	padding_right:        i32,
	has_padding_bottom:   bool,
	padding_bottom:       i32,
	has_padding_left:     bool,
	padding_left:         i32,
	has_color:            bool,
	color:                draw_record.Draw_Color,
	has_background_color: bool,
	background_color:     draw_record.Draw_Color,
	has_font_size:        bool,
	font_size:            i32,
}

// One parsed CSS rule with selector list, declarations, and source order.
Css_Rule :: struct {
	selectors:      [MAX_SELECTORS_PER_RULE]Css_Selector,
	selector_count: u8,
	decls:          Css_Declarations,
	order:          u16,
}

// Fixed-capacity stylesheet parsed from CSS text.
Css_Stylesheet :: struct {
	rules:      [MAX_CSS_RULES]Css_Rule,
	rule_count: u16,
}

// Final cascaded and inherited style for one DOM node.
Computed_Style :: struct {
	display:          Display_Mode,
	flex_direction:   Flex_Direction,
	gap:              i32,
	has_width:        bool,
	width:            i32,
	has_height:       bool,
	height:           i32,
	margin_top:       i32,
	margin_right:     i32,
	margin_bottom:    i32,
	margin_left:      i32,
	padding_top:      i32,
	padding_right:    i32,
	padding_bottom:   i32,
	padding_left:     i32,
	color:            draw_record.Draw_Color,
	background_color: draw_record.Draw_Color,
	font_size:        i32,
}

// Computed pixel geometry for one visible DOM node.
Layout_Box :: struct {
	used:           bool,
	node_index:     u16,
	parent_box:     u16,
	first_child:    u16,
	last_child:     u16,
	next_sibling:   u16,
	x:              i32,
	y:              i32,
	width:          i32,
	height:         i32,
	content_x:      i32,
	content_y:      i32,
	content_width:  i32,
	content_height: i32,
	display:        Display_Mode,
	style:          Computed_Style,
	is_text:        bool,
}

// Fixed-capacity layout tree produced by compute_layout.
Layout_Tree :: struct {
	boxes:     [MAX_DOM_NODES]Layout_Box,
	box_count: u16,
	root_box:  u16,
}

// CSS parsing helpers.

@(private = "file")
css_trim :: proc "contextless" (s: []u8) -> []u8 {
	start := 0
	for start < len(s) && html_is_space(s[start]) {
		start += 1
	}
	end := len(s)
	for end > start && html_is_space(s[end - 1]) {
		end -= 1
	}
	return s[start:end]
}

@(private = "file")
css_skip_ws_and_comments :: proc "contextless" (src: []u8, pos: ^int) {
	for pos^ < len(src) {
		if html_is_space(src[pos^]) {
			pos^ += 1
			continue
		}
		if pos^ + 1 < len(src) && src[pos^] == '/' && src[pos^ + 1] == '*' {
			pos^ += 2
			for pos^ + 1 < len(src) && !(src[pos^] == '*' && src[pos^ + 1] == '/') {
				pos^ += 1
			}
			if pos^ + 1 < len(src) {
				pos^ += 2
			} else {
				pos^ = len(src)
			}
			continue
		}
		break
	}
}

@(private = "file")
parse_px_value :: proc "contextless" (raw: []u8) -> (px: i32, ok: bool) {
	s := css_trim(raw)
	if len(s) == 0 {
		return 0, false
	}
	if len(s) >= 2 && html_ascii_lower(s[len(s) - 2]) == 'p' && html_ascii_lower(s[len(s) - 1]) == 'x' {
		s = s[:len(s) - 2]
	}
	if len(s) == 0 {
		return 0, false
	}
	neg := false
	idx := 0
	if s[0] == '-' {
		neg = true
		idx = 1
	} else if s[0] == '+' {
		idx = 1
	}
	if idx >= len(s) {
		return 0, false
	}
	val: i64 = 0
	for i := idx; i < len(s); i += 1 {
		b := s[i]
		if b < '0' || b > '9' {
			return 0, false
		}
		if val < MAX_LAYOUT_COORD {
			val = val * 10 + i64(b - '0')
		}
	}
	if val > MAX_LAYOUT_COORD {
		val = MAX_LAYOUT_COORD
	}
	res := i32(-val) if neg else i32(val)
	return res, true
}

@(private = "file")
hex_nibble :: proc "contextless" (b: u8) -> (v: u8, ok: bool) {
	switch {
	case b >= '0' && b <= '9': return b - '0', true
	case b >= 'a' && b <= 'f': return b - 'a' + 10, true
	case b >= 'A' && b <= 'F': return b - 'A' + 10, true
	}
	return 0, false
}

// parse_css_color parses #RGB, #RRGGBB, #RRGGBBAA, rgb(r,g,b), and basic named colors.
parse_css_color :: proc "contextless" (raw: []u8) -> (color: draw_record.Draw_Color, ok: bool) {
	s := css_trim(raw)
	if len(s) == 0 {
		return 0, false
	}
	if s[0] == '#' {
		hex := s[1:]
		switch len(hex) {
		case 3:
			r, ok1 := hex_nibble(hex[0])
			g, ok2 := hex_nibble(hex[1])
			b, ok3 := hex_nibble(hex[2])
			if !ok1 || !ok2 || !ok3 {
				return 0, false
			}
			rgb := u32(r * 17) << 16 | u32(g * 17) << 8 | u32(b * 17)
			return draw_record.opaque(rgb), true
		case 6:
			r1, ok1 := hex_nibble(hex[0]); r2, ok2 := hex_nibble(hex[1])
			g1, ok3 := hex_nibble(hex[2]); g2, ok4 := hex_nibble(hex[3])
			b1, ok5 := hex_nibble(hex[4]); b2, ok6 := hex_nibble(hex[5])
			if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 || !ok6 {
				return 0, false
			}
			rgb := u32((r1 << 4) | r2) << 16 | u32((g1 << 4) | g2) << 8 | u32((b1 << 4) | b2)
			return draw_record.opaque(rgb), true
		case 8:
			r1, ok1 := hex_nibble(hex[0]); r2, ok2 := hex_nibble(hex[1])
			g1, ok3 := hex_nibble(hex[2]); g2, ok4 := hex_nibble(hex[3])
			b1, ok5 := hex_nibble(hex[4]); b2, ok6 := hex_nibble(hex[5])
			a1, ok7 := hex_nibble(hex[6]); a2, ok8 := hex_nibble(hex[7])
			if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 || !ok6 || !ok7 || !ok8 {
				return 0, false
			}
			rgb := u32((r1 << 4) | r2) << 16 | u32((g1 << 4) | g2) << 8 | u32((b1 << 4) | b2)
			a := (a1 << 4) | a2
			return draw_record.with_alpha(rgb, a), true
		}
		return 0, false
	}

	if len(s) >= 6 && html_ascii_eq_ci(s[:4], "rgb(") && s[len(s) - 1] == ')' {
		inner := s[4 : len(s) - 1]
		parts: [3]i32
		pcount := 0
		pos := 0
		for pos < len(inner) && pcount < 3 {
			c := pos
			for c < len(inner) && inner[c] != ',' {
				c += 1
			}
			v, vok := parse_px_value(inner[pos:c])
			if !vok || v < 0 || v > 255 {
				return 0, false
			}
			parts[pcount] = v
			pcount += 1
			pos = c + 1
		}
		if pcount == 3 {
			rgb := u32(parts[0]) << 16 | u32(parts[1]) << 8 | u32(parts[2])
			return draw_record.opaque(rgb), true
		}
		return 0, false
	}

	switch {
	case html_ascii_eq_ci(s, "transparent"): return 0, true
	case html_ascii_eq_ci(s, "black"):       return draw_record.opaque(0x000000), true
	case html_ascii_eq_ci(s, "white"):       return draw_record.opaque(0xFFFFFF), true
	case html_ascii_eq_ci(s, "red"):         return draw_record.opaque(0xFF0000), true
	case html_ascii_eq_ci(s, "green"):       return draw_record.opaque(0x008000), true
	case html_ascii_eq_ci(s, "blue"):        return draw_record.opaque(0x0000FF), true
	case html_ascii_eq_ci(s, "gray"), html_ascii_eq_ci(s, "grey"):
		return draw_record.opaque(0x808080), true
	case html_ascii_eq_ci(s, "yellow"):      return draw_record.opaque(0xFFFF00), true
	case html_ascii_eq_ci(s, "cyan"):        return draw_record.opaque(0x00FFFF), true
	case html_ascii_eq_ci(s, "magenta"):     return draw_record.opaque(0xFF00FF), true
	}
	return 0, false
}

@(private = "file")
parse_box_shorthand :: proc "contextless" (raw: []u8) -> (top, right, bottom, left: i32, ok: bool) {
	vals: [4]i32
	count := 0
	pos := 0
	for pos < len(raw) && count < 4 {
		for pos < len(raw) && html_is_space(raw[pos]) {
			pos += 1
		}
		if pos >= len(raw) {
			break
		}
		start := pos
		for pos < len(raw) && !html_is_space(raw[pos]) {
			pos += 1
		}
		v, vok := parse_px_value(raw[start:pos])
		if !vok {
			return 0, 0, 0, 0, false
		}
		vals[count] = v
		count += 1
	}
	switch count {
	case 1:
		return vals[0], vals[0], vals[0], vals[0], true
	case 2:
		return vals[0], vals[1], vals[0], vals[1], true
	case 3:
		return vals[0], vals[1], vals[2], vals[1], true
	case 4:
		return vals[0], vals[1], vals[2], vals[3], true
	}
	return 0, 0, 0, 0, false
}

// parse_declarations parses CSS "prop: val; ..." declarations into Css_Declarations.
parse_declarations :: proc "contextless" (raw: []u8) -> Css_Declarations {
	d: Css_Declarations
	pos := 0
	for pos < len(raw) {
		css_skip_ws_and_comments(raw, &pos)
		if pos >= len(raw) {
			break
		}
		semi := pos
		for semi < len(raw) && raw[semi] != ';' {
			semi += 1
		}
		decl := css_trim(raw[pos:semi])
		pos = semi + 1
		if len(decl) == 0 {
			continue
		}
		colon := -1
		for i := 0; i < len(decl); i += 1 {
			if decl[i] == ':' {
				colon = i
				break
			}
		}
		if colon <= 0 {
			continue
		}
		prop := css_trim(decl[:colon])
		val := css_trim(decl[colon + 1:])
		if len(prop) == 0 || len(val) == 0 {
			continue
		}

		switch {
		case html_ascii_eq_ci(prop, "display"):
			switch {
			case html_ascii_eq_ci(val, "block"):  d.has_display = true; d.display = .Block
			case html_ascii_eq_ci(val, "inline"): d.has_display = true; d.display = .Inline
			case html_ascii_eq_ci(val, "flex"):   d.has_display = true; d.display = .Flex
			case html_ascii_eq_ci(val, "none"):   d.has_display = true; d.display = .None
			}
		case html_ascii_eq_ci(prop, "flex-direction"):
			switch {
			case html_ascii_eq_ci(val, "row"):    d.has_flex_direction = true; d.flex_direction = .Row
			case html_ascii_eq_ci(val, "column"): d.has_flex_direction = true; d.flex_direction = .Column
			}
		case html_ascii_eq_ci(prop, "gap"):
			if v, ok := parse_px_value(val); ok && v >= 0 {
				d.has_gap = true
				d.gap = v
			}
		case html_ascii_eq_ci(prop, "width"):
			if v, ok := parse_px_value(val); ok && v >= 0 {
				d.has_width = true
				d.width = v
			}
		case html_ascii_eq_ci(prop, "height"):
			if v, ok := parse_px_value(val); ok && v >= 0 {
				d.has_height = true
				d.height = v
			}
		case html_ascii_eq_ci(prop, "margin"):
			if mt, mr, mb, ml, ok := parse_box_shorthand(val); ok {
				d.has_margin_top = true; d.margin_top = mt
				d.has_margin_right = true; d.margin_right = mr
				d.has_margin_bottom = true; d.margin_bottom = mb
				d.has_margin_left = true; d.margin_left = ml
			}
		case html_ascii_eq_ci(prop, "margin-top"):
			if v, ok := parse_px_value(val); ok { d.has_margin_top = true; d.margin_top = v }
		case html_ascii_eq_ci(prop, "margin-right"):
			if v, ok := parse_px_value(val); ok { d.has_margin_right = true; d.margin_right = v }
		case html_ascii_eq_ci(prop, "margin-bottom"):
			if v, ok := parse_px_value(val); ok { d.has_margin_bottom = true; d.margin_bottom = v }
		case html_ascii_eq_ci(prop, "margin-left"):
			if v, ok := parse_px_value(val); ok { d.has_margin_left = true; d.margin_left = v }
		case html_ascii_eq_ci(prop, "padding"):
			if pt, pr, pb, pl, ok := parse_box_shorthand(val); ok && pt >= 0 && pr >= 0 && pb >= 0 && pl >= 0 {
				d.has_padding_top = true; d.padding_top = pt
				d.has_padding_right = true; d.padding_right = pr
				d.has_padding_bottom = true; d.padding_bottom = pb
				d.has_padding_left = true; d.padding_left = pl
			}
		case html_ascii_eq_ci(prop, "padding-top"):
			if v, ok := parse_px_value(val); ok && v >= 0 { d.has_padding_top = true; d.padding_top = v }
		case html_ascii_eq_ci(prop, "padding-right"):
			if v, ok := parse_px_value(val); ok && v >= 0 { d.has_padding_right = true; d.padding_right = v }
		case html_ascii_eq_ci(prop, "padding-bottom"):
			if v, ok := parse_px_value(val); ok && v >= 0 { d.has_padding_bottom = true; d.padding_bottom = v }
		case html_ascii_eq_ci(prop, "padding-left"):
			if v, ok := parse_px_value(val); ok && v >= 0 { d.has_padding_left = true; d.padding_left = v }
		case html_ascii_eq_ci(prop, "color"):
			if c, ok := parse_css_color(val); ok { d.has_color = true; d.color = c }
		case html_ascii_eq_ci(prop, "background-color"), html_ascii_eq_ci(prop, "background"):
			if c, ok := parse_css_color(val); ok { d.has_background_color = true; d.background_color = c }
		case html_ascii_eq_ci(prop, "font-size"):
			if v, ok := parse_px_value(val); ok && v >= 4 && v <= 128 {
				d.has_font_size = true
				d.font_size = v
			}
		}
	}
	return d
}

@(private = "file")
parse_selector :: proc "contextless" (raw: []u8) -> Css_Selector {
	s := css_trim(raw)
	sel: Css_Selector
	if len(s) == 0 {
		return sel
	}
	if len(s) == 1 && s[0] == '*' {
		sel.valid = true
		sel.specificity = 0
		return sel
	}
	pos := 0
	id_count: u32 = 0
	class_count: u32 = 0
	tag_count: u32 = 0

	// Optional leading tag name.
	if pos < len(s) && html_is_alpha(s[pos]) {
		start := pos
		for pos < len(s) && html_is_tag_char(s[pos]) {
			pos += 1
		}
		t := tag_from_name(s[start:pos])
		if t == .Unknown {
			return {}
		}
		sel.has_tag = true
		sel.tag = t
		tag_count = 1
	}

	// Optional .class and #id parts.
	for pos < len(s) {
		ch := s[pos]
		if ch == '.' || ch == '#' {
			pos += 1
			start := pos
			for pos < len(s) && html_is_tag_char(s[pos]) {
				pos += 1
			}
			part := s[start:pos]
			if len(part) == 0 || len(part) > MAX_SELECTOR_NAME_LEN {
				return {}
			}
			if ch == '.' {
				copy(sel.class_name[:len(part)], part)
				sel.class_len = u8(len(part))
				class_count += 1
			} else {
				copy(sel.id_name[:len(part)], part)
				sel.id_len = u8(len(part))
				id_count += 1
			}
		} else {
			return {}
		}
	}

	if tag_count == 0 && class_count == 0 && id_count == 0 {
		return {}
	}
	sel.specificity = (id_count << 16) | (class_count << 8) | tag_count
	sel.valid = true
	return sel
}

// parse_stylesheet parses CSS rules into sheet (appending to existing rules up to MAX_CSS_RULES).
parse_stylesheet :: proc "contextless" (sheet: ^Css_Stylesheet, css: []u8) {
	pos := 0
	for pos < len(css) && int(sheet.rule_count) < MAX_CSS_RULES {
		css_skip_ws_and_comments(css, &pos)
		if pos >= len(css) {
			break
		}
		brace_open := pos
		for brace_open < len(css) && css[brace_open] != '{' {
			brace_open += 1
		}
		if brace_open >= len(css) {
			break
		}
		sel_text := css[pos:brace_open]
		pos = brace_open + 1
		brace_close := pos
		for brace_close < len(css) && css[brace_close] != '}' {
			brace_close += 1
		}
		decl_text := css[pos:brace_close]
		pos = brace_close + 1 if brace_close < len(css) else len(css)

		rule: Css_Rule
		rule.order = sheet.rule_count
		rule.decls = parse_declarations(decl_text)

		// Split comma-separated selectors.
		sp := 0
		for sp < len(sel_text) && int(rule.selector_count) < MAX_SELECTORS_PER_RULE {
			c := sp
			for c < len(sel_text) && sel_text[c] != ',' {
				c += 1
			}
			parsed := parse_selector(sel_text[sp:c])
			if parsed.valid {
				rule.selectors[rule.selector_count] = parsed
				rule.selector_count += 1
			}
			sp = c + 1
		}
		if rule.selector_count > 0 {
			sheet.rules[sheet.rule_count] = rule
			sheet.rule_count += 1
		}
	}
}

// parse_document_styles extracts and parses every <style> block inside a Dom_Tree.
parse_document_styles :: proc "contextless" (tree: ^Dom_Tree, sheet: ^Css_Stylesheet) {
	for i := 0; i < int(tree.node_count); i += 1 {
		n := &tree.nodes[i]
		if n.kind == .Element && n.tag == .Style {
			child := n.first_child
			for child != NO_NODE {
				if tree.nodes[child].kind == .Text {
					parse_stylesheet(sheet, dom_node_text(tree, child))
				}
				child = tree.nodes[child].next_sibling
			}
		}
	}
}

// Style resolution (UA defaults + specificity cascade + inheritance).

@(private = "file")
ua_default_style :: proc "contextless" (tag: Html_Tag, parent_style: ^Computed_Style) -> Computed_Style {
	s := Computed_Style{
		display        = .Block,
		flex_direction = .Row,
		color          = parent_style.color if parent_style != nil else DEFAULT_TEXT_COLOR,
		font_size      = parent_style.font_size if parent_style != nil else DEFAULT_FONT_SIZE,
	}
	switch tag {
	case .Head, .Title, .Meta, .Link, .Style, .Script:
		s.display = .None
	case .Span, .A, .Strong, .Em, .Code, .Label, .Button, .Img, .Input, .Br:
		s.display = .Inline
	case .H1:
		s.font_size = 32
	case .H2:
		s.font_size = 24
	case .H3:
		s.font_size = 20
	case .Unknown, .Html, .Body, .Div, .P, .H4, .H5, .H6, .Ul, .Ol, .Li, .Header, .Footer,
	     .Main, .Nav, .Section, .Article, .Form, .Hr, .Pre:
	}
	return s
}

@(private = "file")
apply_declarations :: proc "contextless" (style: ^Computed_Style, d: ^Css_Declarations) {
	if d.has_display { style.display = d.display }
	if d.has_flex_direction { style.flex_direction = d.flex_direction }
	if d.has_gap { style.gap = d.gap }
	if d.has_width { style.has_width = true; style.width = d.width }
	if d.has_height { style.has_height = true; style.height = d.height }
	if d.has_margin_top { style.margin_top = d.margin_top }
	if d.has_margin_right { style.margin_right = d.margin_right }
	if d.has_margin_bottom { style.margin_bottom = d.margin_bottom }
	if d.has_margin_left { style.margin_left = d.margin_left }
	if d.has_padding_top { style.padding_top = d.padding_top }
	if d.has_padding_right { style.padding_right = d.padding_right }
	if d.has_padding_bottom { style.padding_bottom = d.padding_bottom }
	if d.has_padding_left { style.padding_left = d.padding_left }
	if d.has_color { style.color = d.color }
	if d.has_background_color { style.background_color = d.background_color }
	if d.has_font_size { style.font_size = d.font_size }
}

@(private = "file")
selector_matches :: proc "contextless" (tree: ^Dom_Tree, node_idx: u16, sel: ^Css_Selector) -> bool {
	if !sel.valid {
		return false
	}
	node := &tree.nodes[node_idx]
	if node.kind != .Element {
		return false
	}
	if sel.has_tag && node.tag != sel.tag {
		return false
	}
	if sel.class_len > 0 && !dom_node_has_class(tree, node_idx, sel.class_name[:sel.class_len]) {
		return false
	}
	if sel.id_len > 0 {
		id_val, has_id := dom_node_attr(tree, node_idx, "id")
		if !has_id || len(id_val) != int(sel.id_len) {
			return false
		}
		for k := 0; k < int(sel.id_len); k += 1 {
			if id_val[k] != sel.id_name[k] {
				return false
			}
		}
	}
	return true
}

@(private = "file")
Matched_Rule :: struct {
	rule_idx:    u16,
	specificity: u32,
	order:       u16,
}

// resolve_styles computes cascaded and inherited styles for every node in tree.
resolve_styles :: proc "contextless" (tree: ^Dom_Tree, sheet: ^Css_Stylesheet, styles_out: ^[MAX_DOM_NODES]Computed_Style) {
	// Node indices are allocated in preorder, so parent always precedes child.
	for i := 0; i < int(tree.node_count); i += 1 {
		n := &tree.nodes[i]
		parent_style: ^Computed_Style = nil
		if n.parent != NO_NODE && int(n.parent) < i {
			parent_style = &styles_out[n.parent]
		}
		if n.kind == .Document {
			styles_out[i] = Computed_Style{
				display        = .Block,
				flex_direction = .Row,
				color          = DEFAULT_TEXT_COLOR,
				font_size      = DEFAULT_FONT_SIZE,
			}
			continue
		}
		if n.kind == .Text {
			styles_out[i] = Computed_Style{
				display        = .Inline,
				flex_direction = .Row,
				color          = parent_style.color if parent_style != nil else DEFAULT_TEXT_COLOR,
				font_size      = parent_style.font_size if parent_style != nil else DEFAULT_FONT_SIZE,
			}
			continue
		}
		if n.kind == .Comment {
			styles_out[i] = Computed_Style{display = .None}
			continue
		}

		st := ua_default_style(n.tag, parent_style)
		matches: [MAX_CSS_RULES]Matched_Rule
		mcount := 0
		if sheet != nil {
			for r := 0; r < int(sheet.rule_count); r += 1 {
				rule := &sheet.rules[r]
				best_spec: u32 = 0
				matched := false
				for s := 0; s < int(rule.selector_count); s += 1 {
					if selector_matches(tree, u16(i), &rule.selectors[s]) {
						if !matched || rule.selectors[s].specificity > best_spec {
							best_spec = rule.selectors[s].specificity
						}
						matched = true
					}
				}
				if matched {
					matches[mcount] = Matched_Rule{rule_idx = u16(r), specificity = best_spec, order = rule.order}
					mcount += 1
				}
			}
		}

		// Insertion sort matched rules by ascending (specificity, order).
		for a := 1; a < mcount; a += 1 {
			key := matches[a]
			b := a - 1
			for b >= 0 && (matches[b].specificity > key.specificity || (matches[b].specificity == key.specificity && matches[b].order > key.order)) {
				matches[b + 1] = matches[b]
				b -= 1
			}
			matches[b + 1] = key
		}
		for m := 0; m < mcount; m += 1 {
			apply_declarations(&st, &sheet.rules[matches[m].rule_idx].decls)
		}

		// Inline style attribute has highest cascade priority.
		if inline_val, has_inline := dom_node_attr(tree, u16(i), "style"); has_inline {
			inline_decls := parse_declarations(inline_val)
			apply_declarations(&st, &inline_decls)
		}

		styles_out[i] = st
	}
}

// Block, inline, and flex layout engine.

@(private = "file")
layout_alloc_box :: proc "contextless" (layout: ^Layout_Tree, parent_box: u16, node_idx: u16, style: Computed_Style, is_text: bool) -> u16 {
	if int(layout.box_count) >= MAX_DOM_NODES {
		return NO_NODE
	}
	idx := layout.box_count
	layout.box_count += 1
	layout.boxes[idx] = Layout_Box{
		used         = true,
		node_index   = node_idx,
		parent_box   = parent_box,
		first_child  = NO_NODE,
		last_child   = NO_NODE,
		next_sibling = NO_NODE,
		display      = style.display,
		style        = style,
		is_text      = is_text,
	}
	if parent_box != NO_NODE && int(parent_box) < int(layout.box_count) {
		p := &layout.boxes[parent_box]
		if p.first_child == NO_NODE {
			p.first_child = idx
			p.last_child = idx
		} else {
			layout.boxes[p.last_child].next_sibling = idx
			p.last_child = idx
		}
	}
	return idx
}

@(private = "file")
measure_text_width :: proc "contextless" (text: []u8, font_size: i32) -> i32 {
	char_w := max(i32(1), font_size / 2)
	return i32(len(text)) * char_w
}

@(private = "file")
is_whitespace_only :: proc "contextless" (text: []u8) -> bool {
	for b in text {
		if !html_is_space(b) {
			return false
		}
	}
	return true
}

@(private = "file")
shift_subtree :: proc "contextless" (layout: ^Layout_Tree, box_idx: u16, dx, dy: i32, depth: int) {
	if box_idx == NO_NODE || depth > MAX_DOM_DEPTH {
		return
	}
	b := &layout.boxes[box_idx]
	b.x += dx
	b.y += dy
	b.content_x += dx
	b.content_y += dy
	child := b.first_child
	for child != NO_NODE {
		shift_subtree(layout, child, dx, dy, depth + 1)
		child = layout.boxes[child].next_sibling
	}
}

@(private = "file")
layout_node :: proc "contextless" (tree: ^Dom_Tree, styles: ^[MAX_DOM_NODES]Computed_Style, layout: ^Layout_Tree, node_idx: u16, parent_box: u16, origin_x, origin_y, avail_width: i32, shrink_to_fit: bool, depth: int) -> u16 {
	if node_idx == NO_NODE || int(node_idx) >= int(tree.node_count) || depth > MAX_DOM_DEPTH {
		return NO_NODE
	}
	node := &tree.nodes[node_idx]
	st := styles[node_idx]
	if st.display == .None {
		return NO_NODE
	}

	if node.kind == .Text {
		txt := dom_node_text(tree, node_idx)
		if len(txt) == 0 || is_whitespace_only(txt) {
			return NO_NODE
		}
		bidx := layout_alloc_box(layout, parent_box, node_idx, st, true)
		if bidx == NO_NODE {
			return NO_NODE
		}
		w := measure_text_width(txt, st.font_size)
		h := max(i32(4), st.font_size)
		if avail_width > 0 && w > avail_width {
			lines := (w + avail_width - 1) / avail_width
			w = avail_width
			h = lines * max(i32(4), st.font_size)
		}
		b := &layout.boxes[bidx]
		b.x = origin_x
		b.y = origin_y
		b.width = w
		b.height = h
		b.content_x = origin_x
		b.content_y = origin_y
		b.content_width = w
		b.content_height = h
		return bidx
	}

	bidx := layout_alloc_box(layout, parent_box, node_idx, st, false)
	if bidx == NO_NODE {
		return NO_NODE
	}

	box_x := origin_x + st.margin_left
	box_y := origin_y + st.margin_top
	pad_h := st.padding_left + st.padding_right
	pad_v := st.padding_top + st.padding_bottom

	border_w: i32
	if st.has_width {
		border_w = st.width
	} else if shrink_to_fit || st.display == .Inline {
		border_w = max(i32(0), avail_width - st.margin_left - st.margin_right)
	} else {
		border_w = max(i32(0), avail_width - st.margin_left - st.margin_right)
	}
	inner_w := max(i32(0), border_w - pad_h)
	cx := box_x + st.padding_left
	cy := box_y + st.padding_top

	used_w: i32 = 0
	used_h: i32 = 0

	if st.display == .Flex {
		if st.flex_direction == .Row {
			cursor_x := cx
			max_child_h: i32 = 0
			visible_count := 0
			child := node.first_child
			for child != NO_NODE {
				if styles[child].display == .None {
					child = tree.nodes[child].next_sibling
					continue
				}
				if tree.nodes[child].kind == .Text && is_whitespace_only(dom_node_text(tree, child)) {
					child = tree.nodes[child].next_sibling
					continue
				}
				if visible_count > 0 {
					cursor_x += st.gap
				}
				rem_w := max(i32(0), (cx + inner_w) - cursor_x)
				cb := layout_node(tree, styles, layout, child, bidx, cursor_x, cy, rem_w, true, depth + 1)
				if cb != NO_NODE {
					cbox := &layout.boxes[cb]
					outer_w := cbox.style.margin_left + cbox.width + cbox.style.margin_right
					outer_h := cbox.style.margin_top + cbox.height + cbox.style.margin_bottom
					cursor_x += outer_w
					if outer_h > max_child_h {
						max_child_h = outer_h
					}
					visible_count += 1
				}
				child = tree.nodes[child].next_sibling
			}
			used_w = cursor_x - cx
			used_h = max_child_h
		} else {
			// Flex column.
			cursor_y := cy
			max_child_w: i32 = 0
			visible_count := 0
			child := node.first_child
			for child != NO_NODE {
				if styles[child].display == .None {
					child = tree.nodes[child].next_sibling
					continue
				}
				if tree.nodes[child].kind == .Text && is_whitespace_only(dom_node_text(tree, child)) {
					child = tree.nodes[child].next_sibling
					continue
				}
				if visible_count > 0 {
					cursor_y += st.gap
				}
				cb := layout_node(tree, styles, layout, child, bidx, cx, cursor_y, inner_w, false, depth + 1)
				if cb != NO_NODE {
					cbox := &layout.boxes[cb]
					outer_w := cbox.style.margin_left + cbox.width + cbox.style.margin_right
					outer_h := cbox.style.margin_top + cbox.height + cbox.style.margin_bottom
					cursor_y += outer_h
					if outer_w > max_child_w {
						max_child_w = outer_w
					}
					visible_count += 1
				}
				child = tree.nodes[child].next_sibling
			}
			used_w = max_child_w
			used_h = cursor_y - cy
		}
	} else {
		// Block or Inline flow with horizontal inline line wrapping.
		cursor_y := cy
		line_x := cx
		line_h: i32 = 0
		max_line_w: i32 = 0

		child := node.first_child
		for child != NO_NODE {
			cn := &tree.nodes[child]
			cst := styles[child]
			if cst.display == .None {
				child = cn.next_sibling
				continue
			}
			if cn.kind == .Element && cn.tag == .Br {
				cursor_y += max(line_h, max(i32(4), st.font_size))
				if line_x - cx > max_line_w {
					max_line_w = line_x - cx
				}
				line_x = cx
				line_h = 0
				child = cn.next_sibling
				continue
			}
			if cst.display == .Inline {
				if cn.kind == .Text && is_whitespace_only(dom_node_text(tree, child)) {
					child = cn.next_sibling
					continue
				}
				rem_w := max(i32(0), (cx + inner_w) - line_x)
				cb := layout_node(tree, styles, layout, child, bidx, line_x, cursor_y, inner_w, true, depth + 1)
				if cb != NO_NODE {
					cbox := &layout.boxes[cb]
					outer_w := cbox.style.margin_left + cbox.width + cbox.style.margin_right
					outer_h := cbox.style.margin_top + cbox.height + cbox.style.margin_bottom
					// Wrap to next line if this inline item overflows current line and line is non-empty.
					if line_x > cx && outer_w > rem_w && inner_w > 0 {
						if line_x - cx > max_line_w {
							max_line_w = line_x - cx
						}
						cursor_y += max(line_h, max(i32(4), st.font_size))
						dx := cx - line_x
						dy := cursor_y - (cbox.y - cbox.style.margin_top)
						shift_subtree(layout, cb, dx, dy, 0)
						line_x = cx + outer_w
						line_h = outer_h
					} else {
						line_x += outer_w
						if outer_h > line_h {
							line_h = outer_h
						}
					}
				}
			} else {
				// Block or Flex child flushes any pending inline line first.
				if line_x > cx || line_h > 0 {
					if line_x - cx > max_line_w {
						max_line_w = line_x - cx
					}
					cursor_y += line_h
					line_x = cx
					line_h = 0
				}
				cb := layout_node(tree, styles, layout, child, bidx, cx, cursor_y, inner_w, false, depth + 1)
				if cb != NO_NODE {
					cbox := &layout.boxes[cb]
					outer_w := cbox.style.margin_left + cbox.width + cbox.style.margin_right
					outer_h := cbox.style.margin_top + cbox.height + cbox.style.margin_bottom
					cursor_y += outer_h
					if outer_w > max_line_w {
						max_line_w = outer_w
					}
				}
			}
			child = cn.next_sibling
		}

		if line_x > cx || line_h > 0 {
			if line_x - cx > max_line_w {
				max_line_w = line_x - cx
			}
			cursor_y += line_h
		}
		used_w = max_line_w
		used_h = cursor_y - cy
	}

	final_w := border_w
	if !st.has_width && (shrink_to_fit || st.display == .Inline) {
		final_w = used_w + pad_h
	}
	final_h := st.height if st.has_height else (used_h + pad_v)

	b := &layout.boxes[bidx]
	b.x = box_x
	b.y = box_y
	b.width = max(i32(0), final_w)
	b.height = max(i32(0), final_h)
	b.content_x = cx
	b.content_y = cy
	b.content_width = max(i32(0), b.width - pad_h)
	b.content_height = max(i32(0), b.height - pad_v)
	return bidx
}

// compute_layout resolves CSS cascade and computes pixel Layout_Box rects for the DOM tree.
compute_layout :: proc "contextless" (tree: ^Dom_Tree, sheet: ^Css_Stylesheet, viewport_width, viewport_height: i32, layout_out: ^Layout_Tree) {
	layout_out^ = {}
	layout_out.root_box = NO_NODE
	if tree.node_count == 0 {
		return
	}
	styles: [MAX_DOM_NODES]Computed_Style
	resolve_styles(tree, sheet, &styles)
	vw := max(i32(0), min(viewport_width, MAX_LAYOUT_COORD))
	_ = viewport_height
	layout_out.root_box = layout_node(tree, &styles, layout_out, 0, NO_NODE, 0, 0, vw, false, 0)
}

// layout_find_box_by_id returns the Layout_Box index for the first element with matching HTML id attribute.
layout_find_box_by_id :: proc "contextless" (tree: ^Dom_Tree, layout: ^Layout_Tree, id: string) -> (box_idx: u16, found: bool) {
	for i := 0; i < int(layout.box_count); i += 1 {
		b := &layout.boxes[i]
		if !b.used || b.is_text {
			continue
		}
		val, ok := dom_node_attr(tree, b.node_index, "id")
		if ok && len(val) == len(id) {
			eq := true
			for k := 0; k < len(id); k += 1 {
				if val[k] != id[k] {
					eq = false
					break
				}
			}
			if eq {
				return u16(i), true
			}
		}
	}
	return NO_NODE, false
}

// Draw table emission into modus:contract/draw_record primitives.

@(private = "file")
clamp_coord :: proc "contextless" (px: i32) -> i32 {
	if px < -draw_record.COORDINATE_LIMIT {
		return -draw_record.COORDINATE_LIMIT
	}
	if px > draw_record.COORDINATE_LIMIT {
		return draw_record.COORDINATE_LIMIT
	}
	return px
}

@(private = "file")
emit_box_paint :: proc "contextless" (tree: ^Dom_Tree, layout: ^Layout_Tree, box_idx: u16, records_out: []draw_record.Draw_Record, text_out: []u8, rec_count: ^int, text_pos: ^int, depth: int) {
	if box_idx == NO_NODE || int(box_idx) >= int(layout.box_count) || depth > MAX_DOM_DEPTH {
		return
	}
	b := &layout.boxes[box_idx]
	if !b.used || b.display == .None {
		return
	}

	left_px := clamp_coord(b.x)
	top_px := clamp_coord(b.y)
	right_px := clamp_coord(b.x + b.width)
	bottom_px := clamp_coord(b.y + b.height)
	if right_px < left_px { right_px = left_px }
	if bottom_px < top_px { bottom_px = top_px }

	// Paint background rectangle if visible.
	if !b.is_text && b.style.background_color != 0 && right_px > left_px && bottom_px > top_px {
		if rec_count^ < len(records_out) {
			records_out[rec_count^] = draw_record.record_of(
				draw_record.Draw_Rectangle{color = b.style.background_color},
				u32(b.node_index) + 1,
				draw_record.units_of_pixels(int(left_px)),
				draw_record.units_of_pixels(int(top_px)),
				draw_record.units_of_pixels(int(right_px)),
				draw_record.units_of_pixels(int(bottom_px)),
			)
			rec_count^ += 1
		}
	}

	// Paint text run if text node with visible ink.
	if b.is_text && b.style.color != 0 && right_px > left_px && bottom_px > top_px {
		txt := dom_node_text(tree, b.node_index)
		if len(txt) > 0 && rec_count^ < len(records_out) && text_pos^ + len(txt) <= len(text_out) {
			first := u32(text_pos^)
			copy(text_out[text_pos^:], txt)
			text_pos^ += len(txt)
			fs := b.style.font_size
			if fs < 4 { fs = 4 }
			if fs > 128 { fs = 128 }
			records_out[rec_count^] = draw_record.record_of(
				draw_record.Draw_Text{
					first    = first,
					count    = u32(len(txt)),
					color    = b.style.color,
					origin_x = draw_record.units_of_pixels(int(left_px)),
					font     = .Cells_8x16,
					weight   = .Regular,
					size     = u16(fs * draw_record.UNITS_PER_PIXEL),
				},
				u32(b.node_index) + 1,
				draw_record.units_of_pixels(int(left_px)),
				draw_record.units_of_pixels(int(top_px)),
				draw_record.units_of_pixels(int(right_px)),
				draw_record.units_of_pixels(int(bottom_px)),
			)
			rec_count^ += 1
		}
	}

	child := b.first_child
	for child != NO_NODE {
		emit_box_paint(tree, layout, child, records_out, text_out, rec_count, text_pos, depth + 1)
		child = layout.boxes[child].next_sibling
	}
}

// emit_draw_records converts a computed Layout_Tree into valid draw_record primitives and text bytes.
emit_draw_records :: proc "contextless" (tree: ^Dom_Tree, layout: ^Layout_Tree, records_out: []draw_record.Draw_Record, text_out: []u8) -> (record_count: int, text_bytes: int) {
	if layout.root_box == NO_NODE {
		return 0, 0
	}
	rc := 0
	tp := 0
	emit_box_paint(tree, layout, layout.root_box, records_out, text_out, &rc, &tp, 0)
	return rc, tp
}

// CSS parser, cascade and inheritance resolver, block, inline, flex and
// table layout engine, and modus draw_record emitter. Pure freestanding
// zero-allocation contract code. The design is in
// src/md/features/desktop_to_browser.md, "The CSS engine".
package html_css

import "modus:contract/draw_record"

MAX_SELECTORS_PER_RULE :: 8
MAX_SELECTOR_NAME_LEN :: 64
// A selector is at most 4 compound selectors joined by combinators, and a
// compound selector names at most 4 classes.
MAX_COMPOUNDS_PER_SELECTOR :: 4
MAX_CLASSES_PER_COMPOUND :: 4
// The ancestors that a selector with combinators reads: past them, a node
// matches as if it had no other ancestor.
SELECTOR_ANCESTOR_LIMIT :: 2 * MAX_DOM_DEPTH
// The columns of a table: the cells past the last one get no box.
TABLE_COLUMN_CAPACITY :: 64
MAX_LAYOUT_COORD :: 65536
DEFAULT_FONT_SIZE :: i32(16)
DEFAULT_TEXT_COLOR :: draw_record.Draw_Color(0xFF000000)
// The width of a border that names none: "medium".
DEFAULT_BORDER_WIDTH :: i32(3)

// CSS display modes supported by the layout engine.
Display_Mode :: enum u8 {
	Block           = 1,
	Inline          = 2,
	Flex            = 3,
	None            = 4,
	Table           = 5,
	Table_Row_Group = 6,
	Table_Row       = 7,
	Table_Cell      = 8,
}

// CSS flex-direction options.
Flex_Direction :: enum u8 {
	Row    = 1,
	Column = 2,
}

// CSS text-align: where the lines of a block sit in its width.
Text_Align :: enum u8 {
	Left   = 1,
	Center = 2,
	Right  = 3,
}

// CSS border-style. Each visible style paints as a solid line.
Border_Style :: enum u8 {
	None  = 1,
	Solid = 2,
}

// How a compound selector relates to the one at its left.
Css_Combinator :: enum u8 {
	Descendant = 1, // "div p": an ancestor.
	Child      = 2, // "div > p": the parent.
}

// The four sides of a box.
Box_Side :: enum u8 {
	Top,
	Right,
	Bottom,
	Left,
}

// A name of a selector: bytes of Css_Stylesheet.names.
Css_Name :: struct {
	offset: u32,
	count:  u8,
}

// A compound selector: an optional tag, classes and an optional id, which
// the same element must all have.
Css_Compound :: struct {
	has_tag:     bool,
	tag:         Html_Tag,
	classes:     [MAX_CLASSES_PER_COMPOUND]Css_Name,
	class_count: u8,
	has_id:      bool,
	id:          Css_Name,
}

// A complex selector: compound selectors from left to right, and the
// combinator between each two. Its specificity is (ids, classes, tags),
// packed as ids << 16 | classes << 8 | tags: the order of the packed
// numbers is the order of the triples.
Css_Selector :: struct {
	compounds:      [MAX_COMPOUNDS_PER_SELECTOR]Css_Compound,
	combinators:    [MAX_COMPOUNDS_PER_SELECTOR - 1]Css_Combinator,
	compound_count: u8,
	specificity:    u32,
	valid:          bool,
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
	has_text_align:       bool,
	text_align:           Text_Align,
	has_border_width:     bool,
	border_width:         [Box_Side]i32,
	has_border_style:     bool,
	border_style:         Border_Style,
	has_border_color:     bool,
	border_color:         draw_record.Draw_Color,
}

// One parsed CSS rule with selector list, declarations, and source order.
Css_Rule :: struct {
	selectors:      [MAX_SELECTORS_PER_RULE]Css_Selector,
	selector_count: u8,
	decls:          Css_Declarations,
	order:          u32,
}

// The parts of the memory of a style sheet, which grow apart.
Css_Part :: enum u8 {
	Rules = 0,
	Names = 1, // The bytes of the class and id names of the selectors.
}

// Css_Grow makes a part of the memory of a style sheet hold at least
// wanted entries, as Dom_Grow does for a tree. false: the part cannot grow,
// and the sheet keeps the rules before, and says that it is cut.
Css_Grow :: #type proc "contextless" (sheet: ^Css_Stylesheet, part: Css_Part, wanted: int) -> bool

// A style sheet parsed from CSS text, in memory of the caller: a document
// has no fixed count of rules, and the budget of the caller bounds it. The
// slices are the room of each part, the counts the entries in use.
Css_Stylesheet :: struct {
	rules:      []Css_Rule,
	rule_count: u32,
	names:      []u8,
	name_count: u32,
	truncated:  bool, // A rule or a name found no room.
	grow:       Css_Grow,
	grow_data:  rawptr,
}

// stylesheet_clear empties a style sheet and keeps its memory and its
// grow procedure. It wipes the rules and the names of the last sheet, as
// dom_tree_clear wipes a tree.
stylesheet_clear :: proc "contextless" (sheet: ^Css_Stylesheet) {
	zero_entries(sheet.rules, int(sheet.rule_count))
	zero_entries(sheet.names, int(sheet.name_count))
	sheet^ = {rules = sheet.rules, names = sheet.names, grow = sheet.grow, grow_data = sheet.grow_data}
}

@(private = "file")
css_room :: proc "contextless" (sheet: ^Css_Stylesheet, part: Css_Part, wanted: int) -> bool {
	room := part == .Rules ? len(sheet.rules) : len(sheet.names)
	if wanted <= room {
		return true
	}
	if wanted > int(max(u32)) || sheet.grow == nil || !sheet.grow(sheet, part, wanted) {
		sheet.truncated = true
		return false
	}
	room = part == .Rules ? len(sheet.rules) : len(sheet.names)
	return wanted <= room
}

// Final cascaded and inherited style for one DOM node. The width and the
// height are those of the border box: they hold the padding and the
// border.
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
	text_align:       Text_Align,
	// The used widths: 0 on each side when the style is None.
	border_width:     [Box_Side]i32,
	border_style:     Border_Style,
	// 0: the color of the text, as currentColor.
	border_color:     draw_record.Draw_Color,
}

// Computed pixel geometry for one visible DOM node.
Layout_Box :: struct {
	used:           bool,
	node_index:     u32,
	parent_box:     u32,
	first_child:    u32,
	last_child:     u32,
	next_sibling:   u32,
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

// A rule that matches a node, with its specificity: the cascade sorts
// them.
Matched_Rule :: struct {
	rule_idx:    u32,
	specificity: u32,
	order:       u32,
}

// The parts of the memory of a layout tree, which grow apart.
Layout_Part :: enum u8 {
	Styles  = 0, // The cascaded style of each node: one for each node of the tree.
	Boxes   = 1, // The boxes: at most one for each node.
	Matched = 2, // The rules that match one node: one for each rule of the sheet.
}

// Layout_Grow makes a part of the memory of a layout tree hold at least
// wanted entries, as Dom_Grow does for a tree.
Layout_Grow :: #type proc "contextless" (layout: ^Layout_Tree, part: Layout_Part, wanted: int) -> bool

// A layout tree produced by compute_layout, in memory of the caller, never
// on the stack: the styles of the nodes of a large page are larger than the
// stack of a thread.
Layout_Tree :: struct {
	node_styles: []Computed_Style,
	boxes:       []Layout_Box,
	matched:     []Matched_Rule,
	box_count:   u32,
	root_box:    u32,
	truncated:   bool, // A part found no room: the layout stops there.
	// The styles and the matched rules that the last layout wrote, which
	// layout_tree_clear wipes.
	styled_count:  u32,
	matched_count: u32,
	grow:        Layout_Grow,
	grow_data:   rawptr,
}

@(private = "file")
layout_room :: proc "contextless" (layout: ^Layout_Tree, part: Layout_Part, wanted: int) -> bool {
	room :: proc "contextless" (layout: ^Layout_Tree, part: Layout_Part) -> int {
		switch part {
		case .Styles:
			return len(layout.node_styles)
		case .Boxes:
			return len(layout.boxes)
		case .Matched:
			return len(layout.matched)
		}
		return 0
	}
	if wanted <= room(layout, part) {
		return true
	}
	if wanted > NODE_INDEX_LIMIT || layout.grow == nil || !layout.grow(layout, part, wanted) {
		layout.truncated = true
		return false
	}
	return wanted <= room(layout, part)
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
		inner := s[4:len(s) - 1]
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

// parse_box_shorthand reads the 1 to 4 lengths of margin, padding and
// border-width: one for each side, two for top and bottom then left and
// right, three for top, the sides and bottom, four from the top clockwise.
@(private = "file")
parse_box_shorthand :: proc "contextless" (raw: []u8) -> (top, right, bottom, left: i32, ok: bool) {
	vals: [4]i32
	count := 0
	pos := 0
	for pos < len(raw) {
		for pos < len(raw) && html_is_space(raw[pos]) {
			pos += 1
		}
		if pos >= len(raw) {
			break
		}
		if count == 4 {
			return 0, 0, 0, 0, false
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

// border_width_of reads one width of a border: a length of 0 or more, or
// thin, medium or thick.
@(private = "file")
border_width_of :: proc "contextless" (raw: []u8) -> (width: i32, ok: bool) {
	switch {
	case html_ascii_eq_ci(raw, "thin"):
		return 1, true
	case html_ascii_eq_ci(raw, "medium"):
		return DEFAULT_BORDER_WIDTH, true
	case html_ascii_eq_ci(raw, "thick"):
		return 5, true
	}
	value, parsed := parse_px_value(raw)
	if !parsed || value < 0 {
		return 0, false
	}
	return value, true
}

@(private = "file")
border_style_of :: proc "contextless" (raw: []u8) -> (style: Border_Style, ok: bool) {
	switch {
	case html_ascii_eq_ci(raw, "none"), html_ascii_eq_ci(raw, "hidden"):
		return .None, true
	case html_ascii_eq_ci(raw, "solid"), html_ascii_eq_ci(raw, "dashed"), html_ascii_eq_ci(raw, "dotted"),
	     html_ascii_eq_ci(raw, "double"), html_ascii_eq_ci(raw, "groove"), html_ascii_eq_ci(raw, "ridge"),
	     html_ascii_eq_ci(raw, "inset"), html_ascii_eq_ci(raw, "outset"):
		return .Solid, true
	}
	return {}, false
}

// border_shorthand_parse reads "border: <width> <style> <color>", in any
// order, each part at most once. A part that it omits takes its initial
// value: medium, none, the color of the text.
@(private = "file")
border_shorthand_parse :: proc "contextless" (d: ^Css_Declarations, raw: []u8) {
	width := DEFAULT_BORDER_WIDTH
	style := Border_Style.None
	color := draw_record.Draw_Color(0)
	seen_width, seen_style, seen_color := false, false, false
	pos := 0
	for pos < len(raw) {
		for pos < len(raw) && html_is_space(raw[pos]) {
			pos += 1
		}
		if pos >= len(raw) {
			break
		}
		start := pos
		// A color of rgb() holds spaces: its part ends at its parenthesis.
		depth := 0
		for pos < len(raw) && (depth > 0 || !html_is_space(raw[pos])) {
			if raw[pos] == '(' {
				depth += 1
			} else if raw[pos] == ')' && depth > 0 {
				depth -= 1
			}
			pos += 1
		}
		part := raw[start:pos]
		part_width, is_width := border_width_of(part)
		part_style, is_style := border_style_of(part)
		part_color, is_color := parse_css_color(part)
		switch {
		case is_width && !seen_width:
			width, seen_width = part_width, true
		case is_style && !seen_style:
			style, seen_style = part_style, true
		case is_color && !seen_color:
			color, seen_color = part_color, true
		case:
			return
		}
	}
	if !seen_width && !seen_style && !seen_color {
		return
	}
	d.has_border_width = true
	d.border_width = {.Top = width, .Right = width, .Bottom = width, .Left = width}
	d.has_border_style = true
	d.border_style = style
	d.has_border_color = true
	d.border_color = color
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
			case html_ascii_eq_ci(val, "block"):              d.has_display = true; d.display = .Block
			case html_ascii_eq_ci(val, "inline"):             d.has_display = true; d.display = .Inline
			case html_ascii_eq_ci(val, "flex"):               d.has_display = true; d.display = .Flex
			case html_ascii_eq_ci(val, "none"):               d.has_display = true; d.display = .None
			case html_ascii_eq_ci(val, "table"):              d.has_display = true; d.display = .Table
			case html_ascii_eq_ci(val, "table-row-group"), html_ascii_eq_ci(val, "table-header-group"), html_ascii_eq_ci(val, "table-footer-group"):
				d.has_display = true; d.display = .Table_Row_Group
			case html_ascii_eq_ci(val, "table-row"):          d.has_display = true; d.display = .Table_Row
			case html_ascii_eq_ci(val, "table-cell"):         d.has_display = true; d.display = .Table_Cell
			}
		case html_ascii_eq_ci(prop, "flex-direction"):
			switch {
			case html_ascii_eq_ci(val, "row"):    d.has_flex_direction = true; d.flex_direction = .Row
			case html_ascii_eq_ci(val, "column"): d.has_flex_direction = true; d.flex_direction = .Column
			}
		case html_ascii_eq_ci(prop, "text-align"):
			switch {
			case html_ascii_eq_ci(val, "left"), html_ascii_eq_ci(val, "start"), html_ascii_eq_ci(val, "justify"):
				d.has_text_align = true; d.text_align = .Left
			case html_ascii_eq_ci(val, "center"):
				d.has_text_align = true; d.text_align = .Center
			case html_ascii_eq_ci(val, "right"), html_ascii_eq_ci(val, "end"):
				d.has_text_align = true; d.text_align = .Right
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
		case html_ascii_eq_ci(prop, "border"):
			border_shorthand_parse(&d, val)
		case html_ascii_eq_ci(prop, "border-width"):
			if bt, br, bb, bl, ok := parse_box_shorthand(val); ok && bt >= 0 && br >= 0 && bb >= 0 && bl >= 0 {
				d.has_border_width = true
				d.border_width = {.Top = bt, .Right = br, .Bottom = bb, .Left = bl}
			} else if width, width_ok := border_width_of(val); width_ok {
				d.has_border_width = true
				d.border_width = {.Top = width, .Right = width, .Bottom = width, .Left = width}
			}
		case html_ascii_eq_ci(prop, "border-style"):
			if style, ok := border_style_of(val); ok { d.has_border_style = true; d.border_style = style }
		case html_ascii_eq_ci(prop, "border-color"):
			if c, ok := parse_css_color(val); ok { d.has_border_color = true; d.border_color = c }
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

// css_name_bytes gives the bytes of a name of a selector.
css_name_bytes :: proc "contextless" (sheet: ^Css_Stylesheet, name: Css_Name) -> []u8 {
	end := int(name.offset) + int(name.count)
	if end > int(sheet.name_count) {
		return nil
	}
	return sheet.names[name.offset:end]
}

@(private = "file")
css_name_store :: proc "contextless" (sheet: ^Css_Stylesheet, bytes: []u8) -> (name: Css_Name, ok: bool) {
	if len(bytes) == 0 || len(bytes) > MAX_SELECTOR_NAME_LEN || !css_room(sheet, .Names, int(sheet.name_count) + len(bytes)) {
		return {}, false
	}
	name = {offset = sheet.name_count, count = u8(len(bytes))}
	copy(sheet.names[sheet.name_count:], bytes)
	sheet.name_count += u32(len(bytes))
	return name, true
}

// parse_selector reads a selector of compound selectors joined by spaces
// (a descendant) and '>' (a child). A part that it does not read (an
// attribute, a pseudo-class, a sibling combinator) makes the selector
// invalid, and an invalid selector names no element.
@(private = "file")
parse_selector :: proc "contextless" (sheet: ^Css_Stylesheet, raw: []u8) -> Css_Selector {
	s := css_trim(raw)
	selector: Css_Selector
	if len(s) == 0 {
		return {}
	}
	ids, classes, tags: u32
	pos := 0
	pending := Css_Combinator.Descendant
	for {
		if int(selector.compound_count) >= MAX_COMPOUNDS_PER_SELECTOR {
			return {}
		}
		compound: Css_Compound
		named := false
		if s[pos] == '*' {
			pos += 1
			named = true
		} else if html_is_alpha(s[pos]) {
			start := pos
			for pos < len(s) && html_is_tag_char(s[pos]) {
				pos += 1
			}
			tag := tag_from_name(s[start:pos])
			if tag == .Unknown {
				return {}
			}
			compound.has_tag = true
			compound.tag = tag
			tags += 1
			named = true
		}
		for pos < len(s) && (s[pos] == '.' || s[pos] == '#') {
			kind := s[pos]
			pos += 1
			start := pos
			for pos < len(s) && html_is_tag_char(s[pos]) {
				pos += 1
			}
			name, stored := css_name_store(sheet, s[start:pos])
			if !stored {
				return {}
			}
			if kind == '.' {
				if int(compound.class_count) >= MAX_CLASSES_PER_COMPOUND {
					return {}
				}
				compound.classes[compound.class_count] = name
				compound.class_count += 1
				classes += 1
			} else {
				// Two ids in one compound selector name no element.
				if compound.has_id {
					return {}
				}
				compound.has_id = true
				compound.id = name
				ids += 1
			}
			named = true
		}
		if !named {
			return {}
		}
		if selector.compound_count > 0 {
			selector.combinators[selector.compound_count - 1] = pending
		}
		selector.compounds[selector.compound_count] = compound
		selector.compound_count += 1
		spaced := false
		for pos < len(s) && html_is_space(s[pos]) {
			pos += 1
			spaced = true
		}
		if pos >= len(s) {
			break
		}
		if s[pos] == '>' {
			pos += 1
			for pos < len(s) && html_is_space(s[pos]) {
				pos += 1
			}
			if pos >= len(s) {
				return {}
			}
			pending = .Child
		} else if spaced {
			pending = .Descendant
		} else {
			return {}
		}
	}
	selector.specificity = min(ids, 255) << 16 | min(classes, 255) << 8 | min(tags, 255)
	selector.valid = true
	return selector
}

// parse_stylesheet parses CSS rules into sheet, after its rules, in its memory, which it grows.
// A rule whose list holds a selector that is not valid is dropped whole,
// as CSS says.
parse_stylesheet :: proc "contextless" (sheet: ^Css_Stylesheet, css: []u8) {
	pos := 0
	for pos < len(css) {
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

		names_before := sheet.name_count
		rule: Css_Rule
		rule.order = sheet.rule_count
		rule.decls = parse_declarations(decl_text)
		valid := true
		sp := 0
		for sp <= len(sel_text) {
			c := sp
			for c < len(sel_text) && sel_text[c] != ',' {
				c += 1
			}
			parsed := parse_selector(sheet, sel_text[sp:c])
			if !parsed.valid || int(rule.selector_count) >= MAX_SELECTORS_PER_RULE {
				valid = false
				break
			}
			rule.selectors[rule.selector_count] = parsed
			rule.selector_count += 1
			sp = c + 1
		}
		if !valid || rule.selector_count == 0 {
			sheet.name_count = names_before
			continue
		}
		if !css_room(sheet, .Rules, int(sheet.rule_count) + 1) {
			sheet.name_count = names_before
			break
		}
		sheet.rules[sheet.rule_count] = rule
		sheet.rule_count += 1
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
	s := Computed_Style {
		display        = .Block,
		flex_direction = .Row,
		color          = parent_style.color if parent_style != nil else DEFAULT_TEXT_COLOR,
		font_size      = parent_style.font_size if parent_style != nil else DEFAULT_FONT_SIZE,
		text_align     = parent_style.text_align if parent_style != nil else .Left,
		border_width   = {.Top = DEFAULT_BORDER_WIDTH, .Right = DEFAULT_BORDER_WIDTH, .Bottom = DEFAULT_BORDER_WIDTH, .Left = DEFAULT_BORDER_WIDTH},
		border_style   = .None,
	}
	switch tag {
	case .Head, .Title, .Meta, .Link, .Style, .Script, .Base:
		s.display = .None
	case .Span, .A, .Strong, .Em, .Code, .Label, .Button, .Img, .Input, .Br, .B, .I, .U, .S, .Textarea:
		s.display = .Inline
	case .Small:
		s.display = .Inline
		s.font_size = max(i32(4), s.font_size * 5 / 6)
	case .H1:
		s.font_size = 32
	case .H2:
		s.font_size = 24
	case .H3:
		s.font_size = 20
	case .Table:
		s.display = .Table
	case .Thead, .Tbody, .Tfoot:
		s.display = .Table_Row_Group
	case .Tr:
		s.display = .Table_Row
	case .Td:
		s.display = .Table_Cell
		s.padding_top, s.padding_right, s.padding_bottom, s.padding_left = 1, 1, 1, 1
	case .Th:
		s.display = .Table_Cell
		s.padding_top, s.padding_right, s.padding_bottom, s.padding_left = 1, 1, 1, 1
		s.text_align = .Center
	case .Caption:
		s.text_align = .Center
	case .Dd:
		s.margin_left = 40
	case .Blockquote:
		s.margin_left = 40
		s.margin_right = 40
	case .Unknown, .Html, .Body, .Div, .P, .H4, .H5, .H6, .Ul, .Ol, .Li, .Header, .Footer,
	     .Main, .Nav, .Section, .Article, .Form, .Hr, .Pre, .Dl, .Dt:
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
	if d.has_text_align { style.text_align = d.text_align }
	if d.has_border_width { style.border_width = d.border_width }
	if d.has_border_style { style.border_style = d.border_style }
	if d.has_border_color { style.border_color = d.border_color }
}

@(private = "file")
compound_matches :: proc "contextless" (tree: ^Dom_Tree, sheet: ^Css_Stylesheet, node_idx: u32, compound: ^Css_Compound) -> bool {
	node := &tree.nodes[node_idx]
	if node.kind != .Element {
		return false
	}
	if compound.has_tag && node.tag != compound.tag {
		return false
	}
	for class_name in compound.classes[:compound.class_count] {
		if !dom_node_has_class(tree, node_idx, css_name_bytes(sheet, class_name)) {
			return false
		}
	}
	if compound.has_id {
		id_value, has_id := dom_node_attr(tree, node_idx, "id")
		if !has_id || string(id_value) != string(css_name_bytes(sheet, compound.id)) {
			return false
		}
	}
	return true
}

// selector_matches reads a selector from its right: the last compound at
// the node, then each compound to its left at the parent (a child
// combinator) or at an ancestor (a descendant combinator). One pass for
// each compound along the ancestors of the node, with no backtracking:
// the work is the compounds times the ancestors, whatever the page.
@(private = "file")
selector_matches :: proc "contextless" (tree: ^Dom_Tree, sheet: ^Css_Stylesheet, node_idx: u32, selector: ^Css_Selector) -> bool {
	if !selector.valid || selector.compound_count == 0 {
		return false
	}
	last := int(selector.compound_count) - 1
	if !compound_matches(tree, sheet, node_idx, &selector.compounds[last]) {
		return false
	}
	if last == 0 {
		return true
	}
	// path[0] is the node, path[i] its ancestor i levels up.
	path: [SELECTOR_ANCESTOR_LIMIT + 1]u32
	path[0] = node_idx
	path_count := 1
	ancestor := tree.nodes[node_idx].parent
	for ancestor != NO_NODE && path_count < len(path) {
		path[path_count] = ancestor
		path_count += 1
		ancestor = tree.nodes[ancestor].parent
	}
	// matched[i]: the compounds 0 .. k match with compound k at path[i].
	previous, current: [SELECTOR_ANCESTOR_LIMIT + 1]bool
	for i in 1 ..< path_count {
		previous[i] = compound_matches(tree, sheet, path[i], &selector.compounds[0])
	}
	for k in 1 ..= last {
		lowest := 0 if k == last else 1
		combinator := selector.combinators[k - 1]
		above := false // Some j > i has previous[j].
		for i := path_count - 1; i >= lowest; i -= 1 {
			current[i] = false
			related := false
			switch combinator {
			case .Child:
				related = i + 1 < path_count && previous[i + 1]
			case .Descendant:
				related = above
			}
			if related {
				current[i] = k == last || compound_matches(tree, sheet, path[i], &selector.compounds[k])
			}
			above ||= previous[i]
		}
		if k == last {
			return current[0]
		}
		previous = current
		previous[0] = false
	}
	return false
}

// resolve_styles computes cascaded and inherited styles for every node in
// tree. styles_out holds a style for each node, and matches a rule for each
// rule of the sheet: the memory of the layout tree (compute_layout).
@(private = "file")
resolve_styles :: proc "contextless" (tree: ^Dom_Tree, sheet: ^Css_Stylesheet, styles_out: []Computed_Style, matches: []Matched_Rule) {
	// Node indices are in preorder, so parent always precedes child.
	for i := 0; i < int(tree.node_count); i += 1 {
		n := &tree.nodes[i]
		parent_style: ^Computed_Style = nil
		if n.parent != NO_NODE && int(n.parent) < i {
			parent_style = &styles_out[n.parent]
		}
		switch n.kind {
		case .Document:
			styles_out[i] = Computed_Style {
				display        = .Block,
				flex_direction = .Row,
				color          = DEFAULT_TEXT_COLOR,
				font_size      = DEFAULT_FONT_SIZE,
				text_align     = .Left,
				border_style   = .None,
			}
			continue
		case .Text:
			styles_out[i] = Computed_Style {
				display        = .Inline,
				flex_direction = .Row,
				color          = parent_style.color if parent_style != nil else DEFAULT_TEXT_COLOR,
				font_size      = parent_style.font_size if parent_style != nil else DEFAULT_FONT_SIZE,
				text_align     = parent_style.text_align if parent_style != nil else .Left,
				border_style   = .None,
			}
			continue
		case .Comment, .Doctype:
			styles_out[i] = Computed_Style{display = .None, flex_direction = .Row, text_align = .Left, border_style = .None}
			continue
		case .Element:
		}

		st := ua_default_style(n.tag, parent_style)
		mcount := 0
		if sheet != nil {
			for r := 0; r < int(sheet.rule_count); r += 1 {
				rule := &sheet.rules[r]
				best_spec: u32 = 0
				matched := false
				for s := 0; s < int(rule.selector_count); s += 1 {
					if selector_matches(tree, sheet, u32(i), &rule.selectors[s]) {
						if !matched || rule.selectors[s].specificity > best_spec {
							best_spec = rule.selectors[s].specificity
						}
						matched = true
					}
				}
				if matched {
					matches[mcount] = Matched_Rule{rule_idx = u32(r), specificity = best_spec, order = rule.order}
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
		if inline_val, has_inline := dom_node_attr(tree, u32(i), "style"); has_inline {
			inline_decls := parse_declarations(inline_val)
			apply_declarations(&st, &inline_decls)
		}
		if st.border_style == .None {
			st.border_width = {}
		}

		styles_out[i] = st
	}
}

// Block, inline, flex and table layout engine.

@(private = "file")
layout_alloc_box :: proc "contextless" (layout: ^Layout_Tree, parent_box: u32, node_idx: u32, style: Computed_Style, is_text: bool) -> u32 {
	if !layout_room(layout, .Boxes, int(layout.box_count) + 1) {
		return NO_NODE
	}
	idx := layout.box_count
	layout.box_count += 1
	layout.boxes[idx] = Layout_Box {
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
	return i32(min(i64(len(text)) * i64(char_w), MAX_LAYOUT_COORD))
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
shift_subtree :: proc "contextless" (layout: ^Layout_Tree, box_idx: u32, dx, dy: i32, depth: int) {
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

// line_align moves the boxes of a finished line, from first up to stop,
// to the center or the right of the width of the content.
@(private = "file")
line_align :: proc "contextless" (layout: ^Layout_Tree, align: Text_Align, first, stop: u32, line_width, inner_width: i32) {
	if first == NO_NODE {
		return
	}
	room := inner_width - line_width
	dx: i32
	switch align {
	case .Left:
		return
	case .Center:
		dx = room / 2
	case .Right:
		dx = room
	}
	if dx <= 0 {
		return
	}
	box := first
	for box != NO_NODE && box != stop {
		shift_subtree(layout, box, dx, 0, 0)
		box = layout.boxes[box].next_sibling
	}
}

@(private = "file")
node_visible_in_flow :: proc "contextless" (tree: ^Dom_Tree, styles: []Computed_Style, node: u32) -> bool {
	if styles[node].display == .None {
		return false
	}
	return tree.nodes[node].kind != .Text || !is_whitespace_only(dom_node_text(tree, node))
}

// preferred_width measures the width that a node takes when nothing
// wraps: the widest line of its content, with its padding, its border and
// its margins. A table sizes its columns with it.
@(private = "file")
preferred_width :: proc "contextless" (tree: ^Dom_Tree, styles: []Computed_Style, node_idx: u32, depth: int) -> i32 {
	if depth > MAX_DOM_DEPTH {
		return 0
	}
	st := &styles[node_idx]
	node := &tree.nodes[node_idx]
	if st.display == .None {
		return 0
	}
	if node.kind == .Text {
		text := dom_node_text(tree, node_idx)
		if is_whitespace_only(text) {
			return 0
		}
		return measure_text_width(text, st.font_size)
	}
	margins := i64(st.margin_left) + i64(st.margin_right)
	if st.has_width {
		return i32(clamp(i64(st.width) + margins, 0, MAX_LAYOUT_COORD))
	}
	frame := i64(st.padding_left) + i64(st.padding_right) + i64(st.border_width[.Left]) + i64(st.border_width[.Right])
	in_a_row := st.display == .Table_Row || st.display == .Flex && st.flex_direction == .Row
	line: i64 = 0
	widest: i64 = 0
	items := 0
	child := node.first_child
	for child != NO_NODE {
		if node_visible_in_flow(tree, styles, child) {
			width := i64(preferred_width(tree, styles, child, depth + 1))
			child_node := &tree.nodes[child]
			switch {
			case in_a_row:
				if items > 0 {
					line += i64(st.gap)
				}
				line += width
			case child_node.kind == .Element && child_node.tag == .Br:
				widest = max(widest, line)
				line = 0
			case styles[child].display == .Inline:
				line += width
			case:
				widest = max(widest, line, width)
				line = 0
			}
			items += 1
		}
		child = tree.nodes[child].next_sibling
	}
	widest = max(widest, line)
	return i32(clamp(widest + frame + margins, 0, MAX_LAYOUT_COORD))
}

// table_row_measure widens each column to the preferred width of its cell
// in one row.
@(private = "file")
table_row_measure :: proc "contextless" (tree: ^Dom_Tree, styles: []Computed_Style, row: u32, preferred: ^[TABLE_COLUMN_CAPACITY]i32, column_count: ^int, depth: int) {
	column := 0
	cell := tree.nodes[row].first_child
	for cell != NO_NODE && column < TABLE_COLUMN_CAPACITY {
		if node_visible_in_flow(tree, styles, cell) {
			preferred[column] = max(preferred[column], preferred_width(tree, styles, cell, depth + 1))
			column += 1
		}
		cell = tree.nodes[cell].next_sibling
	}
	column_count^ = max(column_count^, column)
}

// table_row_lay_out lays out one row: each cell at the width of its
// column, then each cell box as high as the highest one. The result is
// the top of the next row.
@(private = "file")
table_row_lay_out :: proc "contextless" (tree: ^Dom_Tree, styles: []Computed_Style, layout: ^Layout_Tree, row: u32, parent_box: u32, left, top: i32, widths: ^[TABLE_COLUMN_CAPACITY]i32, column_count: int, depth: int) -> i32 {
	if depth > MAX_DOM_DEPTH {
		return top
	}
	row_box := layout_alloc_box(layout, parent_box, row, styles[row], false)
	if row_box == NO_NODE {
		return top
	}
	x := left
	row_height: i32 = 0
	column := 0
	cell := tree.nodes[row].first_child
	for cell != NO_NODE && column < column_count {
		if node_visible_in_flow(tree, styles, cell) {
			cell_box := layout_node(tree, styles, layout, cell, row_box, x, top, widths[column], false, depth + 1)
			if cell_box != NO_NODE {
				b := &layout.boxes[cell_box]
				row_height = max(row_height, b.style.margin_top + b.height + b.style.margin_bottom)
			}
			x += widths[column]
			column += 1
		}
		cell = tree.nodes[cell].next_sibling
	}
	child := layout.boxes[row_box].first_child
	for child != NO_NODE {
		b := &layout.boxes[child]
		if !b.is_text {
			target := row_height - b.style.margin_top - b.style.margin_bottom
			if target > b.height {
				frame_vertical := b.style.padding_top + b.style.padding_bottom + b.style.border_width[.Top] + b.style.border_width[.Bottom]
				b.height = target
				b.content_height = max(i32(0), target - frame_vertical)
			}
		}
		child = b.next_sibling
	}
	r := &layout.boxes[row_box]
	r.x, r.y, r.width, r.height = left, top, x - left, row_height
	r.content_x, r.content_y, r.content_width, r.content_height = left, top, x - left, row_height
	return top + row_height
}

// layout_table lays out a table: the columns as wide as their widest
// cell, cut in proportion when they do not fit, and spread over the width
// of a table that names its width; then the rows from the top, each in
// its row group when it has one.
@(private = "file")
layout_table :: proc "contextless" (tree: ^Dom_Tree, styles: []Computed_Style, layout: ^Layout_Tree, node_idx: u32, table_box: u32, left, top, inner_width: i32, fixed_width: bool, depth: int) -> (used_width, used_height: i32) {
	preferred: [TABLE_COLUMN_CAPACITY]i32
	column_count := 0
	child := tree.nodes[node_idx].first_child
	for child != NO_NODE {
		switch styles[child].display {
		case .Table_Row_Group:
			row := tree.nodes[child].first_child
			for row != NO_NODE {
				if styles[row].display == .Table_Row {
					table_row_measure(tree, styles, row, &preferred, &column_count, depth + 1)
				}
				row = tree.nodes[row].next_sibling
			}
		case .Table_Row:
			table_row_measure(tree, styles, child, &preferred, &column_count, depth)
		case .Block, .Inline, .Flex, .None, .Table, .Table_Cell:
		}
		child = tree.nodes[child].next_sibling
	}
	widths: [TABLE_COLUMN_CAPACITY]i32
	total: i64 = 0
	for column in 0 ..< column_count {
		total += i64(preferred[column])
	}
	if total > i64(inner_width) && total > 0 {
		for column in 0 ..< column_count {
			widths[column] = i32(i64(preferred[column]) * i64(inner_width) / total)
		}
	} else {
		widths = preferred
		if fixed_width && column_count > 0 && total < i64(inner_width) {
			extra := inner_width - i32(total)
			share := extra / i32(column_count)
			for column in 0 ..< column_count {
				widths[column] += share
			}
			widths[column_count - 1] += extra - share * i32(column_count)
		}
	}
	table_width: i32 = 0
	for column in 0 ..< column_count {
		table_width += widths[column]
	}
	cursor_y := top
	used_width = table_width
	child = tree.nodes[node_idx].first_child
	for child != NO_NODE {
		if !node_visible_in_flow(tree, styles, child) {
			child = tree.nodes[child].next_sibling
			continue
		}
		switch styles[child].display {
		case .Table_Row_Group:
			group_box := layout_alloc_box(layout, table_box, child, styles[child], false)
			if group_box == NO_NODE {
				break
			}
			group_top := cursor_y
			row := tree.nodes[child].first_child
			for row != NO_NODE {
				if styles[row].display == .Table_Row {
					cursor_y = table_row_lay_out(tree, styles, layout, row, group_box, left, cursor_y, &widths, column_count, depth + 2)
				} else if node_visible_in_flow(tree, styles, row) && depth + 2 <= MAX_DOM_DEPTH {
					other := layout_node(tree, styles, layout, row, group_box, left, cursor_y, table_width, false, depth + 2)
					if other != NO_NODE {
						b := &layout.boxes[other]
						cursor_y += b.style.margin_top + b.height + b.style.margin_bottom
					}
				}
				row = tree.nodes[row].next_sibling
			}
			g := &layout.boxes[group_box]
			g.x, g.y, g.width, g.height = left, group_top, table_width, cursor_y - group_top
			g.content_x, g.content_y, g.content_width, g.content_height = left, group_top, table_width, cursor_y - group_top
		case .Table_Row:
			cursor_y = table_row_lay_out(tree, styles, layout, child, table_box, left, cursor_y, &widths, column_count, depth + 1)
		case .Block, .Inline, .Flex, .None, .Table, .Table_Cell:
			// A caption, or content that a table built by CSS holds outside
			// its rows: a block across the table.
			other := layout_node(tree, styles, layout, child, table_box, left, cursor_y, max(table_width, inner_width), false, depth + 1)
			if other != NO_NODE {
				b := &layout.boxes[other]
				cursor_y += b.style.margin_top + b.height + b.style.margin_bottom
				used_width = max(used_width, b.style.margin_left + b.width + b.style.margin_right)
			}
		}
		child = tree.nodes[child].next_sibling
	}
	return used_width, cursor_y - top
}

@(private = "file")
layout_node :: proc "contextless" (tree: ^Dom_Tree, styles: []Computed_Style, layout: ^Layout_Tree, node_idx: u32, parent_box: u32, origin_x, origin_y, avail_width: i32, shrink_to_fit: bool, depth: int) -> u32 {
	if node_idx == NO_NODE || int(node_idx) >= int(tree.node_count) || depth > MAX_DOM_DEPTH {
		return NO_NODE
	}
	node := &tree.nodes[node_idx]
	st := styles[node_idx]
	if st.display == .None || node.kind == .Comment || node.kind == .Doctype {
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
			h = i32(min(i64(lines) * i64(max(i32(4), st.font_size)), MAX_LAYOUT_COORD))
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
	frame_left := st.padding_left + st.border_width[.Left]
	frame_right := st.padding_right + st.border_width[.Right]
	frame_top := st.padding_top + st.border_width[.Top]
	frame_bottom := st.padding_bottom + st.border_width[.Bottom]
	frame_horizontal := frame_left + frame_right
	frame_vertical := frame_top + frame_bottom

	border_w: i32
	if st.has_width {
		border_w = st.width
	} else {
		border_w = max(i32(0), avail_width - st.margin_left - st.margin_right)
	}
	inner_w := max(i32(0), border_w - frame_horizontal)
	cx := box_x + frame_left
	cy := box_y + frame_top
	shrinks := !st.has_width && (shrink_to_fit || st.display == .Inline || st.display == .Table)

	used_w: i32 = 0
	used_h: i32 = 0

	switch st.display {
	case .Flex:
		if st.flex_direction == .Row {
			cursor_x := cx
			max_child_h: i32 = 0
			visible_count := 0
			child := node.first_child
			for child != NO_NODE {
				if !node_visible_in_flow(tree, styles, child) {
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
			cursor_y := cy
			max_child_w: i32 = 0
			visible_count := 0
			child := node.first_child
			for child != NO_NODE {
				if !node_visible_in_flow(tree, styles, child) {
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
	case .Table:
		used_w, used_h = layout_table(tree, styles, layout, node_idx, bidx, cx, cy, inner_w, st.has_width, depth)
	case .Block, .Inline, .Table_Row_Group, .Table_Row, .Table_Cell, .None:
		// Block or inline flow with line wrapping. A part of a table outside
		// a table is a block.
		align := st.text_align if !shrinks else .Left
		cursor_y := cy
		line_x := cx
		line_h: i32 = 0
		line_first := NO_NODE
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
				line_align(layout, align, line_first, NO_NODE, line_x - cx, inner_w)
				cursor_y += max(line_h, max(i32(4), st.font_size))
				max_line_w = max(max_line_w, line_x - cx)
				line_x = cx
				line_h = 0
				line_first = NO_NODE
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
						line_align(layout, align, line_first, cb, line_x - cx, inner_w)
						max_line_w = max(max_line_w, line_x - cx)
						cursor_y += max(line_h, max(i32(4), st.font_size))
						dx := cx - line_x
						dy := cursor_y - (cbox.y - cbox.style.margin_top)
						shift_subtree(layout, cb, dx, dy, 0)
						line_x = cx + outer_w
						line_h = outer_h
						line_first = cb
					} else {
						if line_first == NO_NODE {
							line_first = cb
						}
						line_x += outer_w
						if outer_h > line_h {
							line_h = outer_h
						}
					}
				}
			} else {
				// Block, flex or table child flushes any pending inline line first.
				if line_x > cx || line_h > 0 {
					line_align(layout, align, line_first, NO_NODE, line_x - cx, inner_w)
					max_line_w = max(max_line_w, line_x - cx)
					cursor_y += line_h
					line_x = cx
					line_h = 0
				}
				line_first = NO_NODE
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
			line_align(layout, align, line_first, NO_NODE, line_x - cx, inner_w)
			max_line_w = max(max_line_w, line_x - cx)
			cursor_y += line_h
		}
		used_w = max_line_w
		used_h = cursor_y - cy
	}

	final_w := border_w
	if shrinks {
		final_w = used_w + frame_horizontal
	}
	final_h := st.height if st.has_height else (used_h + frame_vertical)

	b := &layout.boxes[bidx]
	b.x = box_x
	b.y = box_y
	b.width = max(i32(0), final_w)
	b.height = max(i32(0), final_h)
	b.content_x = cx
	b.content_y = cy
	b.content_width = max(i32(0), b.width - frame_horizontal)
	b.content_height = max(i32(0), b.height - frame_vertical)
	return bidx
}

// layout_tree_clear empties a layout tree and keeps its memory and its
// grow procedure. It wipes the styles, the boxes and the matched rules of
// the last layout, as dom_tree_clear wipes a tree.
layout_tree_clear :: proc "contextless" (layout: ^Layout_Tree) {
	zero_entries(layout.node_styles, int(layout.styled_count))
	zero_entries(layout.boxes, int(layout.box_count))
	zero_entries(layout.matched, int(layout.matched_count))
	layout^ = {node_styles = layout.node_styles, boxes = layout.boxes, matched = layout.matched, grow = layout.grow, grow_data = layout.grow_data}
	layout.root_box = NO_NODE
}

// compute_layout resolves CSS cascade and computes pixel Layout_Box rects for the DOM tree.
compute_layout :: proc "contextless" (tree: ^Dom_Tree, sheet: ^Css_Stylesheet, viewport_width, viewport_height: i32, layout_out: ^Layout_Tree) {
	layout_tree_clear(layout_out)
	if tree.node_count == 0 {
		return
	}
	// The styles of each node and the work of the cascade: with no room
	// for them, there is no layout, and the tree says that it is cut.
	rules := sheet != nil ? int(sheet.rule_count) : 0
	if !layout_room(layout_out, .Styles, int(tree.node_count)) || !layout_room(layout_out, .Matched, max(rules, 1)) {
		return
	}
	layout_out.styled_count, layout_out.matched_count = tree.node_count, u32(max(rules, 1))
	resolve_styles(tree, sheet, layout_out.node_styles, layout_out.matched)
	vw := max(i32(0), min(viewport_width, MAX_LAYOUT_COORD))
	_ = viewport_height
	layout_out.root_box = layout_node(tree, layout_out.node_styles, layout_out, 0, NO_NODE, 0, 0, vw, false, 0)
}

// layout_find_box_by_id returns the Layout_Box index for the first element with matching HTML id attribute.
layout_find_box_by_id :: proc "contextless" (tree: ^Dom_Tree, layout: ^Layout_Tree, id: string) -> (box_idx: u32, found: bool) {
	for i := 0; i < int(layout.box_count); i += 1 {
		b := &layout.boxes[i]
		if !b.used || b.is_text {
			continue
		}
		val, ok := dom_node_attr(tree, b.node_index, "id")
		if ok && string(val) == id {
			return u32(i), true
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
emit_rectangle :: proc "contextless" (records_out: []draw_record.Draw_Record, rec_count: ^int, element: u32, color: draw_record.Draw_Color, left, top, right, bottom: i32) {
	if color == 0 || right <= left || bottom <= top || rec_count^ >= len(records_out) {
		return
	}
	records_out[rec_count^] = draw_record.record_of(
		draw_record.Draw_Rectangle{color = color},
		element,
		draw_record.units_of_pixels(int(left)),
		draw_record.units_of_pixels(int(top)),
		draw_record.units_of_pixels(int(right)),
		draw_record.units_of_pixels(int(bottom)),
	)
	rec_count^ += 1
}

@(private = "file")
emit_box_paint :: proc "contextless" (tree: ^Dom_Tree, layout: ^Layout_Tree, box_idx: u32, records_out: []draw_record.Draw_Record, text_out: []u8, rec_count: ^int, text_pos: ^int, depth: int) {
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
	element := u32(b.node_index) + 1

	if !b.is_text {
		emit_rectangle(records_out, rec_count, element, b.style.background_color, left_px, top_px, right_px, bottom_px)
		// The border: four bands inside the box, in the color of the text
		// when it names none.
		color := b.style.border_color if b.style.border_color != 0 else b.style.color
		widths := b.style.border_width
		top_edge := min(top_px + widths[.Top], bottom_px)
		bottom_edge := max(bottom_px - widths[.Bottom], top_px)
		emit_rectangle(records_out, rec_count, element, color, left_px, top_px, right_px, top_edge)
		emit_rectangle(records_out, rec_count, element, color, left_px, bottom_edge, right_px, bottom_px)
		emit_rectangle(records_out, rec_count, element, color, left_px, top_edge, min(left_px + widths[.Left], right_px), bottom_edge)
		emit_rectangle(records_out, rec_count, element, color, max(right_px - widths[.Right], left_px), top_edge, right_px, bottom_edge)
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
				draw_record.Draw_Text {
					first    = first,
					count    = u32(len(txt)),
					color    = b.style.color,
					origin_x = draw_record.units_of_pixels(int(left_px)),
					font     = .Cells_8x16,
					weight   = .Regular,
					size     = u16(fs * draw_record.UNITS_PER_PIXEL),
				},
				element,
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

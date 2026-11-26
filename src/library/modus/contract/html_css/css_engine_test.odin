#+build !freestanding
#+build !modus
package html_css

import "core:strings"
import "core:testing"
import "modus:contract/draw_record"

// The tests of the CSS engine: the selectors and their specificity, the
// cascade, and the layout of borders, text alignment, tables and display.

@(private = "file")
Css_Fixture :: struct {
	tree:   Dom_Tree,
	sheet:  Css_Stylesheet,
	layout: Layout_Tree,
}

// fixture_make gives a fixture whose memory grows from the heap.
@(private = "file")
fixture_make :: proc() -> ^Css_Fixture {
	fixture := new(Css_Fixture)
	fixture.tree.grow = test_dom_grow
	fixture.sheet.grow = test_css_grow
	fixture.layout.grow = test_layout_grow
	return fixture
}

@(private = "file")
fixture_lay_out :: proc(fixture: ^Css_Fixture, html, css: string, width: i32 = 800) {
	origin := Document_Origin {
		principal_id = 1,
		scheme       = .Https,
		port         = 443,
	}
	origin.host_len = u16(copy(origin.host[:], "css.example"))
	parse_html(&fixture.tree, origin, transmute([]u8)html)
	stylesheet_clear(&fixture.sheet)
	parse_stylesheet(&fixture.sheet, transmute([]u8)css)
	parse_document_styles(&fixture.tree, &fixture.sheet)
	compute_layout(&fixture.tree, &fixture.sheet, width, 600, &fixture.layout)
}

@(private = "file")
box_of :: proc(t: ^testing.T, fixture: ^Css_Fixture, id: string, location := #caller_location) -> ^Layout_Box {
	index, found := layout_find_box_by_id(&fixture.tree, &fixture.layout, id)
	testing.expectf(t, found, "no box with the id %s", id, loc = location)
	if !found {
		@(static) empty: Layout_Box
		empty = {}
		return &empty
	}
	return &fixture.layout.boxes[index]
}

@(private = "file")
join :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

@(private = "file")
SPECIFICITY_ID :: 1 << 16
@(private = "file")
SPECIFICITY_CLASS :: 1 << 8
@(private = "file")
SPECIFICITY_TAG :: 1

// The specificity of a selector is (ids, classes, tags), summed over its
// compound selectors; the universal selector counts nothing.
@(test)
selector_specificity_is_ids_classes_tags :: proc(t: ^testing.T) {
	sheet := test_sheet_make()
	defer free(sheet)
	Case :: struct {
		selector:    string,
		specificity: u32,
		compounds:   u8,
	}
	cases := [?]Case {
		{"*", 0, 1},
		{"p", SPECIFICITY_TAG, 1},
		{".a", SPECIFICITY_CLASS, 1},
		{"#a", SPECIFICITY_ID, 1},
		{"#a .b p", SPECIFICITY_ID + SPECIFICITY_CLASS + SPECIFICITY_TAG, 3},
		{"div > p.x.y", 2 * SPECIFICITY_CLASS + 2 * SPECIFICITY_TAG, 2},
		{"ul li a", 3 * SPECIFICITY_TAG, 3},
		{"*.a > * #b", SPECIFICITY_ID + SPECIFICITY_CLASS, 3},
		{"  div   p  ", 2 * SPECIFICITY_TAG, 2},
		{"div>p", 2 * SPECIFICITY_TAG, 2},
		{".a.b.c.d", 4 * SPECIFICITY_CLASS, 1},
		{"a b i u", 4 * SPECIFICITY_TAG, 4},
	}
	for item in cases {
		stylesheet_clear(sheet)
		parse_stylesheet(sheet, transmute([]u8)join(item.selector, " { color: red }"))
		testing.expectf(t, sheet.rule_count == 1, "%q: %d rules", item.selector, sheet.rule_count)
		if sheet.rule_count == 1 {
			selector := sheet.rules[0].selectors[0]
			testing.expectf(t, selector.specificity == item.specificity, "%q: specificity %x, not %x", item.selector, selector.specificity, item.specificity)
			testing.expectf(t, selector.compound_count == item.compounds, "%q: %d compounds", item.selector, selector.compound_count)
		}
	}
}

// A selector that the engine does not read makes its whole rule dropped,
// as CSS drops a rule whose selector list holds an invalid selector.
@(test)
invalid_selectors_drop_their_rule :: proc(t: ^testing.T) {
	sheet := test_sheet_make()
	defer free(sheet)
	refused := [?]string {
		"p, a:hover",
		"div + p",
		"div ~ p",
		"[href]",
		"div >",
		"> p",
		"div > > p",
		"#a#b",
		".a.b.c.d.e",
		"a b c d e",
		"unknowntag",
		".",
		"#",
		"",
		",",
		"p,",
		"p,p,p,p,p,p,p,p,p",
		"@media screen",
	}
	for selector in refused {
		stylesheet_clear(sheet)
		parse_stylesheet(sheet, transmute([]u8)join(selector, " { color: red }"))
		testing.expectf(t, sheet.rule_count == 0, "%q was kept", selector)
		testing.expectf(t, sheet.name_count == 0, "%q left %d bytes of names", selector, sheet.name_count)
	}
	// Eight selectors is the bound: kept.
	stylesheet_clear(sheet)
	parse_stylesheet(sheet, transmute([]u8)string("p,p,p,p,p,p,p,p { color: red } div { color: blue }"))
	testing.expect_value(t, sheet.rule_count, u32(2))
	testing.expect_value(t, sheet.rules[0].selector_count, u8(MAX_SELECTORS_PER_RULE))
	testing.expect_value(t, sheet.rules[1].order, u32(1))
}

// The cascade orders the rules by specificity, then by source order: an
// id beats any count of classes, a class beats any count of tags, and of
// two equal selectors the later one wins.
@(test)
cascade_orders_by_specificity_then_source :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	html := `<div id="a" class="b c"><p id="t" class="x">t</p><p id="u">u</p></div>`
	css := `
		#a p { color: #000005; }
		.b.c .x { color: #000004; background: #000004; }
		.x { color: #000003; background: #000003; }
		div > p { color: #000002; background: #000002; }
		div p { color: #000001; background: #000001; font-size: 20px; }
		* { color: #0000FF; font-size: 10px; }
	`
	fixture_lay_out(fixture, html, css)
	t_box := box_of(t, fixture, "t")
	testing.expect_value(t, t_box.style.color, draw_record.opaque(0x000005))
	testing.expect_value(t, t_box.style.background_color, draw_record.opaque(0x000004))
	testing.expect_value(t, t_box.style.font_size, i32(20))
	u_box := box_of(t, fixture, "u")
	testing.expect_value(t, u_box.style.color, draw_record.opaque(0x000005))
	// div > p and div p have the same specificity: the earlier rule in the
	// sheet loses to the later one.
	testing.expect_value(t, u_box.style.background_color, draw_record.opaque(0x000001))
	// The inline style beats every rule.
	fixture_lay_out(fixture, `<p id="v" style="color: #00000A">v</p>`, "#v { color: #000009 }")
	testing.expect_value(t, box_of(t, fixture, "v").style.color, draw_record.opaque(0x00000A))
}

// The child combinator needs the parent, the descendant combinator any
// ancestor; a selector with both finds an ancestor past the nearest one
// that matches when the nearest one fails the rest of the selector.
@(test)
combinators_match_parents_and_ancestors :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	html := `<section><div class="y"><div class="x"><div class="x"><p id="deep">d</p></div></div></div><p id="near">n</p></section>`
	Case :: struct {
		selector: string,
		deep:     bool,
		near:     bool,
	}
	cases := [?]Case {
		{"section p", true, true},
		{"section > p", false, true},
		{"div p", true, false},
		{".x > p", true, false},
		{".y > .x p", true, false},
		{".y > .x > .x > p", true, false},
		{".y > .x > p", false, false},
		{".x .y p", false, false},
		{"section > div > div > div > p", false, false},
		{"section > .y .x > p", true, false},
		{"p p", false, false},
		{"* > p", true, true},
	}
	for item in cases {
		css := join(item.selector, " { color: #FF0000 }")
		fixture_lay_out(fixture, html, css)
		deep := box_of(t, fixture, "deep").style.color == draw_record.opaque(0xFF0000)
		near := box_of(t, fixture, "near").style.color == draw_record.opaque(0xFF0000)
		testing.expectf(t, deep == item.deep && near == item.near, "%q: deep %v near %v", item.selector, deep, near)
	}
}

// text-align moves each line of a block to its center or its right, and
// is inherited.
@(test)
text_align_moves_the_lines :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	fixture_lay_out(fixture, `<div style="width:200px;text-align:center"><span id="s">abcd</span></div><div style="width:200px;text-align:right"><p><span id="r">ab</span></p></div><div style="width:200px"><span id="l">ab</span></div>`, "")
	testing.expect_value(t, box_of(t, fixture, "s").x, i32((200 - 32) / 2))
	testing.expect_value(t, box_of(t, fixture, "r").x, i32(200 - 16))
	testing.expect_value(t, box_of(t, fixture, "l").x, i32(0))
	// A line wider than the block stays at its left.
	fixture_lay_out(fixture, `<div style="width:20px;text-align:right"><span id="w">abcdefgh</span></div>`, "")
	testing.expect_value(t, box_of(t, fixture, "w").x, i32(0))
}

// A border takes room inside the box, its style none takes none, and it is
// painted as four rectangles in its color, or in the color of the text.
@(test)
borders_take_room_and_paint :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	fixture_lay_out(fixture, `<div id="b" style="width:100px;border:2px solid red;padding:3px">x</div><div id="n" style="width:100px;border:2px">y</div><div id="s" style="width:100px;border-width:1px 2px 3px 4px;border-style:dashed;color:#123456">z</div><div id="o" style="border: red solid thick">o</div>`, "")
	b := box_of(t, fixture, "b")
	testing.expect_value(t, b.width, i32(100))
	testing.expect_value(t, b.content_x, i32(5))
	testing.expect_value(t, b.content_width, i32(90))
	testing.expect_value(t, b.height, i32(16 + 10))
	n := box_of(t, fixture, "n")
	testing.expect_value(t, n.content_x, i32(0))
	testing.expect_value(t, n.style.border_width, [Box_Side]i32{})
	s := box_of(t, fixture, "s")
	testing.expect_value(t, s.content_x, i32(4))
	testing.expect_value(t, s.content_width, i32(100 - 6))
	testing.expect_value(t, s.height, i32(16 + 4))
	o := box_of(t, fixture, "o")
	testing.expect_value(t, o.style.border_width[.Left], i32(5))
	records: [256]draw_record.Draw_Record
	text: [256]u8
	count, _ := emit_draw_records(&fixture.tree, &fixture.layout, records[:], text[:])
	border_records := 0
	ink_records := 0
	for record in records[:count] {
		primitive, problem := draw_record.read(record)
		testing.expect_value(t, problem, draw_record.Problem.None)
		rectangle, is_rectangle := primitive.(draw_record.Draw_Rectangle)
		if !is_rectangle {
			continue
		}
		if record.element == u32(b.node_index) + 1 && rectangle.color == draw_record.opaque(0xFF0000) {
			border_records += 1
		}
		if record.element == u32(s.node_index) + 1 && rectangle.color == draw_record.opaque(0x123456) {
			ink_records += 1
		}
		testing.expectf(t, record.element != u32(n.node_index) + 1, "a border of style none painted")
	}
	testing.expect_value(t, border_records, 4)
	testing.expect_value(t, ink_records, 4)
	// A shorthand with a part that it does not read sets nothing.
	declarations := parse_declarations(transmute([]u8)string("border: 1px solid red blue"))
	testing.expect(t, !declarations.has_border_width && !declarations.has_border_style, "two colors refused")
	declarations = parse_declarations(transmute([]u8)string("border: -1px solid"))
	testing.expect(t, !declarations.has_border_width, "a negative width refused")
}

// margin and padding take 1 to 4 values, and refuse 0 and 5.
@(test)
box_shorthands_one_to_four_values :: proc(t: ^testing.T) {
	Case :: struct {
		value:                    string,
		top, right, bottom, left: i32,
	}
	cases := [?]Case {
		{"1px", 1, 1, 1, 1},
		{"1px 2px", 1, 2, 1, 2},
		{"1px 2px 3px", 1, 2, 3, 2},
		{"1px 2px 3px 4px", 1, 2, 3, 4},
		{"0 65537px -3px 4", 0, MAX_LAYOUT_COORD, -3, 4},
	}
	for item in cases {
		d := parse_declarations(transmute([]u8)join("margin: ", item.value))
		testing.expectf(t, d.has_margin_top && d.margin_top == item.top && d.margin_right == item.right && d.margin_bottom == item.bottom && d.margin_left == item.left, "margin: %s gives %v", item.value, d)
	}
	for refused in ([?]string{"", "1px 2px 3px 4px 5px", "1em", "auto", "1px x"}) {
		d := parse_declarations(transmute([]u8)join("margin: ", refused, "; padding: ", refused))
		testing.expectf(t, !d.has_margin_top && !d.has_padding_top, "%q accepted", refused)
	}
	d := parse_declarations(transmute([]u8)string("padding: 1px -2px"))
	testing.expect(t, !d.has_padding_left, "a negative padding refused")
}

// A table lays its cells out in columns as wide as their widest cell, its
// rows as high as their highest cell, and spreads the columns over the
// width that it names, or cuts them to fit the view.
@(test)
table_grid_rows_and_columns :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	html := `<table id="t"><tr><td id="a">x</td><td id="b">yyyy</td></tr><tr><td id="c">zzzzzz</td><td id="d" style="padding:10px">w</td></tr></table>`
	fixture_lay_out(fixture, html, "")
	a := box_of(t, fixture, "a")
	b := box_of(t, fixture, "b")
	c := box_of(t, fixture, "c")
	d := box_of(t, fixture, "d")
	testing.expect_value(t, a.x, c.x)
	testing.expect_value(t, b.x, d.x)
	testing.expect_value(t, a.width, i32(48 + 2))
	testing.expect_value(t, b.x - a.x, i32(50))
	// The second column: "yyyy" (32 + 2) is wider than "w" with its padding (8 + 20).
	testing.expect_value(t, b.width, i32(32 + 2))
	testing.expect_value(t, a.height, b.height)
	testing.expect_value(t, c.height, d.height)
	testing.expect_value(t, c.height, i32(16 + 20))
	testing.expect_value(t, c.y, a.y + a.height)
	table := box_of(t, fixture, "t")
	testing.expect_value(t, table.width, i32(50 + 34))
	// A table that names its width spreads its columns over it.
	fixture_lay_out(fixture, `<table id="t" style="width:400px"><tr><td id="a">x</td><td id="b">y</td></tr></table>`, "")
	a = box_of(t, fixture, "a")
	b = box_of(t, fixture, "b")
	testing.expect_value(t, a.width + b.width, i32(400))
	testing.expect_value(t, box_of(t, fixture, "t").width, i32(400))
	// A table wider than the view cuts its columns in proportion.
	fixture_lay_out(fixture, html, "", 60)
	a = box_of(t, fixture, "a")
	b = box_of(t, fixture, "b")
	testing.expect(t, a.width + b.width <= 60, "the columns fit the view")
	testing.expect(t, a.width > b.width, "the wider column stays wider")
	// More cells than columns of the capacity: the cells past it get no box.
	many := "<table><tr>"
	for _ in 0 ..< TABLE_COLUMN_CAPACITY + 4 {
		many = join(many, "<td>c</td>")
	}
	fixture_lay_out(fixture, join(many, "</tr></table>"), "")
	cells := 0
	for box in fixture.layout.boxes[:fixture.layout.box_count] {
		if !box.is_text && fixture.tree.nodes[box.node_index].tag == .Td {
			cells += 1
		}
	}
	testing.expect_value(t, cells, TABLE_COLUMN_CAPACITY)
}

// display: none removes a box and its subtree; inline puts a block in the
// line; block takes a whole line; flex row puts the children side by side;
// table on a div makes a grid of its rows.
@(test)
display_modes_by_css :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	html := `<div class="gone"><p id="hidden">h</p></div><div id="i1" class="inline">aa</div><div id="i2" class="inline">bb</div><span id="blk" class="block">c</span><div class="row"><div id="f1">1</div><div id="f2">2</div></div><div class="grid"><div class="r"><div id="g1" class="c">ab</div><div id="g2" class="c">c</div></div></div>`
	css := `.gone { display: none } .inline { display: inline } .block { display: block } .row { display: flex; flex-direction: row; gap: 4px } #f1 { width: 30px } .grid { display: table } .r { display: table-row } .c { display: table-cell }`
	fixture_lay_out(fixture, html, css)
	_, hidden := layout_find_box_by_id(&fixture.tree, &fixture.layout, "hidden")
	testing.expect(t, !hidden, "a box under display: none")
	i1 := box_of(t, fixture, "i1")
	i2 := box_of(t, fixture, "i2")
	testing.expect_value(t, i2.y, i1.y)
	testing.expect_value(t, i2.x, i1.x + i1.width)
	block := box_of(t, fixture, "blk")
	testing.expect(t, block.y >= i1.y + i1.height, "a block starts a new line")
	testing.expect_value(t, block.width, i32(800))
	f1 := box_of(t, fixture, "f1")
	f2 := box_of(t, fixture, "f2")
	testing.expect_value(t, f2.y, f1.y)
	testing.expect_value(t, f2.x, f1.x + 30 + 4)
	g1 := box_of(t, fixture, "g1")
	g2 := box_of(t, fixture, "g2")
	testing.expect_value(t, g2.y, g1.y)
	testing.expect_value(t, g2.x, g1.x + 16)
	// An unknown display keeps the default.
	d := parse_declarations(transmute([]u8)string("display: grid"))
	testing.expect(t, !d.has_display, "display: grid is not read")
}

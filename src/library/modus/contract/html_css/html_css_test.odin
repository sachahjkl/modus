#+build !freestanding
package html_css

import "core:testing"
import "modus:contract/draw_record"

@(private = "file")
make_test_origin :: proc(principal_id: u64, host: string) -> Document_Origin {
	o := Document_Origin{
		principal_id = principal_id,
		scheme       = .Https,
		port         = 443,
	}
	copy(o.host[:], host)
	o.host_len = u16(len(host))
	return o
}

@(test)
test_html_malformed_void_rawtext_and_implicit_closure :: proc(t: ^testing.T) {
	tree := new(Dom_Tree)
	defer free(tree)

	html := `<!DOCTYPE html>
<!-- leading comment --><!-->
<div id="root" class="a b" data-flag>
  <p>first<p>second<br><img src="a.png" alt="A &amp; B">
  <ul><li>one<li>two</ul>
  <script>if (x < 5 && y > 3) { var s = "<div>&amp;</div>"; }</script>
  <span><b>misnested</div></span></p>
</div>`

	parse_html(tree, make_test_origin(0, "example.com"), transmute([]u8)html)
	testing.expect(t, tree.node_count > 10, "tree must contain parsed elements and text")
	testing.expect(t, !tree.truncated, "normal HTML must not truncate")

	// Verify script content is verbatim raw text (no inner <div> node, no entity decoding).
	found_script := false
	for i := 0; i < int(tree.node_count); i += 1 {
		n := &tree.nodes[i]
		if n.kind == .Element && n.tag == .Script {
			found_script = true
			testing.expect(t, n.first_child != NO_NODE, "script must have raw text child")
			raw := string(dom_node_text(tree, n.first_child))
			testing.expect_value(t, raw, `if (x < 5 && y > 3) { var s = "<div>&amp;</div>"; }`)
		}
		if n.kind == .Element && (n.tag == .Br || n.tag == .Img) {
			testing.expect_value(t, n.first_child, NO_NODE)
		}
		if n.kind == .Element && n.tag == .Img {
			alt, ok := dom_node_attr(tree, u16(i), "alt")
			testing.expect(t, ok && string(alt) == "A & B", "img alt attribute must decode &amp;")
		}
	}
	testing.expect(t, found_script, "must find script element")

	// Verify implicit <p> closure: the two <p> elements must be siblings, not nested.
	p_parents: [4]u16
	p_count := 0
	for i := 0; i < int(tree.node_count); i += 1 {
		if tree.nodes[i].kind == .Element && tree.nodes[i].tag == .P && p_count < 4 {
			p_parents[p_count] = tree.nodes[i].parent
			p_count += 1
		}
	}
	testing.expect_value(t, p_count, 2)
	testing.expect_value(t, p_parents[0], p_parents[1])
}

@(test)
test_html_entity_decoding_edge_cases :: proc(t: ^testing.T) {
	tree := new(Dom_Tree)
	defer free(tree)

	html := `<p>&amp;&lt;&gt;&quot;&apos;&#65;&#x42;&unknown;&;&#;&#xZZ;&#0;&#xD800;&#x110000;</p>`
	parse_html(tree, make_test_origin(0, "example.com"), transmute([]u8)html)

	txt := ""
	for i := 0; i < int(tree.node_count); i += 1 {
		if tree.nodes[i].kind == .Element && tree.nodes[i].tag == .P {
			txt = string(dom_node_text(tree, tree.nodes[i].first_child))
			break
		}
	}
	expected := "&<>\"'AB&unknown;&;&#;&#xZZ;\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD"
	testing.expect_value(t, txt, expected)
}

@(test)
test_deep_nesting_500_divs_bounded_safely :: proc(t: ^testing.T) {
	buf := make([]u8, 500 * 11 + 10)
	defer delete(buf)
	pos := 0
	for i := 0; i < 500; i += 1 {
		copy(buf[pos:], "<div>")
		pos += 5
	}
	copy(buf[pos:], "leaf")
	pos += 4
	for i := 0; i < 500; i += 1 {
		copy(buf[pos:], "</div>")
		pos += 6
	}

	tree := new(Dom_Tree)
	layout := new(Layout_Tree)
	sheet := new(Css_Stylesheet)
	defer free(tree)
	defer free(layout)
	defer free(sheet)

	parse_html(tree, make_test_origin(0, "deep.example"), buf[:pos])
	testing.expect(t, tree.truncated, "500-deep input must record truncation")
	testing.expect(t, tree.max_depth_reached <= MAX_DOM_DEPTH, "DOM depth must never exceed MAX_DOM_DEPTH")
	testing.expect(t, tree.node_count <= MAX_DOM_NODES, "DOM node count must never exceed MAX_DOM_NODES")

	compute_layout(tree, sheet, 800, 600, layout)
	records := make([]draw_record.Draw_Record, 512)
	text_buf := make([]u8, 4096)
	defer delete(records)
	defer delete(text_buf)
	rc, _ := emit_draw_records(tree, layout, records, text_buf)
	for i := 0; i < rc; i += 1 {
		_, prob := draw_record.read(records[i])
		testing.expect_value(t, prob, draw_record.Problem.None)
	}
}

@(test)
test_fuzzed_byte_soup_1000_inputs_never_panics :: proc(t: ^testing.T) {
	tree := new(Dom_Tree)
	sheet := new(Css_Stylesheet)
	layout := new(Layout_Tree)
	records := make([]draw_record.Draw_Record, 512)
	text_buf := make([]u8, 8192)
	soup := make([]u8, 256)
	defer free(tree)
	defer free(sheet)
	defer free(layout)
	defer delete(records)
	defer delete(text_buf)
	defer delete(soup)

	alphabet := "<div></p><br/><script><!-- -->&amp;&#xFF;=\"' \t\r\n{}color:#f00;display:flex;gap:4px;/*"
	state: u64 = 0x9E37_79B9_7F4A_7C15
	origin := make_test_origin(7, "fuzz.example")

	for iter := 0; iter < 1000; iter += 1 {
		state ~= state >> 12
		state ~= state << 25
		state ~= state >> 27
		slen := int((state * 0x2545_F491_4F6C_DD1D) % 256)

		for j := 0; j < slen; j += 1 {
			state ~= state >> 12
			state ~= state << 25
			state ~= state >> 27
			r := (state * 0x2545_F491_4F6C_DD1D) >> 32
			if (r & 3) == 0 {
				soup[j] = u8(r & 0xFF)
			} else {
				soup[j] = alphabet[int(r) % len(alphabet)]
			}
		}

		parse_html(tree, origin, soup[:slen])
		testing.expect(t, tree.node_count <= MAX_DOM_NODES, "node_count bounded")
		testing.expect(t, tree.attr_count <= MAX_ATTRS, "attr_count bounded")
		testing.expect(t, tree.max_depth_reached <= MAX_DOM_DEPTH, "depth bounded")

		sheet^ = {}
		parse_stylesheet(sheet, soup[:slen])
		parse_document_styles(tree, sheet)
		compute_layout(tree, sheet, 640, 480, layout)
		testing.expect(t, layout.box_count <= MAX_DOM_NODES, "box_count bounded")

		rc, _ := emit_draw_records(tree, layout, records, text_buf)
		for k := 0; k < rc; k += 1 {
			_, prob := draw_record.read(records[k])
			testing.expect_value(t, prob, draw_record.Problem.None)
		}
	}
}

@(test)
test_css_cascade_specificity_and_inheritance :: proc(t: ^testing.T) {
	tree := new(Dom_Tree)
	sheet := new(Css_Stylesheet)
	layout := new(Layout_Tree)
	defer free(tree)
	defer free(sheet)
	defer free(layout)

	html := `<div id="outer"><p id="hero" class="lead"><span>Hello</span></p></div>`
	css := `
		#outer { color: #112233; font-size: 20px; background-color: #EEEEEE; padding: 8px; }
		#hero { color: #FF0000; }
		.lead { color: #00FF00; background-color: #222222; }
		p { color: #0000FF; background-color: #111111; }
	`

	parse_html(tree, make_test_origin(1, "cascade.example"), transmute([]u8)html)
	parse_stylesheet(sheet, transmute([]u8)css)
	compute_layout(tree, sheet, 800, 600, layout)

	hero_box_idx, found := layout_find_box_by_id(tree, layout, "hero")
	testing.expect(t, found, "must locate #hero box")
	hero := &layout.boxes[hero_box_idx]
	testing.expect_value(t, hero.style.color, draw_record.opaque(0xFF0000))
	testing.expect_value(t, hero.style.background_color, draw_record.opaque(0x222222))
	testing.expect_value(t, hero.style.font_size, i32(20))
	testing.expect_value(t, hero.style.padding_left, i32(0))

	span_box := &layout.boxes[hero.first_child]
	testing.expect_value(t, span_box.style.color, draw_record.opaque(0xFF0000))
	testing.expect_value(t, span_box.style.font_size, i32(20))
	testing.expect_value(t, span_box.style.background_color, draw_record.Draw_Color(0))
}

@(test)
test_block_inline_flex_layout_and_draw_records :: proc(t: ^testing.T) {
	tree := new(Dom_Tree)
	sheet := new(Css_Stylesheet)
	layout := new(Layout_Tree)
	defer free(tree)
	defer free(sheet)
	defer free(layout)

	html := `
	<div id="page">
		<div id="header">Header</div>
		<div id="hidden">Invisible</div>
		<div id="row">
			<div id="c1">A</div>
			<div id="c2">B</div>
			<div id="c3">C</div>
		</div>
		<div id="col">
			<div id="r1">Top</div>
			<div id="r2">Bottom</div>
		</div>
		<div id="wrapbox">
			<span id="w1">AAAAAAAAAA</span><span id="w2">BBBBBBBBBB</span>
		</div>
	</div>`

	css := `
		#page { width: 400px; padding: 10px; background-color: #FFFFFF; }
		#header { height: 40px; margin-bottom: 8px; background-color: #102030; color: #FFFFFF; }
		#hidden { display: none; height: 999px; }
		#row { display: flex; flex-direction: row; gap: 10px; margin-bottom: 12px; }
		#c1 { width: 50px; height: 30px; background-color: #FF0000; }
		#c2 { width: 60px; height: 45px; background-color: #00FF00; }
		#c3 { width: 70px; height: 20px; background-color: #0000FF; }
		#col { display: flex; flex-direction: column; gap: 6px; margin-bottom: 10px; }
		#r1 { width: 100px; height: 20px; }
		#r2 { width: 100px; height: 25px; }
		#wrapbox { width: 100px; font-size: 16px; }
	`

	parse_html(tree, make_test_origin(2, "layout.example"), transmute([]u8)html)
	parse_stylesheet(sheet, transmute([]u8)css)
	compute_layout(tree, sheet, 400, 600, layout)

	_, hidden_found := layout_find_box_by_id(tree, layout, "hidden")
	testing.expect(t, !hidden_found, "display:none must produce no layout box")

	hdr_idx, _ := layout_find_box_by_id(tree, layout, "header")
	hdr := &layout.boxes[hdr_idx]
	testing.expect_value(t, hdr.x, i32(10))
	testing.expect_value(t, hdr.y, i32(10))
	testing.expect_value(t, hdr.width, i32(380))
	testing.expect_value(t, hdr.height, i32(40))

	row_idx, _ := layout_find_box_by_id(tree, layout, "row")
	c1_idx, _ := layout_find_box_by_id(tree, layout, "c1")
	c2_idx, _ := layout_find_box_by_id(tree, layout, "c2")
	c3_idx, _ := layout_find_box_by_id(tree, layout, "c3")
	row := &layout.boxes[row_idx]
	c1 := &layout.boxes[c1_idx]
	c2 := &layout.boxes[c2_idx]
	c3 := &layout.boxes[c3_idx]
	testing.expect_value(t, row.y, i32(58))
	testing.expect_value(t, row.height, i32(45))
	testing.expect_value(t, c1.x, i32(10))
	testing.expect_value(t, c2.x, i32(70))
	testing.expect_value(t, c3.x, i32(140))
	testing.expect_value(t, c1.y, i32(58))
	testing.expect_value(t, c2.y, i32(58))
	testing.expect_value(t, c3.y, i32(58))

	col_idx, _ := layout_find_box_by_id(tree, layout, "col")
	r1_idx, _ := layout_find_box_by_id(tree, layout, "r1")
	r2_idx, _ := layout_find_box_by_id(tree, layout, "r2")
	col := &layout.boxes[col_idx]
	r1 := &layout.boxes[r1_idx]
	r2 := &layout.boxes[r2_idx]
	testing.expect_value(t, col.y, i32(115))
	testing.expect_value(t, col.height, i32(51))
	testing.expect_value(t, r1.y, i32(115))
	testing.expect_value(t, r2.y, i32(141))

	w1_idx, _ := layout_find_box_by_id(tree, layout, "w1")
	w2_idx, _ := layout_find_box_by_id(tree, layout, "w2")
	w1 := &layout.boxes[w1_idx]
	w2 := &layout.boxes[w2_idx]
	testing.expect_value(t, w1.x, i32(10))
	testing.expect_value(t, w2.x, i32(10))
	testing.expect(t, w2.y >= w1.y + 16, "second 80px inline span must wrap onto next line inside 100px box")

	records := make([]draw_record.Draw_Record, 128)
	text_buf := make([]u8, 2048)
	defer delete(records)
	defer delete(text_buf)

	rc, tlen := emit_draw_records(tree, layout, records, text_buf)
	testing.expect(t, rc >= 10, "must emit background rectangles and text runs")
	testing.expect(t, tlen > 0, "must emit text table bytes")
	for i := 0; i < rc; i += 1 {
		_, prob := draw_record.read(records[i])
		testing.expect_value(t, prob, draw_record.Problem.None)
	}
}

@(test)
test_origin_isolation_and_scheme_border :: proc(t: ^testing.T) {
	_, ok := document_scheme_of_word(0)
	testing.expect(t, !ok, "scheme 0 must be refused")
	_, ok = document_scheme_of_word(3)
	testing.expect(t, !ok, "scheme 3 must be refused")
	_, ok = document_scheme_of_word(255)
	testing.expect(t, !ok, "scheme 255 must be refused")

	o0 := make_test_origin(0, "site.example")
	o1 := make_test_origin(1, "site.example")
	o0_same := make_test_origin(0, "site.example")
	testing.expect(t, origins_equal(&o0, &o0_same), "identical principal+origin must match")
	testing.expect(t, !origins_equal(&o0, &o1), "different principals must never share origin")
}

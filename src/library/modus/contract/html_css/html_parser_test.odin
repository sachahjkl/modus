#+build !freestanding
#+build !modus
package html_css

import "core:strings"
import "core:testing"
import "modus:contract/draw_record"

// The tests of the tree builder after the WHATWG: each tries a page that
// the standard reads in one exact way, or a page that tries to break the
// bounds of the parser.

@(private = "file")
test_origin :: proc() -> Document_Origin {
	origin := Document_Origin {
		principal_id = 1,
		scheme       = .Https,
		port         = 443,
	}
	origin.host_len = u16(copy(origin.host[:], "parser.example"))
	return origin
}

@(private = "file")
parse_text :: proc(tree: ^Dom_Tree, text: string) {
	parse_html(tree, test_origin(), transmute([]u8)text)
}

// expect_tree_well_formed checks the invariants that the layout and the
// browser rely on: preorder, links in both directions, depths, bounds.
expect_tree_well_formed :: proc(t: ^testing.T, tree: ^Dom_Tree, location := #caller_location) {
	count := int(tree.node_count)
	testing.expect(t, count >= 1 && count <= len(tree.nodes), "node count out of bounds", loc = location)
	testing.expect(t, tree.nodes[0].kind == .Document, "the first node is the document", loc = location)
	children_seen := 0
	deepest: u32 = 0
	for index in 0 ..< count {
		node := &tree.nodes[index]
		deepest = max(deepest, node.depth)
		if index > 0 {
			testing.expectf(t, node.parent != NO_NODE && int(node.parent) < index, "node %d has the parent %d", index, node.parent, loc = location)
			if node.parent != NO_NODE && int(node.parent) < index {
				testing.expectf(t, node.depth == min(tree.nodes[node.parent].depth + 1, MAX_DOM_DEPTH), "node %d has the depth %d", index, node.depth, loc = location)
			}
		}
		previous := NO_NODE
		child := node.first_child
		for child != NO_NODE && children_seen <= count {
			testing.expectf(t, int(child) > index && int(child) < count, "node %d has the child %d", index, child, loc = location)
			if int(child) >= count {
				break
			}
			testing.expectf(t, tree.nodes[child].parent == u32(index), "child %d of %d names another parent", child, index, loc = location)
			children_seen += 1
			previous = child
			child = tree.nodes[child].next_sibling
		}
		testing.expectf(t, node.last_child == previous, "node %d: last child %d, list ends at %d", index, node.last_child, previous, loc = location)
		if node.kind == .Element && is_void_tag(node.tag) {
			testing.expectf(t, node.first_child == NO_NODE, "void node %d has a child", index, loc = location)
		}
	}
	testing.expect_value(t, children_seen, count - 1, loc = location)
	testing.expect_value(t, deepest, tree.max_depth_reached, loc = location)
	testing.expect(t, tree.max_depth_reached <= MAX_DOM_DEPTH, "depth past the bound", loc = location)
}

// first_element gives the first element of a tag, in preorder.
@(private = "file")
first_element :: proc(tree: ^Dom_Tree, tag: Html_Tag, after: int = 0) -> u32 {
	for index in after ..< int(tree.node_count) {
		if tree.nodes[index].kind == .Element && tree.nodes[index].tag == tag {
			return u32(index)
		}
	}
	return NO_NODE
}

@(private = "file")
count_elements :: proc(tree: ^Dom_Tree, tag: Html_Tag) -> int {
	count := 0
	for index in 0 ..< int(tree.node_count) {
		if tree.nodes[index].kind == .Element && tree.nodes[index].tag == tag {
			count += 1
		}
	}
	return count
}

// child_tags writes the tags of the children of a node, "#" for a text.
@(private = "file")
child_tags :: proc(tree: ^Dom_Tree, node: u32) -> string {
	builder := strings.builder_make(context.temp_allocator)
	child := tree.nodes[node].first_child
	for child != NO_NODE {
		if strings.builder_len(builder) > 0 {
			strings.write_byte(&builder, ' ')
		}
		switch tree.nodes[child].kind {
		case .Element:
			name := TAG_DESCRIPTIONS[tree.nodes[child].tag].name
			strings.write_string(&builder, name if name != "" else "?")
		case .Text:
			strings.write_byte(&builder, '#')
		case .Comment:
			strings.write_string(&builder, "!")
		case .Doctype:
			strings.write_string(&builder, "doctype")
		case .Document:
			strings.write_string(&builder, "document")
		}
		child = tree.nodes[child].next_sibling
	}
	return strings.to_string(builder)
}

@(private = "file")
first_text :: proc(tree: ^Dom_Tree, node: u32) -> string {
	if node == NO_NODE {
		return ""
	}
	child := tree.nodes[node].first_child
	for child != NO_NODE {
		if tree.nodes[child].kind == .Text {
			return string(dom_node_text(tree, child))
		}
		child = tree.nodes[child].next_sibling
	}
	return ""
}

// The document gets its html, head and body even when the page names
// none of them, and an element of the head goes into the head.
@(test)
the_implied_html_head_and_body :: proc(t: ^testing.T) {
	tree := test_tree_make()
	defer free(tree)
	parse_text(tree, "")
	testing.expect_value(t, child_tags(tree, 0), "html")
	testing.expect_value(t, child_tags(tree, 1), "head body")
	expect_tree_well_formed(t, tree)

	parse_text(tree, "<!DOCTYPE html><title>T &amp; U</title><p>x")
	testing.expect_value(t, child_tags(tree, 0), "doctype html")
	testing.expect_value(t, string(dom_node_text(tree, 1)), "html")
	html := first_element(tree, .Html)
	testing.expect_value(t, child_tags(tree, html), "head body")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Head)), "title")
	testing.expect_value(t, first_text(tree, first_element(tree, .Title)), "T & U")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Body)), "p")
	expect_tree_well_formed(t, tree)

	// A title after </head> still goes into the head.
	parse_text(tree, "<html><head></head><title>late</title><body>b</body></html>")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Head)), "title")
	testing.expect_value(t, count_elements(tree, .Body), 1)
	// A second body and a second html are dropped.
	parse_text(tree, "<body><body><html><p>x</p></body></html>")
	testing.expect_value(t, count_elements(tree, .Body), 1)
	testing.expect_value(t, count_elements(tree, .Html), 1)
	expect_tree_well_formed(t, tree)
}

// <b><i>text</b>more</i>: the WHATWG closes i with b, then opens a copy of
// i for the text after </b>.
@(test)
misnested_formatting_elements_are_reopened :: proc(t: ^testing.T) {
	tree := test_tree_make()
	defer free(tree)
	parse_text(tree, "<b><i>text</b>more</i>")
	body := first_element(tree, .Body)
	testing.expect_value(t, child_tags(tree, body), "b i")
	bold := first_element(tree, .B)
	testing.expect_value(t, child_tags(tree, bold), "i")
	inner := tree.nodes[bold].first_child
	testing.expect_value(t, first_text(tree, inner), "text")
	reopened := tree.nodes[bold].next_sibling
	testing.expect_value(t, tree.nodes[reopened].tag, Html_Tag.I)
	testing.expect_value(t, first_text(tree, reopened), "more")
	expect_tree_well_formed(t, tree)
}

// <b>1<p>2</b>3</p>: the adoption agency moves the content of p after the
// end of b into a copy of b inside p.
@(test)
adoption_agency_moves_the_furthest_block :: proc(t: ^testing.T) {
	tree := test_tree_make()
	defer free(tree)
	parse_text(tree, "<b>1<p>2</b>3</p>")
	body := first_element(tree, .Body)
	testing.expect_value(t, child_tags(tree, body), "b p")
	first_bold := first_element(tree, .B)
	testing.expect_value(t, child_tags(tree, first_bold), "#")
	paragraph := first_element(tree, .P)
	testing.expect_value(t, tree.nodes[paragraph].parent, body)
	testing.expect_value(t, child_tags(tree, paragraph), "b #")
	testing.expect_value(t, first_text(tree, tree.nodes[paragraph].first_child), "2")
	testing.expect_value(t, string(dom_node_text(tree, tree.nodes[paragraph].last_child)), "3")
	expect_tree_well_formed(t, tree)

	// An attribute of the formatting element goes with each copy.
	parse_text(tree, "<a href=x>1<div>2</a>3</div>")
	anchors := count_elements(tree, .A)
	testing.expect_value(t, anchors, 2)
	second := first_element(tree, .A, int(first_element(tree, .A)) + 1)
	href, found := dom_node_attr(tree, second, "href")
	testing.expect(t, found && string(href) == "x", "the copy of a keeps its href")
	expect_tree_well_formed(t, tree)

	// A new <a> closes an open one first.
	parse_text(tree, "<a>1<a>2")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Body)), "a a")
}

// Pages that try to make the adoption agency and the reconstruction of
// the formatting elements grow without bound: the tree stays in its pools
// and well formed, and the work stays linear.
@(test)
hostile_formatting_stays_bounded :: proc(t: ^testing.T) {
	tree := test_tree_make()
	defer free(tree)
	patterns := [?]string {
		"<b><i><u><s><em><strong><code><small>x</b>",
		"<a><p><b><div></a>x</b>",
		"<b><b><b><b><b><b><b><b><b><b>x<p>y</b>z",
		"<table><b><tr><td>x</b></table>y",
		"<i><div><i><div><i><div>t</i></i></i>",
	}
	for pattern in patterns {
		page := strings.repeat(pattern, 16 * 1024 / len(pattern), context.temp_allocator)
		parse_text(tree, page)
		testing.expectf(t, int(tree.node_count) <= len(tree.nodes), "%q: %d nodes", pattern, tree.node_count)
		expect_tree_well_formed(t, tree)
	}
	// Noah's Ark: the list keeps at most 3 alike copies, so 10 nested <b>
	// that a block closes are opened again 3 times, not 10.
	parse_text(tree, "<p><b><b><b><b><b><b><b><b><b><b>x</p>y")
	testing.expect_value(t, count_elements(tree, .B), 13)
	expect_tree_well_formed(t, tree)
}

// 2000 nested <div>: the open elements stop at 64, the pool at 512 nodes,
// the tree says that it is cut, and the layout and the paint stay valid.
@(test)
deep_nesting_2000_divs_is_bounded :: proc(t: ^testing.T) {
	tree := test_tree_make()
	sheet := test_sheet_make()
	layout := test_layout_make()
	defer free(tree)
	defer free(sheet)
	defer free(layout)
	page := strings.concatenate({strings.repeat("<div>", 2000, context.temp_allocator), "leaf", strings.repeat("</div>", 2000, context.temp_allocator)}, context.temp_allocator)
	parse_text(tree, page)
	testing.expect(t, tree.truncated, "a page past the depth says that it is cut")
	testing.expect(t, tree.max_depth_reached <= MAX_DOM_DEPTH, "depth bounded")
	testing.expect(t, int(tree.node_count) <= len(tree.nodes), "nodes bounded")
	expect_tree_well_formed(t, tree)
	// The leaf text is still in the tree, under the deepest open div.
	leaf_found := false
	for index in 0 ..< int(tree.node_count) {
		if tree.nodes[index].kind == .Text && string(dom_node_text(tree, u32(index))) == "leaf" {
			leaf_found = true
		}
	}
	testing.expect(t, leaf_found, "the text of the deepest element is kept")
	compute_layout(tree, sheet, 800, 600, layout)
	records := make([]draw_record.Draw_Record, 2048, context.temp_allocator)
	text := make([]u8, 1 << 20, context.temp_allocator)
	record_count, _ := emit_draw_records(tree, layout, records, text)
	for record in records[:record_count] {
		_, problem := draw_record.read(record)
		testing.expect_value(t, problem, draw_record.Problem.None)
	}
}

// A table with no tbody, an implied row, a cell closed by the next one,
// and text inside the table that it cannot hold: the text goes before the
// table (foster parenting).
@(test)
broken_tables_are_repaired :: proc(t: ^testing.T) {
	tree := test_tree_make()
	defer free(tree)
	parse_text(tree, "<table><tr><td>a<td>b</tr>stray<tr><td>c</table>after")
	body := first_element(tree, .Body)
	testing.expect_value(t, child_tags(tree, body), "# table #")
	testing.expect_value(t, first_text(tree, body), "stray")
	table := first_element(tree, .Table)
	testing.expect_value(t, child_tags(tree, table), "tbody")
	body_rows := first_element(tree, .Tbody)
	testing.expect_value(t, child_tags(tree, body_rows), "tr tr")
	first_row := first_element(tree, .Tr)
	testing.expect_value(t, child_tags(tree, first_row), "td td")
	testing.expect_value(t, string(dom_node_text(tree, tree.nodes[body].last_child)), "after")
	expect_tree_well_formed(t, tree)

	// A cell with no row and no row group.
	parse_text(tree, "<table><td>x</table>")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Table)), "tbody")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Tbody)), "tr")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Tr)), "td")
	// Parts of a table outside a table are dropped, their text kept.
	parse_text(tree, "<td>a</td><tr><th>b")
	testing.expect_value(t, count_elements(tree, .Td) + count_elements(tree, .Tr) + count_elements(tree, .Th), 0)
	testing.expect_value(t, child_tags(tree, first_element(tree, .Body)), "#")
	// A <div> inside a table but outside a cell goes before the table.
	parse_text(tree, "<table><tr><div>moved</div><td>kept</td></tr></table>")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Body)), "div table")
	// A second <table> in a table closes the first.
	parse_text(tree, "<table><tr><td>1<table><tr><td>2</table></table>")
	expect_tree_well_formed(t, tree)
	testing.expect_value(t, count_elements(tree, .Table), 2)
	// A nested table inside a cell, a caption, a row group of each kind.
	parse_text(tree, "<table><caption>c</caption><thead><tr><th>h</thead><tbody><tr><td><table><tr><td>in</table></td></tr></tbody><tfoot><tr><td>f</tfoot></table>")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Table)), "caption thead tbody tfoot")
	expect_tree_well_formed(t, tree)
	// A table left open at the end of the page.
	parse_text(tree, "<table><tr><td>open")
	expect_tree_well_formed(t, tree)
	testing.expect_value(t, first_text(tree, first_element(tree, .Td)), "open")
}

// Lists and definition lists close their items; a block closes an open p.
@(test)
implied_ends_of_lists_and_paragraphs :: proc(t: ^testing.T) {
	tree := test_tree_make()
	defer free(tree)
	parse_text(tree, "<ul><li>a<li>b<ol><li>c<li>d</ol></ul>")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Ul)), "li li")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Ol)), "li li")
	parse_text(tree, "<dl><dt>t<dd>d<dt>t2<dd>d2</dl>")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Dl)), "dt dd dt dd")
	parse_text(tree, "<p>a<div>b</div><p>c<h1>d</h1><p>e<table></table>")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Body)), "p div p h1 p table")
	parse_text(tree, "<h1>a<h2>b")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Body)), "h1 h2")
	// A form inside a form is dropped.
	parse_text(tree, "<form><form><input name=a></form>")
	testing.expect_value(t, count_elements(tree, .Form), 1)
	// A lone end tag closes nothing past a special element.
	parse_text(tree, "<span><div>x</span>y</div>")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Div)), "#")
	testing.expect_value(t, first_text(tree, first_element(tree, .Div)), "xy")
	expect_tree_well_formed(t, tree)
}

// The void elements never hold a child, with or without a slash.
@(test)
void_elements_hold_nothing :: proc(t: ^testing.T) {
	tree := test_tree_make()
	defer free(tree)
	parse_text(tree, "<p>a<br>b<hr>c<img src=x>d<input value=v>e<meta charset=utf-8><link rel=x><br/></br>")
	for tag in ([?]Html_Tag{.Br, .Hr, .Img, .Input, .Meta, .Link}) {
		node := first_element(tree, tag)
		testing.expectf(t, node != NO_NODE, "%v present", tag)
		if node != NO_NODE {
			testing.expect_value(t, tree.nodes[node].first_child, NO_NODE)
		}
	}
	// </br> is read as <br>.
	testing.expect_value(t, count_elements(tree, .Br), 3)
	expect_tree_well_formed(t, tree)
}

// Character references: numeric ones replace 0, surrogates and values
// past U+10FFFF with U+FFFD, read 0x80 to 0x9F as windows-1252, and take
// no semicolon; a legacy named one takes no semicolon in text, and stays
// as written in an attribute when a letter or '=' follows.
@(test)
character_references_after_the_whatwg :: proc(t: ^testing.T) {
	tree := test_tree_make()
	defer free(tree)
	Case :: struct {
		source, decoded: string,
	}
	cases := [?]Case {
		{"&#0;", "�"},
		{"&#x110000;", "�"},
		{"&#xD800;", "�"},
		{"&#xDFFF;", "�"},
		{"&#99999999999999999999;", "�"},
		{"&#x10FFFF;", "\U0010FFFF"},
		{"&#x1F600;", "\U0001F600"},
		{"&#128;", "€"},
		{"&#x81;", "\u0081"},
		{"&#65", "A"},
		{"&#x41x", "Ax"},
		{"&amp", "&"},
		{"&ampx", "&x"},
		{"&apos", "&apos"},
		{"&apos;", "'"},
		{"&AMP;&LT;", "&<"},
		{"&copy=", "©="},
		{"&unknown;", "&unknown;"},
		{"&#;&#x;&#xZZ;", "&#;&#x;&#xZZ;"},
		{"a&b", "a&b"},
		{"&", "&"},
		{"x\x00y", "x�y"},
	}
	for item in cases {
		parse_text(tree, strings.concatenate({"<p>", item.source, "</p>"}, context.temp_allocator))
		testing.expectf(t, first_text(tree, first_element(tree, .P)) == item.decoded, "%q gives %q, not %q", item.source, first_text(tree, first_element(tree, .P)), item.decoded)
	}
	parse_text(tree, "<a href=\"?a=1&copy=2&amp;b=&lt;\" title='&copy x'>t</a>")
	anchor := first_element(tree, .A)
	href, _ := dom_node_attr(tree, anchor, "href")
	testing.expect_value(t, string(href), "?a=1&copy=2&b=<")
	title, _ := dom_node_attr(tree, anchor, "title")
	testing.expect_value(t, string(title), "© x")
}

// Comments, doctypes, CDATA and processing instructions, well formed and
// broken, become comments or a doctype; none becomes markup.
@(test)
comments_and_doctypes_malformed :: proc(t: ^testing.T) {
	tree := test_tree_make()
	defer free(tree)
	Case :: struct {
		source, comment: string,
	}
	cases := [?]Case {
		{"<!--a-->", "a"},
		{"<!-->", ""},
		{"<!--->", ""},
		{"<!--a--!>", "a"},
		{"<!--a<b>c-->", "a<b>c"},
		{"<!-- unterminated <p>", " unterminated <p>"},
		{"<![CDATA[x<y]]>", "[CDATA[x<y]]"},
		{"<?php echo 1 ?>", "?php echo 1 ?"},
		{"</ space>", " space"},
		{"<!bogus>", "bogus"},
	}
	for item in cases {
		parse_text(tree, item.source)
		found := false
		for index in 0 ..< int(tree.node_count) {
			if tree.nodes[index].kind == .Comment {
				found = true
				testing.expectf(t, string(dom_node_text(tree, u32(index))) == item.comment, "%q gives the comment %q", item.source, string(dom_node_text(tree, u32(index))))
			}
		}
		testing.expectf(t, found, "%q gives a comment", item.source)
		testing.expectf(t, count_elements(tree, .P) == 0, "%q made a p", item.source)
		expect_tree_well_formed(t, tree)
	}
	parse_text(tree, "<!DOCTYPE>x")
	testing.expect_value(t, tree.nodes[1].kind, Node_Kind.Doctype)
	testing.expect_value(t, tree.nodes[1].text_len, u32(0))
	parse_text(tree, "<!doctype HTML PUBLIC \"x\">")
	testing.expect_value(t, string(dom_node_text(tree, 1)), "html")
	// </> is dropped; a tag that the end of the page cuts is dropped.
	parse_text(tree, "a</>b<div id=\"cut")
	testing.expect_value(t, child_tags(tree, first_element(tree, .Body)), "#")
	testing.expect_value(t, first_text(tree, first_element(tree, .Body)), "ab")
	// A '<' that opens no tag is text.
	parse_text(tree, "1 < 2 <3 <")
	testing.expect_value(t, first_text(tree, first_element(tree, .Body)), "1 < 2 <3 <")
}

// The content of script and style is text with no references; the content
// of title and textarea is text with references; neither holds a tag.
@(test)
text_only_elements :: proc(t: ^testing.T) {
	tree := test_tree_make()
	defer free(tree)
	parse_text(tree, "<script>a</scriptx>b<div>&amp;</script><style>p{}</STYLE ><textarea>\n<b>&lt;</textarea><title>x</title y>")
	testing.expect_value(t, first_text(tree, first_element(tree, .Script)), "a</scriptx>b<div>&amp;")
	testing.expect_value(t, first_text(tree, first_element(tree, .Style)), "p{}")
	testing.expect_value(t, first_text(tree, first_element(tree, .Textarea)), "<b><")
	testing.expect_value(t, first_text(tree, first_element(tree, .Title)), "x")
	testing.expect_value(t, count_elements(tree, .Div) + count_elements(tree, .B), 0)
	// A self-closing script still reads its content as text.
	parse_text(tree, "<script/>x<p>y</script>")
	testing.expect_value(t, count_elements(tree, .P), 0)
	// An unterminated script holds the rest of the page.
	parse_text(tree, "<script>never closed <p>")
	testing.expect_value(t, first_text(tree, first_element(tree, .Script)), "never closed <p>")
	// A newline right after <pre> is not part of its text.
	parse_text(tree, "<pre>\nline</pre>")
	testing.expect_value(t, first_text(tree, first_element(tree, .Pre)), "line")
}

// Attributes: names in lower case, the first of two with the same name
// kept, values in quotes, with no quotes, and with none.
@(test)
attributes_after_the_whatwg :: proc(t: ^testing.T) {
	tree := test_tree_make()
	defer free(tree)
	parse_text(tree, "<div ID=a id=b Class='x y' data-flag title=\"q'\" lang=en/>")
	div := first_element(tree, .Div)
	id, _ := dom_node_attr(tree, div, "id")
	testing.expect_value(t, string(id), "a")
	testing.expect_value(t, tree.nodes[div].attr_count, u32(5))
	flag, has_flag := dom_node_attr(tree, div, "data-flag")
	testing.expect(t, has_flag && len(flag) == 0, "an attribute with no value")
	lang, _ := dom_node_attr(tree, div, "lang")
	testing.expect_value(t, string(lang), "en/")
	testing.expect(t, dom_node_has_class(tree, div, transmute([]u8)string("y")), "class y")
	// The attributes past the capacity of a tag are dropped and counted as a cut.
	many := strings.builder_make(context.temp_allocator)
	strings.write_string(&many, "<p")
	for index in 0 ..< TOKEN_ATTRIBUTE_CAPACITY + 1 {
		strings.write_string(&many, " a")
		strings.write_int(&many, index)
	}
	strings.write_string(&many, ">x")
	parse_text(tree, strings.to_string(many))
	testing.expect_value(t, tree.nodes[first_element(tree, .P)].attr_count, u32(TOKEN_ATTRIBUTE_CAPACITY))
	testing.expect(t, tree.truncated, "dropped attributes mark the tree as cut")
}

// The memory of a tree that cannot grow, at its bounds: one more node or
// byte is dropped, the tree says so, and nothing past its memory is
// written. A memory with no room for the order keeps the document node.
@(test)
pools_at_their_bounds :: proc(t: ^testing.T) {
	NODES :: 64
	TEXT :: 1024
	nodes := make([]Dom_Node, NODES)
	defer delete(nodes)
	attrs := make([]Dom_Attr, 16)
	defer delete(attrs)
	text_pool := make([]u8, TEXT)
	defer delete(text_pool)
	order := make([]u32, 2 * NODES + 2)
	defer delete(order)
	tree := new(Dom_Tree)
	defer free(tree)
	tree^ = {nodes = nodes, attrs = attrs, text_pool = text_pool, order = order}
	page := strings.repeat("<b>x</b>", NODES, context.temp_allocator)
	parse_text(tree, page)
	testing.expect_value(t, int(tree.node_count), NODES)
	testing.expect(t, tree.truncated, "the node pool is full")
	expect_tree_well_formed(t, tree)
	long_text := strings.repeat("&#x1F600;", TEXT / 4 + 8, context.temp_allocator)
	parse_text(tree, long_text)
	testing.expect(t, tree.truncated, "the text pool is full")
	testing.expect(t, tree.text_len <= TEXT, "text bounded")
	// No character is cut in two at the end of the pool.
	testing.expect_value(t, tree.text_len % 4, u32(0))
	tree.order = order[:2 * NODES - 1]
	parse_text(tree, page)
	testing.expect(t, tree.truncated && tree.node_count == 1, "no room for the order: the document node alone")
	expect_tree_well_formed(t, tree)
}

// A memory that grows takes a page past each fixed count of before: 40 000
// elements and their texts, 80 003 nodes, past the 16 bits of the indexes of before,
// and 2 MB of text, past 1 MiB.
@(test)
a_tree_grows_with_its_page :: proc(t: ^testing.T) {
	tree := test_tree_make()
	defer free(tree)
	ELEMENTS :: 40_000
	page := strings.repeat("<b>xy</b>", ELEMENTS, context.temp_allocator)
	parse_text(tree, page)
	testing.expect(t, !tree.truncated, "nothing is cut")
	testing.expect(t, int(tree.node_count) > int(max(u16)), "past the indexes of 16 bits")
	testing.expect_value(t, count_elements(tree, .B), ELEMENTS)
	expect_tree_well_formed(t, tree)
	long_text := strings.repeat("a", 2 << 20, context.temp_allocator)
	parse_text(tree, long_text)
	testing.expect(t, !tree.truncated && tree.text_len >= 2 << 20, "2 MB of text")
}

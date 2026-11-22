package fuzz

import "core:slice"
import "modus:contract/draw_record"
import "modus:contract/html_css"

// The fuzz target of the light browser core (src/md/features/desktop_to_browser.md,
// "E. A light browser"): the parser of a page reads the bytes of any
// server, so a hostile page must give a bounded tree and never a fault. The
// input is the bytes of one page; the target parses it, reads its style
// blocks, lays it out at several widths and paints it into draw records.

FUZZ_HTML_CSS_INPUT_LIMIT :: 16 << 10

// The widths of the viewport: none, one pixel, a common one and the largest
// word, which the layout must clamp.
@(rodata, private = "file")
fuzz_html_css_widths := [?]i32{0, 1, 640, max(i32)}

FUZZ_HTML_CSS_RECORD_CAPACITY :: 1024
FUZZ_HTML_CSS_TEXT_CAPACITY :: html_css.MAX_TEXT_POOL

// The records of the package are large (a tree, a style sheet, a layout):
// in the memory of the process, not on the stack of each execution.
@(private = "file")
fuzz_html_css_state: struct {
	tree:         html_css.Dom_Tree,
	tree_again:   html_css.Dom_Tree,
	sheet:        html_css.Css_Stylesheet,
	sheet_again:  html_css.Css_Stylesheet,
	layout:       html_css.Layout_Tree,
	layout_again: html_css.Layout_Tree,
	records:      [FUZZ_HTML_CSS_RECORD_CAPACITY]draw_record.Draw_Record,
	text:         [FUZZ_HTML_CSS_TEXT_CAPACITY]u8,
}

// fuzz_html_css_execute: the tree, the style sheet, each layout and its
// draw records keep their bounds and their links; the same bytes give the
// same tree, sheet and layout; no reader changes the input.
fuzz_html_css_execute :: proc(input: []u8) -> Fuzz_Verdict {
	state := &fuzz_html_css_state
	before := slice.clone(input, context.temp_allocator)
	origin := html_css.Document_Origin{principal_id = 1, scheme = .Https, port = 443}
	copy(origin.host[:], "fuzz.example")
	origin.host_len = len("fuzz.example")

	html_css.parse_html(&state.tree, origin, input)
	if problem := fuzz_dom_problem(&state.tree); problem != "" {
		return fuzz_broken(.Contract, "the tree: %s", problem)
	}
	if !html_css.origins_equal(&state.tree.origin, &origin) {
		return fuzz_broken(.Contract, "the tree holds another origin than the one of its parse")
	}
	html_css.parse_html(&state.tree_again, origin, input)
	if state.tree != state.tree_again {
		return fuzz_broken(.Contract, "two parses of the same bytes give two trees")
	}

	state.sheet = {}
	html_css.parse_document_styles(&state.tree, &state.sheet)
	if problem := fuzz_stylesheet_problem(&state.sheet); problem != "" {
		return fuzz_broken(.Contract, "the style sheet: %s", problem)
	}
	state.sheet_again = {}
	html_css.parse_document_styles(&state.tree, &state.sheet_again)
	if state.sheet != state.sheet_again {
		return fuzz_broken(.Contract, "two reads of the same style blocks give two style sheets")
	}
	if state.tree != state.tree_again {
		return fuzz_broken(.Contract, "the read of the style blocks changed the tree")
	}

	for width in fuzz_html_css_widths {
		html_css.compute_layout(&state.tree, &state.sheet, width, 480, &state.layout)
		if problem := fuzz_layout_problem(&state.tree, &state.layout); problem != "" {
			return fuzz_broken(.Contract, "the layout at the width %d: %s", width, problem)
		}
		html_css.compute_layout(&state.tree, &state.sheet, width, 480, &state.layout_again)
		if state.layout != state.layout_again {
			return fuzz_broken(.Contract, "two layouts at the width %d give two box trees", width)
		}
		if problem := fuzz_paint_problem(&state.tree, &state.layout); problem != "" {
			return fuzz_broken(.Contract, "the paint at the width %d: %s", width, problem)
		}
	}
	if state.tree != state.tree_again {
		return fuzz_broken(.Contract, "the layout changed the tree")
	}
	if !slice.equal(input, before) {
		return fuzz_broken(.Contract, "a reader changed the bytes of the page")
	}
	return FUZZ_PASSED
}

// fuzz_dom_problem checks the tree that parse_html gives: each count in
// its capacity, each node at its place in the list of its parent and in
// one list only, each range in the text pool and the attributes.
@(private = "file")
fuzz_dom_problem :: proc(tree: ^html_css.Dom_Tree) -> string {
	node_count := int(tree.node_count)
	if node_count < 1 || node_count > html_css.MAX_DOM_NODES {
		return fuzz_text("%d nodes, out of 1 to %d", node_count, html_css.MAX_DOM_NODES)
	}
	if int(tree.attr_count) > html_css.MAX_ATTRS || int(tree.text_len) > html_css.MAX_TEXT_POOL {
		return fuzz_text("%d attributes and %d bytes of text, past the capacities", tree.attr_count, tree.text_len)
	}
	root := tree.nodes[0]
	if root.kind != .Document || root.parent != html_css.NO_NODE || root.depth != 0 {
		return fuzz_text("the first node is %v at the depth %d with the parent %d", root.kind, root.depth, root.parent)
	}
	deepest: u16 = 0
	attributes_named := 0
	for index in 0 ..< node_count {
		node := &tree.nodes[index]
		if node.kind > max(html_css.Node_Kind) || node.tag > max(html_css.Html_Tag) {
			return fuzz_text("the node %d has the kind %d and the tag %d", index, u8(node.kind), u8(node.tag))
		}
		if u64(node.text_off) + u64(node.text_len) > u64(tree.text_len) {
			return fuzz_text("the text of the node %d, %d bytes at %d, ends past the pool of %d bytes", index, node.text_len, node.text_off, tree.text_len)
		}
		if int(node.attr_start) + int(node.attr_count) > int(tree.attr_count) {
			return fuzz_text("the attributes of the node %d, %d at %d, end past the %d attributes", index, node.attr_count, node.attr_start, tree.attr_count)
		}
		attributes_named += int(node.attr_count)
		deepest = max(deepest, node.depth)
		if node.depth > html_css.MAX_DOM_DEPTH {
			return fuzz_text("the node %d is at the depth %d, past %d", index, node.depth, html_css.MAX_DOM_DEPTH)
		}
		if node.kind != .Element && (node.tag != .Unknown || node.attr_count != 0) {
			return fuzz_text("the node %d of the kind %v has the tag %v and %d attributes", index, node.kind, node.tag, node.attr_count)
		}
		if (node.kind == .Text || node.kind == .Comment || node.kind == .Element && html_css.is_void_tag(node.tag)) && (node.first_child != html_css.NO_NODE || node.last_child != html_css.NO_NODE) {
			return fuzz_text("the node %d, %v %v, has a child", index, node.kind, node.tag)
		}
		if index == 0 {
			continue
		}
		if node.kind == .Document {
			return fuzz_text("the node %d is a second document", index)
		}
		// The nodes are made in preorder, so a parent comes first: this
		// also says that the links to the parents make no cycle.
		if node.parent == html_css.NO_NODE || int(node.parent) >= index {
			return fuzz_text("the node %d has the parent %d", index, node.parent)
		}
		parent := &tree.nodes[node.parent]
		if parent.kind != .Document && parent.kind != .Element {
			return fuzz_text("the parent %d of the node %d is a %v", node.parent, index, parent.kind)
		}
		if node.depth != min(parent.depth + 1, html_css.MAX_DOM_DEPTH) {
			return fuzz_text("the node %d is at the depth %d under a parent at %d", index, node.depth, parent.depth)
		}
		if parent.kind == .Element && html_css.is_raw_text_tag(parent.tag) && node.kind != .Text {
			return fuzz_text("the node %d, a %v, is in a %v", index, node.kind, parent.tag)
		}
	}
	if attributes_named != int(tree.attr_count) {
		return fuzz_text("the nodes name %d attributes of %d", attributes_named, tree.attr_count)
	}
	if deepest != tree.max_depth_reached {
		return fuzz_text("the deepest node is at %d, the tree says %d", deepest, tree.max_depth_reached)
	}
	for index in 0 ..< int(tree.attr_count) {
		attribute := tree.attrs[index]
		if u64(attribute.name_off) + u64(attribute.name_len) > u64(tree.text_len) || u64(attribute.value_off) + u64(attribute.value_len) > u64(tree.text_len) {
			return fuzz_text("the attribute %d names text past the pool of %d bytes", index, tree.text_len)
		}
		for character in tree.text_pool[attribute.name_off:][:attribute.name_len] {
			if character >= 'A' && character <= 'Z' {
				return fuzz_text("the name of the attribute %d is not in lower case", index)
			}
		}
	}
	// Each node but the root is in the list of its parent once: the walks
	// of the lists, bounded by the count, meet each node once.
	children_met := 0
	for index in 0 ..< node_count {
		node := &tree.nodes[index]
		previous := html_css.NO_NODE
		child := node.first_child
		for child != html_css.NO_NODE {
			if int(child) >= node_count || int(child) <= index {
				return fuzz_text("the node %d has the child %d", index, child)
			}
			if tree.nodes[child].parent != u16(index) {
				return fuzz_text("the child %d of the node %d names the parent %d", child, index, tree.nodes[child].parent)
			}
			children_met += 1
			if children_met >= node_count {
				return fuzz_text("the lists of the children meet more nodes than the tree holds")
			}
			previous = child
			child = tree.nodes[child].next_sibling
		}
		if node.last_child != previous {
			return fuzz_text("the last child of the node %d is %d, its list ends at %d", index, node.last_child, previous)
		}
	}
	if children_met != node_count - 1 {
		return fuzz_text("the lists of the children meet %d nodes of %d", children_met, node_count - 1)
	}
	return ""
}

// fuzz_stylesheet_problem checks the rules that the style blocks give:
// each rule has a valid selector, and each value is in the range that its
// property takes.
@(private = "file")
fuzz_stylesheet_problem :: proc(sheet: ^html_css.Css_Stylesheet) -> string {
	if int(sheet.rule_count) > html_css.MAX_CSS_RULES {
		return fuzz_text("%d rules, past %d", sheet.rule_count, html_css.MAX_CSS_RULES)
	}
	for index in 0 ..< int(sheet.rule_count) {
		rule := &sheet.rules[index]
		if int(rule.order) != index {
			return fuzz_text("the rule %d has the order %d", index, rule.order)
		}
		if rule.selector_count < 1 || int(rule.selector_count) > html_css.MAX_SELECTORS_PER_RULE {
			return fuzz_text("the rule %d has %d selectors", index, rule.selector_count)
		}
		for selector in rule.selectors[:rule.selector_count] {
			if !selector.valid || int(selector.class_len) > html_css.MAX_SELECTOR_NAME_LEN || int(selector.id_len) > html_css.MAX_SELECTOR_NAME_LEN {
				return fuzz_text("the rule %d has a selector that is not valid: %v", index, selector)
			}
			if selector.has_tag && (selector.tag == .Unknown || selector.tag > max(html_css.Html_Tag)) {
				return fuzz_text("the rule %d has a selector of the tag %d", index, u8(selector.tag))
			}
		}
		if problem := fuzz_declarations_problem(&rule.decls); problem != "" {
			return fuzz_text("the rule %d: %s", index, problem)
		}
	}
	return ""
}

@(private = "file")
fuzz_declarations_problem :: proc(declared: ^html_css.Css_Declarations) -> string {
	in_range :: proc(value, least: i32) -> bool {
		return value >= least && value <= html_css.MAX_LAYOUT_COORD
	}
	switch {
	case declared.has_display && (declared.display < min(html_css.Display_Mode) || declared.display > max(html_css.Display_Mode)):
		return fuzz_text("the display %d", u8(declared.display))
	case declared.has_flex_direction && (declared.flex_direction < min(html_css.Flex_Direction) || declared.flex_direction > max(html_css.Flex_Direction)):
		return fuzz_text("the flex direction %d", u8(declared.flex_direction))
	case declared.has_gap && !in_range(declared.gap, 0) || declared.has_width && !in_range(declared.width, 0) || declared.has_height && !in_range(declared.height, 0):
		return fuzz_text("a gap %d, a width %d or a height %d out of its range", declared.gap, declared.width, declared.height)
	case declared.has_padding_top && !in_range(declared.padding_top, 0) || declared.has_padding_right && !in_range(declared.padding_right, 0) || declared.has_padding_bottom && !in_range(declared.padding_bottom, 0) || declared.has_padding_left && !in_range(declared.padding_left, 0):
		return fuzz_text("a padding out of its range")
	case declared.has_margin_top && !in_range(declared.margin_top, -html_css.MAX_LAYOUT_COORD) || declared.has_margin_right && !in_range(declared.margin_right, -html_css.MAX_LAYOUT_COORD) || declared.has_margin_bottom && !in_range(declared.margin_bottom, -html_css.MAX_LAYOUT_COORD) || declared.has_margin_left && !in_range(declared.margin_left, -html_css.MAX_LAYOUT_COORD):
		return fuzz_text("a margin out of its range")
	case declared.has_font_size && (declared.font_size < 4 || declared.font_size > 128):
		return fuzz_text("the font size %d", declared.font_size)
	}
	return ""
}

// fuzz_layout_problem checks the box tree: each box names a node of the
// tree that is visible, its parent box is the box of an ancestor, the
// lists of the children meet each box once, and no size or far edge is
// negative or past the range of its word.
@(private = "file")
fuzz_layout_problem :: proc(tree: ^html_css.Dom_Tree, layout: ^html_css.Layout_Tree) -> string {
	box_count := int(layout.box_count)
	if box_count > html_css.MAX_DOM_NODES || box_count > int(tree.node_count) {
		return fuzz_text("%d boxes for %d nodes", box_count, tree.node_count)
	}
	if (box_count == 0) != (layout.root_box == html_css.NO_NODE) || box_count > 0 && layout.root_box != 0 {
		return fuzz_text("%d boxes with the root box %d", box_count, layout.root_box)
	}
	for index in 0 ..< box_count {
		box := &layout.boxes[index]
		if !box.used || int(box.node_index) >= int(tree.node_count) {
			return fuzz_text("the box %d is not used or names the node %d", index, box.node_index)
		}
		node := &tree.nodes[box.node_index]
		if box.is_text != (node.kind == .Text) || node.kind == .Comment {
			return fuzz_text("the box %d is a text box %v for a %v", index, box.is_text, node.kind)
		}
		if box.display < min(html_css.Display_Mode) || box.display > max(html_css.Display_Mode) || box.display == .None {
			return fuzz_text("the box %d has the display %d", index, u8(box.display))
		}
		if box.width < 0 || box.height < 0 || box.content_width < 0 || box.content_height < 0 {
			return fuzz_text("the box %d has the sizes %d, %d and the content %d, %d", index, box.width, box.height, box.content_width, box.content_height)
		}
		if box.content_width > box.width || box.content_height > box.height {
			return fuzz_text("the content of the box %d, %dx%d, is larger than its box %dx%d", index, box.content_width, box.content_height, box.width, box.height)
		}
		if !fuzz_fits_word(i64(box.x) + i64(box.width)) || !fuzz_fits_word(i64(box.y) + i64(box.height)) || !fuzz_fits_word(i64(box.content_x) + i64(box.content_width)) || !fuzz_fits_word(i64(box.content_y) + i64(box.content_height)) {
			return fuzz_text("a far edge of the box %d is past the range of its word", index)
		}
		if index == 0 {
			if box.parent_box != html_css.NO_NODE || box.node_index != 0 {
				return fuzz_text("the root box has the parent %d and the node %d", box.parent_box, box.node_index)
			}
			continue
		}
		if box.parent_box == html_css.NO_NODE || int(box.parent_box) >= index {
			return fuzz_text("the box %d has the parent box %d", index, box.parent_box)
		}
		// The parent box lays out an ancestor of the node of the box.
		ancestor := node.parent
		parent_node := layout.boxes[box.parent_box].node_index
		steps := 0
		for ancestor != html_css.NO_NODE && ancestor != parent_node && steps < html_css.MAX_DOM_NODES {
			ancestor = tree.nodes[ancestor].parent
			steps += 1
		}
		if ancestor != parent_node {
			return fuzz_text("the parent box of the box %d lays out the node %d, which is no ancestor of its node %d", index, parent_node, box.node_index)
		}
	}
	children_met := 0
	for index in 0 ..< box_count {
		box := &layout.boxes[index]
		previous := html_css.NO_NODE
		child := box.first_child
		for child != html_css.NO_NODE {
			if int(child) >= box_count || int(child) <= index {
				return fuzz_text("the box %d has the child %d", index, child)
			}
			if layout.boxes[child].parent_box != u16(index) {
				return fuzz_text("the child %d of the box %d names the parent %d", child, index, layout.boxes[child].parent_box)
			}
			children_met += 1
			if children_met >= box_count {
				return fuzz_text("the lists of the children meet more boxes than the layout holds")
			}
			previous = child
			child = layout.boxes[child].next_sibling
		}
		if box.last_child != previous {
			return fuzz_text("the last child of the box %d is %d, its list ends at %d", index, box.last_child, previous)
		}
	}
	if box_count > 0 && children_met != box_count - 1 {
		return fuzz_text("the lists of the children meet %d boxes of %d", children_met, box_count - 1)
	}
	return ""
}

@(private = "file")
fuzz_fits_word :: proc(value: i64) -> bool {
	return value >= i64(min(i32)) && value <= i64(max(i32))
}

// fuzz_paint_problem paints the layout into draw records and gives each
// one to the border of the drawing module: the writer of the browser and
// the reader of the drawing must agree, and a text record names bytes
// that the paint wrote.
@(private = "file")
fuzz_paint_problem :: proc(tree: ^html_css.Dom_Tree, layout: ^html_css.Layout_Tree) -> string {
	state := &fuzz_html_css_state
	record_count, text_bytes := html_css.emit_draw_records(tree, layout, state.records[:], state.text[:])
	if record_count < 0 || record_count > len(state.records) || text_bytes < 0 || text_bytes > len(state.text) {
		return fuzz_text("%d records and %d bytes of text, past the buffers", record_count, text_bytes)
	}
	for index in 0 ..< record_count {
		primitive, problem := draw_record.read(state.records[index])
		if problem != .None {
			return fuzz_text("the record %d is refused by the border with %v: %v", index, problem, state.records[index])
		}
		if first, count, has_range := draw_record.byte_range_of(primitive); has_range && u64(first) + u64(count) > u64(text_bytes) {
			return fuzz_text("the record %d names %d bytes of text at %d, past the %d bytes written", index, count, first, text_bytes)
		}
	}
	return ""
}

@(private = "file")
fuzz_text :: proc(format: string, args: ..any) -> string {
	return fuzz_broken(.Contract, format, ..args).text
}

// The seeds: each form of the grammar that the parser and the style
// reader know, and each limit of the pools.
fuzz_html_css_seeds :: proc(seeds: ^[dynamic][]u8) {
	add :: proc(seeds: ^[dynamic][]u8, text: string) {
		append(seeds, slice.clone(transmute([]u8)text))
	}
	add(seeds, "<!DOCTYPE html><html><head><title>A &amp; B</title><style>body{margin:8px;color:#333} .card, #main {padding: 4px 8px; background: rgb(10, 20, 30)} p.note{display:flex;flex-direction:column;gap:2px;font-size:20px}</style></head><body><div id=\"main\" class=\"card wide\"><p class=note>One<br>two &lt;three&gt; &#x41;&#66;&nbsp;</p><ul><li>a<li>b</ul></div></body></html>")
	add(seeds, "<div><span><b><i>unclosed <p>para <p>next</div></span>")
	add(seeds, "<!-- a comment --><!--><!---><!-- unterminated")
	add(seeds, "<script>if (a < b && c > d) { document.write('</div>') }</script><style>/* c */ div > p { color: red } </style>")
	add(seeds, "<img src=a.png alt='x' width=10 / ><input disabled value=\"&quot;q&quot;\"><br/><hr>")
	add(seeds, "&#0;&#xD800;&#x110000;&#99999999999;&#x;&#;&amp &unknown; &AMP; &lt")
	add(seeds, "<p title=\"\xff\xfe\xc3\x28\xe2\x82\">\xf0\x9f\x98\x80 \xed\xa0\x80 \xc0\xaf</p>")
	add(seeds, "<custom-tag data-x=1>text</CUSTOM-TAG></unknown><//><  /x><a<b>c")
	add(seeds, "<style>* {display:none} h1{font-size:999px;margin:-70000px 1 2 3 4} div{width:+65537px;height:-1px;padding:-3px} .a.b#c{color:#12345678} #{} .{} {}{}</style><h1 class=a>t</h1>")
	add(seeds, "<div style=\"display:flex;gap:65536px;width:65536;margin-left:-65536px\"><span>a</span><span>b</span><div style=\"display:flex;flex-direction:column\">c</div></div>")
	// The limits: the depth, the count of nodes, the attributes and the
	// text pool.
	deep := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< html_css.MAX_DOM_DEPTH + 8 {
		append(&deep, "<div style=\"margin:-65536px;padding:1px\">")
	}
	append(&deep, "<style>div{display:block}</style><script>x</script>deep")
	append(seeds, slice.clone(deep[:]))
	many := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< html_css.MAX_DOM_NODES + 8 {
		append(&many, "<b>x</b>")
	}
	append(seeds, slice.clone(many[:]))
	attributes := make([dynamic]u8, context.temp_allocator)
	append(&attributes, "<p")
	for _ in 0 ..< html_css.MAX_ATTRS + 8 {
		append(&attributes, " a=b")
	}
	append(&attributes, ">attributes</p>")
	append(seeds, slice.clone(attributes[:]))
	text := make([dynamic]u8, context.temp_allocator)
	append(&text, "<p style=\"width:1px\">")
	for len(text) + len("&amp;&lt;") <= FUZZ_HTML_CSS_INPUT_LIMIT {
		append(&text, "&amp;&lt;")
	}
	append(seeds, slice.clone(text[:]))
	rules := make([dynamic]u8, context.temp_allocator)
	append(&rules, "<style>")
	for _ in 0 ..< html_css.MAX_CSS_RULES + 8 {
		append(&rules, "p,div,.a,#b,span,li,ul,ol,em{color:blue;margin:1px}")
	}
	append(&rules, "</style><p class=a id=b>r</p>")
	append(seeds, slice.clone(rules[:]))
}

// Words of the grammar that the constants of the package do not give.
fuzz_html_css_words :: proc(words: ^[dynamic][]u8) {
	for word in ([?]string{"<!--", "-->", "</", "/>", "<script>", "</script>", "<style>", "</style>", "&#x", "&amp;", "style=\"", "class=", "id=", "display:flex", "flex-direction:column", "margin:", "padding:", "width:", "px", "rgb(", "#fff", "{", "}", "/*", "*/"}) {
		append(words, slice.clone(transmute([]u8)word))
	}
}
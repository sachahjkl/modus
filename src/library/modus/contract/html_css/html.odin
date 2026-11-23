// HTML tokenizer and tree builder after the parsing algorithm of the WHATWG
// (https://html.spec.whatwg.org/multipage/parsing.html), with fixed pools:
// the insertion modes of a document, of its head, of its body and of its
// tables, the implied end tags, the list of active formatting elements and
// the adoption agency algorithm with the bounds of the standard. The design
// and the parts of the standard that it leaves out are in
// src/md/features/desktop_to_browser.md, "The HTML parser".
// Pure freestanding contract package: no allocation, no recursion.
package html_css

import "modus:contract/enum_word"

// The nodes, the attributes and the text of one document: a page of the
// web of today has some thousands of nodes and some hundred KiB of text. A
// node index is a u16, and NO_NODE is its largest value.
MAX_DOM_NODES :: 8192
MAX_DOM_DEPTH :: 64
MAX_ATTRS :: 16384
MAX_TEXT_POOL :: 1 << 20
#assert(MAX_DOM_NODES < int(max(u16)) && MAX_ATTRS <= int(max(u16)))
MAX_ORIGIN_HOST_LEN :: 253 // The longest name of a host that DNS gives (RFC 1035).
NO_NODE :: u16(0xFFFF)
// The entries of the list of active formatting elements, markers included.
ACTIVE_FORMATTING_CAPACITY :: 16
// The attributes that one start tag keeps: the parser drops the others.
TOKEN_ATTRIBUTE_CAPACITY :: 64
// The rounds of the adoption agency algorithm, as the WHATWG bounds them:
// they keep a misnested page linear in its length.
ADOPTION_OUTER_ROUNDS :: 8
ADOPTION_INNER_ROUNDS :: 3
// The copies of one formatting element with the same attributes that the
// list keeps after its last marker (the clause "Noah's Ark").
FORMATTING_COPIES_LIMIT :: 3
// The times that one token is processed again after a change of the
// insertion mode. The longest chain of the algorithm is 5 changes; the
// bound only ends a fault.
REPROCESS_LIMIT :: 16

// Scheme of an origin-isolated document. Modus names a page built into a
// program of the system: it comes from no network, and its host names the
// page, so each such page is its own origin.
Document_Scheme :: enum u8 {
	Http  = 1,
	Https = 2,
	Modus = 3,
}

document_scheme_of_word :: proc "contextless" (word: u8) -> (scheme: Document_Scheme, ok: bool) {
	return enum_word.member_of_word(Document_Scheme, u64(word))
}

// Security origin bound to a parsed DOM tree.
Document_Origin :: struct {
	principal_id: u64,
	scheme:       Document_Scheme,
	host:         [MAX_ORIGIN_HOST_LEN]u8,
	host_len:     u16,
	port:         u16,
}

// origins_equal reports whether two documents belong to the exact same principal and origin.
origins_equal :: proc "contextless" (a, b: ^Document_Origin) -> bool {
	if a.principal_id != b.principal_id || a.scheme != b.scheme || a.port != b.port || a.host_len != b.host_len {
		return false
	}
	if int(a.host_len) > MAX_ORIGIN_HOST_LEN {
		return false
	}
	for i := 0; i < int(a.host_len); i += 1 {
		if a.host[i] != b.host[i] {
			return false
		}
	}
	return true
}

// DOM node kind.
Node_Kind :: enum u8 {
	Document = 0,
	Element  = 1,
	Text     = 2,
	Comment  = 3,
	Doctype  = 4, // Its text is the name of the doctype, in lower case.
}

// Known HTML elements handled by the tokenizer, tree builder, and layout engine.
Html_Tag :: enum u8 {
	Unknown = 0,
	Html,
	Head,
	Body,
	Title,
	Meta,
	Link,
	Style,
	Script,
	Div,
	Span,
	P,
	A,
	H1,
	H2,
	H3,
	H4,
	H5,
	H6,
	Ul,
	Ol,
	Li,
	Header,
	Footer,
	Main,
	Nav,
	Section,
	Article,
	Button,
	Form,
	Input,
	Label,
	Br,
	Hr,
	Img,
	Pre,
	Code,
	Strong,
	Em,
	B,
	I,
	U,
	S,
	Small,
	Dl,
	Dt,
	Dd,
	Blockquote,
	Textarea,
	Base,
	Table,
	Caption,
	Thead,
	Tbody,
	Tfoot,
	Tr,
	Th,
	Td,
}

// What the parser knows of a tag.
Tag_Trait :: enum u8 {
	Void, // The element has no content and no end tag.
	Text_Only, // The tokenizer reads its content as text, up to its end tag.
	Text_References, // That text has character references: title and textarea.
	Formatting, // A formatting element of the list of active formatting elements.
	Special, // The category "special" of the WHATWG: it stops the search of an end tag.
}

Tag_Traits :: bit_set[Tag_Trait;u8]

Tag_Description :: struct {
	name:   string,
	traits: Tag_Traits,
}

@(rodata)
TAG_DESCRIPTIONS := [Html_Tag]Tag_Description {
	.Unknown    = {"", {}},
	.Html       = {"html", {.Special}},
	.Head       = {"head", {.Special}},
	.Body       = {"body", {.Special}},
	.Title      = {"title", {.Special, .Text_Only, .Text_References}},
	.Meta       = {"meta", {.Special, .Void}},
	.Link       = {"link", {.Special, .Void}},
	.Style      = {"style", {.Special, .Text_Only}},
	.Script     = {"script", {.Special, .Text_Only}},
	.Div        = {"div", {.Special}},
	.Span       = {"span", {}},
	.P          = {"p", {.Special}},
	.A          = {"a", {.Formatting}},
	.H1         = {"h1", {.Special}},
	.H2         = {"h2", {.Special}},
	.H3         = {"h3", {.Special}},
	.H4         = {"h4", {.Special}},
	.H5         = {"h5", {.Special}},
	.H6         = {"h6", {.Special}},
	.Ul         = {"ul", {.Special}},
	.Ol         = {"ol", {.Special}},
	.Li         = {"li", {.Special}},
	.Header     = {"header", {.Special}},
	.Footer     = {"footer", {.Special}},
	.Main       = {"main", {.Special}},
	.Nav        = {"nav", {.Special}},
	.Section    = {"section", {.Special}},
	.Article    = {"article", {.Special}},
	.Button     = {"button", {.Special}},
	.Form       = {"form", {.Special}},
	.Input      = {"input", {.Special, .Void}},
	.Label      = {"label", {}},
	.Br         = {"br", {.Special, .Void}},
	.Hr         = {"hr", {.Special, .Void}},
	.Img        = {"img", {.Special, .Void}},
	.Pre        = {"pre", {.Special}},
	.Code       = {"code", {.Formatting}},
	.Strong     = {"strong", {.Formatting}},
	.Em         = {"em", {.Formatting}},
	.B          = {"b", {.Formatting}},
	.I          = {"i", {.Formatting}},
	.U          = {"u", {.Formatting}},
	.S          = {"s", {.Formatting}},
	.Small      = {"small", {.Formatting}},
	.Dl         = {"dl", {.Special}},
	.Dt         = {"dt", {.Special}},
	.Dd         = {"dd", {.Special}},
	.Blockquote = {"blockquote", {.Special}},
	.Textarea   = {"textarea", {.Special, .Text_Only, .Text_References}},
	.Base       = {"base", {.Special, .Void}},
	.Table      = {"table", {.Special}},
	.Caption    = {"caption", {.Special}},
	.Thead      = {"thead", {.Special}},
	.Tbody      = {"tbody", {.Special}},
	.Tfoot      = {"tfoot", {.Special}},
	.Tr         = {"tr", {.Special}},
	.Th         = {"th", {.Special}},
	.Td         = {"td", {.Special}},
}

// Single attribute referencing slices in Dom_Tree.text_pool.
Dom_Attr :: struct {
	name_off:  u32,
	name_len:  u16,
	value_off: u32,
	value_len: u16,
}

// Single DOM node stored in Dom_Tree.nodes.
Dom_Node :: struct {
	kind:         Node_Kind,
	tag:          Html_Tag,
	depth:        u16,
	parent:       u16,
	first_child:  u16,
	last_child:   u16,
	next_sibling: u16,
	text_off:     u32,
	text_len:     u32,
	attr_start:   u16,
	attr_count:   u16,
}

// Fixed-capacity origin-isolated DOM tree. The nodes are in preorder: a
// parent comes before each of its children.
Dom_Tree :: struct {
	origin:            Document_Origin,
	nodes:             [MAX_DOM_NODES]Dom_Node,
	node_count:        u16,
	attrs:             [MAX_ATTRS]Dom_Attr,
	attr_count:        u16,
	text_pool:         [MAX_TEXT_POOL]u8,
	text_len:          u32,
	max_depth_reached: u16,
	truncated:         bool,
}

// Tag classification helpers.

is_void_tag :: proc "contextless" (tag: Html_Tag) -> bool {
	return .Void in TAG_DESCRIPTIONS[tag].traits
}

// is_text_only_tag: the content of the element is one text, read up to its
// end tag: script, style, title and textarea.
is_text_only_tag :: proc "contextless" (tag: Html_Tag) -> bool {
	return .Text_Only in TAG_DESCRIPTIONS[tag].traits
}

is_formatting_tag :: proc "contextless" (tag: Html_Tag) -> bool {
	return .Formatting in TAG_DESCRIPTIONS[tag].traits
}

is_special_tag :: proc "contextless" (tag: Html_Tag) -> bool {
	return .Special in TAG_DESCRIPTIONS[tag].traits
}

@(private)
html_ascii_lower :: proc "contextless" (b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {
		return b + 32
	}
	return b
}

@(private)
html_ascii_eq_ci :: proc "contextless" (a: []u8, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i += 1 {
		if html_ascii_lower(a[i]) != html_ascii_lower(b[i]) {
			return false
		}
	}
	return true
}

@(private)
html_is_space :: proc "contextless" (b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == '\f'
}

@(private)
html_is_alpha :: proc "contextless" (b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

@(private)
html_is_digit :: proc "contextless" (b: u8) -> bool {
	return b >= '0' && b <= '9'
}

@(private)
html_is_tag_char :: proc "contextless" (b: u8) -> bool {
	return html_is_alpha(b) || html_is_digit(b) || b == '-' || b == '_' || b == ':'
}

// tag_from_name maps a tag name (case-insensitive) to Html_Tag.
tag_from_name :: proc "contextless" (name: []u8) -> Html_Tag {
	if len(name) == 0 {
		return .Unknown
	}
	for description, tag in TAG_DESCRIPTIONS {
		if tag != .Unknown && html_ascii_eq_ci(name, description.name) {
			return tag
		}
	}
	return .Unknown
}

// The text pool of the tree.

@(private = "file")
pool_append_raw :: proc "contextless" (tree: ^Dom_Tree, bytes: []u8, lowercase: bool) -> (off: u32, length: u32) {
	off = tree.text_len
	avail := int(MAX_TEXT_POOL) - int(tree.text_len)
	if avail <= 0 || len(bytes) == 0 {
		if len(bytes) > 0 {
			tree.truncated = true
		}
		return off, 0
	}
	n := len(bytes)
	if n > avail {
		n = avail
		tree.truncated = true
	}
	for i := 0; i < n; i += 1 {
		b := bytes[i]
		tree.text_pool[int(off) + i] = html_ascii_lower(b) if lowercase else b
	}
	tree.text_len += u32(n)
	return off, u32(n)
}

@(private = "file")
pool_push_byte :: proc "contextless" (tree: ^Dom_Tree, b: u8) {
	if int(tree.text_len) < MAX_TEXT_POOL {
		tree.text_pool[tree.text_len] = b
		tree.text_len += 1
	} else {
		tree.truncated = true
	}
}

// pool_push_utf8 writes a code point in UTF-8. The pool never holds a
// part of a character: when the whole sequence does not fit, none of it
// is written.
@(private = "file")
pool_push_utf8 :: proc "contextless" (tree: ^Dom_Tree, code_point: u32) {
	code := code_point
	if code == 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF) {
		code = 0xFFFD
	}
	size := 4
	switch {
	case code <= 0x7F:
		size = 1
	case code <= 0x7FF:
		size = 2
	case code <= 0xFFFF:
		size = 3
	}
	if int(tree.text_len) + size > MAX_TEXT_POOL {
		tree.truncated = true
		return
	}
	switch size {
	case 1:
		pool_push_byte(tree, u8(code))
	case 2:
		pool_push_byte(tree, u8(0xC0 | (code >> 6)))
		pool_push_byte(tree, u8(0x80 | (code & 0x3F)))
	case 3:
		pool_push_byte(tree, u8(0xE0 | (code >> 12)))
		pool_push_byte(tree, u8(0x80 | ((code >> 6) & 0x3F)))
		pool_push_byte(tree, u8(0x80 | (code & 0x3F)))
	case:
		pool_push_byte(tree, u8(0xF0 | (code >> 18)))
		pool_push_byte(tree, u8(0x80 | ((code >> 12) & 0x3F)))
		pool_push_byte(tree, u8(0x80 | ((code >> 6) & 0x3F)))
		pool_push_byte(tree, u8(0x80 | (code & 0x3F)))
	}
}

// Character references.

// A named character reference that the parser decodes. A reference that
// the WHATWG lists as legacy is decoded with no semicolon too.
@(private = "file")
Named_Reference :: struct {
	name:              string,
	code_point:        u32,
	without_semicolon: bool,
}

@(private = "file", rodata)
NAMED_REFERENCES := [?]Named_Reference {
	{"amp", '&', true},
	{"AMP", '&', true},
	{"lt", '<', true},
	{"LT", '<', true},
	{"gt", '>', true},
	{"GT", '>', true},
	{"quot", '"', true},
	{"QUOT", '"', true},
	{"apos", '\'', false},
	{"nbsp", 0x00A0, true},
	{"copy", 0x00A9, true},
	{"COPY", 0x00A9, true},
	{"reg", 0x00AE, true},
	{"REG", 0x00AE, true},
	{"laquo", 0x00AB, true},
	{"raquo", 0x00BB, true},
	{"middot", 0x00B7, true},
	{"times", 0x00D7, true},
	{"ndash", 0x2013, false},
	{"mdash", 0x2014, false},
	{"bull", 0x2022, false},
	{"hellip", 0x2026, false},
	{"euro", 0x20AC, false},
	{"larr", 0x2190, false},
	{"rarr", 0x2192, false},
}

// The code points that a numeric reference from 0x80 to 0x9F names: the
// WHATWG reads them as windows-1252, as the pages of old servers mean.
// 0 marks a value that stays as it is.
@(private = "file", rodata)
WINDOWS_1252_CODE_POINTS := [32]u32 {
	0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
	0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
	0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
	0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
}

// numeric_reference_code_point gives the code point of a numeric
// reference: 0, a surrogate and a value past U+10FFFF become U+FFFD.
numeric_reference_code_point :: proc "contextless" (value: u32) -> u32 {
	if value == 0 || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF) {
		return 0xFFFD
	}
	if value >= 0x80 && value <= 0x9F && WINDOWS_1252_CODE_POINTS[value - 0x80] != 0 {
		return WINDOWS_1252_CODE_POINTS[value - 0x80]
	}
	return value
}

// references_decode copies text into the pool with its character
// references decoded. A NUL byte becomes U+FFFD. In an attribute, a legacy
// reference with no semicolon that a letter, a digit or '=' follows stays
// as it is written, as the WHATWG says.
@(private = "file")
references_decode :: proc "contextless" (tree: ^Dom_Tree, source: []u8, in_attribute: bool) -> (off: u32, length: u32) {
	off = tree.text_len
	i := 0
	for i < len(source) {
		byte := source[i]
		if byte == 0 {
			pool_push_utf8(tree, 0xFFFD)
			i += 1
			continue
		}
		if byte != '&' {
			pool_push_byte(tree, byte)
			i += 1
			continue
		}
		if i + 1 < len(source) && source[i + 1] == '#' {
			position := i + 2
			hexadecimal := position < len(source) && (source[position] == 'x' || source[position] == 'X')
			if hexadecimal {
				position += 1
			}
			value: u32 = 0
			digits := 0
			for position < len(source) {
				digit: u32 = 16
				character := source[position]
				switch {
				case character >= '0' && character <= '9':
					digit = u32(character - '0')
				case hexadecimal && character >= 'a' && character <= 'f':
					digit = u32(character - 'a' + 10)
				case hexadecimal && character >= 'A' && character <= 'F':
					digit = u32(character - 'A' + 10)
				}
				if digit == 16 {
					break
				}
				// The value saturates past the last code point: a long
				// number never wraps to a small one.
				value = min(value * (16 if hexadecimal else 10) + digit, 0x110000)
				digits += 1
				position += 1
			}
			if digits == 0 {
				pool_push_byte(tree, '&')
				i += 1
				continue
			}
			if position < len(source) && source[position] == ';' {
				position += 1
			}
			pool_push_utf8(tree, numeric_reference_code_point(value))
			i = position
			continue
		}
		best := -1
		best_length := 0
		best_semicolon := false
		for reference, index in NAMED_REFERENCES {
			name := reference.name
			if len(name) <= best_length || i + 1 + len(name) > len(source) || string(source[i + 1:i + 1 + len(name)]) != name {
				continue
			}
			after := i + 1 + len(name)
			semicolon := after < len(source) && source[after] == ';'
			if !semicolon {
				if !reference.without_semicolon {
					continue
				}
				if in_attribute && after < len(source) && (html_is_alpha(source[after]) || html_is_digit(source[after]) || source[after] == '=') {
					continue
				}
			}
			best, best_length, best_semicolon = index, len(name), semicolon
		}
		if best < 0 {
			pool_push_byte(tree, '&')
			i += 1
			continue
		}
		pool_push_utf8(tree, NAMED_REFERENCES[best].code_point)
		i += 1 + best_length + (1 if best_semicolon else 0)
	}
	return off, tree.text_len - off
}

// The nodes of the tree.

@(private = "file")
node_allocate :: proc "contextless" (tree: ^Dom_Tree, kind: Node_Kind, tag: Html_Tag) -> u16 {
	if int(tree.node_count) >= MAX_DOM_NODES {
		tree.truncated = true
		return NO_NODE
	}
	index := tree.node_count
	tree.node_count += 1
	tree.nodes[index] = Dom_Node {
		kind         = kind,
		tag          = tag,
		parent       = NO_NODE,
		first_child  = NO_NODE,
		last_child   = NO_NODE,
		next_sibling = NO_NODE,
		attr_start   = tree.attr_count,
	}
	return index
}

// node_insert_before links a node into the children of a parent, before a
// child of it, or last when before is NO_NODE.
@(private = "file")
node_insert_before :: proc "contextless" (tree: ^Dom_Tree, parent, child, before: u16) {
	parent_node := &tree.nodes[parent]
	node := &tree.nodes[child]
	node.parent = parent
	node.next_sibling = NO_NODE
	if before == NO_NODE || tree.nodes[before].parent != parent {
		if parent_node.first_child == NO_NODE {
			parent_node.first_child = child
		} else {
			tree.nodes[parent_node.last_child].next_sibling = child
		}
		parent_node.last_child = child
		return
	}
	node.next_sibling = before
	if parent_node.first_child == before {
		parent_node.first_child = child
		return
	}
	previous := parent_node.first_child
	for previous != NO_NODE && tree.nodes[previous].next_sibling != before {
		previous = tree.nodes[previous].next_sibling
	}
	if previous != NO_NODE {
		tree.nodes[previous].next_sibling = child
	}
}

@(private = "file")
node_detach :: proc "contextless" (tree: ^Dom_Tree, child: u16) {
	node := &tree.nodes[child]
	parent := node.parent
	if parent == NO_NODE {
		return
	}
	parent_node := &tree.nodes[parent]
	previous := NO_NODE
	walker := parent_node.first_child
	for walker != NO_NODE && walker != child {
		previous = walker
		walker = tree.nodes[walker].next_sibling
	}
	if walker == child {
		if previous == NO_NODE {
			parent_node.first_child = node.next_sibling
		} else {
			tree.nodes[previous].next_sibling = node.next_sibling
		}
		if parent_node.last_child == child {
			parent_node.last_child = previous
		}
	}
	node.parent = NO_NODE
	node.next_sibling = NO_NODE
}

// node_previous_sibling gives the child of a parent before another, or NO_NODE.
@(private = "file")
node_previous_sibling :: proc "contextless" (tree: ^Dom_Tree, parent, child: u16) -> u16 {
	previous := NO_NODE
	walker := tree.nodes[parent].first_child
	for walker != NO_NODE && walker != child {
		previous = walker
		walker = tree.nodes[walker].next_sibling
	}
	return previous
}

// The tokenizer.

@(private = "file")
Token_Kind :: enum u8 {
	Characters, // A run of text, with its references not decoded yet.
	Start_Tag,
	End_Tag,
	Comment,
	Doctype,
	End_Of_File,
}

@(private = "file")
Token_Attribute :: struct {
	name:  []u8,
	value: []u8,
}

@(private = "file")
Token :: struct {
	kind:            Token_Kind,
	tag:             Html_Tag,
	name:            []u8,
	self_closing:    bool,
	// Characters: the raw text. Comment: its data. Doctype: its name. A
	// start tag of a text-only element: its content.
	text:            []u8,
	attributes:      [TOKEN_ATTRIBUTE_CAPACITY]Token_Attribute,
	attribute_count: int,
}

@(private = "file")
markup_starts :: proc "contextless" (input: []u8, position: int) -> bool {
	if position + 1 >= len(input) {
		return false
	}
	next := input[position + 1]
	return html_is_alpha(next) || next == '!' || next == '/' || next == '?'
}

@(private = "file")
starts_with :: proc "contextless" (input: []u8, position: int, text: string, case_insensitive: bool) -> bool {
	if position < 0 || position + len(text) > len(input) {
		return false
	}
	if case_insensitive {
		return html_ascii_eq_ci(input[position:position + len(text)], text)
	}
	return string(input[position:position + len(text)]) == text
}

// bogus_comment_read reads a comment up to the next '>' (the state "bogus
// comment" of the WHATWG): <?...>, <!...>, and </ followed by no letter.
@(private = "file")
bogus_comment_read :: proc "contextless" (parser: ^Parser, token: ^Token, data_start: int) {
	input := parser.input
	end := data_start
	for end < len(input) && input[end] != '>' {
		end += 1
	}
	token.kind = .Comment
	token.text = input[data_start:end]
	parser.position = min(end + 1, len(input))
}

// markup_declaration_read reads what follows "<!": a comment, a doctype, or
// a bogus comment. CDATA is a bogus comment too: it has a meaning only in
// SVG and MathML.
@(private = "file")
markup_declaration_read :: proc "contextless" (parser: ^Parser, token: ^Token, start: int) {
	input := parser.input
	position := start + 2
	if starts_with(input, position, "--", false) {
		position += 2
		token.kind = .Comment
		// An abrupt end: <!--> and <!--->.
		if position < len(input) && input[position] == '>' {
			token.text = nil
			parser.position = position + 1
			return
		}
		if starts_with(input, position, "->", false) {
			token.text = nil
			parser.position = position + 2
			return
		}
		scan := position
		for scan < len(input) {
			if starts_with(input, scan, "-->", false) {
				token.text = input[position:scan]
				parser.position = scan + 3
				return
			}
			if starts_with(input, scan, "--!>", false) {
				token.text = input[position:scan]
				parser.position = scan + 4
				return
			}
			scan += 1
		}
		token.text = input[position:]
		parser.position = len(input)
		return
	}
	if starts_with(input, position, "doctype", true) {
		position += len("doctype")
		for position < len(input) && html_is_space(input[position]) {
			position += 1
		}
		name_start := position
		for position < len(input) && !html_is_space(input[position]) && input[position] != '>' {
			position += 1
		}
		token.kind = .Doctype
		token.text = input[name_start:position]
		for position < len(input) && input[position] != '>' {
			position += 1
		}
		parser.position = min(position + 1, len(input))
		return
	}
	bogus_comment_read(parser, token, position)
}

// tag_read reads a start tag or an end tag from the first byte of its
// name. A tag that the end of the input cuts is dropped, as the WHATWG
// says: the result is false.
@(private = "file")
tag_read :: proc "contextless" (parser: ^Parser, token: ^Token, name_start: int, is_end: bool) -> bool {
	input := parser.input
	position := name_start
	for position < len(input) && !html_is_space(input[position]) && input[position] != '/' && input[position] != '>' {
		position += 1
	}
	token.kind = .End_Tag if is_end else .Start_Tag
	token.name = input[name_start:position]
	token.tag = tag_from_name(token.name)
	token.self_closing = false
	token.text = nil
	token.attribute_count = 0
	for {
		for position < len(input) && html_is_space(input[position]) {
			position += 1
		}
		if position >= len(input) {
			parser.position = len(input)
			return false
		}
		character := input[position]
		if character == '>' {
			position += 1
			break
		}
		if character == '/' {
			if position + 1 < len(input) && input[position + 1] == '>' {
				token.self_closing = true
				position += 2
				break
			}
			position += 1
			continue
		}
		// The first byte of a name may be '=': the WHATWG keeps it in the name.
		name_begin := position
		position += 1
		for position < len(input) && !html_is_space(input[position]) && input[position] != '/' && input[position] != '>' && input[position] != '=' {
			position += 1
		}
		attribute_name := input[name_begin:position]
		for position < len(input) && html_is_space(input[position]) {
			position += 1
		}
		value: []u8
		if position < len(input) && input[position] == '=' {
			position += 1
			for position < len(input) && html_is_space(input[position]) {
				position += 1
			}
			if position < len(input) && (input[position] == '"' || input[position] == '\'') {
				quote := input[position]
				position += 1
				value_start := position
				for position < len(input) && input[position] != quote {
					position += 1
				}
				value = input[value_start:position]
				if position < len(input) {
					position += 1
				}
			} else {
				value_start := position
				for position < len(input) && !html_is_space(input[position]) && input[position] != '>' {
					position += 1
				}
				value = input[value_start:position]
			}
		}
		if is_end {
			continue
		}
		// A second attribute of the same name is dropped.
		duplicate := false
		for existing in token.attributes[:token.attribute_count] {
			if html_ascii_eq_ci(existing.name, string(attribute_name)) {
				duplicate = true
				break
			}
		}
		if duplicate {
			continue
		}
		if token.attribute_count >= TOKEN_ATTRIBUTE_CAPACITY {
			parser.tree.truncated = true
			continue
		}
		token.attributes[token.attribute_count] = {attribute_name, value}
		token.attribute_count += 1
	}
	parser.position = position
	// The content of a text-only element is text up to its end tag. The
	// flag of a self-closing tag has no effect on it, as in the WHATWG.
	if !is_end && is_text_only_tag(token.tag) {
		close_name := TAG_DESCRIPTIONS[token.tag].name
		content_start := position
		scan := position
		for scan < len(input) {
			if input[scan] == '<' && scan + 1 < len(input) && input[scan + 1] == '/' && starts_with(input, scan + 2, close_name, true) {
				after := scan + 2 + len(close_name)
				if after >= len(input) || html_is_space(input[after]) || input[after] == '>' || input[after] == '/' {
					token.text = input[content_start:scan]
					for after < len(input) && input[after] != '>' {
						after += 1
					}
					parser.position = min(after + 1, len(input))
					return true
				}
			}
			scan += 1
		}
		token.text = input[content_start:]
		parser.position = len(input)
	}
	return true
}

// token_next reads the next token. The result is false at the end of the
// input.
@(private = "file")
token_next :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	input := parser.input
	for parser.position < len(input) {
		start := parser.position
		if input[start] != '<' || !markup_starts(input, start) {
			end := start + 1
			for end < len(input) && !(input[end] == '<' && markup_starts(input, end)) {
				end += 1
			}
			parser.position = end
			token.kind = .Characters
			token.text = input[start:end]
			return true
		}
		next := input[start + 1]
		switch {
		case next == '!':
			markup_declaration_read(parser, token, start)
			return true
		case next == '?':
			bogus_comment_read(parser, token, start + 1)
			return true
		case next == '/':
			if start + 2 >= len(input) {
				parser.position = len(input)
				token.kind = .Characters
				token.text = input[start:]
				return true
			}
			after := input[start + 2]
			switch {
			case html_is_alpha(after):
				if tag_read(parser, token, start + 2, true) {
					return true
				}
			case after == '>':
				parser.position = start + 3
			case:
				bogus_comment_read(parser, token, start + 2)
				return true
			}
		case:
			if tag_read(parser, token, start + 1, false) {
				return true
			}
		}
	}
	return false
}

// The tree builder.

@(private = "file")
Insertion_Mode :: enum u8 {
	Initial,
	Before_Html,
	Before_Head,
	In_Head,
	After_Head,
	In_Body,
	In_Table,
	In_Caption,
	In_Table_Body,
	In_Row,
	In_Cell,
	After_Body,
	After_After_Body,
}

// The scopes of the WHATWG: each stops the search of an element at its
// own set of elements.
@(private = "file")
Scope :: enum u8 {
	Default,
	List_Item,
	Button,
	Table,
}

// An entry of the list of active formatting elements that is a marker.
@(private = "file")
FORMATTING_MARKER :: u16(0xFFFE)

@(private = "file")
Parser :: struct {
	tree:             ^Dom_Tree,
	input:            []u8,
	position:         int,
	mode:             Insertion_Mode,
	open:             [MAX_DOM_DEPTH]u16,
	open_count:       int,
	formatting:       [ACTIVE_FORMATTING_CAPACITY]u16,
	formatting_count: int,
	head:             u16,
	form:             u16,
	foster_parenting: bool,
	skip_newline:     bool,
}

@(private = "file")
tag_of :: proc "contextless" (parser: ^Parser, node: u16) -> Html_Tag {
	return parser.tree.nodes[node].tag
}

@(private = "file")
current_node :: proc "contextless" (parser: ^Parser) -> u16 {
	if parser.open_count == 0 {
		return 0
	}
	return parser.open[parser.open_count - 1]
}

@(private = "file")
current_tag :: proc "contextless" (parser: ^Parser) -> Html_Tag {
	if parser.open_count == 0 {
		return .Unknown
	}
	return tag_of(parser, current_node(parser))
}

@(private = "file")
is_table_context_tag :: proc "contextless" (tag: Html_Tag) -> bool {
	return tag == .Table || tag == .Tbody || tag == .Tfoot || tag == .Thead || tag == .Tr
}

@(private = "file")
is_heading_tag :: proc "contextless" (tag: Html_Tag) -> bool {
	return tag == .H1 || tag == .H2 || tag == .H3 || tag == .H4 || tag == .H5 || tag == .H6
}

// element_matches_end: an element closes for an end tag of its tag, and an
// unknown element for an end tag of its name.
@(private = "file")
element_matches_end :: proc "contextless" (parser: ^Parser, node: u16, token: ^Token) -> bool {
	tree := parser.tree
	element := &tree.nodes[node]
	if element.kind != .Element || element.tag != token.tag {
		return false
	}
	if token.tag != .Unknown {
		return true
	}
	return html_ascii_eq_ci(tree.text_pool[element.text_off:element.text_off + element.text_len], string(token.name))
}

// The stack of open elements.

@(private = "file")
stack_index :: proc "contextless" (parser: ^Parser, node: u16) -> int {
	for index := parser.open_count - 1; index >= 0; index -= 1 {
		if parser.open[index] == node {
			return index
		}
	}
	return -1
}

@(private = "file")
stack_remove_at :: proc "contextless" (parser: ^Parser, index: int) {
	for move := index; move + 1 < parser.open_count; move += 1 {
		parser.open[move] = parser.open[move + 1]
	}
	parser.open_count -= 1
}

@(private = "file")
stack_remove :: proc "contextless" (parser: ^Parser, node: u16) {
	if index := stack_index(parser, node); index >= 0 {
		stack_remove_at(parser, index)
	}
}

@(private = "file")
stack_insert_at :: proc "contextless" (parser: ^Parser, index: int, node: u16) {
	if parser.open_count >= MAX_DOM_DEPTH || index < 0 {
		parser.tree.truncated = true
		return
	}
	for move := parser.open_count; move > index; move -= 1 {
		parser.open[move] = parser.open[move - 1]
	}
	parser.open[index] = node
	parser.open_count += 1
}

@(private = "file")
pop_until_tag :: proc "contextless" (parser: ^Parser, tag: Html_Tag) {
	for parser.open_count > 1 {
		parser.open_count -= 1
		if tag_of(parser, parser.open[parser.open_count]) == tag {
			return
		}
	}
}

@(private = "file")
pop_until_heading :: proc "contextless" (parser: ^Parser) {
	for parser.open_count > 1 {
		parser.open_count -= 1
		if is_heading_tag(tag_of(parser, parser.open[parser.open_count])) {
			return
		}
	}
}

@(private = "file")
scope_stops_at :: proc "contextless" (tag: Html_Tag, scope: Scope) -> bool {
	switch scope {
	case .Default:
		return tag == .Html || tag == .Table || tag == .Caption || tag == .Td || tag == .Th
	case .List_Item:
		return tag == .Html || tag == .Table || tag == .Caption || tag == .Td || tag == .Th || tag == .Ol || tag == .Ul
	case .Button:
		return tag == .Html || tag == .Table || tag == .Caption || tag == .Td || tag == .Th || tag == .Button
	case .Table:
		return tag == .Html || tag == .Table
	}
	return true
}

@(private = "file")
in_scope :: proc "contextless" (parser: ^Parser, tag: Html_Tag, scope: Scope) -> bool {
	for index := parser.open_count - 1; index >= 0; index -= 1 {
		node_tag := tag_of(parser, parser.open[index])
		if node_tag == tag {
			return true
		}
		if scope_stops_at(node_tag, scope) {
			return false
		}
	}
	return false
}

@(private = "file")
node_in_scope :: proc "contextless" (parser: ^Parser, node: u16) -> bool {
	for index := parser.open_count - 1; index >= 0; index -= 1 {
		if parser.open[index] == node {
			return true
		}
		if scope_stops_at(tag_of(parser, parser.open[index]), .Default) {
			return false
		}
	}
	return false
}

@(private = "file")
heading_in_scope :: proc "contextless" (parser: ^Parser) -> bool {
	for index := parser.open_count - 1; index >= 0; index -= 1 {
		node_tag := tag_of(parser, parser.open[index])
		if is_heading_tag(node_tag) {
			return true
		}
		if scope_stops_at(node_tag, .Default) {
			return false
		}
	}
	return false
}

// generate_implied_end_tags pops the elements whose end tag is implied:
// dd, dt, li and p, except the one of the tag given.
@(private = "file")
generate_implied_end_tags :: proc "contextless" (parser: ^Parser, except: Html_Tag) {
	for parser.open_count > 1 {
		tag := current_tag(parser)
		if tag == except || !(tag == .Dd || tag == .Dt || tag == .Li || tag == .P) {
			return
		}
		parser.open_count -= 1
	}
}

@(private = "file")
close_p_element :: proc "contextless" (parser: ^Parser) {
	generate_implied_end_tags(parser, .P)
	pop_until_tag(parser, .P)
}

@(private = "file")
close_p_in_button_scope :: proc "contextless" (parser: ^Parser) {
	if in_scope(parser, .P, .Button) {
		close_p_element(parser)
	}
}

// clear_stack_back_to pops the elements down to the first one of the
// context of a table: the table, its row group or its row.
@(private = "file")
clear_stack_back_to :: proc "contextless" (parser: ^Parser, first, second, third: Html_Tag) {
	for parser.open_count > 1 {
		tag := current_tag(parser)
		if tag == .Html || tag == first || tag == second || tag == third {
			return
		}
		parser.open_count -= 1
	}
}

@(private = "file")
reset_insertion_mode :: proc "contextless" (parser: ^Parser) {
	for index := parser.open_count - 1; index >= 0; index -= 1 {
		last := index == 0
		tag := tag_of(parser, parser.open[index])
		switch {
		case (tag == .Td || tag == .Th) && !last:
			parser.mode = .In_Cell
		case tag == .Tr:
			parser.mode = .In_Row
		case tag == .Tbody || tag == .Thead || tag == .Tfoot:
			parser.mode = .In_Table_Body
		case tag == .Caption:
			parser.mode = .In_Caption
		case tag == .Table:
			parser.mode = .In_Table
		case tag == .Head && !last:
			parser.mode = .In_Head
		case tag == .Body:
			parser.mode = .In_Body
		case tag == .Html:
			parser.mode = .Before_Head if parser.head == NO_NODE else .After_Head
		case last:
			parser.mode = .In_Body
		case:
			continue
		}
		return
	}
	parser.mode = .In_Body
}

// The place of an insertion: the current node, or, when foster parenting
// is on and the target is a part of a table, the parent of the last open
// table, before that table.
@(private = "file")
insertion_place :: proc "contextless" (parser: ^Parser, override: u16) -> (parent, before: u16) {
	target := override if override != NO_NODE else current_node(parser)
	if parser.foster_parenting && is_table_context_tag(tag_of(parser, target)) {
		for index := parser.open_count - 1; index >= 0; index -= 1 {
			if tag_of(parser, parser.open[index]) != .Table {
				continue
			}
			table := parser.open[index]
			table_parent := parser.tree.nodes[table].parent
			if table_parent != NO_NODE {
				return table_parent, table
			}
			return parser.open[max(index - 1, 0)], NO_NODE
		}
		return parser.open[0], NO_NODE
	}
	return target, NO_NODE
}

// element_create makes an element of a token, with its attributes, not
// linked to the tree yet.
@(private = "file")
element_create :: proc "contextless" (parser: ^Parser, token: ^Token) -> u16 {
	tree := parser.tree
	node := node_allocate(tree, .Element, token.tag)
	if node == NO_NODE {
		return NO_NODE
	}
	if token.tag == .Unknown {
		tree.nodes[node].text_off, tree.nodes[node].text_len = pool_append_raw(tree, token.name, true)
	}
	tree.nodes[node].attr_start = tree.attr_count
	for attribute in token.attributes[:token.attribute_count] {
		if int(tree.attr_count) >= MAX_ATTRS {
			tree.truncated = true
			break
		}
		name_off, name_len := pool_append_raw(tree, attribute.name, true)
		value_off, value_len := references_decode(tree, attribute.value, true)
		tree.attrs[tree.attr_count] = Dom_Attr {
			name_off  = name_off,
			name_len  = u16(min(name_len, u32(max(u16)))),
			value_off = value_off,
			value_len = u16(min(value_len, u32(max(u16)))),
		}
		tree.attr_count += 1
		tree.nodes[node].attr_count += 1
	}
	return node
}

// element_clone makes a new element with the tag, the name and the
// attributes of another, for the list of active formatting elements.
@(private = "file")
element_clone :: proc "contextless" (parser: ^Parser, source: u16) -> u16 {
	tree := parser.tree
	node := node_allocate(tree, .Element, tree.nodes[source].tag)
	if node == NO_NODE {
		return NO_NODE
	}
	original := tree.nodes[source]
	tree.nodes[node].text_off = original.text_off
	tree.nodes[node].text_len = original.text_len
	tree.nodes[node].attr_start = tree.attr_count
	for index in 0 ..< int(original.attr_count) {
		if int(tree.attr_count) >= MAX_ATTRS {
			tree.truncated = true
			break
		}
		tree.attrs[tree.attr_count] = tree.attrs[int(original.attr_start) + index]
		tree.attr_count += 1
		tree.nodes[node].attr_count += 1
	}
	return node
}

// element_insert inserts an element at the place of an insertion and
// pushes it on the stack of open elements. When the stack is full, the
// element is not made: its content goes to the current node.
@(private = "file")
element_insert :: proc "contextless" (parser: ^Parser, token: ^Token) -> u16 {
	if parser.open_count >= MAX_DOM_DEPTH {
		parser.tree.truncated = true
		return NO_NODE
	}
	node := element_create(parser, token)
	if node == NO_NODE {
		return NO_NODE
	}
	parent, before := insertion_place(parser, NO_NODE)
	node_insert_before(parser.tree, parent, node, before)
	parser.open[parser.open_count] = node
	parser.open_count += 1
	return node
}

// element_insert_implied inserts an element that no tag of the page
// names: html, head, body, tbody, tr, or the p of a lone </p>.
@(private = "file")
element_insert_implied :: proc "contextless" (parser: ^Parser, tag: Html_Tag) -> u16 {
	if parser.open_count >= MAX_DOM_DEPTH {
		parser.tree.truncated = true
		return NO_NODE
	}
	node := node_allocate(parser.tree, .Element, tag)
	if node == NO_NODE {
		return NO_NODE
	}
	parent, before := insertion_place(parser, NO_NODE)
	node_insert_before(parser.tree, parent, node, before)
	parser.open[parser.open_count] = node
	parser.open_count += 1
	return node
}

// void_insert inserts an element that has no content: it is never pushed.
@(private = "file")
void_insert :: proc "contextless" (parser: ^Parser, token: ^Token) -> u16 {
	node := element_create(parser, token)
	if node == NO_NODE {
		return NO_NODE
	}
	parent, before := insertion_place(parser, NO_NODE)
	node_insert_before(parser.tree, parent, node, before)
	return node
}

// text_only_insert inserts an element whose content the tokenizer read as
// one text: script, style, title, textarea. It is never pushed.
@(private = "file")
text_only_insert :: proc "contextless" (parser: ^Parser, token: ^Token) {
	tree := parser.tree
	node := void_insert(parser, token)
	if node == NO_NODE {
		return
	}
	content := token.text
	// A newline right after <textarea> is not part of its value.
	if token.tag == .Textarea && len(content) > 0 && content[0] == '\n' {
		content = content[1:]
	}
	if len(content) == 0 {
		return
	}
	text_off, text_len: u32
	if .Text_References in TAG_DESCRIPTIONS[token.tag].traits {
		text_off, text_len = references_decode(tree, content, false)
	} else {
		text_off, text_len = pool_append_raw(tree, content, false)
	}
	if text_len == 0 {
		return
	}
	text := node_allocate(tree, .Text, .Unknown)
	if text == NO_NODE {
		return
	}
	tree.nodes[text].text_off = text_off
	tree.nodes[text].text_len = text_len
	node_insert_before(tree, node, text, NO_NODE)
}

// characters_insert decodes a run of text and inserts it at the place of
// an insertion. A text right after another text of the same parent, with
// its bytes right after the bytes of the other in the pool, extends it.
@(private = "file")
characters_insert :: proc "contextless" (parser: ^Parser, raw: []u8) {
	if len(raw) == 0 {
		return
	}
	tree := parser.tree
	parent, before := insertion_place(parser, NO_NODE)
	text_off, text_len := references_decode(tree, raw, false)
	if text_len == 0 {
		return
	}
	previous := tree.nodes[parent].last_child if before == NO_NODE else node_previous_sibling(tree, parent, before)
	if previous != NO_NODE && tree.nodes[previous].kind == .Text && tree.nodes[previous].text_off + tree.nodes[previous].text_len == text_off {
		tree.nodes[previous].text_len += text_len
		return
	}
	text := node_allocate(tree, .Text, .Unknown)
	if text == NO_NODE {
		return
	}
	tree.nodes[text].text_off = text_off
	tree.nodes[text].text_len = text_len
	node_insert_before(tree, parent, text, before)
}

// comment_insert inserts a comment under a parent, or at the place of an
// insertion when the parent is NO_NODE.
@(private = "file")
comment_insert :: proc "contextless" (parser: ^Parser, data: []u8, parent: u16) {
	tree := parser.tree
	text_off, text_len := pool_append_raw(tree, data, false)
	node := node_allocate(tree, .Comment, .Unknown)
	if node == NO_NODE {
		return
	}
	tree.nodes[node].text_off = text_off
	tree.nodes[node].text_len = text_len
	place, before := parent, NO_NODE
	if parent == NO_NODE {
		place, before = insertion_place(parser, NO_NODE)
	}
	node_insert_before(tree, place, node, before)
}

// The list of active formatting elements.

@(private = "file")
formatting_index :: proc "contextless" (parser: ^Parser, node: u16) -> int {
	for index := parser.formatting_count - 1; index >= 0; index -= 1 {
		if parser.formatting[index] == node {
			return index
		}
	}
	return -1
}

@(private = "file")
formatting_remove_at :: proc "contextless" (parser: ^Parser, index: int) {
	if index < 0 || index >= parser.formatting_count {
		return
	}
	for move := index; move + 1 < parser.formatting_count; move += 1 {
		parser.formatting[move] = parser.formatting[move + 1]
	}
	parser.formatting_count -= 1
}

@(private = "file")
formatting_insert_at :: proc "contextless" (parser: ^Parser, index: int, node: u16) {
	if parser.formatting_count >= ACTIVE_FORMATTING_CAPACITY {
		return
	}
	place := clamp(index, 0, parser.formatting_count)
	for move := parser.formatting_count; move > place; move -= 1 {
		parser.formatting[move] = parser.formatting[move - 1]
	}
	parser.formatting[place] = node
	parser.formatting_count += 1
}

// formatting_make_room frees an entry of a full list: its oldest element.
// A list of markers only has no room.
@(private = "file")
formatting_make_room :: proc "contextless" (parser: ^Parser) -> bool {
	if parser.formatting_count < ACTIVE_FORMATTING_CAPACITY {
		return true
	}
	for index in 0 ..< parser.formatting_count {
		if parser.formatting[index] != FORMATTING_MARKER {
			formatting_remove_at(parser, index)
			return true
		}
	}
	return false
}

@(private = "file")
formatting_marker_push :: proc "contextless" (parser: ^Parser) {
	if formatting_make_room(parser) {
		parser.formatting[parser.formatting_count] = FORMATTING_MARKER
		parser.formatting_count += 1
	}
}

@(private = "file")
formatting_clear_to_marker :: proc "contextless" (parser: ^Parser) {
	for parser.formatting_count > 0 {
		parser.formatting_count -= 1
		if parser.formatting[parser.formatting_count] == FORMATTING_MARKER {
			return
		}
	}
}

// elements_alike: the same tag, the same name and the same attributes, in
// any order.
@(private = "file")
elements_alike :: proc "contextless" (tree: ^Dom_Tree, first, second: u16) -> bool {
	a := &tree.nodes[first]
	b := &tree.nodes[second]
	if a.tag != b.tag || a.attr_count != b.attr_count {
		return false
	}
	if a.tag == .Unknown && string(tree.text_pool[a.text_off:a.text_off + a.text_len]) != string(tree.text_pool[b.text_off:b.text_off + b.text_len]) {
		return false
	}
	for index in 0 ..< int(a.attr_count) {
		attribute := tree.attrs[int(a.attr_start) + index]
		name := string(tree.text_pool[attribute.name_off:attribute.name_off + u32(attribute.name_len)])
		value := string(tree.text_pool[attribute.value_off:attribute.value_off + u32(attribute.value_len)])
		other, found := dom_node_attr(tree, second, name)
		if !found || string(other) != value {
			return false
		}
	}
	return true
}

@(private = "file")
formatting_push :: proc "contextless" (parser: ^Parser, node: u16) {
	alike := 0
	earliest := -1
	for index := parser.formatting_count - 1; index >= 0; index -= 1 {
		entry := parser.formatting[index]
		if entry == FORMATTING_MARKER {
			break
		}
		if elements_alike(parser.tree, entry, node) {
			alike += 1
			earliest = index
		}
	}
	if alike >= FORMATTING_COPIES_LIMIT {
		formatting_remove_at(parser, earliest)
	}
	if formatting_make_room(parser) {
		parser.formatting[parser.formatting_count] = node
		parser.formatting_count += 1
	}
}

// formatting_reconstruct opens again each formatting element of the list
// that a misnested end tag closed, before the content that follows it.
@(private = "file")
formatting_reconstruct :: proc "contextless" (parser: ^Parser) {
	if parser.formatting_count == 0 {
		return
	}
	last := parser.formatting[parser.formatting_count - 1]
	if last == FORMATTING_MARKER || stack_index(parser, last) >= 0 {
		return
	}
	entry := parser.formatting_count - 1
	for entry > 0 {
		previous := parser.formatting[entry - 1]
		if previous == FORMATTING_MARKER || stack_index(parser, previous) >= 0 {
			break
		}
		entry -= 1
	}
	for ; entry < parser.formatting_count; entry += 1 {
		if parser.open_count >= MAX_DOM_DEPTH {
			parser.tree.truncated = true
			return
		}
		clone := element_clone(parser, parser.formatting[entry])
		if clone == NO_NODE {
			return
		}
		parent, before := insertion_place(parser, NO_NODE)
		node_insert_before(parser.tree, parent, clone, before)
		parser.open[parser.open_count] = clone
		parser.open_count += 1
		parser.formatting[entry] = clone
	}
}

// adoption_agency runs the adoption agency algorithm of the WHATWG for the
// end tag of a formatting element, in at most 8 outer rounds of at most the
// open elements each. The result is false when the end tag is to be read
// as any other end tag.
@(private = "file")
adoption_agency :: proc "contextless" (parser: ^Parser, subject: Html_Tag) -> bool {
	tree := parser.tree
	if parser.open_count > 0 && current_tag(parser) == subject && formatting_index(parser, current_node(parser)) < 0 {
		parser.open_count -= 1
		return true
	}
	for _ in 0 ..< ADOPTION_OUTER_ROUNDS {
		formatting_position := -1
		for index := parser.formatting_count - 1; index >= 0; index -= 1 {
			entry := parser.formatting[index]
			if entry == FORMATTING_MARKER {
				break
			}
			if tag_of(parser, entry) == subject {
				formatting_position = index
				break
			}
		}
		if formatting_position < 0 {
			return false
		}
		formatting_element := parser.formatting[formatting_position]
		stack_position := stack_index(parser, formatting_element)
		if stack_position < 0 {
			formatting_remove_at(parser, formatting_position)
			return true
		}
		if !node_in_scope(parser, formatting_element) {
			return true
		}
		furthest_position := -1
		for index := stack_position + 1; index < parser.open_count; index += 1 {
			if is_special_tag(tag_of(parser, parser.open[index])) {
				furthest_position = index
				break
			}
		}
		if furthest_position < 0 {
			parser.open_count = stack_position
			formatting_remove_at(parser, formatting_position)
			return true
		}
		furthest_block := parser.open[furthest_position]
		common_ancestor := parser.open[max(stack_position - 1, 0)]
		bookmark := formatting_position
		node_position := furthest_position
		last_node := furthest_block
		for inner := 1;; inner += 1 {
			node_position -= 1
			node := parser.open[node_position]
			if node == formatting_element {
				break
			}
			node_formatting := formatting_index(parser, node)
			if inner > ADOPTION_INNER_ROUNDS && node_formatting >= 0 {
				formatting_remove_at(parser, node_formatting)
				if node_formatting < bookmark {
					bookmark -= 1
				}
				node_formatting = -1
			}
			if node_formatting < 0 {
				stack_remove_at(parser, node_position)
				continue
			}
			clone := element_clone(parser, node)
			if clone == NO_NODE {
				// The pool is full: the nodes met so far keep their places.
				break
			}
			parser.formatting[node_formatting] = clone
			parser.open[node_position] = clone
			if last_node == furthest_block {
				bookmark = node_formatting + 1
			}
			node_detach(tree, last_node)
			node_insert_before(tree, clone, last_node, NO_NODE)
			last_node = clone
		}
		node_detach(tree, last_node)
		parent, before := insertion_place(parser, common_ancestor)
		node_insert_before(tree, parent, last_node, before)
		new_element := element_clone(parser, formatting_element)
		if new_element == NO_NODE {
			formatting_remove_at(parser, formatting_index(parser, formatting_element))
			stack_remove(parser, formatting_element)
			return true
		}
		// The children of the furthest block move into the new element,
		// which becomes the one child of the furthest block.
		block := &tree.nodes[furthest_block]
		child := block.first_child
		for child != NO_NODE {
			tree.nodes[child].parent = new_element
			child = tree.nodes[child].next_sibling
		}
		tree.nodes[new_element].first_child = block.first_child
		tree.nodes[new_element].last_child = block.last_child
		block.first_child = NO_NODE
		block.last_child = NO_NODE
		node_insert_before(tree, furthest_block, new_element, NO_NODE)
		old_index := formatting_index(parser, formatting_element)
		formatting_remove_at(parser, old_index)
		if old_index >= 0 && old_index < bookmark {
			bookmark -= 1
		}
		formatting_insert_at(parser, bookmark, new_element)
		stack_remove(parser, formatting_element)
		stack_insert_at(parser, stack_index(parser, furthest_block) + 1, new_element)
	}
	return true
}

// any_other_end_tag closes the nearest open element of the end tag, unless
// a special element is open above it.
@(private = "file")
any_other_end_tag :: proc "contextless" (parser: ^Parser, token: ^Token) {
	for index := parser.open_count - 1; index >= 1; index -= 1 {
		node := parser.open[index]
		if element_matches_end(parser, node, token) {
			generate_implied_end_tags(parser, token.tag)
			parser.open_count = min(parser.open_count, index)
			return
		}
		if is_special_tag(tag_of(parser, node)) {
			return
		}
	}
}

@(private = "file")
whitespace_prefix :: proc "contextless" (text: []u8) -> int {
	count := 0
	for count < len(text) && html_is_space(text[count]) {
		count += 1
	}
	return count
}

@(private = "file")
token_attribute :: proc "contextless" (token: ^Token, name: string) -> (value: []u8, found: bool) {
	for attribute in token.attributes[:token.attribute_count] {
		if html_ascii_eq_ci(attribute.name, name) {
			return attribute.value, true
		}
	}
	return nil, false
}

// The insertion modes. Each returns true when the token is to be
// processed again in the new mode.

@(private = "file")
mode_initial :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	switch token.kind {
	case .Characters:
		token.text = token.text[whitespace_prefix(token.text):]
		if len(token.text) == 0 {
			return false
		}
	case .Comment:
		comment_insert(parser, token.text, 0)
		return false
	case .Doctype:
		tree := parser.tree
		name_off, name_len := pool_append_raw(tree, token.text, true)
		node := node_allocate(tree, .Doctype, .Unknown)
		if node != NO_NODE {
			tree.nodes[node].text_off = name_off
			tree.nodes[node].text_len = name_len
			node_insert_before(tree, 0, node, NO_NODE)
		}
		parser.mode = .Before_Html
		return false
	case .Start_Tag, .End_Tag, .End_Of_File:
	}
	parser.mode = .Before_Html
	return true
}

@(private = "file")
mode_before_html :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	switch token.kind {
	case .Doctype:
		return false
	case .Comment:
		comment_insert(parser, token.text, 0)
		return false
	case .Characters:
		token.text = token.text[whitespace_prefix(token.text):]
		if len(token.text) == 0 {
			return false
		}
	case .Start_Tag:
		if token.tag == .Html {
			if element_insert(parser, token) != NO_NODE {
				parser.mode = .Before_Head
			}
			return false
		}
	case .End_Tag:
		if token.tag != .Head && token.tag != .Body && token.tag != .Html && token.tag != .Br {
			return false
		}
	case .End_Of_File:
	}
	element_insert_implied(parser, .Html)
	parser.mode = .Before_Head
	return true
}

@(private = "file")
mode_before_head :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	switch token.kind {
	case .Characters:
		token.text = token.text[whitespace_prefix(token.text):]
		if len(token.text) == 0 {
			return false
		}
	case .Comment:
		comment_insert(parser, token.text, NO_NODE)
		return false
	case .Doctype:
		return false
	case .Start_Tag:
		if token.tag == .Html {
			return false
		}
		if token.tag == .Head {
			parser.head = element_insert(parser, token)
			parser.mode = .In_Head
			return false
		}
	case .End_Tag:
		if token.tag != .Head && token.tag != .Body && token.tag != .Html && token.tag != .Br {
			return false
		}
	case .End_Of_File:
	}
	parser.head = element_insert_implied(parser, .Head)
	parser.mode = .In_Head
	return true
}

// head_content_insert inserts an element of the head: base, link, meta,
// and the text-only title, style and script. false: the tag is no such
// element.
@(private = "file")
head_content_insert :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	switch token.tag {
	case .Base, .Link, .Meta:
		void_insert(parser, token)
		return true
	case .Title, .Style, .Script:
		text_only_insert(parser, token)
		return true
	case .Unknown, .Html, .Head, .Body, .Div, .Span, .P, .A, .H1, .H2, .H3, .H4, .H5, .H6, .Ul, .Ol, .Li,
	     .Header, .Footer, .Main, .Nav, .Section, .Article, .Button, .Form, .Input, .Label, .Br, .Hr, .Img,
	     .Pre, .Code, .Strong, .Em, .B, .I, .U, .S, .Small, .Dl, .Dt, .Dd, .Blockquote, .Textarea, .Table,
	     .Caption, .Thead, .Tbody, .Tfoot, .Tr, .Th, .Td:
	}
	return false
}

@(private = "file")
head_pop :: proc "contextless" (parser: ^Parser) {
	if parser.open_count > 1 && current_tag(parser) == .Head {
		parser.open_count -= 1
	}
	parser.mode = .After_Head
}

@(private = "file")
mode_in_head :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	switch token.kind {
	case .Characters:
		spaces := whitespace_prefix(token.text)
		characters_insert(parser, token.text[:spaces])
		token.text = token.text[spaces:]
		if len(token.text) == 0 {
			return false
		}
	case .Comment:
		comment_insert(parser, token.text, NO_NODE)
		return false
	case .Doctype:
		return false
	case .Start_Tag:
		if token.tag == .Html || token.tag == .Head {
			return false
		}
		if head_content_insert(parser, token) {
			return false
		}
	case .End_Tag:
		if token.tag == .Head {
			head_pop(parser)
			return false
		}
		if token.tag != .Body && token.tag != .Html && token.tag != .Br {
			return false
		}
	case .End_Of_File:
	}
	head_pop(parser)
	return true
}

@(private = "file")
mode_after_head :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	switch token.kind {
	case .Characters:
		spaces := whitespace_prefix(token.text)
		characters_insert(parser, token.text[:spaces])
		token.text = token.text[spaces:]
		if len(token.text) == 0 {
			return false
		}
	case .Comment:
		comment_insert(parser, token.text, NO_NODE)
		return false
	case .Doctype:
		return false
	case .Start_Tag:
		if token.tag == .Html || token.tag == .Head {
			return false
		}
		if token.tag == .Body {
			if element_insert(parser, token) != NO_NODE {
				parser.mode = .In_Body
			}
			return false
		}
		// An element of the head after </head> goes into the head.
		if parser.head != NO_NODE && parser.open_count < MAX_DOM_DEPTH {
			parser.open[parser.open_count] = parser.head
			parser.open_count += 1
			inserted := head_content_insert(parser, token)
			stack_remove(parser, parser.head)
			if inserted {
				return false
			}
		}
	case .End_Tag:
		if token.tag != .Body && token.tag != .Html && token.tag != .Br {
			return false
		}
	case .End_Of_File:
	}
	element_insert_implied(parser, .Body)
	parser.mode = .In_Body
	return true
}

@(private = "file")
mode_in_body :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	switch token.kind {
	case .Characters:
		text := token.text
		// A newline right after <pre> is not part of its text.
		if parser.skip_newline && len(text) > 0 && text[0] == '\n' {
			text = text[1:]
		}
		parser.skip_newline = false
		if len(text) == 0 {
			return false
		}
		formatting_reconstruct(parser)
		characters_insert(parser, text)
		return false
	case .Comment:
		comment_insert(parser, token.text, NO_NODE)
		return false
	case .Doctype, .End_Of_File:
		return false
	case .Start_Tag:
		return body_start_tag(parser, token)
	case .End_Tag:
		return body_end_tag(parser, token)
	}
	return false
}

@(private = "file")
list_item_close :: proc "contextless" (parser: ^Parser, first, second: Html_Tag) {
	for index := parser.open_count - 1; index >= 1; index -= 1 {
		tag := tag_of(parser, parser.open[index])
		if tag == first || tag == second {
			generate_implied_end_tags(parser, tag)
			pop_until_tag(parser, tag)
			return
		}
		if is_special_tag(tag) && tag != .Div && tag != .P {
			return
		}
	}
}

@(private = "file")
body_start_tag :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	switch token.tag {
	case .Html, .Body, .Head, .Caption, .Thead, .Tbody, .Tfoot, .Tr, .Th, .Td:
	// Ignored in the body: a part of a table outside a table, and a
	// second html, head or body.
	case .Base, .Link, .Meta, .Title, .Style, .Script:
		head_content_insert(parser, token)
	case .Div, .Ul, .Ol, .Dl, .Header, .Footer, .Main, .Nav, .Section, .Article, .Blockquote, .P:
		close_p_in_button_scope(parser)
		element_insert(parser, token)
	case .H1, .H2, .H3, .H4, .H5, .H6:
		close_p_in_button_scope(parser)
		if parser.open_count > 1 && is_heading_tag(current_tag(parser)) {
			parser.open_count -= 1
		}
		element_insert(parser, token)
	case .Pre:
		close_p_in_button_scope(parser)
		if element_insert(parser, token) != NO_NODE {
			parser.skip_newline = true
		}
	case .Form:
		if parser.form != NO_NODE {
			return false
		}
		close_p_in_button_scope(parser)
		parser.form = element_insert(parser, token)
	case .Li:
		list_item_close(parser, .Li, .Li)
		close_p_in_button_scope(parser)
		element_insert(parser, token)
	case .Dd, .Dt:
		list_item_close(parser, .Dd, .Dt)
		close_p_in_button_scope(parser)
		element_insert(parser, token)
	case .Button:
		if in_scope(parser, .Button, .Default) {
			generate_implied_end_tags(parser, .Unknown)
			pop_until_tag(parser, .Button)
		}
		formatting_reconstruct(parser)
		element_insert(parser, token)
	case .A:
		for index := parser.formatting_count - 1; index >= 0; index -= 1 {
			entry := parser.formatting[index]
			if entry == FORMATTING_MARKER {
				break
			}
			if tag_of(parser, entry) == .A {
				adoption_agency(parser, .A)
				formatting_remove_at(parser, formatting_index(parser, entry))
				stack_remove(parser, entry)
				break
			}
		}
		formatting_reconstruct(parser)
		if node := element_insert(parser, token); node != NO_NODE {
			formatting_push(parser, node)
		}
	case .B, .I, .U, .S, .Small, .Strong, .Em, .Code:
		formatting_reconstruct(parser)
		if node := element_insert(parser, token); node != NO_NODE {
			formatting_push(parser, node)
		}
	case .Table:
		close_p_in_button_scope(parser)
		if element_insert(parser, token) != NO_NODE {
			parser.mode = .In_Table
		}
	case .Br, .Img, .Input:
		formatting_reconstruct(parser)
		void_insert(parser, token)
	case .Hr:
		close_p_in_button_scope(parser)
		void_insert(parser, token)
	case .Textarea:
		text_only_insert(parser, token)
	case .Unknown, .Span, .Label:
		formatting_reconstruct(parser)
		element_insert(parser, token)
	}
	return false
}

@(private = "file")
body_end_tag :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	switch token.tag {
	case .Body:
		if in_scope(parser, .Body, .Default) {
			parser.mode = .After_Body
		}
	case .Html:
		if in_scope(parser, .Body, .Default) {
			parser.mode = .After_Body
			return true
		}
	case .Div, .Ul, .Ol, .Dl, .Header, .Footer, .Main, .Nav, .Section, .Article, .Blockquote, .Pre, .Button:
		if in_scope(parser, token.tag, .Default) {
			generate_implied_end_tags(parser, .Unknown)
			pop_until_tag(parser, token.tag)
		}
	case .Form:
		node := parser.form
		parser.form = NO_NODE
		if node != NO_NODE && node_in_scope(parser, node) {
			generate_implied_end_tags(parser, .Unknown)
			stack_remove(parser, node)
		}
	case .P:
		if !in_scope(parser, .P, .Button) {
			element_insert_implied(parser, .P)
		}
		close_p_element(parser)
	case .Li:
		if in_scope(parser, .Li, .List_Item) {
			generate_implied_end_tags(parser, .Li)
			pop_until_tag(parser, .Li)
		}
	case .Dd, .Dt:
		if in_scope(parser, token.tag, .Default) {
			generate_implied_end_tags(parser, token.tag)
			pop_until_tag(parser, token.tag)
		}
	case .H1, .H2, .H3, .H4, .H5, .H6:
		if heading_in_scope(parser) {
			generate_implied_end_tags(parser, .Unknown)
			pop_until_heading(parser)
		}
	case .A, .B, .I, .U, .S, .Small, .Strong, .Em, .Code:
		if !adoption_agency(parser, token.tag) {
			any_other_end_tag(parser, token)
		}
	case .Br:
		// </br> is read as <br>.
		formatting_reconstruct(parser)
		token.kind = .Start_Tag
		token.attribute_count = 0
		void_insert(parser, token)
	case .Unknown, .Head, .Title, .Meta, .Link, .Style, .Script, .Span, .Input, .Label, .Hr, .Img, .Textarea,
	     .Base, .Table, .Caption, .Thead, .Tbody, .Tfoot, .Tr, .Th, .Td:
		any_other_end_tag(parser, token)
	}
	return false
}

// in_body_fostered processes a token with the rules of the body, with each
// insertion before the table, as the WHATWG does for content that a table
// cannot hold.
@(private = "file")
in_body_fostered :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	parser.foster_parenting = true
	reprocess := mode_in_body(parser, token)
	parser.foster_parenting = false
	return reprocess
}

@(private = "file")
mode_in_table :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	switch token.kind {
	case .Characters:
		if is_table_context_tag(current_tag(parser)) && whitespace_prefix(token.text) == len(token.text) {
			characters_insert(parser, token.text)
			return false
		}
		return in_body_fostered(parser, token)
	case .Comment:
		comment_insert(parser, token.text, NO_NODE)
		return false
	case .Doctype, .End_Of_File:
		return false
	case .Start_Tag:
		switch token.tag {
		case .Caption:
			clear_stack_back_to(parser, .Table, .Table, .Table)
			formatting_marker_push(parser)
			if element_insert(parser, token) != NO_NODE {
				parser.mode = .In_Caption
			}
			return false
		case .Tbody, .Tfoot, .Thead:
			clear_stack_back_to(parser, .Table, .Table, .Table)
			if element_insert(parser, token) != NO_NODE {
				parser.mode = .In_Table_Body
			}
			return false
		case .Td, .Th, .Tr:
			clear_stack_back_to(parser, .Table, .Table, .Table)
			if element_insert_implied(parser, .Tbody) == NO_NODE {
				return false
			}
			parser.mode = .In_Table_Body
			return true
		case .Table:
			if !in_scope(parser, .Table, .Table) {
				return false
			}
			pop_until_tag(parser, .Table)
			reset_insertion_mode(parser)
			return true
		case .Style, .Script:
			head_content_insert(parser, token)
			return false
		case .Input:
			if type_value, has_type := token_attribute(token, "type"); has_type && html_ascii_eq_ci(type_value, "hidden") {
				void_insert(parser, token)
				return false
			}
		case .Form:
			if parser.form == NO_NODE {
				parser.form = element_insert(parser, token)
				if parser.form != NO_NODE {
					parser.open_count -= 1
				}
			}
			return false
		case .Unknown, .Html, .Head, .Body, .Title, .Meta, .Link, .Div, .Span, .P, .A, .H1, .H2, .H3, .H4, .H5,
		     .H6, .Ul, .Ol, .Li, .Header, .Footer, .Main, .Nav, .Section, .Article, .Button, .Label, .Br, .Hr,
		     .Img, .Pre, .Code, .Strong, .Em, .B, .I, .U, .S, .Small, .Dl, .Dt, .Dd, .Blockquote, .Textarea, .Base:
		}
	case .End_Tag:
		switch token.tag {
		case .Table:
			if in_scope(parser, .Table, .Table) {
				pop_until_tag(parser, .Table)
				reset_insertion_mode(parser)
			}
			return false
		case .Body, .Caption, .Html, .Tbody, .Td, .Tfoot, .Th, .Thead, .Tr:
			return false
		case .Unknown, .Head, .Title, .Meta, .Link, .Style, .Script, .Div, .Span, .P, .A, .H1, .H2, .H3, .H4,
		     .H5, .H6, .Ul, .Ol, .Li, .Header, .Footer, .Main, .Nav, .Section, .Article, .Button, .Form, .Input,
		     .Label, .Br, .Hr, .Img, .Pre, .Code, .Strong, .Em, .B, .I, .U, .S, .Small, .Dl, .Dt, .Dd,
		     .Blockquote, .Textarea, .Base:
		}
	}
	return in_body_fostered(parser, token)
}

@(private = "file")
caption_close :: proc "contextless" (parser: ^Parser) -> bool {
	if !in_scope(parser, .Caption, .Table) {
		return false
	}
	generate_implied_end_tags(parser, .Unknown)
	pop_until_tag(parser, .Caption)
	formatting_clear_to_marker(parser)
	parser.mode = .In_Table
	return true
}

@(private = "file")
is_table_part_start :: proc "contextless" (tag: Html_Tag) -> bool {
	return tag == .Caption || tag == .Tbody || tag == .Td || tag == .Tfoot || tag == .Th || tag == .Thead || tag == .Tr
}

@(private = "file")
mode_in_caption :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	switch token.kind {
	case .End_Tag:
		switch token.tag {
		case .Caption:
			caption_close(parser)
			return false
		case .Table:
			return caption_close(parser)
		case .Body, .Html, .Tbody, .Td, .Tfoot, .Th, .Thead, .Tr:
			return false
		case .Unknown, .Head, .Title, .Meta, .Link, .Style, .Script, .Div, .Span, .P, .A, .H1, .H2, .H3, .H4,
		     .H5, .H6, .Ul, .Ol, .Li, .Header, .Footer, .Main, .Nav, .Section, .Article, .Button, .Form, .Input,
		     .Label, .Br, .Hr, .Img, .Pre, .Code, .Strong, .Em, .B, .I, .U, .S, .Small, .Dl, .Dt, .Dd,
		     .Blockquote, .Textarea, .Base:
		}
	case .Start_Tag:
		if is_table_part_start(token.tag) {
			return caption_close(parser)
		}
	case .Characters, .Comment, .Doctype, .End_Of_File:
	}
	return mode_in_body(parser, token)
}

@(private = "file")
row_group_close :: proc "contextless" (parser: ^Parser) -> bool {
	if !in_scope(parser, .Tbody, .Table) && !in_scope(parser, .Thead, .Table) && !in_scope(parser, .Tfoot, .Table) {
		return false
	}
	clear_stack_back_to(parser, .Tbody, .Thead, .Tfoot)
	if parser.open_count > 1 {
		parser.open_count -= 1
	}
	parser.mode = .In_Table
	return true
}

@(private = "file")
mode_in_table_body :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	switch token.kind {
	case .Start_Tag:
		switch token.tag {
		case .Tr:
			clear_stack_back_to(parser, .Tbody, .Thead, .Tfoot)
			if element_insert(parser, token) != NO_NODE {
				parser.mode = .In_Row
			}
			return false
		case .Th, .Td:
			clear_stack_back_to(parser, .Tbody, .Thead, .Tfoot)
			if element_insert_implied(parser, .Tr) == NO_NODE {
				return false
			}
			parser.mode = .In_Row
			return true
		case .Caption, .Tbody, .Tfoot, .Thead:
			return row_group_close(parser)
		case .Unknown, .Html, .Head, .Body, .Title, .Meta, .Link, .Style, .Script, .Div, .Span, .P, .A, .H1,
		     .H2, .H3, .H4, .H5, .H6, .Ul, .Ol, .Li, .Header, .Footer, .Main, .Nav, .Section, .Article, .Button,
		     .Form, .Input, .Label, .Br, .Hr, .Img, .Pre, .Code, .Strong, .Em, .B, .I, .U, .S, .Small, .Dl, .Dt,
		     .Dd, .Blockquote, .Textarea, .Base, .Table:
		}
	case .End_Tag:
		switch token.tag {
		case .Tbody, .Tfoot, .Thead:
			if in_scope(parser, token.tag, .Table) {
				clear_stack_back_to(parser, .Tbody, .Thead, .Tfoot)
				if parser.open_count > 1 {
					parser.open_count -= 1
				}
				parser.mode = .In_Table
			}
			return false
		case .Table:
			return row_group_close(parser)
		case .Body, .Caption, .Html, .Td, .Th, .Tr:
			return false
		case .Unknown, .Head, .Title, .Meta, .Link, .Style, .Script, .Div, .Span, .P, .A, .H1, .H2, .H3, .H4,
		     .H5, .H6, .Ul, .Ol, .Li, .Header, .Footer, .Main, .Nav, .Section, .Article, .Button, .Form, .Input,
		     .Label, .Br, .Hr, .Img, .Pre, .Code, .Strong, .Em, .B, .I, .U, .S, .Small, .Dl, .Dt, .Dd,
		     .Blockquote, .Textarea, .Base:
		}
	case .Characters, .Comment, .Doctype, .End_Of_File:
	}
	return mode_in_table(parser, token)
}

@(private = "file")
row_close :: proc "contextless" (parser: ^Parser) -> bool {
	if !in_scope(parser, .Tr, .Table) {
		return false
	}
	clear_stack_back_to(parser, .Tr, .Tr, .Tr)
	if parser.open_count > 1 {
		parser.open_count -= 1
	}
	parser.mode = .In_Table_Body
	return true
}

@(private = "file")
mode_in_row :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	switch token.kind {
	case .Start_Tag:
		switch token.tag {
		case .Th, .Td:
			clear_stack_back_to(parser, .Tr, .Tr, .Tr)
			if element_insert(parser, token) != NO_NODE {
				parser.mode = .In_Cell
				formatting_marker_push(parser)
			}
			return false
		case .Caption, .Tbody, .Tfoot, .Thead, .Tr:
			return row_close(parser)
		case .Unknown, .Html, .Head, .Body, .Title, .Meta, .Link, .Style, .Script, .Div, .Span, .P, .A, .H1,
		     .H2, .H3, .H4, .H5, .H6, .Ul, .Ol, .Li, .Header, .Footer, .Main, .Nav, .Section, .Article, .Button,
		     .Form, .Input, .Label, .Br, .Hr, .Img, .Pre, .Code, .Strong, .Em, .B, .I, .U, .S, .Small, .Dl, .Dt,
		     .Dd, .Blockquote, .Textarea, .Base, .Table:
		}
	case .End_Tag:
		switch token.tag {
		case .Tr:
			row_close(parser)
			return false
		case .Table:
			return row_close(parser)
		case .Tbody, .Tfoot, .Thead:
			if !in_scope(parser, token.tag, .Table) {
				return false
			}
			return row_close(parser)
		case .Body, .Caption, .Html, .Td, .Th:
			return false
		case .Unknown, .Head, .Title, .Meta, .Link, .Style, .Script, .Div, .Span, .P, .A, .H1, .H2, .H3, .H4,
		     .H5, .H6, .Ul, .Ol, .Li, .Header, .Footer, .Main, .Nav, .Section, .Article, .Button, .Form, .Input,
		     .Label, .Br, .Hr, .Img, .Pre, .Code, .Strong, .Em, .B, .I, .U, .S, .Small, .Dl, .Dt, .Dd,
		     .Blockquote, .Textarea, .Base:
		}
	case .Characters, .Comment, .Doctype, .End_Of_File:
	}
	return mode_in_table(parser, token)
}

@(private = "file")
cell_close :: proc "contextless" (parser: ^Parser) {
	generate_implied_end_tags(parser, .Unknown)
	for parser.open_count > 1 {
		parser.open_count -= 1
		tag := tag_of(parser, parser.open[parser.open_count])
		if tag == .Td || tag == .Th {
			break
		}
	}
	formatting_clear_to_marker(parser)
	parser.mode = .In_Row
}

@(private = "file")
mode_in_cell :: proc "contextless" (parser: ^Parser, token: ^Token) -> bool {
	switch token.kind {
	case .End_Tag:
		switch token.tag {
		case .Td, .Th:
			if in_scope(parser, token.tag, .Table) {
				cell_close(parser)
			}
			return false
		case .Body, .Caption, .Html:
			return false
		case .Table, .Tbody, .Tfoot, .Thead, .Tr:
			if !in_scope(parser, token.tag, .Table) {
				return false
			}
			cell_close(parser)
			return true
		case .Unknown, .Head, .Title, .Meta, .Link, .Style, .Script, .Div, .Span, .P, .A, .H1, .H2, .H3, .H4,
		     .H5, .H6, .Ul, .Ol, .Li, .Header, .Footer, .Main, .Nav, .Section, .Article, .Button, .Form, .Input,
		     .Label, .Br, .Hr, .Img, .Pre, .Code, .Strong, .Em, .B, .I, .U, .S, .Small, .Dl, .Dt, .Dd,
		     .Blockquote, .Textarea, .Base:
		}
	case .Start_Tag:
		if is_table_part_start(token.tag) {
			if !in_scope(parser, .Td, .Table) && !in_scope(parser, .Th, .Table) {
				return false
			}
			cell_close(parser)
			return true
		}
	case .Characters, .Comment, .Doctype, .End_Of_File:
	}
	return mode_in_body(parser, token)
}

@(private = "file")
mode_after_body :: proc "contextless" (parser: ^Parser, token: ^Token, after_after: bool) -> bool {
	switch token.kind {
	case .Characters:
		if whitespace_prefix(token.text) == len(token.text) {
			return mode_in_body(parser, token)
		}
	case .Comment:
		// After </body> a comment goes to the html element; after </html>,
		// to the document.
		comment_insert(parser, token.text, 0 if after_after || parser.open_count == 0 else parser.open[0])
		return false
	case .Doctype, .End_Of_File:
		return false
	case .Start_Tag:
		if token.tag == .Html {
			return false
		}
	case .End_Tag:
		if token.tag == .Html && !after_after {
			parser.mode = .After_After_Body
			return false
		}
	}
	parser.mode = .In_Body
	return true
}

@(private = "file")
token_process :: proc "contextless" (parser: ^Parser, token: ^Token) {
	if token.kind != .Characters {
		parser.skip_newline = false
	}
	for _ in 0 ..< REPROCESS_LIMIT {
		reprocess: bool
		switch parser.mode {
		case .Initial:
			reprocess = mode_initial(parser, token)
		case .Before_Html:
			reprocess = mode_before_html(parser, token)
		case .Before_Head:
			reprocess = mode_before_head(parser, token)
		case .In_Head:
			reprocess = mode_in_head(parser, token)
		case .After_Head:
			reprocess = mode_after_head(parser, token)
		case .In_Body:
			reprocess = mode_in_body(parser, token)
		case .In_Table:
			reprocess = mode_in_table(parser, token)
		case .In_Caption:
			reprocess = mode_in_caption(parser, token)
		case .In_Table_Body:
			reprocess = mode_in_table_body(parser, token)
		case .In_Row:
			reprocess = mode_in_row(parser, token)
		case .In_Cell:
			reprocess = mode_in_cell(parser, token)
		case .After_Body:
			reprocess = mode_after_body(parser, token, false)
		case .After_After_Body:
			reprocess = mode_after_body(parser, token, true)
		}
		if !reprocess {
			return
		}
	}
}

// tree_order puts the nodes in preorder and computes their depths. The
// adoption agency and foster parenting move nodes after they are made, so
// the order of their making is not the order of the tree.
@(private = "file")
tree_order :: proc "contextless" (tree: ^Dom_Tree) {
	count := int(tree.node_count)
	order: [MAX_DOM_NODES]u16
	new_index: [MAX_DOM_NODES]u16
	for index in 0 ..< count {
		new_index[index] = NO_NODE
	}
	placed := 0
	node := u16(0)
	// Each step of the walk is bounded by the count: a broken link ends
	// the walk, never the bounds of the table.
	walk: for placed < count {
		order[placed] = node
		new_index[node] = u16(placed)
		placed += 1
		first_child := tree.nodes[node].first_child
		if first_child != NO_NODE && int(first_child) < count && new_index[first_child] == NO_NODE {
			node = first_child
			continue
		}
		for _ in 0 ..< count {
			if node == 0 {
				break walk
			}
			sibling := tree.nodes[node].next_sibling
			if sibling != NO_NODE && int(sibling) < count && new_index[sibling] == NO_NODE {
				node = sibling
				continue walk
			}
			parent := tree.nodes[node].parent
			if parent == NO_NODE || int(parent) >= count {
				break walk
			}
			node = parent
		}
		break
	}
	// The parser links each node it makes, so the walk meets each once; a
	// node that it does not meet is dropped, and the tree says it is cut.
	if placed != count {
		tree.truncated = true
	}
	remap :: proc "contextless" (new_index: ^[MAX_DOM_NODES]u16, value: u16) -> u16 {
		return NO_NODE if value == NO_NODE else new_index[value]
	}
	for index in 0 ..< count {
		element := &tree.nodes[index]
		element.parent = remap(&new_index, element.parent)
		element.first_child = remap(&new_index, element.first_child)
		element.last_child = remap(&new_index, element.last_child)
		element.next_sibling = remap(&new_index, element.next_sibling)
	}
	// Each node moves to its new place along the cycles of the order.
	visited: [MAX_DOM_NODES / 64]u64
	for start in 0 ..< placed {
		if visited[start / 64] & (1 << uint(start % 64)) != 0 {
			continue
		}
		saved := tree.nodes[start]
		place := start
		for {
			visited[place / 64] |= 1 << uint(place % 64)
			source := int(order[place])
			if source == start {
				tree.nodes[place] = saved
				break
			}
			tree.nodes[place] = tree.nodes[source]
			place = source
		}
	}
	tree.node_count = u16(placed)
	tree.max_depth_reached = 0
	for index in 1 ..< placed {
		element := &tree.nodes[index]
		element.depth = min(tree.nodes[element.parent].depth + 1, MAX_DOM_DEPTH)
		tree.max_depth_reached = max(tree.max_depth_reached, element.depth)
	}
}

// parse_html tokenizes and builds a bounded, origin-isolated DOM tree from arbitrary bytes.
// Never panics, never allocates, never recurses, and never exceeds MAX_DOM_DEPTH open
// elements or MAX_DOM_NODES nodes.
parse_html :: proc "contextless" (tree: ^Dom_Tree, origin: Document_Origin, input: []u8) {
	tree^ = {}
	tree.origin = origin
	node_allocate(tree, .Document, .Unknown)
	parser := Parser {
		tree  = tree,
		input = input,
		mode  = .Initial,
		head  = NO_NODE,
		form  = NO_NODE,
	}
	token: Token
	for token_next(&parser, &token) {
		token_process(&parser, &token)
	}
	token.kind = .End_Of_File
	token_process(&parser, &token)
	tree_order(tree)
}

// DOM query helpers.

dom_node_text :: proc "contextless" (tree: ^Dom_Tree, node_idx: u16) -> []u8 {
	if node_idx == NO_NODE || int(node_idx) >= int(tree.node_count) {
		return nil
	}
	n := &tree.nodes[node_idx]
	end := n.text_off + n.text_len
	if end > tree.text_len {
		return nil
	}
	return tree.text_pool[n.text_off:end]
}

dom_node_attr :: proc "contextless" (tree: ^Dom_Tree, node_idx: u16, name: string) -> (value: []u8, found: bool) {
	if node_idx == NO_NODE || int(node_idx) >= int(tree.node_count) {
		return nil, false
	}
	n := &tree.nodes[node_idx]
	start := int(n.attr_start)
	end := min(start + int(n.attr_count), int(tree.attr_count))
	for i := start; i < end; i += 1 {
		a := &tree.attrs[i]
		aname := tree.text_pool[a.name_off:a.name_off + u32(a.name_len)]
		if html_ascii_eq_ci(aname, name) {
			return tree.text_pool[a.value_off:a.value_off + u32(a.value_len)], true
		}
	}
	return nil, false
}

dom_node_has_class :: proc "contextless" (tree: ^Dom_Tree, node_idx: u16, class_name: []u8) -> bool {
	if len(class_name) == 0 {
		return false
	}
	val, ok := dom_node_attr(tree, node_idx, "class")
	if !ok || len(val) == 0 {
		return false
	}
	pos := 0
	for pos < len(val) {
		for pos < len(val) && html_is_space(val[pos]) {
			pos += 1
		}
		start := pos
		for pos < len(val) && !html_is_space(val[pos]) {
			pos += 1
		}
		if pos > start && pos - start == len(class_name) {
			match := true
			for k := 0; k < len(class_name); k += 1 {
				if val[start + k] != class_name[k] {
					match = false
					break
				}
			}
			if match {
				return true
			}
		}
	}
	return false
}

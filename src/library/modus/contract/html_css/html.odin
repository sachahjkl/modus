// WHATWG-subset HTML tokenizer, iterative tree builder, and origin-isolated DOM.
// Pure freestanding contract package with zero heap allocations and fixed pools.
package html_css

import "modus:contract/enum_word"

MAX_DOM_NODES :: 512
MAX_DOM_DEPTH :: 64
MAX_ATTRS :: 1024
MAX_TEXT_POOL :: 32768
MAX_ORIGIN_HOST_LEN :: 128
NO_NODE :: u16(0xFFFF)

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

// Fixed-capacity origin-isolated DOM tree.
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
	switch tag {
	case .Br, .Hr, .Img, .Input, .Meta, .Link:
		return true
	case .Unknown, .Html, .Head, .Body, .Title, .Style, .Script, .Div, .Span, .P, .A,
	     .H1, .H2, .H3, .H4, .H5, .H6, .Ul, .Ol, .Li, .Header, .Footer, .Main, .Nav,
	     .Section, .Article, .Button, .Form, .Label, .Pre, .Code, .Strong, .Em:
		return false
	}
	return false
}

is_raw_text_tag :: proc "contextless" (tag: Html_Tag) -> bool {
	return tag == .Script || tag == .Style
}

is_p_closing_tag :: proc "contextless" (tag: Html_Tag) -> bool {
	switch tag {
	case .P, .Div, .H1, .H2, .H3, .H4, .H5, .H6, .Ul, .Ol, .Li, .Header, .Footer, .Main, .Nav, .Section, .Article, .Pre, .Hr, .Form:
		return true
	case .Unknown, .Html, .Head, .Body, .Title, .Meta, .Link, .Style, .Script, .Span, .A,
	     .Button, .Input, .Label, .Br, .Img, .Code, .Strong, .Em:
		return false
	}
	return false
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
html_is_tag_char :: proc "contextless" (b: u8) -> bool {
	return html_is_alpha(b) || (b >= '0' && b <= '9') || b == '-' || b == '_' || b == ':'
}

// tag_from_name maps a tag name (case-insensitive) to Html_Tag.
tag_from_name :: proc "contextless" (name: []u8) -> Html_Tag {
	switch len(name) {
	case 1:
		if html_ascii_eq_ci(name, "p") { return .P }
		if html_ascii_eq_ci(name, "a") { return .A }
	case 2:
		if html_ascii_eq_ci(name, "h1") { return .H1 }
		if html_ascii_eq_ci(name, "h2") { return .H2 }
		if html_ascii_eq_ci(name, "h3") { return .H3 }
		if html_ascii_eq_ci(name, "h4") { return .H4 }
		if html_ascii_eq_ci(name, "h5") { return .H5 }
		if html_ascii_eq_ci(name, "h6") { return .H6 }
		if html_ascii_eq_ci(name, "ul") { return .Ul }
		if html_ascii_eq_ci(name, "ol") { return .Ol }
		if html_ascii_eq_ci(name, "li") { return .Li }
		if html_ascii_eq_ci(name, "br") { return .Br }
		if html_ascii_eq_ci(name, "hr") { return .Hr }
		if html_ascii_eq_ci(name, "em") { return .Em }
	case 3:
		if html_ascii_eq_ci(name, "div") { return .Div }
		if html_ascii_eq_ci(name, "img") { return .Img }
		if html_ascii_eq_ci(name, "nav") { return .Nav }
		if html_ascii_eq_ci(name, "pre") { return .Pre }
	case 4:
		if html_ascii_eq_ci(name, "html") { return .Html }
		if html_ascii_eq_ci(name, "head") { return .Head }
		if html_ascii_eq_ci(name, "body") { return .Body }
		if html_ascii_eq_ci(name, "meta") { return .Meta }
		if html_ascii_eq_ci(name, "link") { return .Link }
		if html_ascii_eq_ci(name, "span") { return .Span }
		if html_ascii_eq_ci(name, "main") { return .Main }
		if html_ascii_eq_ci(name, "form") { return .Form }
		if html_ascii_eq_ci(name, "code") { return .Code }
	case 5:
		if html_ascii_eq_ci(name, "title") { return .Title }
		if html_ascii_eq_ci(name, "style") { return .Style }
		if html_ascii_eq_ci(name, "input") { return .Input }
		if html_ascii_eq_ci(name, "label") { return .Label }
	case 6:
		if html_ascii_eq_ci(name, "script") { return .Script }
		if html_ascii_eq_ci(name, "header") { return .Header }
		if html_ascii_eq_ci(name, "footer") { return .Footer }
		if html_ascii_eq_ci(name, "button") { return .Button }
		if html_ascii_eq_ci(name, "strong") { return .Strong }
	case 7:
		if html_ascii_eq_ci(name, "section") { return .Section }
		if html_ascii_eq_ci(name, "article") { return .Article }
	}
	return .Unknown
}

// Pool allocation helpers inside Dom_Tree.

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

@(private = "file")
pool_push_utf8 :: proc "contextless" (tree: ^Dom_Tree, cp: u32) {
	// Replace NUL, surrogates, and out-of-range code points with U+FFFD.
	code := cp
	if code == 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF) {
		code = 0xFFFD
	}
	switch {
	case code <= 0x7F:
		pool_push_byte(tree, u8(code))
	case code <= 0x7FF:
		pool_push_byte(tree, u8(0xC0 | (code >> 6)))
		pool_push_byte(tree, u8(0x80 | (code & 0x3F)))
	case code <= 0xFFFF:
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

// decode_entities_into_pool decodes named and numeric HTML character references into tree.text_pool.
@(private = "file")
decode_entities_into_pool :: proc "contextless" (tree: ^Dom_Tree, src: []u8) -> (off: u32, length: u32) {
	off = tree.text_len
	i := 0
	for i < len(src) {
		if src[i] != '&' {
			pool_push_byte(tree, src[i])
			i += 1
			continue
		}
		// Find semicolon within next 16 bytes.
		semi := -1
		limit := min(len(src), i + 16)
		for j := i + 1; j < limit; j += 1 {
			if src[j] == ';' {
				semi = j
				break
			}
			if src[j] == '&' || src[j] == '<' || html_is_space(src[j]) {
				break
			}
		}
		if semi <= i + 1 {
			pool_push_byte(tree, '&')
			i += 1
			continue
		}
		ent := src[i + 1 : semi]
		decoded := false
		if ent[0] == '#' {
			if len(ent) >= 2 && (ent[1] == 'x' || ent[1] == 'X') {
				if len(ent) > 2 {
					val: u32 = 0
					valid := true
					for k := 2; k < len(ent); k += 1 {
						c := ent[k]
						d: u32
						switch {
						case c >= '0' && c <= '9': d = u32(c - '0')
						case c >= 'a' && c <= 'f': d = u32(c - 'a' + 10)
						case c >= 'A' && c <= 'F': d = u32(c - 'A' + 10)
						case: valid = false
						}
						if !valid { break }
						if val <= 0x10FFFF {
							val = (val << 4) | d
						}
					}
					if valid {
						pool_push_utf8(tree, val)
						decoded = true
					}
				}
			} else if len(ent) >= 2 {
				val: u32 = 0
				valid := true
				for k := 1; k < len(ent); k += 1 {
					c := ent[k]
					if c < '0' || c > '9' {
						valid = false
						break
					}
					if val <= 0x10FFFF {
						val = val * 10 + u32(c - '0')
					}
				}
				if valid {
					pool_push_utf8(tree, val)
					decoded = true
				}
			}
		} else {
			switch {
			case html_ascii_eq_ci(ent, "amp"):
				pool_push_byte(tree, '&')
				decoded = true
			case html_ascii_eq_ci(ent, "lt"):
				pool_push_byte(tree, '<')
				decoded = true
			case html_ascii_eq_ci(ent, "gt"):
				pool_push_byte(tree, '>')
				decoded = true
			case html_ascii_eq_ci(ent, "quot"):
				pool_push_byte(tree, '"')
				decoded = true
			case html_ascii_eq_ci(ent, "apos"):
				pool_push_byte(tree, '\'')
				decoded = true
			case html_ascii_eq_ci(ent, "nbsp"):
				pool_push_utf8(tree, 0x00A0)
				decoded = true
			}
		}

		if decoded {
			i = semi + 1
		} else {
			pool_push_byte(tree, '&')
			i += 1
		}
	}
	return off, tree.text_len - off
}

@(private = "file")
dom_alloc_node :: proc "contextless" (tree: ^Dom_Tree, parent: u16, kind: Node_Kind, tag: Html_Tag, depth: u16) -> u16 {
	if int(tree.node_count) >= MAX_DOM_NODES {
		tree.truncated = true
		return NO_NODE
	}
	idx := tree.node_count
	tree.node_count += 1
	node := &tree.nodes[idx]
	node^ = Dom_Node{
		kind         = kind,
		tag          = tag,
		depth        = depth,
		parent       = parent,
		first_child  = NO_NODE,
		last_child   = NO_NODE,
		next_sibling = NO_NODE,
	}
	if depth > tree.max_depth_reached {
		tree.max_depth_reached = depth
	}
	if parent != NO_NODE && int(parent) < int(tree.node_count) {
		p := &tree.nodes[parent]
		if p.first_child == NO_NODE {
			p.first_child = idx
			p.last_child = idx
		} else {
			tree.nodes[p.last_child].next_sibling = idx
			p.last_child = idx
		}
	}
	return idx
}

// parse_html tokenizes and builds a bounded, origin-isolated DOM tree from arbitrary bytes.
// Never panics, never allocates, never overflows stack, and never exceeds MAX_DOM_DEPTH or MAX_DOM_NODES.
parse_html :: proc "contextless" (tree: ^Dom_Tree, origin: Document_Origin, input: []u8) {
	tree^ = {}
	tree.origin = origin

	// Root Document node at index 0.
	root := dom_alloc_node(tree, NO_NODE, .Document, .Unknown, 0)
	open_stack: [MAX_DOM_DEPTH]u16
	open_stack[0] = root
	stack_len := 1

	pos := 0
	for pos < len(input) {
		if input[pos] != '<' {
			start := pos
			for pos < len(input) && input[pos] != '<' {
				pos += 1
			}
			t_off, t_len := decode_entities_into_pool(tree, input[start:pos])
			if t_len > 0 {
				parent := open_stack[stack_len - 1]
				depth := min(u16(stack_len), u16(MAX_DOM_DEPTH))
				n := dom_alloc_node(tree, parent, .Text, .Unknown, depth)
				if n != NO_NODE {
					tree.nodes[n].text_off = t_off
					tree.nodes[n].text_len = t_len
				}
			}
			continue
		}

		// Handle comments: <!-- ... -->
		if pos + 4 <= len(input) && input[pos + 1] == '!' && input[pos + 2] == '-' && input[pos + 3] == '-' {
			cstart := pos + 4
			pos = cstart
			cend := len(input)
			for pos < len(input) {
				if pos + 3 <= len(input) && input[pos] == '-' && input[pos + 1] == '-' && input[pos + 2] == '>' {
					cend = pos
					pos += 3
					break
				}
				pos += 1
			}
			// Handle abrupt comment close <!--> or <!--->.
			if cend == len(input) && cstart < len(input) && input[cstart] == '>' {
				cend = cstart
				pos = cstart + 1
			}
			c_off, c_len := pool_append_raw(tree, input[cstart:cend], false)
			parent := open_stack[stack_len - 1]
			depth := min(u16(stack_len), u16(MAX_DOM_DEPTH))
			cn := dom_alloc_node(tree, parent, .Comment, .Unknown, depth)
			if cn != NO_NODE {
				tree.nodes[cn].text_off = c_off
				tree.nodes[cn].text_len = c_len
			}
			continue
		}

		// Skip <!DOCTYPE ...>, <! ... >, and <? ... > markup declarations.
		if pos + 1 < len(input) && (input[pos + 1] == '!' || input[pos + 1] == '?') {
			pos += 2
			for pos < len(input) && input[pos] != '>' {
				pos += 1
			}
			if pos < len(input) {
				pos += 1
			}
			continue
		}

		// Handle end tag: </tagName ... >
		if pos + 1 < len(input) && input[pos + 1] == '/' {
			pos += 2
			for pos < len(input) && html_is_space(input[pos]) {
				pos += 1
			}
			name_start := pos
			for pos < len(input) && html_is_tag_char(input[pos]) {
				pos += 1
			}
			end_name := input[name_start:pos]
			for pos < len(input) && input[pos] != '>' {
				pos += 1
			}
			if pos < len(input) {
				pos += 1
			}
			if len(end_name) == 0 {
				continue
			}
			end_tag := tag_from_name(end_name)
			// Search open_stack from top down (never popping root 0).
			found := -1
			for s := stack_len - 1; s >= 1; s -= 1 {
				node := &tree.nodes[open_stack[s]]
				if end_tag != .Unknown {
					if node.tag == end_tag {
						found = s
						break
					}
				} else if node.tag == .Unknown {
					existing := tree.text_pool[node.text_off : node.text_off + node.text_len]
					if html_ascii_eq_ci(existing, string(end_name)) {
						found = s
						break
					}
				}
			}
			if found >= 1 {
				stack_len = found
			}
			continue
		}

		// Handle start tag: <tagName ... >
		if pos + 1 < len(input) && html_is_alpha(input[pos + 1]) {
			pos += 1
			name_start := pos
			for pos < len(input) && html_is_tag_char(input[pos]) {
				pos += 1
			}
			tag_name := input[name_start:pos]
			tag := tag_from_name(tag_name)

			// Implicit tag closure rules (WHATWG subset).
			if stack_len > 1 {
				top_tag := tree.nodes[open_stack[stack_len - 1]].tag
				if top_tag == .P && is_p_closing_tag(tag) {
					stack_len -= 1
				} else if top_tag == .Li && tag == .Li {
					stack_len -= 1
				}
			}

			parent := open_stack[stack_len - 1]
			depth := min(u16(stack_len), u16(MAX_DOM_DEPTH))
			elem_idx := dom_alloc_node(tree, parent, .Element, tag, depth)
			if elem_idx != NO_NODE {
				// Store lowercased tag name for Unknown tag matching and introspection.
				if tag == .Unknown {
					noff, nlen := pool_append_raw(tree, tag_name, true)
					tree.nodes[elem_idx].text_off = noff
					tree.nodes[elem_idx].text_len = nlen
				}
				tree.nodes[elem_idx].attr_start = tree.attr_count
			}

			// Parse attributes until '>' or '/>' or EOF.
			self_closing := false
			for pos < len(input) {
				for pos < len(input) && html_is_space(input[pos]) {
					pos += 1
				}
				if pos >= len(input) {
					break
				}
				if input[pos] == '>' {
					pos += 1
					break
				}
				if input[pos] == '/' {
					if pos + 1 < len(input) && input[pos + 1] == '>' {
						self_closing = true
						pos += 2
						break
					}
					pos += 1
					continue
				}

				// Attribute name.
				an_start := pos
				for pos < len(input) && !html_is_space(input[pos]) && input[pos] != '=' && input[pos] != '>' && input[pos] != '/' {
					pos += 1
				}
				an_end := pos
				for pos < len(input) && html_is_space(input[pos]) {
					pos += 1
				}

				val_slice: []u8 = nil
				if pos < len(input) && input[pos] == '=' {
					pos += 1
					for pos < len(input) && html_is_space(input[pos]) {
						pos += 1
					}
					if pos < len(input) && (input[pos] == '"' || input[pos] == '\'') {
						q := input[pos]
						pos += 1
						vstart := pos
						for pos < len(input) && input[pos] != q {
							pos += 1
						}
						val_slice = input[vstart:pos]
						if pos < len(input) && input[pos] == q {
							pos += 1
						}
					} else {
						vstart := pos
						for pos < len(input) && !html_is_space(input[pos]) && input[pos] != '>' {
							pos += 1
						}
						val_slice = input[vstart:pos]
					}
				}

				if an_end > an_start && elem_idx != NO_NODE {
					if int(tree.attr_count) < MAX_ATTRS {
						a_name_off, a_name_len := pool_append_raw(tree, input[an_start:an_end], true)
						a_val_off, a_val_len := decode_entities_into_pool(tree, val_slice)
						tree.attrs[tree.attr_count] = Dom_Attr{
							name_off  = a_name_off,
							name_len  = u16(min(a_name_len, u32(max(u16)))),
							value_off = a_val_off,
							value_len = u16(min(a_val_len, u32(max(u16)))),
						}
						tree.attr_count += 1
						tree.nodes[elem_idx].attr_count += 1
					} else {
						tree.truncated = true
					}
				}
			}

			// Raw text elements (<script>, <style>) consume verbatim bytes until matching closing tag.
			if is_raw_text_tag(tag) && !self_closing {
				raw_start := pos
				raw_end := len(input)
				close_name := "script" if tag == .Script else "style"
				for pos < len(input) {
					if input[pos] == '<' && pos + 2 + len(close_name) <= len(input) && input[pos + 1] == '/' {
						cand := input[pos + 2 : pos + 2 + len(close_name)]
						after_idx := pos + 2 + len(close_name)
						boundary_ok := after_idx >= len(input) || html_is_space(input[after_idx]) || input[after_idx] == '>' || input[after_idx] == '/'
						if boundary_ok && html_ascii_eq_ci(cand, close_name) {
							raw_end = pos
							pos = after_idx
							for pos < len(input) && input[pos] != '>' {
								pos += 1
							}
							if pos < len(input) {
								pos += 1
							}
							break
						}
					}
					pos += 1
				}
				if elem_idx != NO_NODE && raw_end > raw_start {
					roff, rlen := pool_append_raw(tree, input[raw_start:raw_end], false)
					tn := dom_alloc_node(tree, elem_idx, .Text, .Unknown, min(depth + 1, u16(MAX_DOM_DEPTH)))
					if tn != NO_NODE {
						tree.nodes[tn].text_off = roff
						tree.nodes[tn].text_len = rlen
					}
				}
				continue
			}

			if !self_closing && !is_void_tag(tag) && elem_idx != NO_NODE {
				if stack_len < MAX_DOM_DEPTH {
					open_stack[stack_len] = elem_idx
					stack_len += 1
				} else {
					// Depth clamped safely at MAX_DOM_DEPTH.
					tree.truncated = true
				}
			}
			continue
		}

		// Bare '<' not starting a tag: emit as literal text byte to guarantee forward progress.
		t_off, t_len := pool_append_raw(tree, input[pos:pos + 1], false)
		pos += 1
		if t_len > 0 {
			parent := open_stack[stack_len - 1]
			depth := min(u16(stack_len), u16(MAX_DOM_DEPTH))
			n := dom_alloc_node(tree, parent, .Text, .Unknown, depth)
			if n != NO_NODE {
				tree.nodes[n].text_off = t_off
				tree.nodes[n].text_len = t_len
			}
		}
	}
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
		aname := tree.text_pool[a.name_off : a.name_off + u32(a.name_len)]
		if html_ascii_eq_ci(aname, name) {
			return tree.text_pool[a.value_off : a.value_off + u32(a.value_len)], true
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

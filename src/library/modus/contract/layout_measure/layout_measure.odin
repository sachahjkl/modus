// Pure freestanding intrinsic content-size layout engine
// (src/md/features/desktop_to_browser.md).
//
// Computes bottom-up intrinsic sizes (a label is as wide as its text, a column
// is as wide as its widest child, a row is as wide as the sum of its children
// plus gaps) and top-down placed rectangles for any container size.
// Zero dynamic allocations and zero kernel operations.
package layout_measure

import "modus:contract/enum_word"

MAX_LAYOUT_NODES :: 128

Node_Kind :: enum u8 {
	Label  = 1,
	Button = 2,
	Row    = 3,
	Column = 4,
	Spacer = 5,
}

node_kind_of_word :: proc "contextless" (word: u64) -> (k: Node_Kind, ok: bool) {
	return enum_word.member_of_word(Node_Kind, word)
}

Layout_Refusal :: enum u8 {
	None             = 0,
	Nil_Tree         = 1,
	Tree_Full        = 2,
	Invalid_Parent   = 3,
	Invalid_Bounds   = 4,
	Cycle_Or_Order   = 5,
}

Box_Rect :: struct {
	x:      i32,
	y:      i32,
	width:  i32,
	height: i32,
}

Layout_Node :: struct {
	used:           bool,
	kind:           Node_Kind,
	parent:         i16, // -1 for root
	padding:        i32,
	gap:            i32,
	min_width:      i32,
	min_height:     i32,
	content_width:  i32, // Intrinsic text/content width for leaf nodes.
	content_height: i32,
	measured_w:     i32,
	measured_h:     i32,
	placed:         Box_Rect,
}

Layout_Tree :: struct {
	nodes: [MAX_LAYOUT_NODES]Layout_Node,
	count: int,
}

layout_tree_init :: proc "contextless" (tree: ^Layout_Tree) {
	if tree == nil {
		return
	}
	tree^ = {}
}

layout_add_node :: proc "contextless" (
	tree: ^Layout_Tree,
	kind: Node_Kind,
	parent: i16,
	content_w, content_h: i32,
	padding: i32 = 0,
	gap: i32 = 0,
	min_w: i32 = 0,
	min_h: i32 = 0,
) -> (idx: i16, refusal: Layout_Refusal) {
	if tree == nil {
		return -1, .Nil_Tree
	}
	if tree.count >= MAX_LAYOUT_NODES {
		return -1, .Tree_Full
	}
	if parent < -1 || int(parent) >= tree.count {
		return -1, .Invalid_Parent
	}
	if content_w < 0 || content_h < 0 || padding < 0 || gap < 0 || min_w < 0 || min_h < 0 {
		return -1, .Invalid_Bounds
	}
	slot := i16(tree.count)
	tree.nodes[slot] = {
		used           = true,
		kind           = kind,
		parent         = parent,
		padding        = padding,
		gap            = gap,
		min_width      = min_w,
		min_height     = min_h,
		content_width  = content_w,
		content_height = content_h,
	}
	tree.count += 1
	return slot, .None
}

// layout_measure_and_place runs a bottom-up intrinsic measurement pass
// (parents always have lower index than children) followed by top-down placement.
layout_measure_and_place :: proc "contextless" (tree: ^Layout_Tree, container: Box_Rect) -> Layout_Refusal {
	if tree == nil {
		return .Nil_Tree
	}
	if container.width <= 0 || container.height <= 0 {
		return .Invalid_Bounds
	}
	if tree.count == 0 {
		return .None
	}

	// Pass 1: bottom-up intrinsic sizing (children always appear after parent).
	for i := tree.count - 1; i >= 0; i -= 1 {
		n := &tree.nodes[i]
		if n.parent >= i16(i) {
			return .Cycle_Or_Order
		}
		switch n.kind {
		case .Label, .Button, .Spacer:
			n.measured_w = max(n.content_width + 2 * n.padding, n.min_width)
			n.measured_h = max(n.content_height + 2 * n.padding, n.min_height)
		case .Row:
			sum_w := i32(0)
			max_h := i32(0)
			children := 0
			for j := i + 1; j < tree.count; j += 1 {
				if tree.nodes[j].parent == i16(i) {
					if children > 0 {
						sum_w += n.gap
					}
					sum_w += tree.nodes[j].measured_w
					max_h = max(max_h, tree.nodes[j].measured_h)
					children += 1
				}
			}
			n.measured_w = max(sum_w + 2 * n.padding, n.min_width)
			n.measured_h = max(max_h + 2 * n.padding, n.min_height)
		case .Column:
			max_w := i32(0)
			sum_h := i32(0)
			children := 0
			for j := i + 1; j < tree.count; j += 1 {
				if tree.nodes[j].parent == i16(i) {
					if children > 0 {
						sum_h += n.gap
					}
					max_w = max(max_w, tree.nodes[j].measured_w)
					sum_h += tree.nodes[j].measured_h
					children += 1
				}
			}
			n.measured_w = max(max_w + 2 * n.padding, n.min_width)
			n.measured_h = max(sum_h + 2 * n.padding, n.min_height)
		}
	}

	// Pass 2: top-down placement inside container.
	root := &tree.nodes[0]
	root.placed = {
		x      = container.x,
		y      = container.y,
		width  = min(root.measured_w, container.width),
		height = min(root.measured_h, container.height),
	}

	for i := 0; i < tree.count; i += 1 {
		n := &tree.nodes[i]
		inner_x := n.placed.x + n.padding
		inner_y := n.placed.y + n.padding
		inner_w := max(0, n.placed.width - 2 * n.padding)
		inner_h := max(0, n.placed.height - 2 * n.padding)
		switch n.kind {
		case .Label, .Button, .Spacer:
		case .Row:
			cursor_x := inner_x
			for j := i + 1; j < tree.count; j += 1 {
				if tree.nodes[j].parent != i16(i) {
					continue
				}
				c := &tree.nodes[j]
				cw := min(c.measured_w, max(0, inner_x + inner_w - cursor_x))
				ch := min(c.measured_h, inner_h)
				c.placed = {x = cursor_x, y = inner_y, width = cw, height = ch}
				cursor_x += cw + n.gap
			}
		case .Column:
			cursor_y := inner_y
			for j := i + 1; j < tree.count; j += 1 {
				if tree.nodes[j].parent != i16(i) {
					continue
				}
				c := &tree.nodes[j]
				cw := min(c.measured_w, inner_w)
				ch := min(c.measured_h, max(0, inner_y + inner_h - cursor_y))
				c.placed = {x = inner_x, y = cursor_y, width = cw, height = ch}
				cursor_y += ch + n.gap
			}
		}
	}
	return .None
}

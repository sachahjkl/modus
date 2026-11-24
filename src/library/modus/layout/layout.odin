// The layout tree: layout boxes in one flat array that the solver sizes and
// places (src/md/features/box_layout.md). The tree is a value of a fixed
// size that the caller puts where its memory is: no procedure of the package
// calls an allocator, and a tree of all zero is a tree that no frame began.
package layout

// The two axes of a layout. A box has one size on each.
Axis :: enum u8 {
	X = 0,
	Y = 1,
}

// Where the room that the children leave goes.
Align :: enum u8 {
	Start  = 0,
	Center = 1,
	End    = 2,
}

// What a box does with children that are larger than its content.
Overflow_Mode :: enum u8 {
	Visible = 0, // They draw past its edge.
	Clip    = 1, // They are cut at its edge.
	Scroll  = 2, // They keep their size on that axis, and the scroll offset of the box moves them.
}

// What gives the size of a box on one axis.
Size_Kind :: enum u8 {
	None         = 0, // No size from the layout.
	Pixels       = 1, // value logical pixels.
	Text         = 2, // The measured text, with value pixels on each side.
	Percent      = 3, // value parts of 10 000 of the content of the nearest ancestor that its children do not size.
	Children_Sum = 4, // The children along the child axis with the gaps, and the largest child across it.
}

// The size of a box on one axis.
Size :: struct {
	kind:       Size_Kind,
	value:      i32, // Pixels, the padding of a text, or parts of 10 000: the kind says which.
	strictness: i32, // Parts of 10 000 of its size that the box keeps when its parent lacks room.
	least:      i32, // Pixels that the box never goes under.
}

// The whole of a ratio: a percent, a strictness and a split ratio are in
// parts of it, so no ratio needs a float.
RATIO_WHOLE :: 10_000

// The unit of the solver: 1/64 logical pixel, the unit of the places of the
// draw table. The edges are snapped to whole pixels once, at the end.
SUBPIXELS_PER_PIXEL :: 64

// The largest length that a box takes, in logical pixels. With it, the sum
// of every length of a full tree stays inside an i32 of pixels.
LENGTH_LIMIT :: 65_536

// Inline capacity: fast tier for typical windows (observed desktop windows use
// 12 to 400 boxes), the root included. Past this count, a tree with an overflow
// tier (tree_set_overflow) moves to its backing slice without refusing the frame.
BOX_CAPACITY :: 1024

// Plan value: maximum open nesting depth of box_open; 64 nested containers
// exceeds any observed desktop window hierarchy by an order of magnitude.
NESTING_CAPACITY :: 64

// The index of a box in its tree. Index 0 is no box, so a zero link is no link.
Box_Index :: distinct u32

NO_BOX :: Box_Index(0)
ROOT_BOX :: Box_Index(1)

// Caller-supplied growth callback for the slower box tier. Returns a slice of
// at least minimum_boxes (index 0 included), or false when the caller's budget
// refuses the growth.
Box_Grow :: #type proc "contextless" (user_data: rawptr, current: []Box, minimum_boxes: int) -> (grown: []Box, ok: bool)

// The identity of a box: the element identity of the element that it holds.
// 0 is no identity: the box keeps no state across frames.
Identity :: distinct u64

// A rectangle in whole logical pixels.
Rect :: struct {
	x, y, width, height: i32,
}

// What a box wants, as the caller gives it to box_open and box_add.
Box_Description :: struct {
	label:       string, // The text of its identity under its parent; "" for no identity.
	identity:    Identity, // An identity that the caller made (identity_with); it takes the place of the label.
	size:        [Axis]Size,
	child_axis:  Axis, // The axis along which its children follow each other.
	align:       Align, // Where the room left along the child axis goes.
	cross_align: Align, // Where each child goes across the child axis.
	overflow:    [Axis]Overflow_Mode,
	padding:     [Axis]i32, // Pixels on each side of that axis.
	gap:         i32, // Pixels between two children along the child axis.
	text_width:  i32, // The text, as the caller measured it, in pixels.
	text_height: i32,
	minimum:     [Axis]i32, // Pixels that the box never goes under.
	maximum:     [Axis]i32, // Pixels that the box never goes over; 0 is no maximum.
	scroll:      [Axis]i32, // The scroll offset, in pixels, of a box that scrolls on that axis.
}

// One box of the tree: its description, its links and what the solver gives it.
Box :: struct {
	parent:           Box_Index,
	first_child:      Box_Index,
	last_child:       Box_Index,
	next_sibling:     Box_Index,
	previous_sibling: Box_Index,
	identity:         Identity,
	size:             [Axis]Size,
	child_axis:       Axis,
	align:            Align,
	cross_align:      Align,
	overflow:         [Axis]Overflow_Mode,
	padding:          [Axis]i32,
	gap:              i32,
	text:             [Axis]i32,
	minimum:          [Axis]i32,
	maximum:          [Axis]i32,
	scroll:           [Axis]i32, // After solve: the offset clamped to the content.
	// What the solver gives.
	extent:           [Axis]i64, // The size, in subpixels.
	place:            [Axis]i64, // The start, in subpixels, from the start of the root.
	rect:             Rect, // The edges snapped to whole pixels.
	clipped_rect:     Rect, // The rect inside the clip of each ancestor that clips.
	content_size:     [Axis]i32, // Pixels that the children take with the gaps and the padding: past rect, the box scrolls.
	children_clip:    Rect, // The clip that its children inherit.
}

// A layout tree of one frame. Frames up to BOX_CAPACITY boxes stay on the fast
// inline tier; larger frames move to external_boxes when configured via
// tree_set_overflow, incrementing overflow_moves on each tier transition or growth.
Box_Tree :: struct {
	boxes:          [BOX_CAPACITY + 1]Box, // Inline capacity: index 0 is no box.
	external_boxes: []Box, // Slower tier: caller-supplied backing slice (index 0 is no box).
	grow:           Box_Grow,
	grow_data:      rawptr,
	using_overflow: bool, // True when this frame holds boxes in external_boxes.
	count:          int, // The boxes in use, the root included, at indexes 1 to count.
	open:           [NESTING_CAPACITY]Box_Index,
	open_depth:     int,
	overflow_moves: u64, // Count of moves to or growths of the slower tier, visible as a measure.
}

// The outcome of a procedure that changes a tree. Each refusal leaves the
// tree as it was.
Box_Status :: enum u8 {
	Done                  = 0,
	Tree_Full             = 1, // The tree reached its inline capacity with no overflow tier, or the overflow tier refused growth.
	Nesting_Full          = 2, // NESTING_CAPACITY boxes are open.
	No_Open_Box           = 3, // No frame began, or box_close found only the root open.
	Boxes_Open            = 4, // solve found a box that box_close did not close.
	Unknown_Member        = 5, // An enum field holds a value that names no member.
	Size_Refused          = 6, // A size whose value, strictness or least is outside the range of its kind.
	Length_Refused        = 7, // A padding, a gap, a text, a bound or a scroll offset under 0 or over LENGTH_LIMIT.
	Bounds_Refused        = 8, // A minimum over its maximum.
	Places_Too_Few        = 9, // table_columns got fewer places than columns.
}

// px gives a size of a count of logical pixels.
px :: proc "contextless" (pixels: i32, strictness: i32 = RATIO_WHOLE) -> Size {
	return {kind = .Pixels, value = pixels, strictness = strictness}
}

// text_size gives the size of the measured text, with a padding on each side.
text_size :: proc "contextless" (padding: i32 = 0, strictness: i32 = RATIO_WHOLE) -> Size {
	return {kind = .Text, value = padding, strictness = strictness}
}

// pct gives a part of the content of the nearest ancestor that its children
// do not size, in parts of 10 000: pct(5_000) is half.
pct :: proc "contextless" (parts: i32, strictness: i32 = 0) -> Size {
	return {kind = .Percent, value = parts, strictness = strictness}
}

// children_sum gives the size of the children.
children_sum :: proc "contextless" (strictness: i32 = RATIO_WHOLE) -> Size {
	return {kind = .Children_Sum, strictness = strictness}
}

// fill takes the room that the siblings leave: the whole content of the
// parent, which gives all of it when the room lacks.
fill :: proc "contextless" () -> Size {
	return pct(RATIO_WHOLE, 0)
}

// fill_least is fill, never under least pixels: past the edge of a parent
// that is too small, which then clips or scrolls.
fill_least :: proc "contextless" (least: i32) -> Size {
	return {kind = .Percent, value = RATIO_WHOLE, strictness = 0, least = least}
}

// identity_of gives the identity of a label alone: 64-bit FNV-1a, never 0.
identity_of :: proc "contextless" (label: string) -> Identity {
	return identity_in(Identity(0xCBF2_9CE4_8422_2325), label)
}

// identity_in gives the identity of a label inside a parent, so one label
// under two parents gives two identities.
identity_in :: proc "contextless" (parent: Identity, label: string) -> Identity {
	hash := u64(parent)
	if hash == 0 {
		hash = 0xCBF2_9CE4_8422_2325
	}
	for index in 0 ..< len(label) {
		hash = (hash ~ u64(label[index])) * 0x0000_0100_0000_01B3
	}
	return Identity(hash | 1)
}

// identity_with gives the identity of one of a set of boxes: a row of a
// list, a column of a table.
identity_with :: proc "contextless" (base: Identity, number: u64) -> Identity {
	hash := u64(base)
	for shift := uint(0); shift < 64; shift += 8 {
		hash = (hash ~ ((number >> shift) & 0xFF)) * 0x0000_0100_0000_01B3
	}
	return Identity(hash | 1)
}

// tree_set_overflow attaches a caller-supplied backing slice and optional
// growth callback for frames past BOX_CAPACITY boxes. Frames within
// BOX_CAPACITY stay on the fast inline tier.
tree_set_overflow :: proc "contextless" (tree: ^Box_Tree, backing: []Box, grow: Box_Grow = nil, grow_data: rawptr = nil) {
	if tree == nil {
		return
	}
	tree.external_boxes = backing
	tree.grow = grow
	tree.grow_data = grow_data
	if tree.count == 0 {
		tree.using_overflow = false
	}
}

// tree_boxes returns the active box slice of the current frame (index 0 is no box).
@(private)
tree_boxes :: #force_inline proc "contextless" (tree: ^Box_Tree) -> []Box {
	if tree.using_overflow {
		return tree.external_boxes
	}
	return tree.boxes[:]
}

// tree_on_overflow reports whether the current frame moved to the slower tier.
tree_on_overflow :: proc "contextless" (tree: ^Box_Tree) -> bool {
	return tree != nil && tree.using_overflow
}

// tree_capacity returns the current box capacity without another tier growth.
tree_capacity :: proc "contextless" (tree: ^Box_Tree) -> int {
	if tree == nil {
		return 0
	}
	if tree.using_overflow {
		return max(len(tree.external_boxes) - 1, 0)
	}
	return BOX_CAPACITY
}

// tree_ensure_room guarantees that the active box slice holds at least
// needed_slots (index 0 plus boxes). Moving from inline to overflow or growing
// the overflow tier increments overflow_moves. A refusal changes nothing.
@(private)
tree_ensure_room :: proc "contextless" (tree: ^Box_Tree, needed_slots: int) -> bool {
	if needed_slots <= 0 {
		return false
	}
	if !tree.using_overflow {
		if needed_slots <= len(tree.boxes) {
			return true
		}
		target := tree.external_boxes
		if len(target) < needed_slots {
			if tree.grow == nil {
				return false
			}
			grown, ok := tree.grow(tree.grow_data, target, needed_slots)
			if !ok || len(grown) < needed_slots || raw_data(grown) == nil {
				return false
			}
			target = grown
		}
		copy(target[:tree.count + 1], tree.boxes[:tree.count + 1])
		tree.external_boxes = target
		tree.using_overflow = true
		tree.overflow_moves += 1
		return true
	}
	if needed_slots <= len(tree.external_boxes) {
		return true
	}
	if tree.grow == nil {
		return false
	}
	grown, ok := tree.grow(tree.grow_data, tree.external_boxes, needed_slots)
	if !ok || len(grown) < needed_slots || raw_data(grown) == nil {
		return false
	}
	if raw_data(grown) != raw_data(tree.external_boxes) {
		copy(grown[:tree.count + 1], tree.external_boxes[:tree.count + 1])
	}
	tree.external_boxes = grown
	tree.overflow_moves += 1
	return true
}

// tree_begin starts a frame on the fast inline tier: the tree then holds only
// its root, at the size of the view, and the root is open. The size fields of
// root are not read. Configured overflow backing and overflow_moves persist.
tree_begin :: proc "contextless" (tree: ^Box_Tree, view_width, view_height: i32, root: Box_Description = {}) -> Box_Status {
	if view_width < 0 || view_width > LENGTH_LIMIT || view_height < 0 || view_height > LENGTH_LIMIT {
		return .Length_Refused
	}
	description := root
	description.size = {.X = px(view_width), .Y = px(view_height)}
	if status := description_check(&description); status != .Done {
		return status
	}
	tree.using_overflow = false
	tree.count = 1
	tree.boxes[NO_BOX] = {}
	tree.boxes[ROOT_BOX] = box_of_description(&description, NO_BOX)
	if description.identity == 0 && description.label != "" {
		tree.boxes[ROOT_BOX].identity = identity_of(description.label)
	}
	tree.open[0] = ROOT_BOX
	tree.open_depth = 1
	return .Done
}

// box_open adds a box as the last child of the open box, and opens it: the
// boxes added until its box_close are its children.
box_open :: proc "contextless" (tree: ^Box_Tree, description: Box_Description) -> (Box_Index, Box_Status) {
	if tree.open_depth >= NESTING_CAPACITY {
		return NO_BOX, tree.open_depth == 0 ? .No_Open_Box : .Nesting_Full
	}
	index, status := box_add(tree, description)
	if status != .Done {
		return NO_BOX, status
	}
	tree.open[tree.open_depth] = index
	tree.open_depth += 1
	return index, .Done
}

// box_add adds a box with no children as the last child of the open box.
box_add :: proc "contextless" (tree: ^Box_Tree, description: Box_Description) -> (Box_Index, Box_Status) {
	if tree.open_depth <= 0 || tree.open_depth > NESTING_CAPACITY || tree.count <= 0 {
		return NO_BOX, .No_Open_Box
	}
	description := description
	if status := description_check(&description); status != .Done {
		return NO_BOX, status
	}
	if tree.count >= int(max(Box_Index)) {
		return NO_BOX, .Tree_Full
	}
	if !tree_ensure_room(tree, tree.count + 2) {
		return NO_BOX, .Tree_Full
	}
	boxes := tree_boxes(tree)
	parent := tree.open[tree.open_depth - 1]
	index := Box_Index(tree.count + 1)
	boxes[index] = box_of_description(&description, parent)
	if description.identity == 0 && description.label != "" {
		boxes[index].identity = identity_in(boxes[parent].identity, description.label)
	}
	parent_box := &boxes[parent]
	if parent_box.last_child == NO_BOX {
		parent_box.first_child = index
	} else {
		boxes[parent_box.last_child].next_sibling = index
		boxes[index].previous_sibling = parent_box.last_child
	}
	parent_box.last_child = index
	tree.count += 1
	return index, .Done
}

// box_close closes the open box. The root closes only with the frame.
box_close :: proc "contextless" (tree: ^Box_Tree) -> Box_Status {
	if tree.open_depth <= 1 || tree.open_depth > NESTING_CAPACITY {
		return .No_Open_Box
	}
	tree.open_depth -= 1
	return .Done
}

// box_of gives the box at an index, or nil for an index that names no box
// of this frame.
box_of :: proc "contextless" (tree: ^Box_Tree, index: Box_Index) -> ^Box {
	boxes := tree_boxes(tree)
	if index == NO_BOX || int(index) > tree.count || int(index) >= len(boxes) {
		return nil
	}
	return &boxes[index]
}

@(private)
box_of_description :: proc "contextless" (description: ^Box_Description, parent: Box_Index) -> Box {
	return {
		parent      = parent,
		identity    = description.identity,
		size        = description.size,
		child_axis  = description.child_axis,
		align       = description.align,
		cross_align = description.cross_align,
		overflow    = description.overflow,
		padding     = description.padding,
		gap         = description.gap,
		text        = {.X = description.text_width, .Y = description.text_height},
		minimum     = description.minimum,
		maximum     = description.maximum,
		scroll      = description.scroll,
	}
}

// description_check is the one border of what a caller gives: a value that
// names no member, or a length outside its range, is refused here, and the
// solver after it never meets one.
@(private)
description_check :: proc "contextless" (description: ^Box_Description) -> Box_Status {
	if u8(description.child_axis) > u8(max(Axis)) || u8(description.align) > u8(max(Align)) || u8(description.cross_align) > u8(max(Align)) {
		return .Unknown_Member
	}
	for axis in Axis {
		if u8(description.overflow[axis]) > u8(max(Overflow_Mode)) || u8(description.size[axis].kind) > u8(max(Size_Kind)) {
			return .Unknown_Member
		}
	}
	for axis in Axis {
		if !size_in_range(description.size[axis]) {
			return .Size_Refused
		}
	}
	lengths := [?]i32{
		description.padding[.X], description.padding[.Y], description.gap, description.text_width, description.text_height,
		description.minimum[.X], description.minimum[.Y], description.maximum[.X], description.maximum[.Y],
		description.scroll[.X], description.scroll[.Y],
	}
	for length in lengths {
		if length < 0 || length > LENGTH_LIMIT {
			return .Length_Refused
		}
	}
	for axis in Axis {
		if description.maximum[axis] != 0 && description.minimum[axis] > description.maximum[axis] {
			return .Bounds_Refused
		}
	}
	return .Done
}

@(private)
size_in_range :: proc "contextless" (size: Size) -> bool {
	if size.strictness < 0 || size.strictness > RATIO_WHOLE || size.least < 0 || size.least > LENGTH_LIMIT {
		return false
	}
	switch size.kind {
	case .None, .Children_Sum:
		return size.value == 0
	case .Pixels, .Text:
		return size.value >= 0 && size.value <= LENGTH_LIMIT
	case .Percent:
		return size.value >= 0 && size.value <= RATIO_WHOLE
	}
	return false
}

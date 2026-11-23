// The solver of a layout tree: the four passes of the box tree of the RAD
// Debugger on each axis, then one snap of the edges and the clip
// (src/md/features/box_layout.md, "The chosen form").
//
// The boxes are added in pre-order, a parent before each of its children,
// so the order of the array is a pre-order and its reverse visits each
// child before its parent. No pass needs a stack or a recursion.
package layout

// solve sizes and places each box of the tree. Each box then has its rect,
// its clipped rect, its content size and its clamped scroll offsets.
solve :: proc "contextless" (tree: ^Box_Tree) -> Box_Status {
	boxes := tree_boxes(tree)
	if tree.count <= 0 || tree.count >= len(boxes) || tree.open_depth <= 0 {
		return .No_Open_Box
	}
	if tree.open_depth != 1 {
		return .Boxes_Open
	}
	for axis in Axis {
		solve_standalone(tree, axis)
		solve_from_above(tree, axis)
		solve_from_below(tree, axis)
		solve_violations_and_places(tree, axis)
	}
	solve_snap_and_clip(tree)
	return .Done
}

@(private)
pixels_to_subpixels :: #force_inline proc "contextless" (pixels: i32) -> i64 {
	return i64(pixels) * SUBPIXELS_PER_PIXEL
}

// The floor of a division by a positive divisor, also for a negative
// dividend: a box scrolled past the top has a negative place.
@(private)
floor_divide :: #force_inline proc "contextless" (dividend, divisor: i64) -> i64 {
	quotient := dividend / divisor
	if (dividend % divisor) != 0 && (dividend < 0) {
		quotient -= 1
	}
	return quotient
}

// The nearest whole pixel of a subpixel place; a half goes up.
@(private)
subpixels_to_nearest_pixel :: #force_inline proc "contextless" (subpixels: i64) -> i32 {
	return i32(floor_divide(subpixels + SUBPIXELS_PER_PIXEL / 2, SUBPIXELS_PER_PIXEL))
}

// a × b / c with no overflow of the product: a length of a full tree times
// a sum of lengths passes 2^63.
@(private)
multiply_divide :: #force_inline proc "contextless" (a, b, c: i64) -> i64 {
	if c <= 0 {
		return 0
	}
	return i64(i128(a) * i128(b) / i128(c))
}

// The least extent of a box on an axis: neither its least size nor its minimum.
@(private)
box_floor :: #force_inline proc "contextless" (box: ^Box, axis: Axis) -> i64 {
	return pixels_to_subpixels(max(box.size[axis].least, box.minimum[axis]))
}

@(private)
box_bounded :: #force_inline proc "contextless" (box: ^Box, axis: Axis, extent: i64) -> i64 {
	bounded := max(extent, box_floor(box, axis), 0)
	if box.maximum[axis] > 0 {
		bounded = min(bounded, max(pixels_to_subpixels(box.maximum[axis]), box_floor(box, axis)))
	}
	return bounded
}

@(private)
box_content :: #force_inline proc "contextless" (box: ^Box, axis: Axis) -> i64 {
	return max(box.extent[axis] - 2 * pixels_to_subpixels(box.padding[axis]), 0)
}

@(private)
child_count :: proc "contextless" (tree: ^Box_Tree, box: ^Box) -> i64 {
	boxes := tree_boxes(tree)
	count: i64
	for child := box.first_child; child != NO_BOX; child = boxes[child].next_sibling {
		count += 1
	}
	return count
}

// The gaps between the children along the child axis: one between two
// children, none before the first or after the last.
@(private)
box_gaps :: proc "contextless" (tree: ^Box_Tree, box: ^Box, axis: Axis) -> i64 {
	if axis != box.child_axis {
		return 0
	}
	return max(child_count(tree, box) - 1, 0) * pixels_to_subpixels(box.gap)
}

// Pass 1: the sizes that need no other box.
@(private)
solve_standalone :: proc "contextless" (tree: ^Box_Tree, axis: Axis) {
	boxes := tree_boxes(tree)
	for index in 1 ..= tree.count {
		box := &boxes[index]
		size := box.size[axis]
		extent: i64
		switch size.kind {
		case .Pixels:
			extent = pixels_to_subpixels(size.value)
		case .Text:
			extent = pixels_to_subpixels(box.text[axis]) + 2 * pixels_to_subpixels(size.value) + 2 * pixels_to_subpixels(box.padding[axis])
		case .None, .Percent, .Children_Sum:
		}
		box.extent[axis] = box_bounded(box, axis, extent)
		box.place[axis] = 0
	}
}

// Pass 2: a percent of the nearest ancestor that its children do not size.
// The ancestor comes before the box in the array, so it has its size.
@(private)
solve_from_above :: proc "contextless" (tree: ^Box_Tree, axis: Axis) {
	boxes := tree_boxes(tree)
	for index in 1 ..= tree.count {
		box := &boxes[index]
		if box.size[axis].kind != .Percent {
			continue
		}
		ancestor := box.parent
		for ancestor != NO_BOX && boxes[ancestor].size[axis].kind == .Children_Sum {
			ancestor = boxes[ancestor].parent
		}
		basis: i64
		if ancestor != NO_BOX {
			basis = box_content(&boxes[ancestor], axis)
		}
		box.extent[axis] = box_bounded(box, axis, multiply_divide(basis, i64(box.size[axis].value), RATIO_WHOLE))
	}
}

// The children of a box along an axis: their sum along the child axis, the
// largest across it.
@(private)
children_extent :: proc "contextless" (tree: ^Box_Tree, box: ^Box, axis: Axis) -> i64 {
	boxes := tree_boxes(tree)
	total: i64
	for child := box.first_child; child != NO_BOX; child = boxes[child].next_sibling {
		if axis == box.child_axis {
			total += boxes[child].extent[axis]
		} else {
			total = max(total, boxes[child].extent[axis])
		}
	}
	return total
}

// Pass 3: the sizes that come from the children. The reverse of the array
// visits each child before its parent.
@(private)
solve_from_below :: proc "contextless" (tree: ^Box_Tree, axis: Axis) {
	boxes := tree_boxes(tree)
	for index := tree.count; index >= 1; index -= 1 {
		box := &boxes[index]
		if box.size[axis].kind != .Children_Sum {
			continue
		}
		extent := children_extent(tree, box, axis) + box_gaps(tree, box, axis) + 2 * pixels_to_subpixels(box.padding[axis])
		box.extent[axis] = box_bounded(box, axis, extent)
	}
}

// What a box gives of its extent when its parent lacks room: (1 − strictness)
// of it, never under its floor.
@(private)
box_giveable :: proc "contextless" (box: ^Box, axis: Axis) -> i64 {
	extent := box.extent[axis]
	by_strictness := multiply_divide(extent, i64(RATIO_WHOLE - box.size[axis].strictness), RATIO_WHOLE)
	return max(min(by_strictness, extent - box_floor(box, axis)), 0)
}

// Pass 4: at each box, from the root down, the percent children again, the
// violations of the children, then their places.
@(private)
solve_violations_and_places :: proc "contextless" (tree: ^Box_Tree, axis: Axis) {
	boxes := tree_boxes(tree)
	root := &boxes[ROOT_BOX]
	root.place[axis] = 0
	for index in 1 ..= tree.count {
		box := &boxes[index]
		content := box_content(box, axis)
		if box.size[axis].kind != .Children_Sum {
			// The pass 2 gave each percent from the size of this box before
			// this box lost room: give it its part of the final size.
			for child := box.first_child; child != NO_BOX; child = boxes[child].next_sibling {
				child_box := &boxes[child]
				if child_box.size[axis].kind == .Percent {
					child_box.extent[axis] = box_bounded(child_box, axis, multiply_divide(content, i64(child_box.size[axis].value), RATIO_WHOLE))
				}
			}
		}
		if box.overflow[axis] != .Scroll {
			if axis == box.child_axis {
				shrink_along(tree, box, axis, content - box_gaps(tree, box, axis))
			} else {
				for child := box.first_child; child != NO_BOX; child = boxes[child].next_sibling {
					child_box := &boxes[child]
					if excess := child_box.extent[axis] - content; excess > 0 {
						child_box.extent[axis] -= min(excess, box_giveable(child_box, axis))
					}
				}
			}
		}
		place_children(tree, box, axis, content)
	}
}

// The children along the child axis give the violation, each in proportion
// to what it can give. The share of each child comes from the running sum,
// so the shares add up to what is taken, with no remainder lost.
@(private)
shrink_along :: proc "contextless" (tree: ^Box_Tree, box: ^Box, axis: Axis, room: i64) {
	boxes := tree_boxes(tree)
	total := children_extent(tree, box, axis)
	violation := total - max(room, 0)
	if violation <= 0 {
		return
	}
	budget: i64
	for child := box.first_child; child != NO_BOX; child = boxes[child].next_sibling {
		budget += box_giveable(&boxes[child], axis)
	}
	if budget <= 0 {
		return
	}
	taken := min(violation, budget)
	running, given_before: i64
	for child := box.first_child; child != NO_BOX; child = boxes[child].next_sibling {
		child_box := &boxes[child]
		giveable := box_giveable(child_box, axis)
		running += giveable
		given_to_here := multiply_divide(taken, running, budget)
		child_box.extent[axis] -= min(given_to_here - given_before, giveable)
		given_before = given_to_here
	}
}

@(private)
align_offset :: #force_inline proc "contextless" (align: Align, room: i64) -> i64 {
	if room <= 0 {
		return 0
	}
	switch align {
	case .Start:
		return 0
	case .Center:
		return room / 2
	case .End:
		return room
	}
	return 0
}

// The places of the children of a box, and its content size and clamped
// scroll offset on the axis.
@(private)
place_children :: proc "contextless" (tree: ^Box_Tree, box: ^Box, axis: Axis, content: i64) {
	boxes := tree_boxes(tree)
	padding := pixels_to_subpixels(box.padding[axis])
	used: i64
	if box.first_child == NO_BOX {
		used = max(box.extent[axis] - 2 * padding, 0)
	} else {
		used = children_extent(tree, box, axis) + box_gaps(tree, box, axis)
	}
	content_total := used + 2 * padding
	box.content_size[axis] = i32(floor_divide(content_total + SUBPIXELS_PER_PIXEL - 1, SUBPIXELS_PER_PIXEL))
	scroll: i64
	if box.overflow[axis] == .Scroll {
		scroll = clamp(pixels_to_subpixels(box.scroll[axis]), 0, max(content_total - box.extent[axis], 0))
		box.scroll[axis] = i32(scroll / SUBPIXELS_PER_PIXEL)
		scroll = pixels_to_subpixels(box.scroll[axis])
	} else {
		box.scroll[axis] = 0
	}
	start := box.place[axis] + padding - scroll
	if axis == box.child_axis {
		cursor := start + align_offset(box.align, content - used)
		gap := pixels_to_subpixels(box.gap)
		for child := box.first_child; child != NO_BOX; child = boxes[child].next_sibling {
			child_box := &boxes[child]
			child_box.place[axis] = cursor
			cursor += child_box.extent[axis] + gap
		}
	} else {
		for child := box.first_child; child != NO_BOX; child = boxes[child].next_sibling {
			child_box := &boxes[child]
			child_box.place[axis] = start + align_offset(box.cross_align, content - child_box.extent[axis])
		}
	}
}

@(private)
rect_intersection :: proc "contextless" (first, second: Rect) -> Rect {
	left := max(first.x, second.x)
	top := max(first.y, second.y)
	right := min(first.x + first.width, second.x + second.width)
	bottom := min(first.y + first.height, second.y + second.height)
	return {left, top, max(right - left, 0), max(bottom - top, 0)}
}

// rect_contains says whether a point is in a rectangle: its left and top
// edges are in it, its right and bottom edges are not.
rect_contains :: proc "contextless" (rect: Rect, x, y: i32) -> bool {
	return x >= rect.x && y >= rect.y && x < rect.x + rect.width && y < rect.y + rect.height
}

// The snap of the edges, not of the sizes: two boxes that touch in
// subpixels touch in pixels. Then the clip of each box from its parent.
@(private)
solve_snap_and_clip :: proc "contextless" (tree: ^Box_Tree) {
	boxes := tree_boxes(tree)
	for index in 1 ..= tree.count {
		box := &boxes[index]
		left := subpixels_to_nearest_pixel(box.place[.X])
		top := subpixels_to_nearest_pixel(box.place[.Y])
		right := subpixels_to_nearest_pixel(box.place[.X] + box.extent[.X])
		bottom := subpixels_to_nearest_pixel(box.place[.Y] + box.extent[.Y])
		box.rect = {left, top, right - left, bottom - top}
		inherited := box.parent == NO_BOX ? box.rect : boxes[box.parent].children_clip
		box.clipped_rect = rect_intersection(box.rect, inherited)
		box.children_clip = inherited
		if box.overflow[.X] != .Visible {
			box.children_clip.x = box.clipped_rect.x
			box.children_clip.width = box.clipped_rect.width
		}
		if box.overflow[.Y] != .Visible {
			box.children_clip.y = box.clipped_rect.y
			box.children_clip.height = box.clipped_rect.height
		}
	}
}

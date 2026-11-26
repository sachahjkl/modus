#+build !freestanding
#+build !modus
package layout

import "core:testing"
import "modus:graphics"

@(private = "file")
SUB :: SUBPIXELS_PER_PIXEL

@(private = "file")
row_root :: proc(tree: ^Box_Tree, width, height: i32, axis := Axis.X, gap: i32 = 0, padding: i32 = 0) {
	status := tree_begin(tree, width, height, {child_axis = axis, gap = gap, padding = {.X = padding, .Y = padding}})
	assert(status == .Done)
}

@(private = "file")
leaf :: proc(tree: ^Box_Tree, width, height: Size, label := "") -> ^Box {
	index, status := box_add(tree, {label = label, size = {.X = width, .Y = height}})
	assert(status == .Done)
	return &tree.boxes[index]
}

// Each helper gives the size that its kind names, and fill_least keeps its least.
@(test)
size_helpers_give_their_kinds :: proc(t: ^testing.T) {
	testing.expect_value(t, px(12), Size{.Pixels, 12, RATIO_WHOLE, 0})
	testing.expect_value(t, px(12, 0), Size{.Pixels, 12, 0, 0})
	testing.expect_value(t, text_size(3), Size{.Text, 3, RATIO_WHOLE, 0})
	testing.expect_value(t, pct(2_500), Size{.Percent, 2_500, 0, 0})
	testing.expect_value(t, children_sum(), Size{.Children_Sum, 0, RATIO_WHOLE, 0})
	testing.expect_value(t, fill(), Size{.Percent, RATIO_WHOLE, 0, 0})
	testing.expect_value(t, fill_least(40), Size{.Percent, RATIO_WHOLE, 0, 40})
}

// A wrong input is refused with its status, and the tree does not change.
@(test)
wrong_descriptions_are_refused_and_change_nothing :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	row_root(tree, 100, 100)
	cases := [?]struct {
		description: Box_Description,
		status:      Box_Status,
	}{
		{{size = {.X = px(-1), .Y = px(1)}}, .Size_Refused},
		{{size = {.X = px(LENGTH_LIMIT + 1), .Y = px(1)}}, .Size_Refused},
		{{size = {.X = px(max(i32)), .Y = px(1)}}, .Size_Refused},
		{{size = {.X = px(min(i32)), .Y = px(1)}}, .Size_Refused},
		{{size = {.X = pct(RATIO_WHOLE + 1), .Y = px(1)}}, .Size_Refused},
		{{size = {.X = pct(-1), .Y = px(1)}}, .Size_Refused},
		{{size = {.X = px(10, RATIO_WHOLE + 1), .Y = px(1)}}, .Size_Refused},
		{{size = {.X = px(10, -1), .Y = px(1)}}, .Size_Refused},
		{{size = {.X = fill_least(-1), .Y = px(1)}}, .Size_Refused},
		{{size = {.X = fill_least(LENGTH_LIMIT + 1), .Y = px(1)}}, .Size_Refused},
		{{size = {.X = {kind = .Children_Sum, value = 1}, .Y = px(1)}}, .Size_Refused},
		{{size = {.X = {kind = .None, value = 1}, .Y = px(1)}}, .Size_Refused},
		{{size = {.X = text_size(-2), .Y = px(1)}}, .Size_Refused},
		{{size = {.X = {kind = Size_Kind(5)}, .Y = px(1)}}, .Unknown_Member},
		{{size = {.X = px(1), .Y = {kind = Size_Kind(255)}}}, .Unknown_Member},
		{{child_axis = Axis(2)}, .Unknown_Member},
		{{align = Align(3)}, .Unknown_Member},
		{{cross_align = Align(255)}, .Unknown_Member},
		{{overflow = {.X = .Visible, .Y = Overflow_Mode(3)}}, .Unknown_Member},
		{{padding = {.X = -1, .Y = 0}}, .Length_Refused},
		{{padding = {.X = 0, .Y = LENGTH_LIMIT + 1}}, .Length_Refused},
		{{gap = -1}, .Length_Refused},
		{{text_width = -5}, .Length_Refused},
		{{text_height = max(i32)}, .Length_Refused},
		{{minimum = {.X = -1, .Y = 0}}, .Length_Refused},
		{{maximum = {.X = 0, .Y = -1}}, .Length_Refused},
		{{scroll = {.X = 0, .Y = -1}}, .Length_Refused},
		{{scroll = {.X = LENGTH_LIMIT + 1, .Y = 0}}, .Length_Refused},
		{{minimum = {.X = 50, .Y = 0}, maximum = {.X = 49, .Y = 0}}, .Bounds_Refused},
	}
	for test_case, number in cases {
		before := tree^
		index, status := box_add(tree, test_case.description)
		testing.expectf(t, status == test_case.status, "case %d: status %v, expected %v", number, status, test_case.status)
		testing.expectf(t, index == NO_BOX, "case %d: a refused box got index %d", number, index)
		testing.expectf(t, tree.count == before.count && tree.boxes[ROOT_BOX] == before.boxes[ROOT_BOX], "case %d: the tree changed", number)
		open_index, open_status := box_open(tree, test_case.description)
		testing.expectf(t, open_status == test_case.status && open_index == NO_BOX && tree.open_depth == before.open_depth, "case %d: box_open %v", number, open_status)
	}
	// The edges of each range are taken.
	_, status := box_add(tree, {size = {.X = px(LENGTH_LIMIT), .Y = pct(RATIO_WHOLE)}, minimum = {.X = 7, .Y = 0}, maximum = {.X = 7, .Y = 0}})
	testing.expect_value(t, status, Box_Status.Done)
	_, status = box_add(tree, {size = {.X = px(0, 0), .Y = pct(0)}})
	testing.expect_value(t, status, Box_Status.Done)
}

// A view under 0 or over the limit is refused, and a tree that no frame began refuses each change.
@(test)
tree_borders_refuse_without_a_frame :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	_, status := box_add(tree, {})
	testing.expect_value(t, status, Box_Status.No_Open_Box)
	_, status = box_open(tree, {})
	testing.expect_value(t, status, Box_Status.No_Open_Box)
	testing.expect_value(t, box_close(tree), Box_Status.No_Open_Box)
	testing.expect_value(t, solve(tree), Box_Status.No_Open_Box)
	testing.expect_value(t, tree_begin(tree, -1, 10), Box_Status.Length_Refused)
	testing.expect_value(t, tree_begin(tree, 10, LENGTH_LIMIT + 1), Box_Status.Length_Refused)
	testing.expect_value(t, tree_begin(tree, 10, 10, {child_axis = Axis(9)}), Box_Status.Unknown_Member)
	testing.expect_value(t, tree.count, 0)
	testing.expect_value(t, tree_begin(tree, 0, 0), Box_Status.Done)
	testing.expect_value(t, box_close(tree), Box_Status.No_Open_Box) // The root closes only with the frame.
	_, status = box_open(tree, {})
	testing.expect_value(t, status, Box_Status.Done)
	testing.expect_value(t, solve(tree), Box_Status.Boxes_Open)
	testing.expect_value(t, box_close(tree), Box_Status.Done)
	testing.expect_value(t, solve(tree), Box_Status.Done)
	testing.expect(t, box_of(tree, NO_BOX) == nil && box_of(tree, Box_Index(3)) == nil && box_of(tree, Box_Index(max(u16))) == nil)
	testing.expect(t, box_of(tree, ROOT_BOX) != nil && box_of(tree, Box_Index(2)) != nil)
}

// A full tree and a full nesting refuse the next box and change nothing.
@(test)
capacity_is_refused_without_a_change :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	row_root(tree, 100, 100)
	for _ in 1 ..< BOX_CAPACITY {
		_, status := box_add(tree, {size = {.X = px(1), .Y = px(1)}})
		testing.expect_value(t, status, Box_Status.Done)
	}
	testing.expect_value(t, tree.count, BOX_CAPACITY)
	last := tree.boxes[ROOT_BOX].last_child
	index, status := box_add(tree, {})
	testing.expect_value(t, status, Box_Status.Tree_Full)
	testing.expect_value(t, index, NO_BOX)
	_, status = box_open(tree, {})
	testing.expect_value(t, status, Box_Status.Tree_Full)
	testing.expect_value(t, tree.count, BOX_CAPACITY)
	testing.expect_value(t, tree.boxes[ROOT_BOX].last_child, last)
	testing.expect_value(t, tree.open_depth, 1)
	testing.expect_value(t, solve(tree), Box_Status.Done)
	testing.expect_value(t, tree.boxes[last].rect, Rect{1022, 0, 1, 1}) // The children past the view keep their order and their size.
	testing.expect_value(t, tree.boxes[last].clipped_rect.width, i32(0))

	row_root(tree, 100, 100)
	for _ in 1 ..< NESTING_CAPACITY {
		_, status = box_open(tree, {size = {.X = children_sum(), .Y = children_sum()}})
		testing.expect_value(t, status, Box_Status.Done)
	}
	count := tree.count
	_, status = box_open(tree, {})
	testing.expect_value(t, status, Box_Status.Nesting_Full)
	testing.expect_value(t, tree.count, count)
	testing.expect_value(t, tree.open_depth, NESTING_CAPACITY)
	_, status = box_add(tree, {size = {.X = px(5), .Y = px(6)}})
	testing.expect_value(t, status, Box_Status.Done)
	for _ in 1 ..< NESTING_CAPACITY {
		testing.expect_value(t, box_close(tree), Box_Status.Done)
	}
	testing.expect_value(t, solve(tree), Box_Status.Done)
	testing.expect_value(t, tree.boxes[ROOT_BOX + 1].rect, Rect{0, 0, 5, 6}) // Each Children_Sum of the chain takes the deepest box.
}

// Pixels and gaps and padding along the child axis, and the content size.
@(test)
pixels_follow_each_other_with_gaps_and_padding :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	row_root(tree, 400, 300, .X, 10, 5)
	a := leaf(tree, px(100), px(50))
	b := leaf(tree, px(100), px(50))
	c := leaf(tree, px(100), px(50))
	testing.expect_value(t, solve(tree), Box_Status.Done)
	testing.expect_value(t, a.rect, Rect{5, 5, 100, 50})
	testing.expect_value(t, b.rect, Rect{115, 5, 100, 50})
	testing.expect_value(t, c.rect, Rect{225, 5, 100, 50})
	testing.expect_value(t, tree.boxes[ROOT_BOX].content_size, [Axis]i32{.X = 330, .Y = 60})
	testing.expect_value(t, tree.boxes[ROOT_BOX].rect, Rect{0, 0, 400, 300})
}

// A text box is its measured text, its size padding and its box padding.
@(test)
text_size_is_the_measured_text_and_padding :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	row_root(tree, 400, 300)
	index, _ := box_add(tree, {size = {.X = text_size(4), .Y = text_size()}, text_width = 50, text_height = 16, padding = {.X = 2, .Y = 0}})
	empty, _ := box_add(tree, {size = {.X = text_size(), .Y = text_size()}})
	solve(tree)
	testing.expect_value(t, tree.boxes[index].rect, Rect{0, 0, 62, 16})
	testing.expect_value(t, tree.boxes[empty].rect, Rect{62, 0, 0, 0})
}

// A percent is of the content of the nearest ancestor that its children do
// not size: past a Children_Sum parent.
@(test)
percent_is_of_the_nearest_ancestor_sized_from_above :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	row_root(tree, 400, 300, .X, 0, 10)
	quarter := leaf(tree, pct(2_500), pct(5_000))
	index, _ := box_open(tree, {size = {.X = children_sum(), .Y = children_sum()}, child_axis = .X})
	inner := leaf(tree, pct(2_000), px(10))
	box_close(tree)
	solve(tree)
	testing.expect_value(t, quarter.rect, Rect{10, 10, 95, 140})
	testing.expect_value(t, inner.rect.width, i32(76)) // 20 % of the 380 of the root, not of its parent.
	testing.expect_value(t, tree.boxes[index].rect.width, i32(76))
	testing.expect_value(t, tree.boxes[index].rect.x, i32(105))
}

// A percent child is of the final size of its parent: the parent that lost
// room in the violation pass gives its percent children their part again.
@(test)
percent_follows_a_parent_that_lost_room :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	row_root(tree, 200, 10)
	shrunk, _ := box_open(tree, {size = {.X = px(150, 0), .Y = fill()}, child_axis = .X})
	half := leaf(tree, pct(5_000), fill())
	box_close(tree)
	leaf(tree, px(150, 0), fill())
	solve(tree)
	testing.expect_value(t, tree.boxes[shrunk].rect.width, i32(100))
	testing.expect_value(t, half.rect, Rect{0, 0, 50, 10})
}

// Children_Sum sums along the child axis with gaps and padding, and takes the largest across it.
@(test)
children_sum_sums_along_and_takes_the_largest_across :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	row_root(tree, 400, 300, .Y)
	index, _ := box_open(tree, {size = {.X = children_sum(), .Y = children_sum()}, child_axis = .X, gap = 4, padding = {.X = 3, .Y = 3}})
	leaf(tree, px(10), px(5))
	leaf(tree, px(20), px(15))
	leaf(tree, px(30), px(10))
	box_close(tree)
	empty, _ := box_add(tree, {size = {.X = children_sum(), .Y = children_sum()}, padding = {.X = 2, .Y = 1}})
	solve(tree)
	testing.expect_value(t, tree.boxes[index].rect, Rect{0, 0, 74, 21})
	testing.expect_value(t, tree.boxes[empty].rect, Rect{0, 21, 4, 2})
}

// fill takes what the siblings leave, and two fills share it.
@(test)
fill_takes_the_room_that_the_siblings_leave :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	row_root(tree, 300, 100)
	fixed := leaf(tree, px(100), fill())
	rest := leaf(tree, fill(), fill())
	solve(tree)
	testing.expect_value(t, fixed.rect, Rect{0, 0, 100, 100})
	testing.expect_value(t, rest.rect, Rect{100, 0, 200, 100})

	row_root(tree, 300, 100, .X, 10)
	fixed = leaf(tree, px(100), fill())
	first := leaf(tree, fill(), fill())
	second := leaf(tree, fill(), fill())
	solve(tree)
	testing.expect_value(t, fixed.rect.width, i32(100))
	testing.expect_value(t, first.rect, Rect{110, 0, 90, 100})
	testing.expect_value(t, second.rect, Rect{210, 0, 90, 100})
}

// fill_least never goes under its least: it passes the edge, and the clip cuts it.
@(test)
fill_least_passes_the_edge_and_is_clipped :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	row_root(tree, 100, 20)
	leaf(tree, px(80), fill())
	least := leaf(tree, fill_least(50), fill())
	solve(tree)
	testing.expect_value(t, least.rect, Rect{80, 0, 50, 20})
	testing.expect_value(t, least.clipped_rect, Rect{80, 0, 20, 20})
}

// Strictness 1 keeps a size, 0 gives all of it, and between them each child
// gives its part in proportion.
@(test)
strictness_decides_what_a_child_gives :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	widths :: proc(tree: ^Box_Tree, first, second: Size) -> (i32, i32) {
		row_root(tree, 200, 10)
		a := leaf(tree, first, px(10))
		b := leaf(tree, second, px(10))
		solve(tree)
		return a.rect.width, b.rect.width
	}
	a, b := widths(tree, px(150, 0), px(150, 0))
	testing.expect(t, a == 100 && b == 100, "strictness 0 shares the violation")
	a, b = widths(tree, px(150), px(150))
	testing.expect(t, a == 150 && b == 150, "strictness 1 keeps the size")
	a, b = widths(tree, px(150, 5_000), px(150, 5_000))
	testing.expect(t, a == 100 && b == 100, "half strict gives up to half")
	a, b = widths(tree, px(150, 8_000), px(150, 8_000))
	testing.expect(t, a == 120 && b == 120, "each gives its 30 and the row overflows")
	a, b = widths(tree, px(150), px(150, 0))
	testing.expect(t, a == 150 && b == 50, "the loose child gives all of the violation")
	a, b = widths(tree, px(250, 0), px(150))
	testing.expect(t, a == 50 && b == 150, "the loose child gives down to 0 and no further")
	a, b = widths(tree, px(400, 0), px(250))
	testing.expect(t, a == 0 && b == 250, "no size under 0")
}

// A child never goes under its least size or its minimum, and the shares
// add up to the violation exactly.
@(test)
least_and_minimum_bound_the_shrink :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	row_root(tree, 200, 10)
	a := leaf(tree, {kind = .Pixels, value = 150, strictness = 0, least = 120}, px(10))
	b := leaf(tree, px(150, 0), px(10))
	solve(tree)
	testing.expect(t, a.extent[.X] >= 120 * SUB, "the least size holds")
	testing.expect_value(t, a.extent[.X] + b.extent[.X], i64(200 * SUB))
	testing.expect_value(t, a.extent[.X], i64(9600 - 1066))

	row_root(tree, 200, 10)
	index, _ := box_add(tree, {size = {.X = px(150, 0), .Y = px(10)}, minimum = {.X = 140, .Y = 0}})
	b = leaf(tree, px(150, 0), px(10))
	solve(tree)
	testing.expect(t, tree.boxes[index].rect.width >= 140, "the minimum holds")
	testing.expect_value(t, tree.boxes[index].rect.width + b.rect.width, i32(200))

	row_root(tree, 200, 10)
	index, _ = box_add(tree, {size = {.X = fill(), .Y = px(10)}, maximum = {.X = 60, .Y = 0}})
	b = leaf(tree, px(20), px(10))
	solve(tree)
	testing.expect_value(t, tree.boxes[index].rect.width, i32(60))
	testing.expect_value(t, b.rect.x, i32(60))
}

// Three fills of a width that does not divide: the edges snap, the boxes
// touch with no gap and no overlap, and they fill the row whole.
@(test)
snapped_edges_touch_and_fill_the_row :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	for width in ([]i32{100, 101, 7, 1, 0, 997}) {
		row_root(tree, width, 10)
		boxes: [3]^Box
		for &box in boxes {
			box = leaf(tree, fill(), fill())
		}
		solve(tree)
		testing.expect_value(t, boxes[0].rect.x, i32(0))
		testing.expect_value(t, boxes[0].rect.x + boxes[0].rect.width, boxes[1].rect.x)
		testing.expect_value(t, boxes[1].rect.x + boxes[1].rect.width, boxes[2].rect.x)
		testing.expect_value(t, boxes[2].rect.x + boxes[2].rect.width, width)
		for box in boxes {
			testing.expect(t, box.rect.width >= width / 3 && box.rect.width <= width / 3 + 1, "a share differs by more than one pixel")
		}
	}
}

// A box that scrolls keeps the sizes of its children, gives its content
// size, clamps its offset and clips what it moved out.
@(test)
scroll_keeps_children_and_clamps_the_offset :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	layout_with_scroll :: proc(tree: ^Box_Tree, scroll: i32) -> (Box_Index, [5]Box_Index) {
		row_root(tree, 300, 300, .Y)
		scroller, _ := box_open(tree, {size = {.X = px(200), .Y = px(100)}, child_axis = .Y, overflow = {.X = .Visible, .Y = .Scroll}, scroll = {.X = 0, .Y = scroll}})
		children: [5]Box_Index
		for &child in children {
			child, _ = box_add(tree, {size = {.X = fill(), .Y = px(40, 0)}})
		}
		box_close(tree)
		assert(solve(tree) == .Done)
		return scroller, children
	}
	scroller, children := layout_with_scroll(tree, 0)
	testing.expect_value(t, tree.boxes[scroller].content_size[.Y], i32(200))
	testing.expect_value(t, tree.boxes[children[4]].rect, Rect{0, 160, 200, 40})
	testing.expect_value(t, tree.boxes[children[4]].clipped_rect.height, i32(0))
	testing.expect_value(t, tree.boxes[children[2]].clipped_rect, Rect{0, 80, 200, 20})

	scroller, children = layout_with_scroll(tree, 50)
	testing.expect_value(t, tree.boxes[scroller].scroll[.Y], i32(50))
	testing.expect_value(t, tree.boxes[children[0]].rect, Rect{0, -50, 200, 40})
	testing.expect_value(t, tree.boxes[children[0]].clipped_rect.height, i32(0))
	testing.expect_value(t, tree.boxes[children[1]].clipped_rect, Rect{0, 0, 200, 30})

	scroller, children = layout_with_scroll(tree, LENGTH_LIMIT)
	testing.expect_value(t, tree.boxes[scroller].scroll[.Y], i32(100))
	testing.expect_value(t, tree.boxes[children[4]].rect, Rect{0, 60, 200, 40})
	testing.expect_value(t, tree.boxes[children[4]].clipped_rect, Rect{0, 60, 200, 40})
}

// Clip cuts the children at the edge; Visible lets them pass up to the clip of an ancestor.
@(test)
clip_and_visible_overflow :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	for mode in ([]Overflow_Mode{.Clip, .Visible}) {
		row_root(tree, 300, 300)
		box_open(tree, {size = {.X = px(100), .Y = px(100)}, child_axis = .X, overflow = {.X = mode, .Y = mode}})
		wide := leaf(tree, px(150), px(150))
		box_close(tree)
		solve(tree)
		testing.expect_value(t, wide.rect, Rect{0, 0, 150, 150})
		expected := mode == .Clip ? Rect{0, 0, 100, 100} : Rect{0, 0, 150, 150}
		testing.expect_value(t, wide.clipped_rect, expected)
	}
}

// The room that the children leave goes by the alignment, along and across.
@(test)
alignment_places_the_room :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	expected := [Align][2]i32{.Start = {0, 0}, .Center = {90, 125}, .End = {180, 250}}
	for align in Align {
		tree_begin(tree, 300, 300, {child_axis = .X, align = align, cross_align = align, gap = 20})
		first := leaf(tree, px(50), px(50))
		second := leaf(tree, px(50), px(50))
		solve(tree)
		testing.expectf(t, first.rect.x == expected[align][0] && first.rect.y == expected[align][1], "%v: %v", align, first.rect)
		testing.expect_value(t, second.rect.x, expected[align][0] + 70)
	}
	// A child larger than its room starts at the start, whatever the alignment.
	tree_begin(tree, 100, 100, {child_axis = .X, align = .End, cross_align = .Center})
	wide := leaf(tree, px(150), px(150))
	solve(tree)
	testing.expect_value(t, wide.rect, Rect{0, 0, 150, 150})
}

// A column of rows: each row is as high as its children and as wide as the column.
@(test)
nested_stacks_place_each_box :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	row_root(tree, 400, 300, .Y, 8, 16)
	rows: [2]Box_Index
	labels: [2][2]^Box
	for &row, number in rows {
		row, _ = box_open(tree, {size = {.X = fill(), .Y = children_sum()}, child_axis = .X, gap = 8})
		labels[number][0] = leaf(tree, px(100), px(24))
		labels[number][1] = leaf(tree, fill(), px(24))
		box_close(tree)
	}
	rest := leaf(tree, fill(), fill())
	solve(tree)
	testing.expect_value(t, tree.boxes[rows[0]].rect, Rect{16, 16, 368, 24})
	testing.expect_value(t, tree.boxes[rows[1]].rect, Rect{16, 48, 368, 24})
	testing.expect_value(t, labels[1][1].rect, Rect{124, 48, 260, 24})
	testing.expect_value(t, rest.rect, Rect{16, 80, 368, 204})
}

// Lengths at the limit in a full row: no overflow of an integer, and every place is exact.
@(test)
lengths_at_the_limit_do_not_overflow :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	row_root(tree, LENGTH_LIMIT, LENGTH_LIMIT, .Y)
	row, _ := box_open(tree, {size = {.X = children_sum(), .Y = children_sum()}, child_axis = .X, gap = LENGTH_LIMIT, padding = {.X = LENGTH_LIMIT, .Y = 0}})
	count := 0
	last: ^Box
	for tree.count < BOX_CAPACITY {
		last = leaf(tree, px(LENGTH_LIMIT), px(LENGTH_LIMIT))
		count += 1
	}
	box_close(tree)
	testing.expect_value(t, solve(tree), Box_Status.Done)
	expected_width := i64(count) * LENGTH_LIMIT + i64(count - 1) * LENGTH_LIMIT + 2 * LENGTH_LIMIT
	testing.expect_value(t, i64(tree.boxes[row].rect.width), expected_width)
	testing.expect_value(t, i64(last.rect.x), expected_width - 2 * LENGTH_LIMIT)
	testing.expect_value(t, tree.boxes[row].content_size[.X], i32(expected_width))

	// A full row of fills at the limit shares it with no overflow.
	row_root(tree, LENGTH_LIMIT, 1)
	for tree.count < BOX_CAPACITY {
		leaf(tree, {kind = .Percent, value = RATIO_WHOLE, strictness = 1}, px(1))
	}
	solve(tree)
	sum: i64
	for index in 2 ..= tree.count {
		sum += tree.boxes[index].extent[.X]
		testing.expect(t, tree.boxes[index].extent[.X] >= 0, "a negative extent")
	}
	testing.expect_value(t, sum, i64(LENGTH_LIMIT) * SUB)
}

// The split pane clamps its ratio, places its divider, and follows a drag.
@(test)
split_pane_clamps_and_drags :: proc(t: ^testing.T) {
	pane, status := split_pane({0, 0, 1000, 500}, .X, 5_000, 10)
	testing.expect_value(t, status, Box_Status.Done)
	testing.expect_value(t, pane.first, Rect{0, 0, 495, 500})
	testing.expect_value(t, pane.divider, Rect{495, 0, 10, 500})
	testing.expect_value(t, pane.second, Rect{505, 0, 495, 500})
	pane, _ = split_pane({10, 20, 300, 1010}, .Y, 0, 10)
	testing.expect_value(t, pane.first, Rect{10, 20, 300, 100})
	testing.expect_value(t, pane.second, Rect{10, 130, 300, 900})
	for ratio in ([]i32{min(i32), -1, 0, 999}) {
		testing.expect_value(t, split_ratio_clamp(ratio), i32(SPLIT_RATIO_LEAST))
	}
	for ratio in ([]i32{9_001, RATIO_WHOLE, max(i32)}) {
		testing.expect_value(t, split_ratio_clamp(ratio), i32(SPLIT_RATIO_MOST))
	}
	testing.expect_value(t, split_ratio_clamp(SPLIT_RATIO_LEAST), i32(SPLIT_RATIO_LEAST))
	_, status = split_pane({0, 0, 100, 100}, .X, 5_000, 101)
	testing.expect_value(t, status, Box_Status.Length_Refused)
	_, status = split_pane({0, 0, 100, 100}, .X, 5_000, -1)
	testing.expect_value(t, status, Box_Status.Length_Refused)
	_, status = split_pane({0, 0, -1, 100}, .X, 5_000, 0)
	testing.expect_value(t, status, Box_Status.Length_Refused)
	_, status = split_pane({0, 0, 100, 100}, Axis(7), 5_000, 0)
	testing.expect_value(t, status, Box_Status.Unknown_Member)
	pane, status = split_pane({0, 0, 100, 100}, .X, 5_000, 100)
	testing.expect(t, status == .Done && pane.first.width == 0 && pane.second.width == 0)

	testing.expect_value(t, split_ratio_dragged(5_000, 99, 990), i32(6_000))
	testing.expect_value(t, split_ratio_dragged(5_000, -99, 990), i32(4_000))
	testing.expect_value(t, split_ratio_dragged(5_000, 10_000, 990), i32(SPLIT_RATIO_MOST))
	testing.expect_value(t, split_ratio_dragged(5_000, min(i32), 1), i32(SPLIT_RATIO_LEAST))
	testing.expect_value(t, split_ratio_dragged(5_000, max(i32), 1), i32(SPLIT_RATIO_MOST))
	testing.expect_value(t, split_ratio_dragged(5_000, 300, 0), i32(5_000))
	testing.expect_value(t, split_ratio_dragged(20_000, 0, -5), i32(SPLIT_RATIO_MOST))
}

// The flexible columns share what the fixed ones leave, exactly; a narrow
// table keeps the least of each column; wrong columns are refused.
@(test)
table_columns_share_the_room :: proc(t: ^testing.T) {
	columns := []Table_Column{{width = 100}, {weight = 1}, {weight = 2}, {width = 50}}
	places: [4]Table_Column_Place
	testing.expect_value(t, table_columns(columns, places[:], {0, 0, 450, 30}, 4), Box_Status.Done)
	testing.expect_value(t, places[0], Table_Column_Place{0, 100, {98, 0, 4, 30}})
	testing.expect_value(t, places[1].x, i32(100))
	testing.expect_value(t, places[1].width, i32(100))
	testing.expect_value(t, places[2].width, i32(200))
	testing.expect_value(t, places[3], Table_Column_Place{400, 50, {448, 0, 4, 30}})

	thirds := []Table_Column{{weight = 1}, {weight = 1}, {weight = 1}}
	testing.expect_value(t, table_columns(thirds, places[:], {0, 0, 100, 30}, 0), Box_Status.Done)
	testing.expect_value(t, places[0].width + places[1].width + places[2].width, i32(100))

	narrow := []Table_Column{{width = 100}, {weight = 1, least = 30}}
	testing.expect_value(t, table_columns(narrow, places[:], {0, 0, 80, 30}, 0), Box_Status.Done)
	testing.expect_value(t, places[1], Table_Column_Place{100, 30, {130, 0, 0, 30}})

	before := places
	testing.expect_value(t, table_columns(columns, places[:3], {0, 0, 450, 30}, 4), Box_Status.Places_Too_Few)
	testing.expect_value(t, table_columns([]Table_Column{{width = -1}}, places[:], {0, 0, 10, 10}, 0), Box_Status.Length_Refused)
	testing.expect_value(t, table_columns([]Table_Column{{weight = -1}}, places[:], {0, 0, 10, 10}, 0), Box_Status.Length_Refused)
	testing.expect_value(t, table_columns([]Table_Column{{weight = 1, least = -1}}, places[:], {0, 0, 10, 10}, 0), Box_Status.Length_Refused)
	testing.expect_value(t, table_columns(columns, places[:], {0, 0, -1, 30}, 0), Box_Status.Length_Refused)
	testing.expect_value(t, table_columns(columns, places[:], {0, 0, 10, 30}, -1), Box_Status.Length_Refused)
	testing.expect(t, places == before, "a refusal changed the places")
	testing.expect_value(t, table_columns(nil, nil, {0, 0, 10, 10}, 0), Box_Status.Done)

	testing.expect_value(t, table_column_dragged({width = 100, least = 40}, -100), i32(40))
	testing.expect_value(t, table_column_dragged({width = 100, least = 40}, 25), i32(125))
	testing.expect_value(t, table_column_dragged({width = 100}, max(i32)), i32(LENGTH_LIMIT))
}

// One label under two parents gives two identities, and identity_with makes rows apart.
@(test)
identities_are_scoped_by_parent :: proc(t: ^testing.T) {
	tree := new(Box_Tree)
	defer free(tree)
	tree_begin(tree, 100, 100, {label = "window"})
	box_open(tree, {label = "left"})
	left_ok, _ := box_add(tree, {label = "ok"})
	box_close(tree)
	box_open(tree, {label = "right"})
	right_ok, _ := box_add(tree, {label = "ok"})
	box_close(tree)
	unnamed, _ := box_add(tree, {})
	given, _ := box_add(tree, {identity = identity_with(identity_of("rows"), 7)})
	testing.expect(t, tree.boxes[left_ok].identity != tree.boxes[right_ok].identity, "one label under two parents collided")
	testing.expect(t, tree.boxes[left_ok].identity != 0 && tree.boxes[right_ok].identity != 0)
	testing.expect_value(t, tree.boxes[unnamed].identity, Identity(0))
	testing.expect_value(t, tree.boxes[given].identity, identity_with(identity_of("rows"), 7))
	testing.expect_value(t, tree.boxes[left_ok].identity, identity_in(identity_in(identity_of("window"), "left"), "ok"))
	testing.expect(t, identity_with(identity_of("rows"), 1) != identity_with(identity_of("rows"), 2))
	testing.expect(t, identity_with(identity_of("rows"), 0) != identity_of("rows"))
	testing.expect(t, identity_of("") != 0 && identity_in(0, "") != 0 && identity_with(0, 0) != 0, "an identity of 0")
}

// The state of an identity outlives the frame, is new after it went stale,
// and a full table removes the stale entries before it refuses.
@(test)
state_persists_and_stale_entries_recycle :: proc(t: ^testing.T) {
	states := new(Box_States)
	defer free(states)
	_, status := state_of(states, 0)
	testing.expect_value(t, status, State_Status.No_Identity)
	states_frame_begin(states, {})
	pane := identity_of("pane")
	entry, _ := state_of(states, pane)
	entry.split_ratio = 7_000
	entry.collapsed = true
	other, _ := state_of(states, identity_of("other"))
	other.sort_column = 3
	for _ in 0 ..< STALE_FRAMES {
		states_frame_begin(states, {})
	}
	entry, _ = state_of(states, pane) // At the last frame before stale.
	testing.expect(t, entry.split_ratio == 7_000 && entry.collapsed, "the state was lost before it went stale")
	states_frame_begin(states, {})
	states_frame_begin(states, {})
	other, _ = state_of(states, identity_of("other"))
	testing.expect_value(t, other.sort_column, i32(0)) // Stale: found as a new entry.
	entry, _ = state_of(states, pane)
	testing.expect_value(t, entry.split_ratio, i32(7_000))

	// A full table of entries that this frame saw refuses a new one, and changes nothing.
	hash_capacity := 7 * STATE_GROUP_COUNT * 16 / 8
	for number in 0 ..< u64(hash_capacity) {
		_, status = state_of(states, identity_with(identity_of("fill"), number))
		if status != .Done {
			break
		}
	}
	count := states.table.count
	testing.expect_value(t, count, hash_capacity)
	_, status = state_of(states, identity_of("one more"))
	testing.expect_value(t, status, State_Status.Table_Full)
	testing.expect_value(t, states.table.count, count)

	// When they go stale, the insert removes them and takes the slot.
	for frame in 0 ..= STALE_FRAMES {
		states_frame_begin(states, {})
		if frame == STALE_FRAMES / 2 {
			state_of(states, pane)
		}
	}
	states_frame_begin(states, {})
	_, status = state_of(states, identity_of("one more"))
	testing.expect_value(t, status, State_Status.Done)
	testing.expect_value(t, states.table.count, 2)
	entry, _ = state_of(states, pane)
	testing.expect_value(t, entry.split_ratio, i32(7_000))
}

@(private = "file")
Input_Scene :: struct {
	tree:   ^Box_Tree,
	states: ^Box_States,
}

// One frame of a window: a card at (0, 0, 200, 100) with a button at
// (10, 10, 100, 40) inside it, and a list that scrolls at (0, 100, 200, 100)
// with five rows of 40.
@(private = "file")
scene_frame :: proc(scene: ^Input_Scene, input: Frame_Input) -> (card, button, list: Box_Input, rows: [5]Box_Input) {
	states_frame_begin(scene.states, input)
	tree := scene.tree
	tree_begin(tree, 200, 200, {label = "window", child_axis = .Y})
	card_index, _ := box_open(tree, {label = "card", size = {.X = px(200), .Y = px(100)}, padding = {.X = 10, .Y = 10}})
	button_index, _ := box_add(tree, {label = "button", size = {.X = px(100), .Y = px(40)}})
	box_close(tree)
	list_identity := identity_in(tree.boxes[ROOT_BOX].identity, "list")
	list_state, _ := state_of(scene.states, list_identity)
	list_index, _ := box_open(tree, {label = "list", size = {.X = px(200), .Y = px(100)}, child_axis = .Y, overflow = {.X = .Visible, .Y = .Scroll}, scroll = list_state.scroll})
	row_indexes: [5]Box_Index
	for &row, number in row_indexes {
		row, _ = box_add(tree, {identity = identity_with(list_identity, u64(number)), size = {.X = fill(), .Y = px(40)}})
	}
	box_close(tree)
	card, _ = box_input(scene.states, tree.boxes[card_index].identity)
	button, _ = box_input(scene.states, tree.boxes[button_index].identity)
	list, _ = box_input(scene.states, tree.boxes[list_index].identity)
	for row, number in row_indexes {
		rows[number], _ = box_input(scene.states, tree.boxes[row].identity)
	}
	assert(solve(tree) == .Done)
	assert(states_record(scene.states, tree) == 0)
	return
}

// The press goes to the box on top, the release on it activates it, a drag
// gives its distance, the focus follows the press, and the wheel goes to
// the box that scrolls.
@(test)
box_input_follows_the_pointer_and_the_keys :: proc(t: ^testing.T) {
	scene := Input_Scene{new(Box_Tree), new(Box_States)}
	defer free(scene.tree)
	defer free(scene.states)
	over := Frame_Input{pointer_x = 20, pointer_y = 20, pointer_present = true}
	card, button, _, _ := scene_frame(&scene, over)
	testing.expect(t, !button.under_pointer && !card.under_pointer, "the first frame gives input before the box was seen")
	card, button, _, _ = scene_frame(&scene, over)
	testing.expect(t, button.under_pointer && !card.under_pointer, "the box on top takes the pointer")

	pressed := over
	pressed.primary_down, pressed.primary_pressed = true, true
	card, button, _, _ = scene_frame(&scene, pressed)
	testing.expect(t, button.held && button.focused && !button.activated && !button.dragging)
	testing.expect(t, !card.held && !card.focused)

	moved := Frame_Input{pointer_x = 40, pointer_y = 30, pointer_present = true, primary_down = true}
	_, button, _, _ = scene_frame(&scene, moved)
	testing.expect(t, button.held && button.dragging && button.drag_x == 20 && button.drag_y == 10)

	released := moved
	released.primary_down, released.primary_released = false, true
	_, button, _, _ = scene_frame(&scene, released)
	testing.expect(t, button.activated && !button.held && !button.activated_twice && button.focused)

	_, button, _, _ = scene_frame(&scene, over)
	testing.expect(t, !button.activated, "an activation lasts one frame")

	// A press on the button and a release on the card activate nothing.
	scene_frame(&scene, pressed)
	away := Frame_Input{pointer_x = 150, pointer_y = 80, pointer_present = true, primary_released = true}
	card, button, _, _ = scene_frame(&scene, away)
	testing.expect(t, !button.activated && !card.activated && card.under_pointer)

	// The second press of a double press.
	twice := pressed
	twice.primary_press_count = 2
	scene_frame(&scene, twice)
	release_over := over
	release_over.primary_released = true
	_, button, _, _ = scene_frame(&scene, release_over)
	testing.expect(t, button.activated && button.activated_twice)

	// Enter or Space activates the box with the focus, wherever the pointer is.
	key := Frame_Input{activate_key = true}
	card, button, _, _ = scene_frame(&scene, key)
	testing.expect(t, button.activated && !card.activated && !button.under_pointer)

	// A secondary press, and a press on no box that takes the focus away.
	secondary := over
	secondary.secondary_pressed = true
	_, button, _, _ = scene_frame(&scene, secondary)
	testing.expect(t, button.pressed_secondary && !button.activated)
	nothing := Frame_Input{pointer_x = 500, pointer_y = 500, pointer_present = true, primary_pressed = true, primary_down = true}
	_, button, _, _ = scene_frame(&scene, nothing)
	testing.expect(t, !button.focused && !button.held && !button.under_pointer)
	_, button, _, _ = scene_frame(&scene, {pointer_present = false})
	testing.expect(t, !button.under_pointer && !button.held)
}

// The wheel goes to the list under the pointer; the solver clamps the offset;
// a row moved out of the clip of the list is not under the pointer.
@(test)
box_input_scrolls_and_respects_the_clip :: proc(t: ^testing.T) {
	scene := Input_Scene{new(Box_Tree), new(Box_States)}
	defer free(scene.tree)
	defer free(scene.states)
	over_list := Frame_Input{pointer_x = 50, pointer_y = 110, pointer_present = true}
	scene_frame(&scene, over_list)
	_, _, list, rows := scene_frame(&scene, over_list)
	testing.expect(t, rows[0].under_pointer && !list.under_pointer, "the row on top of the list takes the pointer")

	wheel := over_list
	wheel.wheel_y = 30
	_, _, list, rows = scene_frame(&scene, wheel)
	testing.expect(t, list.scrolled_y == 30 && rows[0].scrolled_y == 0)
	list_identity := identity_in(identity_of("window"), "list")
	state, _ := state_of(scene.states, list_identity)
	testing.expect_value(t, state.scroll[.Y], i32(30))

	wheel.wheel_y = 10_000
	scene_frame(&scene, wheel)
	state, _ = state_of(scene.states, list_identity)
	testing.expect_value(t, state.scroll[.Y], i32(100)) // The content is 200 in a room of 100.

	// Row 0 is now at y = 0 to 40 of the window: under the card, out of the clip of the list.
	over_card := Frame_Input{pointer_x = 150, pointer_y = 20, pointer_present = true}
	scene_frame(&scene, over_card)
	card, _, _, rows2 := scene_frame(&scene, over_card)
	testing.expect(t, card.under_pointer && !rows2[0].under_pointer, "a row out of the clip took the pointer")

	wheel.wheel_y = min(i32)
	scene_frame(&scene, wheel)
	state, _ = state_of(scene.states, list_identity)
	testing.expect_value(t, state.scroll[.Y], i32(0))
}

// One identity asks for its input once in a frame.
@(test)
box_input_refuses_a_second_ask :: proc(t: ^testing.T) {
	states := new(Box_States)
	defer free(states)
	states_frame_begin(states, {})
	_, status := box_input(states, identity_of("twice"))
	testing.expect_value(t, status, State_Status.Done)
	_, status = box_input(states, identity_of("twice"))
	testing.expect_value(t, status, State_Status.Identity_Taken)
	_, status = box_input(states, 0)
	testing.expect_value(t, status, State_Status.No_Identity)
	states_frame_begin(states, {})
	_, status = box_input(states, identity_of("twice"))
	testing.expect_value(t, status, State_Status.Done)
}

@(private = "file")
Contrast_Pair :: struct {
	name:              string,
	foreground:        graphics.Color,
	background:        graphics.Color,
	standard_least:    u32, // The contrast ratio times 100 in the standard appearances.
}

// Each pair of a text, a border or the outline of the focus on the surfaces
// that it is drawn on keeps its contrast: 4.5 to 1 for a text, 3 to 1 for a
// line, and 7 to 1 for each in a forced high contrast mode.
@(test)
element_tokens_keep_their_contrast :: proc(t: ^testing.T) {
	modes := [?]graphics.Color_Contrast_Mode{.Standard, .Forced_High_Contrast_Dark, .Forced_High_Contrast_Light}
	for appearance in graphics.Appearance {
		for mode in modes {
			tokens, ok := tokens_for(appearance, mode)
			testing.expect(t, ok)
			surfaces := [?]graphics.Color{tokens.surface_background, tokens.surface_card, tokens.surface_recess}
			pairs := make([dynamic]Contrast_Pair, context.temp_allocator)
			for surface in surfaces {
				append(&pairs, Contrast_Pair{"text", tokens.text, surface, 450})
				append(&pairs, Contrast_Pair{"text_dim", tokens.text_dim, surface, 450})
				append(&pairs, Contrast_Pair{"text_strong", tokens.text_strong, surface, 450})
				append(&pairs, Contrast_Pair{"expected", tokens.expected, surface, 450})
				append(&pairs, Contrast_Pair{"warning", tokens.warning, surface, 450})
				append(&pairs, Contrast_Pair{"failed", tokens.failed, surface, 450})
				append(&pairs, Contrast_Pair{"border", tokens.border, surface, 300})
				append(&pairs, Contrast_Pair{"focus_outline", tokens.focus_outline, surface, 300})
			}
			append(&pairs, Contrast_Pair{"text on the track", tokens.text, tokens.surface_track, 450})
			append(&pairs, Contrast_Pair{"text_strong on the track", tokens.text_strong, tokens.surface_track, 450})
			append(&pairs, Contrast_Pair{"focus_outline on the track", tokens.focus_outline, tokens.surface_track, 300})
			append(&pairs, Contrast_Pair{"border on the track", tokens.border, tokens.surface_track, 300})
			append(&pairs, Contrast_Pair{"text_on_chosen", tokens.text_on_chosen, tokens.surface_chosen, 450})
			for pair in pairs {
				least := mode == .Standard ? pair.standard_least : graphics.WCAG_AAA_CONTRAST_RATIO_X100
				ratio := graphics.contrast_ratio_x100(pair.foreground, pair.background)
				testing.expectf(t, ratio >= least, "%v %v: %s %06x on %06x is %d, under %d", appearance, mode, pair.name, u32(pair.foreground), u32(pair.background), ratio, least)
			}
		}
	}
}

// The tokens are the values of the one table of the color tokens and of the
// spacing tokens: the package holds no value of its own.
@(test)
element_tokens_come_from_the_one_table :: proc(t: ^testing.T) {
	tokens, ok := tokens_for(.Light, .Standard)
	testing.expect(t, ok)
	light := graphics.LIGHT_COLOR_TOKENS
	testing.expect(t, tokens.text == light.text && tokens.surface_background == light.background && tokens.surface_chosen == light.chosen && tokens.failed == light.failed)
	testing.expect(t, tokens.gap == graphics.GAP && tokens.margin == graphics.MARGIN && tokens.title == graphics.TITLE)
	dark, _ := tokens_for(.Dark, .Standard)
	testing.expect(t, dark.text == graphics.DARK_TEXT && dark.surface_background == graphics.DARK_BACKGROUND)
	forced, _ := tokens_for(.Light, .Forced_High_Contrast_Dark)
	testing.expect_value(t, forced.surface_background, graphics.FORCED_HIGH_CONTRAST_DARK_COLORS.background)

	_, ok = tokens_for(graphics.Appearance(2), .Standard)
	testing.expect(t, !ok, "an appearance that names no member was taken")
	_, ok = tokens_for(.Dark, graphics.Color_Contrast_Mode(3))
	testing.expect(t, !ok, "a contrast mode that names no member was taken")
	_, ok = tokens_for(graphics.Appearance(255), graphics.Color_Contrast_Mode(255))
	testing.expect(t, !ok)
}

// The stack holds 16 records, refuses one more and a pop of an empty stack,
// and an empty stack gives the dark tokens.
@(test)
token_stack_bounds :: proc(t: ^testing.T) {
	stack := new(Token_Stack)
	defer free(stack)
	dark, _ := tokens_for(.Dark, .Standard)
	light, _ := tokens_for(.Light, .Standard)
	testing.expect_value(t, tokens_current(stack), dark)
	testing.expect(t, !pop_tokens(stack), "a pop of an empty stack was taken")
	testing.expect_value(t, stack.depth, 0)
	for number in 0 ..< TOKEN_STACK_CAPACITY {
		testing.expect(t, push_tokens(stack, number % 2 == 0 ? light : dark))
	}
	testing.expect(t, !push_tokens(stack, light), "a push past the capacity was taken")
	testing.expect_value(t, stack.depth, TOKEN_STACK_CAPACITY)
	testing.expect_value(t, tokens_current(stack), dark)
	testing.expect(t, pop_tokens(stack))
	testing.expect_value(t, tokens_current(stack), light)
	stack.depth = -3
	testing.expect(t, !pop_tokens(stack) && !push_tokens(stack, light))
	testing.expect_value(t, tokens_current(stack), dark)
	stack.depth = TOKEN_STACK_CAPACITY + 1
	testing.expect(t, !pop_tokens(stack) && !push_tokens(stack, light))
}

// Crossing BOX_CAPACITY (1024 -> 1025 -> 2048 -> 2049) moves cleanly from the
// fast inline tier to the caller-supplied overflow tier, counts each move,
// solves every box accurately, records states past 1024, returns to inline on
// the next frame, and leaves the tree intact if growth is refused.
@(test)
box_tree_overflow_tier_crosses_inline_capacity :: proc(t: ^testing.T) {
	Grow_Context :: struct {
		backing:   [dynamic]Box,
		limit:     int,
		calls:     int,
	}
	grow_proc :: proc "contextless" (user_data: rawptr, current: []Box, minimum_boxes: int) -> (grown: []Box, ok: bool) {
		ctx := (^Grow_Context)(user_data)
		ctx.calls += 1
		if minimum_boxes > ctx.limit {
			return nil, false
		}
		// Copy existing slots before growing in case backing reallocates.
		return ctx.backing[:min(len(ctx.backing), max(minimum_boxes, min(ctx.limit, max(len(current) * 2, BOX_CAPACITY + 256))))], true
	}

	tree := new(Box_Tree)
	defer free(tree)
	ctx := Grow_Context{limit = 2200}
	resize(&ctx.backing, 2200)
	defer delete(ctx.backing)
	tree_set_overflow(tree, nil, grow_proc, &ctx)

	// Up to BOX_CAPACITY boxes stay on the fast inline tier with zero moves.
	row_root(tree, 4096, 100)
	for _ in 1 ..< BOX_CAPACITY {
		_, status := box_add(tree, {size = {.X = px(1), .Y = px(1)}})
		testing.expect_value(t, status, Box_Status.Done)
	}
	testing.expect_value(t, tree.count, BOX_CAPACITY)
	testing.expect(t, !tree_on_overflow(tree))
	testing.expect_value(t, tree.overflow_moves, u64(0))

	// A refused description at the inline boundary must not trigger an overflow move.
	_, bad_status := box_add(tree, {size = {.X = px(-1), .Y = px(1)}})
	testing.expect_value(t, bad_status, Box_Status.Size_Refused)
	testing.expect(t, !tree_on_overflow(tree))
	testing.expect_value(t, tree.overflow_moves, u64(0))

	// Box 1025 transitions into the slower overflow tier and increments overflow_moves.
	idx_1025, status_1025 := box_add(tree, {label = "box_1025", size = {.X = px(1), .Y = px(1)}})
	testing.expect_value(t, status_1025, Box_Status.Done)
	testing.expect_value(t, idx_1025, Box_Index(BOX_CAPACITY + 1))
	testing.expect(t, tree_on_overflow(tree))
	testing.expect_value(t, tree.overflow_moves, u64(1))

	// Continue to 2048 boxes (triggers a second growth past initial 1280 slice).
	last_index := idx_1025
	for tree.count < 2048 {
		idx, st := box_add(tree, {size = {.X = px(1), .Y = px(1)}})
		testing.expect_value(t, st, Box_Status.Done)
		last_index = idx
	}
	testing.expect_value(t, tree.count, 2048)
	testing.expect(t, tree.overflow_moves >= 2)
	testing.expect_value(t, solve(tree), Box_Status.Done)

	box_1025 := box_of(tree, idx_1025)
	testing.expect(t, box_1025 != nil)
	testing.expect_value(t, box_1025.rect, Rect{1023, 0, 1, 1})
	box_2048 := box_of(tree, last_index)
	testing.expect(t, box_2048 != nil)
	testing.expect_value(t, box_2048.rect, Rect{2046, 0, 1, 1})
	testing.expect(t, box_of(tree, Box_Index(max(u32))) == nil)

	// states_record reads boxes past BOX_CAPACITY cleanly.
	states := new(Box_States)
	defer free(states)
	states_frame_begin(states, {})
	testing.expect_value(t, states_record(states, tree), 0)
	entry, st_ok := state_of(states, box_1025.identity)
	testing.expect_value(t, st_ok, State_Status.Done)
	testing.expect_value(t, entry.last_order, u32(idx_1025))
	testing.expect_value(t, entry.last_rect, Rect{1023, 0, 1, 1})

	// Refused growth past ctx.limit returns Tree_Full and leaves the tree intact.
	for tree.count < ctx.limit - 1 {
		_, st := box_add(tree, {size = {.X = px(1), .Y = px(1)}})
		testing.expect_value(t, st, Box_Status.Done)
	}
	count_before := tree.count
	moves_before := tree.overflow_moves
	_, refused_status := box_add(tree, {size = {.X = px(1), .Y = px(1)}})
	testing.expect_value(t, refused_status, Box_Status.Tree_Full)
	testing.expect_value(t, tree.count, count_before)
	testing.expect_value(t, tree.overflow_moves, moves_before)

	// Next frame starts back on the fast inline tier while preserving overflow_moves.
	row_root(tree, 200, 100)
	testing.expect(t, !tree_on_overflow(tree))
	testing.expect_value(t, tree.overflow_moves, moves_before)
	testing.expect_value(t, tree_capacity(tree), BOX_CAPACITY)
}

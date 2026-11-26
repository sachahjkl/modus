#+build !freestanding
#+build !modus
package layout_measure

import "core:testing"

@(test)
intrinsic_content_layout_measures_column_and_row_accurately :: proc(t: ^testing.T) {
	_, bad := node_kind_of_word(99)
	testing.expect(t, !bad)

	tree: Layout_Tree
	layout_tree_init(&tree)

	col, r0 := layout_add_node(&tree, .Column, -1, 0, 0, padding = 8, gap = 6)
	testing.expect_value(t, r0, Layout_Refusal.None)
	lbl1, _ := layout_add_node(&tree, .Label, col, 120, 16)
	row, _ := layout_add_node(&tree, .Row, col, 0, 0, gap = 10)
	btn1, _ := layout_add_node(&tree, .Button, row, 60, 24, padding = 4) // 68x32
	btn2, _ := layout_add_node(&tree, .Button, row, 90, 24, padding = 4) // 98x32

	testing.expect_value(t, layout_measure_and_place(&tree, Box_Rect{0, 0, 0, 100}), Layout_Refusal.Invalid_Bounds)
	testing.expect_value(t, layout_measure_and_place(&tree, Box_Rect{10, 20, 800, 600}), Layout_Refusal.None)

	// Row width = 68 + 10 + 98 = 176; height = 32.
	testing.expect_value(t, tree.nodes[row].measured_w, i32(176))
	testing.expect_value(t, tree.nodes[row].measured_h, i32(32))
	// Column width = max(120, 176) + 16 = 192; height = 16 + 6 + 32 + 16 = 70.
	testing.expect_value(t, tree.nodes[col].measured_w, i32(192))
	testing.expect_value(t, tree.nodes[col].measured_h, i32(70))
	// Check exact placement coordinates.
	testing.expect_value(t, tree.nodes[lbl1].placed, Box_Rect{18, 28, 120, 16})
	testing.expect_value(t, tree.nodes[btn1].placed, Box_Rect{18, 50, 68, 32})
	testing.expect_value(t, tree.nodes[btn2].placed, Box_Rect{96, 50, 98, 32})
}

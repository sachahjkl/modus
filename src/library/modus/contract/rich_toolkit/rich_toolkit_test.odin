#+build !freestanding
#+build !modus
package rich_toolkit

import "core:testing"

@(test)
outside_module_transitive_imports_and_gui_toolkit_style :: proc(t: ^testing.T) {
	testing.expect_value(t, MODUS_GUI_TOOLKIT_DARK.corner_radius_px, i32(0))
	testing.expect_value(t, MODUS_GUI_TOOLKIT_HIGH_CONTRAST.border_rgba, u32(0xFFFFFFFF))

	h_app: [32]u8; h_app[0] = 1
	h_gt: [32]u8; h_gt[0] = 2
	h_dep: [32]u8; h_dep[0] = 3

	g: Import_Graph
	testing.expect_value(t, graph_add(&g, h_dep, nil), Resolve_Refusal.None)
	testing.expect_value(t, graph_add(&g, h_gt, [][32]u8{h_dep}), Resolve_Refusal.None)
	testing.expect_value(t, graph_add(&g, h_app, [][32]u8{h_gt}), Resolve_Refusal.None)

	order: [8]int
	n, r := graph_resolve_order(&g, h_app, order[:])
	testing.expect_value(t, r, Resolve_Refusal.None)
	testing.expect_value(t, n, 3)
	// Post-order: dependency loaded first, then gui_toolkit, then app.
	testing.expect_value(t, order[0], 0)
	testing.expect_value(t, order[1], 1)
	testing.expect_value(t, order[2], 2)

	// Cycle refused.
	g.modules[0].import_count = 1
	g.modules[0].imports[0] = h_app
	_, rc := graph_resolve_order(&g, h_app, order[:])
	testing.expect_value(t, rc, Resolve_Refusal.Cycle_Detected)
}

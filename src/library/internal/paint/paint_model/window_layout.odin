package paint_model

import "modus:layout"

// Window layout geometry constants for paint (src/md/features/paint_application.md).
LAYOUT_GAP :: 4
LAYOUT_ROW_HEIGHT :: 28
LAYOUT_PALETTE_CELL :: 24
LAYOUT_STATUS_HEIGHT :: 24
LAYOUT_PANEL_WIDTH :: 256
LAYOUT_LIST_MIN_HEIGHT :: 24

LAYOUT_LEAST_WIDTH :: 600
LAYOUT_LEAST_HEIGHT :: 360
LAYOUT_DEFAULT_WIDTH :: 640
LAYOUT_DEFAULT_HEIGHT :: 440
LAYOUT_LARGEST_WIDTH :: 1920
LAYOUT_LARGEST_HEIGHT :: 1080
LAYOUT_CANVAS_TOP :: LAYOUT_GAP + LAYOUT_ROW_HEIGHT + LAYOUT_GAP + LAYOUT_PALETTE_CELL + LAYOUT_GAP

// Minimum pane bounds: canvas stays at least 200x200 even with a side panel open.
#assert(LAYOUT_LEAST_WIDTH >= LAYOUT_PANEL_WIDTH + 2 * LAYOUT_GAP + 200)
#assert(LAYOUT_LEAST_HEIGHT >= LAYOUT_CANVAS_TOP + LAYOUT_STATUS_HEIGHT + 200)

Panel_Kind :: enum u8 {
	None     = 0,
	Pictures = 1,
	Color    = 2,
}

Color_Channel_Rects :: struct {
	label: layout.Rect,
	less:  layout.Rect,
	bar:   layout.Rect,
	more:  layout.Rect,
}

Window_Layout :: struct {
	tools_row:       layout.Rect,
	palette_row:     layout.Rect,
	canvas:          layout.Rect,
	panel:           layout.Rect,
	color_sample:    layout.Rect,
	color_channels:  [Channel]Color_Channel_Rects,
	color_hex_field: layout.Rect,
	color_apply_btn: layout.Rect,
	pic_name_field:  layout.Rect,
	pic_new_btn:     layout.Rect,
	pic_rename_btn:  layout.Rect,
	pic_list:        layout.Rect,
	pic_open_btn:    layout.Rect,
	pic_delete_btn:  layout.Rect,
	pic_prev_btn:    layout.Rect,
	pic_next_btn:    layout.Rect,
	status_bar:      layout.Rect,
}

@(private = "file")
rect_of :: proc "contextless" (tree: ^layout.Box_Tree, index: layout.Box_Index) -> layout.Rect {
	box := layout.box_of(tree, index)
	if box == nil {
		return {}
	}
	return box.rect
}

// window_layout computes the tool bar, palette bar, canvas, active side panel
// controls, and status bar using modus:layout.
window_layout :: proc "contextless" (tree: ^layout.Box_Tree, width, height: int, panel_open: Panel_Kind) -> (places: Window_Layout, ok: bool) {
	if tree == nil || width <= 0 || height <= 0 || width > layout.LENGTH_LIMIT || height > layout.LENGTH_LIMIT {
		return {}, false
	}
	if layout.tree_begin(tree, i32(width), i32(height), {child_axis = .Y}) != .Done {
		return {}, false
	}
	tools_box, s0 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LAYOUT_GAP + LAYOUT_ROW_HEIGHT + LAYOUT_GAP)}})
	palette_box, s1 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LAYOUT_PALETTE_CELL + LAYOUT_GAP)}})
	_, s2 := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .X})
	canvas_box, s3 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill()}})
	if s0 != .Done || s1 != .Done || s2 != .Done || s3 != .Done {
		return {}, false
	}

	panel_box: layout.Box_Index
	color_sample_box: layout.Box_Index
	ch_label, ch_less, ch_bar, ch_more: [Channel]layout.Box_Index
	color_hex_box, color_apply_box: layout.Box_Index
	pic_name_box, pic_new_box, pic_rename_box, pic_list_box, pic_open_box, pic_del_box, pic_prev_box, pic_next_box: layout.Box_Index

	if panel_open != .None {
		if _, st := layout.box_open(tree, {size = {.X = layout.px(LAYOUT_PANEL_WIDTH + 2 * LAYOUT_GAP), .Y = layout.fill()}, child_axis = .Y, padding = {.X = LAYOUT_GAP, .Y = LAYOUT_GAP}}); st != .Done {
			return {}, false
		}
		panel_st: layout.Box_Status
		panel_box, panel_st = layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .Y, gap = LAYOUT_GAP})
		if panel_st != .Done {
			return {}, false
		}
		switch panel_open {
		case .None:
		case .Color:
			cs_st: layout.Box_Status
			color_sample_box, cs_st = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(40)}})
			_, sp_st := layout.box_add(tree, {size = {.X = layout.px(0), .Y = layout.px(LAYOUT_GAP)}})
			if cs_st != .Done || sp_st != .Done {
				return {}, false
			}
			for ch in Channel {
				if _, st := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(LAYOUT_ROW_HEIGHT)}, child_axis = .X, cross_align = .Center, gap = LAYOUT_GAP}); st != .Done {
					return {}, false
				}
				sl, sless, sbar, smore: layout.Box_Status
				ch_label[ch], sl = layout.box_add(tree, {size = {.X = layout.px(48), .Y = layout.fill()}})
				ch_less[ch], sless = layout.box_add(tree, {size = {.X = layout.px(44), .Y = layout.fill()}})
				ch_bar[ch], sbar = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LAYOUT_ROW_HEIGHT - 12)}})
				ch_more[ch], smore = layout.box_add(tree, {size = {.X = layout.px(44), .Y = layout.fill()}})
				sc := layout.box_close(tree)
				if sl != .Done || sless != .Done || sbar != .Done || smore != .Done || sc != .Done {
					return {}, false
				}
			}
			_, sp2 := layout.box_add(tree, {size = {.X = layout.px(0), .Y = layout.px(LAYOUT_GAP)}})
			_, hr := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(LAYOUT_ROW_HEIGHT)}, child_axis = .X, gap = LAYOUT_GAP})
			s_hex, s_app: layout.Box_Status
			color_hex_box, s_hex = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill()}})
			color_apply_box, s_app = layout.box_add(tree, {size = {.X = layout.px(80), .Y = layout.fill()}})
			hc := layout.box_close(tree)
			if sp2 != .Done || hr != .Done || s_hex != .Done || s_app != .Done || hc != .Done {
				return {}, false
			}
		case .Pictures:
			BUTTON_WIDTH :: 72
			_, tr := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(LAYOUT_ROW_HEIGHT)}, child_axis = .X, gap = LAYOUT_GAP})
			s_nf, s_nb, s_rb: layout.Box_Status
			pic_name_box, s_nf = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill()}})
			pic_new_box, s_nb = layout.box_add(tree, {size = {.X = layout.px(BUTTON_WIDTH), .Y = layout.fill()}})
			pic_rename_box, s_rb = layout.box_add(tree, {size = {.X = layout.px(BUTTON_WIDTH), .Y = layout.fill()}})
			tc := layout.box_close(tree)
			s_ls: layout.Box_Status
			pic_list_box, s_ls = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill_least(LAYOUT_LIST_MIN_HEIGHT)}})
			_, ar := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(LAYOUT_ROW_HEIGHT)}, child_axis = .X, gap = LAYOUT_GAP})
			s_ob, s_db: layout.Box_Status
			pic_open_box, s_ob = layout.box_add(tree, {size = {.X = layout.px(BUTTON_WIDTH), .Y = layout.fill()}})
			pic_del_box, s_db = layout.box_add(tree, {size = {.X = layout.px(BUTTON_WIDTH), .Y = layout.fill()}})
			ac := layout.box_close(tree)
			_, pr := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(LAYOUT_ROW_HEIGHT)}, child_axis = .X, gap = LAYOUT_GAP})
			s_pb, s_nxb: layout.Box_Status
			pic_prev_box, s_pb = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill()}})
			pic_next_box, s_nxb = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill()}})
			pc := layout.box_close(tree)
			if tr != .Done || s_nf != .Done || s_nb != .Done || s_rb != .Done || tc != .Done || s_ls != .Done || ar != .Done || s_ob != .Done || s_db != .Done || ac != .Done || pr != .Done || s_pb != .Done || s_nxb != .Done || pc != .Done {
				return {}, false
			}
		}
		if layout.box_close(tree) != .Done || layout.box_close(tree) != .Done {
			return {}, false
		}
	}
	sc_ws := layout.box_close(tree)
	status_box, s_st := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LAYOUT_STATUS_HEIGHT)}})
	if sc_ws != .Done || s_st != .Done || layout.solve(tree) != .Done {
		return {}, false
	}
	places.tools_row = rect_of(tree, tools_box)
	places.palette_row = rect_of(tree, palette_box)
	places.canvas = rect_of(tree, canvas_box)
	places.status_bar = rect_of(tree, status_box)
	if panel_open != .None {
		places.panel = rect_of(tree, panel_box)
		switch panel_open {
		case .None:
		case .Color:
			places.color_sample = rect_of(tree, color_sample_box)
			for ch in Channel {
				places.color_channels[ch] = {
					label = rect_of(tree, ch_label[ch]),
					less  = rect_of(tree, ch_less[ch]),
					bar   = rect_of(tree, ch_bar[ch]),
					more  = rect_of(tree, ch_more[ch]),
				}
			}
			places.color_hex_field = rect_of(tree, color_hex_box)
			places.color_apply_btn = rect_of(tree, color_apply_box)
		case .Pictures:
			places.pic_name_field = rect_of(tree, pic_name_box)
			places.pic_new_btn = rect_of(tree, pic_new_box)
			places.pic_rename_btn = rect_of(tree, pic_rename_box)
			places.pic_list = rect_of(tree, pic_list_box)
			places.pic_open_btn = rect_of(tree, pic_open_box)
			places.pic_delete_btn = rect_of(tree, pic_del_box)
			places.pic_prev_btn = rect_of(tree, pic_prev_box)
			places.pic_next_btn = rect_of(tree, pic_next_box)
		}
	}
	return places, true
}

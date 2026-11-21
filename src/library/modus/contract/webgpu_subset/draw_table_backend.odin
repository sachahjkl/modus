// Freestanding Draw Table v20 to WebGPU subset command-stream translator
// (src/md/api/draw_table.md).
//
// Translates a validated draw_record table into a validated Gpu_Command_Stream
// plus tightly packed Vertex_2D and u32 index buffer bytes. Semantic element
// records (Element_Push, Element_Pop) draw nothing and are skipped after
// unified stack-order validation. Nested Clip_Push/Clip_Pop records lower into
// intersected Set_Scissor_Rect commands, and records outside the active clip
// or damage rectangle are culled.
//
// Two-phase dry-run validation guarantees zero bytes are written to any caller
// buffer when an input record, clip order, path, or buffer capacity fails.
// This file allocates no memory and calls no kernel operation.
package webgpu_subset

import "modus:contract/byte_order"
import "modus:contract/draw_record"

// 32-byte 2D vertex shared between draw_table_translate_to_webgpu and the
// processor Solid_Color_2D backend. Colors are linear-light RGB (gamma 2)
// with straight alpha in [0.0, 1.0].
Vertex_2D :: struct {
	x: f32,
	y: f32,
	r: f32,
	g: f32,
	b: f32,
	a: f32,
	u: f32,
	v: f32,
}

#assert(size_of(Vertex_2D) == 32)
VERTEX_2D_STRIDE :: u32(size_of(Vertex_2D))

// Pixel-space rectangle with non-negative origin and extent.
Pixel_Rect :: struct {
	x:      u32,
	y:      u32,
	width:  u32,
	height: u32,
}

// Binding configuration for translating one draw table frame into WebGPU commands.
Draw_Table_Translate_Config :: struct {
	surface_width:    u32,
	surface_height:   u32,
	color_texture_id: u32,
	pipeline_id:      u32,
	vertex_buffer_id: u32,
	index_buffer_id:  u32,
	load_op:          Load_Op,
	clear_color:      Clear_Color,
	has_damage_rect:  bool,
	damage_rect:      Pixel_Rect,
}

// Output command stream, buffer usage, and translation metrics.
Draw_Table_Translate_Result :: struct {
	stream:               Gpu_Command_Stream,
	vertex_bytes_used:    int,
	index_bytes_used:     int,
	vertex_count:         u32,
	index_count:          u32,
	quad_count:           u32,
	triangle_count:       u32,
	scissor_change_count: u32,
	skipped_records:      u32,
	culled_records:       u32,
}

// Why draw_table_translate_to_webgpu refused a draw table or caller buffer.
Draw_Table_Translation_Problem :: enum u8 {
	None = 0,
	Zero_Surface_Dimensions,
	Surface_Dimension_Too_Large,
	Zero_Object_Id,
	Unknown_Load_Op,
	Damage_Rect_Out_Of_Bounds,
	Unbalanced_Clips_Or_Elements,
	Invalid_Draw_Record,
	Byte_Table_Out_Of_Bounds,
	Invalid_Path_Points,
	Command_Buffer_Overflow,
	Vertex_Buffer_Overflow,
	Index_Buffer_Overflow,
}

@(private = "file")
Clip_Box :: struct {
	left:   i32,
	top:    i32,
	right:  i32,
	bottom: i32,
}

@(private = "file")
clip_box_empty :: proc "contextless" (box: Clip_Box) -> bool {
	return box.right <= box.left || box.bottom <= box.top
}

@(private = "file")
clip_box_intersect :: proc "contextless" (a, b: Clip_Box) -> Clip_Box {
	left := max(a.left, b.left)
	top := max(a.top, b.top)
	right := min(a.right, b.right)
	bottom := min(a.bottom, b.bottom)
	if right <= left || bottom <= top {
		return {}
	}
	return Clip_Box{left = left, top = top, right = right, bottom = bottom}
}

@(private = "file")
draw_color_to_linear_rgba :: proc "contextless" (color: draw_record.Draw_Color) -> (r, g, b, a: f32) {
	alpha_u8 := draw_record.alpha_of(color)
	rgb := draw_record.channels_of(color)
	r_enc := f32((rgb >> 16) & 0xFF) / 255.0
	g_enc := f32((rgb >> 8) & 0xFF) / 255.0
	b_enc := f32(rgb & 0xFF) / 255.0
	return r_enc * r_enc, g_enc * g_enc, b_enc * b_enc, f32(alpha_u8) / 255.0
}

@(private = "file")
mix_encoded_channel :: proc "contextless" (start_ch, end_ch, level: u32) -> u8 {
	return u8((start_ch * (draw_record.GRADIENT_LEVELS - level) + end_ch * level) / draw_record.GRADIENT_LEVELS)
}

@(private = "file")
gradient_color_at_point :: proc "contextless" (gradient: draw_record.Draw_Gradient, x_units, y_units: i32) -> (r, g, b, a: f32) {
	level := draw_record.gradient_level(gradient, i64(x_units), i64(y_units))
	s := u32(gradient.start_color)
	e := u32(gradient.end_color)
	a_u8 := mix_encoded_channel((s >> 24) & 0xFF, (e >> 24) & 0xFF, level)
	r_u8 := mix_encoded_channel((s >> 16) & 0xFF, (e >> 16) & 0xFF, level)
	g_u8 := mix_encoded_channel((s >> 8) & 0xFF, (e >> 8) & 0xFF, level)
	b_u8 := mix_encoded_channel(s & 0xFF, e & 0xFF, level)
	r_enc := f32(r_u8) / 255.0
	g_enc := f32(g_u8) / 255.0
	b_enc := f32(b_u8) / 255.0
	return r_enc * r_enc, g_enc * g_enc, b_enc * b_enc, f32(a_u8) / 255.0
}

@(private = "file")
sqrt_f32_positive :: proc "contextless" (value: f32) -> f32 {
	if value <= 0.0 {
		return 0.0
	}
	bits := transmute(u32)value
	guess := transmute(f32)((bits >> 1) + 0x1FC0_0000)
	guess = 0.5 * (guess + value / guess)
	guess = 0.5 * (guess + value / guess)
	guess = 0.5 * (guess + value / guess)
	guess = 0.5 * (guess + value / guess)
	return guess
}

@(private = "file")
floor_div_i64 :: proc "contextless" (numerator, denominator: i64) -> i64 {
	q := numerator / denominator
	r := numerator % denominator
	if r < 0 {
		q -= 1
	}
	return q
}

@(private = "file")
Translate_Sink :: struct {
	dry_run:               bool,
	max_vertices:          u32,
	max_indices:           u32,
	max_commands:          u32,
	encoder:               Gpu_Command_Encoder,
	vertex_storage:        []u8,
	index_storage:         []u8,
	vertex_count:          u32,
	index_count:           u32,
	command_count:         u32,
	quad_count:            u32,
	triangle_count:        u32,
	scissor_change_count:  u32,
	skipped_records:       u32,
	culled_records:        u32,
	has_batch:             bool,
	batch_scissor:         Clip_Box,
	batch_first_index:     u32,
	has_emitted_scissor:   bool,
	emitted_scissor:       Clip_Box,
}

@(private = "file")
sink_write_vertex :: proc "contextless" (sink: ^Translate_Sink, v: Vertex_2D) -> (index: u32, problem: Draw_Table_Translation_Problem) {
	if sink.vertex_count >= sink.max_vertices {
		return 0, .Vertex_Buffer_Overflow
	}
	index = sink.vertex_count
	if !sink.dry_run {
		base := int(index) * size_of(Vertex_2D)
		byte_order.write_u32_little_endian(sink.vertex_storage, base + 0, transmute(u32)v.x)
		byte_order.write_u32_little_endian(sink.vertex_storage, base + 4, transmute(u32)v.y)
		byte_order.write_u32_little_endian(sink.vertex_storage, base + 8, transmute(u32)v.r)
		byte_order.write_u32_little_endian(sink.vertex_storage, base + 12, transmute(u32)v.g)
		byte_order.write_u32_little_endian(sink.vertex_storage, base + 16, transmute(u32)v.b)
		byte_order.write_u32_little_endian(sink.vertex_storage, base + 20, transmute(u32)v.a)
		byte_order.write_u32_little_endian(sink.vertex_storage, base + 24, transmute(u32)v.u)
		byte_order.write_u32_little_endian(sink.vertex_storage, base + 28, transmute(u32)v.v)
	}
	sink.vertex_count += 1
	return index, .None
}

@(private = "file")
sink_write_index :: proc "contextless" (sink: ^Translate_Sink, vertex_index: u32) -> Draw_Table_Translation_Problem {
	if sink.index_count >= sink.max_indices {
		return .Index_Buffer_Overflow
	}
	if !sink.dry_run {
		base := int(sink.index_count) * size_of(u32)
		byte_order.write_u32_little_endian(sink.index_storage, base, vertex_index)
	}
	sink.index_count += 1
	return .None
}

@(private = "file")
sink_flush_batch :: proc "contextless" (sink: ^Translate_Sink) -> Draw_Table_Translation_Problem {
	if !sink.has_batch {
		return .None
	}
	batch_count := sink.index_count - sink.batch_first_index
	if batch_count == 0 {
		sink.has_batch = false
		return .None
	}
	need_scissor := !sink.has_emitted_scissor || sink.emitted_scissor != sink.batch_scissor
	if need_scissor {
		if sink.command_count >= sink.max_commands {
			return .Command_Buffer_Overflow
		}
		if !sink.dry_run {
			sc := sink.batch_scissor
			if err := encode_set_scissor_rect(&sink.encoder, u32(sc.left), u32(sc.top), u32(sc.right - sc.left), u32(sc.bottom - sc.top)); err != .None {
				return .Command_Buffer_Overflow
			}
		}
		sink.command_count += 1
		sink.scissor_change_count += 1
		sink.has_emitted_scissor = true
		sink.emitted_scissor = sink.batch_scissor
	}
	if sink.command_count >= sink.max_commands {
		return .Command_Buffer_Overflow
	}
	if !sink.dry_run {
		if err := encode_draw_indexed(&sink.encoder, batch_count, 1, sink.batch_first_index, 0, 0); err != .None {
			return .Command_Buffer_Overflow
		}
	}
	sink.command_count += 1
	sink.has_batch = false
	return .None
}

@(private = "file")
sink_prepare_batch :: proc "contextless" (sink: ^Translate_Sink, scissor: Clip_Box) -> Draw_Table_Translation_Problem {
	if sink.has_batch && sink.batch_scissor == scissor {
		return .None
	}
	if err := sink_flush_batch(sink); err != .None {
		return err
	}
	sink.has_batch = true
	sink.batch_scissor = scissor
	sink.batch_first_index = sink.index_count
	return .None
}

@(private = "file")
sink_emit_quad :: proc "contextless" (sink: ^Translate_Sink, scissor: Clip_Box, v0, v1, v2, v3: Vertex_2D) -> Draw_Table_Translation_Problem {
	if err := sink_prepare_batch(sink, scissor); err != .None {
		return err
	}
	i0, e0 := sink_write_vertex(sink, v0)
	if e0 != .None {
		return e0
	}
	i1, e1 := sink_write_vertex(sink, v1)
	if e1 != .None {
		return e1
	}
	i2, e2 := sink_write_vertex(sink, v2)
	if e2 != .None {
		return e2
	}
	i3, e3 := sink_write_vertex(sink, v3)
	if e3 != .None {
		return e3
	}
	indices := [6]u32{i0, i1, i2, i0, i2, i3}
	for idx in indices {
		if err := sink_write_index(sink, idx); err != .None {
			return err
		}
	}
	sink.quad_count += 1
	sink.triangle_count += 2
	return .None
}

@(private = "file")
sink_emit_triangle :: proc "contextless" (sink: ^Translate_Sink, scissor: Clip_Box, v0, v1, v2: Vertex_2D) -> Draw_Table_Translation_Problem {
	if err := sink_prepare_batch(sink, scissor); err != .None {
		return err
	}
	i0, e0 := sink_write_vertex(sink, v0)
	if e0 != .None {
		return e0
	}
	i1, e1 := sink_write_vertex(sink, v1)
	if e1 != .None {
		return e1
	}
	i2, e2 := sink_write_vertex(sink, v2)
	if e2 != .None {
		return e2
	}
	if err := sink_write_index(sink, i0); err != .None {
		return err
	}
	if err := sink_write_index(sink, i1); err != .None {
		return err
	}
	if err := sink_write_index(sink, i2); err != .None {
		return err
	}
	sink.triangle_count += 1
	return .None
}

@(private = "file")
sink_emit_solid_rect_units :: proc "contextless" (sink: ^Translate_Sink, scissor: Clip_Box, left, top, right, bottom: i32, r, g, b, a: f32) -> Draw_Table_Translation_Problem {
	x0 := f32(left) / f32(draw_record.UNITS_PER_PIXEL)
	y0 := f32(top) / f32(draw_record.UNITS_PER_PIXEL)
	x1 := f32(right) / f32(draw_record.UNITS_PER_PIXEL)
	y1 := f32(bottom) / f32(draw_record.UNITS_PER_PIXEL)
	return sink_emit_quad(
		sink,
		scissor,
		Vertex_2D{x = x0, y = y0, r = r, g = g, b = b, a = a, u = 0, v = 0},
		Vertex_2D{x = x1, y = y0, r = r, g = g, b = b, a = a, u = 1, v = 0},
		Vertex_2D{x = x1, y = y1, r = r, g = g, b = b, a = a, u = 1, v = 1},
		Vertex_2D{x = x0, y = y1, r = r, g = g, b = b, a = a, u = 0, v = 1},
	)
}

@(private = "file")
sink_emit_stroke_segment :: proc "contextless" (
	sink: ^Translate_Sink,
	scissor: Clip_Box,
	x0_u, y0_u, x1_u, y1_u: i32,
	half_width_px: f32,
	r, g, b, a: f32,
) -> Draw_Table_Translation_Problem {
	x0 := f32(x0_u) / f32(draw_record.UNITS_PER_PIXEL)
	y0 := f32(y0_u) / f32(draw_record.UNITS_PER_PIXEL)
	x1 := f32(x1_u) / f32(draw_record.UNITS_PER_PIXEL)
	y1 := f32(y1_u) / f32(draw_record.UNITS_PER_PIXEL)
	dx := x1 - x0
	dy := y1 - y0
	length_sq := dx * dx + dy * dy
	if length_sq <= 1e-8 {
		return .None
	}
	inv_len := 1.0 / sqrt_f32_positive(length_sq)
	nx := -dy * inv_len * half_width_px
	ny := dx * inv_len * half_width_px
	return sink_emit_quad(
		sink,
		scissor,
		Vertex_2D{x = x0 + nx, y = y0 + ny, r = r, g = g, b = b, a = a},
		Vertex_2D{x = x1 + nx, y = y1 + ny, r = r, g = g, b = b, a = a},
		Vertex_2D{x = x1 - nx, y = y1 - ny, r = r, g = g, b = b, a = a},
		Vertex_2D{x = x0 - nx, y = y0 - ny, r = r, g = g, b = b, a = a},
	)
}

// Non-inlined so the fixed 12 KiB path-point copy stays in its own stack frame.
@(private = "file")
emit_path_primitive :: #force_no_inline proc "contextless" (
	sink: ^Translate_Sink,
	scissor: Clip_Box,
	path: draw_record.Draw_Path,
	text_bytes: []u8,
	culled: bool,
) -> Draw_Table_Translation_Problem {
	first := u64(path.first)
	count := u64(path.count)
	if first > u64(len(text_bytes)) || count > u64(len(text_bytes)) - first {
		return .Byte_Table_Out_Of_Bounds
	}
	point_count := int(path.count / draw_record.PATH_POINT_SIZE)
	raw_points: [draw_record.PATH_POINT_LIMIT]draw_record.Path_Point_Record
	for i in 0 ..< point_count {
		base := int(path.first) + i * draw_record.PATH_POINT_SIZE
		raw_points[i] = draw_record.Path_Point_Record{
			command = byte_order.read_u32_little_endian(text_bytes, base + 0),
			x       = i32(byte_order.read_u32_little_endian(text_bytes, base + 4)),
			y       = i32(byte_order.read_u32_little_endian(text_bytes, base + 8)),
		}
	}
	points: [draw_record.PATH_POINT_LIMIT]draw_record.Path_Point
	read_count, path_problem := draw_record.path_points_read(raw_points[:point_count], points[:])
	if path_problem != .None {
		return .Invalid_Path_Points
	}
	if culled || (path.fill_color == 0 && path.stroke_color == 0) {
		return .None
	}

	fill_r, fill_g, fill_b, fill_a := draw_color_to_linear_rgba(path.fill_color)
	stroke_r, stroke_g, stroke_b, stroke_a := draw_color_to_linear_rgba(path.stroke_color)
	half_stroke_px := (f32(path.stroke_width) / f32(draw_record.UNITS_PER_PIXEL)) * 0.5

	// Pass 1: fill fan triangles for each subpath when fill_color != 0.
	if path.fill_color != 0 {
		start_x: i32 = 0
		start_y: i32 = 0
		prev_x: i32 = 0
		prev_y: i32 = 0
		seg_in_subpath := 0
		has_control := false
		ctrl_x: i32 = 0
		ctrl_y: i32 = 0

		for i in 0 ..< read_count {
			pt := points[i]
			switch pt.command {
			case .Move:
				start_x, start_y = pt.x, pt.y
				prev_x, prev_y = pt.x, pt.y
				seg_in_subpath = 0
				has_control = false
			case .Curve_Control:
				ctrl_x, ctrl_y = pt.x, pt.y
				has_control = true
			case .Line:
				if has_control {
					segs := draw_record.curve_segment_count(prev_x, prev_y, ctrl_x, ctrl_y, pt.x, pt.y)
					cur_x, cur_y := prev_x, prev_y
					for step in 1 ..= segs {
						nx, ny := draw_record.curve_point(prev_x, prev_y, ctrl_x, ctrl_y, pt.x, pt.y, step, segs)
						if seg_in_subpath >= 1 {
							if err := sink_emit_triangle(
								sink,
								scissor,
								Vertex_2D{x = f32(start_x) / 64.0, y = f32(start_y) / 64.0, r = fill_r, g = fill_g, b = fill_b, a = fill_a},
								Vertex_2D{x = f32(cur_x) / 64.0, y = f32(cur_y) / 64.0, r = fill_r, g = fill_g, b = fill_b, a = fill_a},
								Vertex_2D{x = f32(nx) / 64.0, y = f32(ny) / 64.0, r = fill_r, g = fill_g, b = fill_b, a = fill_a},
							); err != .None {
								return err
							}
						}
						cur_x, cur_y = nx, ny
						seg_in_subpath += 1
					}
					prev_x, prev_y = pt.x, pt.y
					has_control = false
				} else {
					if seg_in_subpath >= 1 {
						if err := sink_emit_triangle(
							sink,
							scissor,
							Vertex_2D{x = f32(start_x) / 64.0, y = f32(start_y) / 64.0, r = fill_r, g = fill_g, b = fill_b, a = fill_a},
							Vertex_2D{x = f32(prev_x) / 64.0, y = f32(prev_y) / 64.0, r = fill_r, g = fill_g, b = fill_b, a = fill_a},
							Vertex_2D{x = f32(pt.x) / 64.0, y = f32(pt.y) / 64.0, r = fill_r, g = fill_g, b = fill_b, a = fill_a},
						); err != .None {
							return err
						}
					}
					prev_x, prev_y = pt.x, pt.y
					seg_in_subpath += 1
				}
			case .Close:
				prev_x, prev_y = start_x, start_y
				has_control = false
			}
		}
	}

	// Pass 2: stroke segment quads over fill when stroke_color != 0.
	if path.stroke_color != 0 && path.stroke_width > 0 {
		start_x: i32 = 0
		start_y: i32 = 0
		prev_x: i32 = 0
		prev_y: i32 = 0
		has_control := false
		ctrl_x: i32 = 0
		ctrl_y: i32 = 0

		for i in 0 ..< read_count {
			pt := points[i]
			switch pt.command {
			case .Move:
				start_x, start_y = pt.x, pt.y
				prev_x, prev_y = pt.x, pt.y
				has_control = false
			case .Curve_Control:
				ctrl_x, ctrl_y = pt.x, pt.y
				has_control = true
			case .Line:
				if has_control {
					segs := draw_record.curve_segment_count(prev_x, prev_y, ctrl_x, ctrl_y, pt.x, pt.y)
					cur_x, cur_y := prev_x, prev_y
					for step in 1 ..= segs {
						nx, ny := draw_record.curve_point(prev_x, prev_y, ctrl_x, ctrl_y, pt.x, pt.y, step, segs)
						if err := sink_emit_stroke_segment(sink, scissor, cur_x, cur_y, nx, ny, half_stroke_px, stroke_r, stroke_g, stroke_b, stroke_a); err != .None {
							return err
						}
						cur_x, cur_y = nx, ny
					}
					prev_x, prev_y = pt.x, pt.y
					has_control = false
				} else {
					if err := sink_emit_stroke_segment(sink, scissor, prev_x, prev_y, pt.x, pt.y, half_stroke_px, stroke_r, stroke_g, stroke_b, stroke_a); err != .None {
						return err
					}
					prev_x, prev_y = pt.x, pt.y
				}
			case .Close:
				if err := sink_emit_stroke_segment(sink, scissor, prev_x, prev_y, start_x, start_y, half_stroke_px, stroke_r, stroke_g, stroke_b, stroke_a); err != .None {
					return err
				}
				prev_x, prev_y = start_x, start_y
				has_control = false
			}
		}
	}

	return .None
}

@(private = "file")
translate_records_pass :: proc "contextless" (
	records: []draw_record.Draw_Record,
	text_bytes: []u8,
	config: Draw_Table_Translate_Config,
	root_clip: Clip_Box,
	sink: ^Translate_Sink,
) -> Draw_Table_Translation_Problem {
	clip_stack: [draw_record.CLIP_DEPTH_LIMIT + 1]Clip_Box
	clip_stack[0] = root_clip
	clip_depth := 0

	for i in 0 ..< len(records) {
		rec := draw_record.copy_once(&records[i])
		primitive, read_problem := draw_record.read(rec)
		if read_problem != .None {
			return .Invalid_Draw_Record
		}

		active_clip := clip_stack[clip_depth]
		rec_pixel_box := Clip_Box{
			left   = i32(draw_record.pixels_floor(rec.left)),
			top    = i32(draw_record.pixels_floor(rec.top)),
			right  = i32(draw_record.pixels_ceiling(rec.right)),
			bottom = i32(draw_record.pixels_ceiling(rec.bottom)),
		}
		visible_box := clip_box_intersect(active_clip, rec_pixel_box)
		culled := clip_box_empty(visible_box)

		switch prim in primitive {
		case draw_record.Draw_Nothing, draw_record.Draw_Element_Push, draw_record.Draw_Element_Pop:
			sink.skipped_records += 1

		case draw_record.Draw_Clip_Push:
			push_box := Clip_Box{
				left   = i32(draw_record.pixels_floor(rec.left)),
				top    = i32(draw_record.pixels_floor(rec.top)),
				right  = i32(draw_record.pixels_floor(rec.right)),
				bottom = i32(draw_record.pixels_floor(rec.bottom)),
			}
			clip_depth += 1
			clip_stack[clip_depth] = clip_box_intersect(active_clip, push_box)

		case draw_record.Draw_Clip_Pop:
			clip_depth -= 1

		case draw_record.Draw_Rectangle:
			if prim.color == 0 || draw_record.alpha_of(prim.color) == 0 {
				sink.skipped_records += 1
				continue
			}
			if culled {
				sink.culled_records += 1
				continue
			}
			r, g, b, a := draw_color_to_linear_rgba(prim.color)
			rep := prim.repetition
			if rep == {} || (rep.cell_width == rep.step_x && rep.cell_height == rep.step_y) {
				if err := sink_emit_solid_rect_units(sink, active_clip, rec.left, rec.top, rec.right, rec.bottom, r, g, b, a); err != .None {
					return err
				}
			} else {
				step_x := i64(rep.step_x)
				step_y := i64(rep.step_y)
				cell_w := i64(rep.cell_width)
				cell_h := i64(rep.cell_height)
				vis_left_u := i64(visible_box.left) * draw_record.UNITS_PER_PIXEL
				vis_top_u := i64(visible_box.top) * draw_record.UNITS_PER_PIXEL
				vis_right_u := i64(visible_box.right) * draw_record.UNITS_PER_PIXEL
				vis_bottom_u := i64(visible_box.bottom) * draw_record.UNITS_PER_PIXEL

				n_start := floor_div_i64(vis_left_u - i64(rep.cell_x), step_x)
				m_start := floor_div_i64(vis_top_u - i64(rep.cell_y), step_y)

				for m := m_start; ; m += 1 {
					cy0 := i64(rep.cell_y) + m * step_y
					if cy0 >= vis_bottom_u {
						break
					}
					cy1 := cy0 + cell_h
					if cy1 <= vis_top_u {
						continue
					}
					clamped_y0 := max(cy0, i64(rec.top))
					clamped_y1 := min(cy1, i64(rec.bottom))
					if clamped_y1 <= clamped_y0 {
						continue
					}
					for n := n_start; ; n += 1 {
						cx0 := i64(rep.cell_x) + n * step_x
						if cx0 >= vis_right_u {
							break
						}
						cx1 := cx0 + cell_w
						if cx1 <= vis_left_u {
							continue
						}
						clamped_x0 := max(cx0, i64(rec.left))
						clamped_x1 := min(cx1, i64(rec.right))
						if clamped_x1 <= clamped_x0 {
							continue
						}
						if err := sink_emit_solid_rect_units(sink, active_clip, i32(clamped_x0), i32(clamped_y0), i32(clamped_x1), i32(clamped_y1), r, g, b, a); err != .None {
							return err
						}
					}
				}
			}

		case draw_record.Draw_Gradient:
			if prim.start_color == 0 && prim.end_color == 0 {
				sink.skipped_records += 1
				continue
			}
			if culled {
				sink.culled_records += 1
				continue
			}
			x0 := f32(rec.left) / f32(draw_record.UNITS_PER_PIXEL)
			y0 := f32(rec.top) / f32(draw_record.UNITS_PER_PIXEL)
			x1 := f32(rec.right) / f32(draw_record.UNITS_PER_PIXEL)
			y1 := f32(rec.bottom) / f32(draw_record.UNITS_PER_PIXEL)
			r0, g0, b0, a0 := gradient_color_at_point(prim, rec.left, rec.top)
			r1, g1, b1, a1 := gradient_color_at_point(prim, rec.right, rec.top)
			r2, g2, b2, a2 := gradient_color_at_point(prim, rec.right, rec.bottom)
			r3, g3, b3, a3 := gradient_color_at_point(prim, rec.left, rec.bottom)
			if err := sink_emit_quad(
				sink,
				active_clip,
				Vertex_2D{x = x0, y = y0, r = r0, g = g0, b = b0, a = a0, u = 0, v = 0},
				Vertex_2D{x = x1, y = y0, r = r1, g = g1, b = b1, a = a1, u = 1, v = 0},
				Vertex_2D{x = x1, y = y1, r = r2, g = g2, b = b2, a = a2, u = 1, v = 1},
				Vertex_2D{x = x0, y = y1, r = r3, g = g3, b = b3, a = a3, u = 0, v = 1},
			); err != .None {
				return err
			}

		case draw_record.Draw_Text:
			if u64(prim.first) > u64(len(text_bytes)) || u64(prim.count) > u64(len(text_bytes)) - u64(prim.first) {
				return .Byte_Table_Out_Of_Bounds
			}
			if prim.count == 0 || prim.color == 0 || draw_record.alpha_of(prim.color) == 0 {
				sink.skipped_records += 1
				continue
			}
			if culled {
				sink.culled_records += 1
				continue
			}
			r, g, b, a := draw_color_to_linear_rgba(prim.color)
			if err := sink_emit_solid_rect_units(sink, active_clip, rec.left, rec.top, rec.right, rec.bottom, r, g, b, a); err != .None {
				return err
			}

		case draw_record.Draw_Picture:
			if culled {
				sink.culled_records += 1
				continue
			}
			if err := sink_emit_solid_rect_units(sink, active_clip, rec.left, rec.top, rec.right, rec.bottom, 1.0, 1.0, 1.0, 1.0); err != .None {
				return err
			}

		case draw_record.Draw_Text_Grid:
			if u64(prim.first) > u64(len(text_bytes)) || u64(prim.count) > u64(len(text_bytes)) - u64(prim.first) {
				return .Byte_Table_Out_Of_Bounds
			}
			if prim.count == 0 || prim.columns == 0 {
				sink.skipped_records += 1
				continue
			}
			if culled {
				sink.culled_records += 1
				continue
			}
			if err := sink_emit_solid_rect_units(sink, active_clip, rec.left, rec.top, rec.right, rec.bottom, 1.0, 1.0, 1.0, 1.0); err != .None {
				return err
			}

		case draw_record.Draw_Path:
			if culled {
				// Still validate path byte range and points even when culled so
				// malformed tables are consistently refused.
				if err := emit_path_primitive(sink, active_clip, prim, text_bytes, true); err != .None {
					return err
				}
				sink.culled_records += 1
				continue
			}
			if err := emit_path_primitive(sink, active_clip, prim, text_bytes, false); err != .None {
				return err
			}
		}
	}

	return sink_flush_batch(sink)
}

// draw_table_translate_to_webgpu validates a draw_record v20 table and lowers
// its visible primitives and nested clips into a validated Gpu_Command_Stream
// with tightly packed Vertex_2D and u32 index buffer data.
//
// Refuses unbalanced clips or elements, invalid or out-of-bounds draw records,
// and command/vertex/index buffer overflow without writing any byte to the
// caller's buffers.
draw_table_translate_to_webgpu :: proc "contextless" (
	records: []draw_record.Draw_Record,
	text_bytes: []u8,
	config: Draw_Table_Translate_Config,
	command_storage: []u8,
	vertex_storage: []u8,
	index_storage: []u8,
) -> (result: Draw_Table_Translate_Result, problem: Draw_Table_Translation_Problem) {
	if config.surface_width == 0 || config.surface_height == 0 {
		return {}, .Zero_Surface_Dimensions
	}
	if config.surface_width > MAX_TEXTURE_DIMENSION || config.surface_height > MAX_TEXTURE_DIMENSION {
		return {}, .Surface_Dimension_Too_Large
	}
	if config.color_texture_id == 0 || config.pipeline_id == 0 || config.vertex_buffer_id == 0 || config.index_buffer_id == 0 {
		return {}, .Zero_Object_Id
	}
	if _, load_ok := load_op_of_word(u32(config.load_op)); !load_ok {
		return {}, .Unknown_Load_Op
	}

	root_clip := Clip_Box{left = 0, top = 0, right = i32(config.surface_width), bottom = i32(config.surface_height)}
	if config.has_damage_rect {
		dmg := config.damage_rect
		if dmg.width == 0 || dmg.height == 0 {
			return {}, .Damage_Rect_Out_Of_Bounds
		}
		if u64(dmg.x) + u64(dmg.width) > u64(config.surface_width) || u64(dmg.y) + u64(dmg.height) > u64(config.surface_height) {
			return {}, .Damage_Rect_Out_Of_Bounds
		}
		root_clip = Clip_Box{
			left   = i32(dmg.x),
			top    = i32(dmg.y),
			right  = i32(dmg.x + dmg.width),
			bottom = i32(dmg.y + dmg.height),
		}
	}

	// Unified clip and semantic element order border check.
	if order_problem, _ := draw_record.table_order_check(records); order_problem != .None {
		return {}, .Unbalanced_Clips_Or_Elements
	}

	max_commands_in_buf := u32(min(len(command_storage) / COMMAND_RECORD_SIZE, MAX_COMMAND_STREAM_COMMANDS))
	max_vertices_in_buf := u32(len(vertex_storage) / size_of(Vertex_2D))
	max_indices_in_buf := u32(len(index_storage) / size_of(u32))

	// Phase 1: full dry-run validation and exact command/vertex/index counting.
	dry_sink := Translate_Sink{
		dry_run      = true,
		max_vertices = max_vertices_in_buf,
		max_indices  = max_indices_in_buf,
		max_commands = max_commands_in_buf,
	}
	if err := translate_records_pass(records, text_bytes, config, root_clip, &dry_sink); err != .None {
		return {}, err
	}

	// Reserve fixed overhead commands:
	//   empty geometry: Begin_Render_Pass + End_Render_Pass (2 commands)
	//   non-empty geometry: Begin_Render_Pass + Set_Pipeline + Set_Vertex_Buffer + Set_Index_Buffer + End_Render_Pass (5 commands)
	overhead_commands: u32 = dry_sink.index_count > 0 ? 5 : 2
	total_commands := overhead_commands + dry_sink.command_count
	if total_commands > max_commands_in_buf {
		return {}, .Command_Buffer_Overflow
	}

	// Phase 2: all validation and capacity checks passed; emit cleanly.
	emit_sink := Translate_Sink{
		dry_run        = false,
		max_vertices   = max_vertices_in_buf,
		max_indices    = max_indices_in_buf,
		max_commands   = max_commands_in_buf,
		encoder        = encoder_init(command_storage),
		vertex_storage = vertex_storage,
		index_storage  = index_storage,
	}

	if err := encode_begin_render_pass(&emit_sink.encoder, config.color_texture_id, 0, config.load_op, .Store, config.clear_color); err != .None {
		return {}, .Command_Buffer_Overflow
	}
	emit_sink.command_count += 1

	if dry_sink.index_count > 0 {
		vertex_bytes := u64(dry_sink.vertex_count) * u64(size_of(Vertex_2D))
		index_bytes := u64(dry_sink.index_count) * u64(size_of(u32))
		if err := encode_set_pipeline(&emit_sink.encoder, config.pipeline_id); err != .None {
			return {}, .Command_Buffer_Overflow
		}
		if err := encode_set_vertex_buffer(&emit_sink.encoder, 0, config.vertex_buffer_id, 0, vertex_bytes); err != .None {
			return {}, .Command_Buffer_Overflow
		}
		if err := encode_set_index_buffer(&emit_sink.encoder, config.index_buffer_id, .Uint32, 0, index_bytes); err != .None {
			return {}, .Command_Buffer_Overflow
		}
		emit_sink.command_count += 3
	}

	if err := translate_records_pass(records, text_bytes, config, root_clip, &emit_sink); err != .None {
		return {}, err
	}

	if err := encode_end_render_pass(&emit_sink.encoder); err != .None {
		return {}, .Command_Buffer_Overflow
	}
	emit_sink.command_count += 1

	return Draw_Table_Translate_Result{
		stream               = encoder_finish(&emit_sink.encoder),
		vertex_bytes_used    = int(emit_sink.vertex_count) * size_of(Vertex_2D),
		index_bytes_used     = int(emit_sink.index_count) * size_of(u32),
		vertex_count         = emit_sink.vertex_count,
		index_count          = emit_sink.index_count,
		quad_count           = emit_sink.quad_count,
		triangle_count       = emit_sink.triangle_count,
		scissor_change_count = emit_sink.scissor_change_count,
		skipped_records      = emit_sink.skipped_records,
		culled_records       = emit_sink.culled_records,
	}, .None
}

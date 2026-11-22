// Processor 3D and 2D rasterizer backend for the WebGPU subset contract
// (src/md/features/gpu_access.md, "The WebGPU of the system").
//
// Executes a validated Gpu_Command_Stream directly into caller-owned RGBA/BGRA
// color framebuffers and u32 Depth24_Plus depth buffers using two built-in
// freestanding shader modes:
// - Solid_Color_2D: pixel-space 2D vertices with linear-light RGBA colors.
// - Vertex_Color_3D: 3D vertices transformed by a 4x4 column-major MVP matrix
//   with perspective divide, edge-function triangle rasterization, top-left
//   fill rule, strict '<' 24-bit depth testing, scissor clipping, and
//   linear-light gamma-2 alpha blending.
//
// Triangles have a scalar form and an SSE2 vector form of four pixels side by
// side, which give the same bytes; on amd64 the vector form runs
// (docs/SIMD.md, "1. The rule of the same bytes").
//
// All backing buffers, textures, pipeline shader bindings, and indexed vertex
// lookups are validated before any pixel or buffer byte is modified.
// This file allocates no memory and calls no kernel operation.
package webgpu_subset

import "base:intrinsics"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Maximum representable 24-bit depth value (represents NDC z = 1.0).
DEPTH24_MAX :: u32(0x00FF_FFFF)

// Byte size of one column-major 4x4 f32 matrix uniform.
MATRIX_4X4_BYTES :: 64

// Closed set of built-in freestanding shader modes for the processor backend.
Software_Shader_Mode :: enum u32 {
	None            = 0,
	Solid_Color_2D  = 1,
	Vertex_Color_3D = 2,
}

// 32-byte 3D vertex for Vertex_Color_3D pipelines. Colors are linear-light
// RGB (gamma 2) with straight alpha in [0.0, 1.0].
Vertex_3D :: struct {
	x:   f32,
	y:   f32,
	z:   f32,
	r:   f32,
	g:   f32,
	b:   f32,
	a:   f32,
	pad: f32,
}

#assert(size_of(Vertex_3D) == 32)
VERTEX_3D_STRIDE :: u32(size_of(Vertex_3D))

// Column-major 4x4 transform matrix: element at (col, row) is m[col*4 + row].
Matrix_4x4 :: [16]f32

// Caller-provided backing memory for one declared Texture_Desc.
// Color textures use color_bytes; Depth24_Plus textures use depth_values.
Software_Texture_Memory :: struct {
	color_bytes:  []u8,
	depth_values: []u32,
}

// Complete caller-owned execution context for software_3d_execute.
Software_Device :: struct {
	resources:           Resource_Registry,
	buffers:             [][]u8,
	textures:            []Software_Texture_Memory,
	pipeline_shaders:    []Software_Shader_Mode,
	bind_group_uniforms: []u32, // Optional 1-based buffer ID per bind group holding a 64-byte Matrix_4x4 MVP.
}

// Summary returned by a successful software_3d_execute run.
Software_Execution_Summary :: struct {
	stream:               Stream_Summary,
	triangles_rasterized: u64,
	pixels_shaded:        u64,
}

// software_shader_mode_of_word is the one border from a u32 word to Software_Shader_Mode.
software_shader_mode_of_word :: proc "contextless" (word: u32) -> (mode: Software_Shader_Mode, ok: bool) {
	decoded, found := enum_word.member_of_word(Software_Shader_Mode, u64(word))
	if !found || decoded == .None {
		return .None, false
	}
	return decoded, true
}

// Matrix helpers (column-major, right-handed WebGPU NDC z in [0, 1]).

matrix_4x4_identity :: proc "contextless" () -> Matrix_4x4 {
	return Matrix_4x4{
		1, 0, 0, 0,
		0, 1, 0, 0,
		0, 0, 1, 0,
		0, 0, 0, 1,
	}
}

matrix_4x4_translate :: proc "contextless" (tx, ty, tz: f32) -> Matrix_4x4 {
	return Matrix_4x4{
		1,  0,  0,  0,
		0,  1,  0,  0,
		0,  0,  1,  0,
		tx, ty, tz, 1,
	}
}

matrix_4x4_scale :: proc "contextless" (sx, sy, sz: f32) -> Matrix_4x4 {
	return Matrix_4x4{
		sx, 0,  0,  0,
		0,  sy, 0,  0,
		0,  0,  sz, 0,
		0,  0,  0,  1,
	}
}

// matrix_4x4_perspective_zero_to_one builds a right-handed perspective matrix
// mapping z in [-near, -far] to WebGPU NDC z in [0, 1].
// fov_cotangent is 1 / tan(fov_y / 2).
matrix_4x4_perspective_zero_to_one :: proc "contextless" (fov_cotangent, aspect, near, far: f32) -> Matrix_4x4 {
	if aspect <= 0.0 || near <= 0.0 || far <= near {
		return matrix_4x4_identity()
	}
	m: Matrix_4x4
	m[0] = fov_cotangent / aspect
	m[5] = fov_cotangent
	m[10] = far / (near - far)
	m[11] = -1.0
	m[14] = (near * far) / (near - far)
	return m
}

matrix_4x4_multiply :: proc "contextless" (a, b: Matrix_4x4) -> Matrix_4x4 {
	out: Matrix_4x4
	for col in 0 ..< 4 {
		for row in 0 ..< 4 {
			sum: f32 = 0.0
			for k in 0 ..< 4 {
				sum += a[k * 4 + row] * b[col * 4 + k]
			}
			out[col * 4 + row] = sum
		}
	}
	return out
}

matrix_4x4_encode :: proc "contextless" (m: Matrix_4x4, destination: []u8, offset: int = 0) -> bool {
	if offset < 0 || offset > len(destination) || len(destination) - offset < MATRIX_4X4_BYTES {
		return false
	}
	for i in 0 ..< 16 {
		byte_order.write_u32_little_endian(destination, offset + i * 4, transmute(u32)m[i])
	}
	return true
}

matrix_4x4_decode :: proc "contextless" (source: []u8, offset: int = 0) -> Matrix_4x4 {
	m: Matrix_4x4
	for i in 0 ..< 16 {
		m[i] = transmute(f32)byte_order.read_u32_little_endian(source, offset + i * 4)
	}
	return m
}

vertex_3d_encode :: proc "contextless" (v: Vertex_3D, destination: []u8, offset: int) -> bool {
	if offset < 0 || offset > len(destination) || len(destination) - offset < size_of(Vertex_3D) {
		return false
	}
	byte_order.write_u32_little_endian(destination, offset + 0, transmute(u32)v.x)
	byte_order.write_u32_little_endian(destination, offset + 4, transmute(u32)v.y)
	byte_order.write_u32_little_endian(destination, offset + 8, transmute(u32)v.z)
	byte_order.write_u32_little_endian(destination, offset + 12, transmute(u32)v.r)
	byte_order.write_u32_little_endian(destination, offset + 16, transmute(u32)v.g)
	byte_order.write_u32_little_endian(destination, offset + 20, transmute(u32)v.b)
	byte_order.write_u32_little_endian(destination, offset + 24, transmute(u32)v.a)
	byte_order.write_u32_little_endian(destination, offset + 28, transmute(u32)v.pad)
	return true
}

@(private = "file")
vertex_2d_decode :: proc "contextless" (source: []u8, offset: int) -> Vertex_2D {
	return Vertex_2D{
		x = transmute(f32)byte_order.read_u32_little_endian(source, offset + 0),
		y = transmute(f32)byte_order.read_u32_little_endian(source, offset + 4),
		r = transmute(f32)byte_order.read_u32_little_endian(source, offset + 8),
		g = transmute(f32)byte_order.read_u32_little_endian(source, offset + 12),
		b = transmute(f32)byte_order.read_u32_little_endian(source, offset + 16),
		a = transmute(f32)byte_order.read_u32_little_endian(source, offset + 20),
		u = transmute(f32)byte_order.read_u32_little_endian(source, offset + 24),
		v = transmute(f32)byte_order.read_u32_little_endian(source, offset + 28),
	}
}

@(private = "file")
vertex_3d_decode :: proc "contextless" (source: []u8, offset: int) -> Vertex_3D {
	return Vertex_3D{
		x   = transmute(f32)byte_order.read_u32_little_endian(source, offset + 0),
		y   = transmute(f32)byte_order.read_u32_little_endian(source, offset + 4),
		z   = transmute(f32)byte_order.read_u32_little_endian(source, offset + 8),
		r   = transmute(f32)byte_order.read_u32_little_endian(source, offset + 12),
		g   = transmute(f32)byte_order.read_u32_little_endian(source, offset + 16),
		b   = transmute(f32)byte_order.read_u32_little_endian(source, offset + 20),
		a   = transmute(f32)byte_order.read_u32_little_endian(source, offset + 24),
		pad = transmute(f32)byte_order.read_u32_little_endian(source, offset + 28),
	}
}

@(private = "file")
f32_is_finite :: proc "contextless" (value: f32) -> bool {
	bits := transmute(u32)value
	return (bits & 0x7F80_0000) != 0x7F80_0000
}

@(private = "file")
clamp_unit :: proc "contextless" (value: f32) -> f32 {
	if !f32_is_finite(value) || value <= 0.0 {
		return 0.0
	}
	if value >= 1.0 {
		return 1.0
	}
	return value
}

@(private = "file")
sqrt_f32 :: proc "contextless" (value: f32) -> f32 {
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
linear_to_encoded_u8 :: proc "contextless" (linear: f32) -> u8 {
	clamped := clamp_unit(linear)
	encoded := sqrt_f32(clamped) * 255.0 + 0.5
	if encoded >= 255.0 {
		return 255
	}
	if encoded <= 0.0 {
		return 0
	}
	return u8(encoded)
}

@(private = "file")
alpha_to_u8 :: proc "contextless" (alpha: f32) -> u8 {
	clamped := clamp_unit(alpha) * 255.0 + 0.5
	if clamped >= 255.0 {
		return 255
	}
	if clamped <= 0.0 {
		return 0
	}
	return u8(clamped)
}

@(private = "file")
encoded_u8_to_linear :: proc "contextless" (channel: u8) -> f32 {
	n := f32(channel) / 255.0
	return n * n
}

@(private = "file")
blend_factor_eval :: proc "contextless" (factor: Blend_Factor, src_a, dst_a: f32) -> f32 {
	switch factor {
	case .Zero:
		return 0.0
	case .One:
		return 1.0
	case .Src_Alpha:
		return src_a
	case .One_Minus_Src_Alpha:
		return 1.0 - src_a
	case .Dst_Alpha:
		return dst_a
	case .One_Minus_Dst_Alpha:
		return 1.0 - dst_a
	}
	return 0.0
}

@(private = "file")
Screen_Vertex :: struct {
	x:     f32, // Viewport pixel X
	y:     f32, // Viewport pixel Y
	z:     f32, // NDC depth in [0.0, 1.0]
	inv_w: f32, // 1 / clip.w (1.0 for 2D)
	r:     f32, // Linear-light R * inv_w
	g:     f32, // Linear-light G * inv_w
	b:     f32, // Linear-light B * inv_w
	a:     f32, // Straight alpha * inv_w
	valid: bool,
}

@(private = "file")
shade_vertex :: proc "contextless" (
	mode: Software_Shader_Mode,
	vertex_bytes: []u8,
	vertex_offset: int,
	mvp: Matrix_4x4,
	pass_width, pass_height: u32,
) -> Screen_Vertex {
	switch mode {
	case .None:
		return {}

	case .Solid_Color_2D:
		v := vertex_2d_decode(vertex_bytes, vertex_offset)
		if !f32_is_finite(v.x) || !f32_is_finite(v.y) {
			return {}
		}
		return Screen_Vertex{
			x     = v.x,
			y     = v.y,
			z     = 0.0,
			inv_w = 1.0,
			r     = clamp_unit(v.r),
			g     = clamp_unit(v.g),
			b     = clamp_unit(v.b),
			a     = clamp_unit(v.a),
			valid = true,
		}

	case .Vertex_Color_3D:
		v := vertex_3d_decode(vertex_bytes, vertex_offset)
		if !f32_is_finite(v.x) || !f32_is_finite(v.y) || !f32_is_finite(v.z) {
			return {}
		}
		cx := mvp[0] * v.x + mvp[4] * v.y + mvp[8] * v.z + mvp[12]
		cy := mvp[1] * v.x + mvp[5] * v.y + mvp[9] * v.z + mvp[13]
		cz := mvp[2] * v.x + mvp[6] * v.y + mvp[10] * v.z + mvp[14]
		cw := mvp[3] * v.x + mvp[7] * v.y + mvp[11] * v.z + mvp[15]
		if !f32_is_finite(cx) || !f32_is_finite(cy) || !f32_is_finite(cz) || !f32_is_finite(cw) {
			return {}
		}
		if cw <= 1e-6 {
			return {}
		}
		inv_w := 1.0 / cw
		ndc_x := cx * inv_w
		ndc_y := cy * inv_w
		ndc_z := cz * inv_w
		return Screen_Vertex{
			x     = (ndc_x * 0.5 + 0.5) * f32(pass_width),
			y     = (0.5 - ndc_y * 0.5) * f32(pass_height),
			z     = ndc_z,
			inv_w = inv_w,
			r     = clamp_unit(v.r) * inv_w,
			g     = clamp_unit(v.g) * inv_w,
			b     = clamp_unit(v.b) * inv_w,
			a     = clamp_unit(v.a) * inv_w,
			valid = true,
		}
	}
	return {}
}

@(private = "file")
edge_function :: proc "contextless" (ax, ay, bx, by, px, py: f32) -> f32 {
	return (bx - ax) * (py - ay) - (by - ay) * (px - ax)
}

// In Y-down viewport space with positive triangle area, a top edge goes left
// to right (by == ay && bx > ax) and a left edge goes upward (by < ay).
@(private = "file")
is_top_left_edge :: proc "contextless" (ax, ay, bx, by: f32) -> bool {
	return (by < ay) || (by == ay && bx > ax)
}

@(private = "file")
write_fragment_pixel :: proc "contextless" (
	color_bytes: []u8,
	depth_values: []u32,
	has_depth: bool,
	format: Texture_Format,
	pipeline: Pipeline_Desc,
	pixel_index: int,
	z: f32,
	src_r, src_g, src_b, src_a: f32,
) -> bool {
	if z < 0.0 || z > 1.0 {
		return false
	}
	if pipeline.src_blend == .Src_Alpha && pipeline.dst_blend == .One_Minus_Src_Alpha && src_a <= 0.0 {
		return false
	}

	depth_u24: u32 = 0
	if has_depth {
		depth_f := z * f32(DEPTH24_MAX) + 0.5
		if depth_f < 0.0 {
			depth_u24 = 0
		} else if depth_f > f32(DEPTH24_MAX) {
			depth_u24 = DEPTH24_MAX
		} else {
			depth_u24 = u32(depth_f)
		}
		if depth_u24 >= depth_values[pixel_index] {
			return false
		}
	}

	opaque_replace := (pipeline.src_blend == .One && pipeline.dst_blend == .Zero) ||
		(pipeline.src_blend == .Src_Alpha && pipeline.dst_blend == .One_Minus_Src_Alpha && src_a >= 1.0)

	out_r: u8
	out_g: u8
	out_b: u8
	out_a: u8

	switch format {
	case .None, .Depth24_Plus:
		return false

	case .R8_Unorm:
		if opaque_replace {
			out_r = linear_to_encoded_u8(src_r)
		} else {
			dst_r := encoded_u8_to_linear(color_bytes[pixel_index])
			sf := blend_factor_eval(pipeline.src_blend, src_a, 1.0)
			df := blend_factor_eval(pipeline.dst_blend, src_a, 1.0)
			out_r = linear_to_encoded_u8(src_r * sf + dst_r * df)
		}
		color_bytes[pixel_index] = out_r

	case .RGBA8_Unorm, .RGBA8_Unorm_Srgb:
		base := pixel_index * 4
		if opaque_replace {
			out_r = linear_to_encoded_u8(src_r)
			out_g = linear_to_encoded_u8(src_g)
			out_b = linear_to_encoded_u8(src_b)
			out_a = alpha_to_u8(src_a)
		} else {
			dst_r := encoded_u8_to_linear(color_bytes[base + 0])
			dst_g := encoded_u8_to_linear(color_bytes[base + 1])
			dst_b := encoded_u8_to_linear(color_bytes[base + 2])
			dst_a := f32(color_bytes[base + 3]) / 255.0
			sf := blend_factor_eval(pipeline.src_blend, src_a, dst_a)
			df := blend_factor_eval(pipeline.dst_blend, src_a, dst_a)
			out_r = linear_to_encoded_u8(src_r * sf + dst_r * df)
			out_g = linear_to_encoded_u8(src_g * sf + dst_g * df)
			out_b = linear_to_encoded_u8(src_b * sf + dst_b * df)
			out_a = alpha_to_u8(src_a * sf + dst_a * df)
		}
		color_bytes[base + 0] = out_r
		color_bytes[base + 1] = out_g
		color_bytes[base + 2] = out_b
		color_bytes[base + 3] = out_a

	case .BGRA8_Unorm:
		base := pixel_index * 4
		if opaque_replace {
			out_r = linear_to_encoded_u8(src_r)
			out_g = linear_to_encoded_u8(src_g)
			out_b = linear_to_encoded_u8(src_b)
			out_a = alpha_to_u8(src_a)
		} else {
			dst_b := encoded_u8_to_linear(color_bytes[base + 0])
			dst_g := encoded_u8_to_linear(color_bytes[base + 1])
			dst_r := encoded_u8_to_linear(color_bytes[base + 2])
			dst_a := f32(color_bytes[base + 3]) / 255.0
			sf := blend_factor_eval(pipeline.src_blend, src_a, dst_a)
			df := blend_factor_eval(pipeline.dst_blend, src_a, dst_a)
			out_r = linear_to_encoded_u8(src_r * sf + dst_r * df)
			out_g = linear_to_encoded_u8(src_g * sf + dst_g * df)
			out_b = linear_to_encoded_u8(src_b * sf + dst_b * df)
			out_a = alpha_to_u8(src_a * sf + dst_a * df)
		}
		color_bytes[base + 0] = out_b
		color_bytes[base + 1] = out_g
		color_bytes[base + 2] = out_r
		color_bytes[base + 3] = out_a
	}

	if has_depth {
		depth_values[pixel_index] = depth_u24
	}
	return true
}

@(private = "file")
floor_to_i32 :: proc "contextless" (value: f32) -> i32 {
	i := i32(value)
	if f32(i) > value {
		i -= 1
	}
	return i
}

@(private = "file")
ceil_to_i32 :: proc "contextless" (value: f32) -> i32 {
	i := i32(value)
	if f32(i) < value {
		i += 1
	}
	return i
}

// The two forms of the triangle rasterizer. The vector form gives the bytes
// of the scalar form for every triangle:
// (docs/SIMD.md, "1. The rule of the same bytes").
// The host tests run each stream in each form and compare the color bytes,
// the depth values and the counts.
@(private)
Rasterizer_Form :: enum u8 {
	Scalar,
	Vector,
}

// SSE2 is in every x86-64 processor (docs/SIMD.md, "2. One form: SSE2"), so
// the form is chosen at compile time, with no test of the processor.
@(private)
RASTERIZER_FORM_OF_TARGET :: Rasterizer_Form.Vector when ODIN_ARCH == .amd64 else Rasterizer_Form.Scalar

// Where the fragments of one draw go.
@(private = "file")
Fragment_Target :: struct {
	color_bytes:  []u8,
	depth_values: []u32,
	has_depth:    bool,
	format:       Texture_Format,
	pipeline:     Pipeline_Desc,
	pass_width:   u32,
}

// The values of a triangle that stay the same across its pixels, and the
// pixels that it can cover inside the scissor rectangle.
@(private = "file")
Triangle_Setup :: struct {
	v0:           Screen_Vertex,
	v1:           Screen_Vertex,
	v2:           Screen_Vertex,
	inverse_area: f32,
	top_left_0:   bool,
	top_left_1:   bool,
	top_left_2:   bool,
	min_x:        i32,
	max_x:        i32,
	min_y:        i32,
	max_y:        i32,
}

// triangle_setup orders the vertices for a positive area and clips the box of
// the triangle to the scissor rectangle. It refuses an invalid vertex, a
// degenerate triangle and a triangle with no pixel inside the scissor.
@(private = "file")
triangle_setup :: proc "contextless" (
	v0_in, v1_in, v2_in: Screen_Vertex,
	scissor_x0, scissor_y0, scissor_x1, scissor_y1: i32,
) -> (setup: Triangle_Setup, ok: bool) {
	if !v0_in.valid || !v1_in.valid || !v2_in.valid {
		return {}, false
	}
	v0 := v0_in
	v1 := v1_in
	v2 := v2_in

	area := edge_function(v0.x, v0.y, v1.x, v1.y, v2.x, v2.y)
	if !f32_is_finite(area) {
		return {}, false
	}
	if area > -1e-6 && area < 1e-6 {
		return {}, false
	}
	if area < 0.0 {
		v1, v2 = v2, v1
		area = -area
	}

	min_xf := min(v0.x, min(v1.x, v2.x))
	max_xf := max(v0.x, max(v1.x, v2.x))
	min_yf := min(v0.y, min(v1.y, v2.y))
	max_yf := max(v0.y, max(v1.y, v2.y))

	if max_xf <= f32(scissor_x0) || min_xf >= f32(scissor_x1) || max_yf <= f32(scissor_y0) || min_yf >= f32(scissor_y1) {
		return {}, false
	}

	setup.min_x = max(scissor_x0, floor_to_i32(min_xf))
	setup.max_x = min(scissor_x1, ceil_to_i32(max_xf))
	setup.min_y = max(scissor_y0, floor_to_i32(min_yf))
	setup.max_y = min(scissor_y1, ceil_to_i32(max_yf))
	if setup.min_x >= setup.max_x || setup.min_y >= setup.max_y {
		return {}, false
	}

	setup.v0 = v0
	setup.v1 = v1
	setup.v2 = v2
	setup.top_left_0 = is_top_left_edge(v1.x, v1.y, v2.x, v2.y)
	setup.top_left_1 = is_top_left_edge(v2.x, v2.y, v0.x, v0.y)
	setup.top_left_2 = is_top_left_edge(v0.x, v0.y, v1.x, v1.y)
	setup.inverse_area = 1.0 / area
	return setup, true
}

// shade_triangle_pixel is the scalar form for one pixel: the reference of the
// vector form, and the code of the last columns of a row that do not fill a
// group of four.
@(private = "file")
shade_triangle_pixel :: proc "contextless" (setup: ^Triangle_Setup, target: ^Fragment_Target, px: i32, cy: f32, row_base: int) -> bool {
	v0 := setup.v0
	v1 := setup.v1
	v2 := setup.v2
	cx := f32(px) + 0.5
	w0 := edge_function(v1.x, v1.y, v2.x, v2.y, cx, cy)
	if w0 < 0.0 || (w0 == 0.0 && !setup.top_left_0) {
		return false
	}
	w1 := edge_function(v2.x, v2.y, v0.x, v0.y, cx, cy)
	if w1 < 0.0 || (w1 == 0.0 && !setup.top_left_1) {
		return false
	}
	w2 := edge_function(v0.x, v0.y, v1.x, v1.y, cx, cy)
	if w2 < 0.0 || (w2 == 0.0 && !setup.top_left_2) {
		return false
	}

	b0 := w0 * setup.inverse_area
	b1 := w1 * setup.inverse_area
	b2 := w2 * setup.inverse_area

	z := b0 * v0.z + b1 * v1.z + b2 * v2.z
	interp_inv_w := b0 * v0.inv_w + b1 * v1.inv_w + b2 * v2.inv_w
	if interp_inv_w <= 1e-12 {
		return false
	}
	w_corr := 1.0 / interp_inv_w
	src_r := (b0 * v0.r + b1 * v1.r + b2 * v2.r) * w_corr
	src_g := (b0 * v0.g + b1 * v1.g + b2 * v2.g) * w_corr
	src_b := (b0 * v0.b + b1 * v1.b + b2 * v2.b) * w_corr
	src_a := (b0 * v0.a + b1 * v1.a + b2 * v2.a) * w_corr

	return write_fragment_pixel(target.color_bytes, target.depth_values, target.has_depth, target.format, target.pipeline, row_base + int(px), z, src_r, src_g, src_b, src_a)
}

// rasterize_triangle_scalar is the reference form: one pixel at a time.
@(private = "file")
rasterize_triangle_scalar :: proc "contextless" (setup: ^Triangle_Setup, target: ^Fragment_Target) -> (pixels_shaded: u64) {
	for py := setup.min_y; py < setup.max_y; py += 1 {
		cy := f32(py) + 0.5
		row_base := int(py) * int(target.pass_width)
		for px := setup.min_x; px < setup.max_x; px += 1 {
			if shade_triangle_pixel(setup, target, px, cy, row_base) {
				pixels_shaded += 1
			}
		}
	}
	return pixels_shaded
}

// One lane for each of four adjacent pixels of a row: 128 bits, one SSE2
// register.
@(private = "file")
Four_Floats :: #simd[4]f32
@(private = "file")
Four_Integers :: #simd[4]i32
// All bits set in a lane that is refused, all clear in a lane that is kept.
@(private = "file")
Four_Masks :: #simd[4]u32

@(private = "file")
four_of :: #force_inline proc "contextless" (value: f32) -> Four_Floats {
	return Four_Floats{value, value, value, value}
}

// edge_refusal is the test of the scalar form for one edge, written as the
// refusal and not as its negation: a NaN fails both comparisons, so the
// scalar form keeps such a pixel, and this form must keep it too.
@(private = "file")
edge_refusal :: #force_inline proc "contextless" (edge_values: Four_Floats, top_left: bool) -> Four_Masks {
	negative := intrinsics.simd_lanes_lt(edge_values, four_of(0.0))
	if top_left {
		return negative
	}
	return intrinsics.simd_bit_or(negative, intrinsics.simd_lanes_eq(edge_values, four_of(0.0)))
}

// rasterize_triangle_simd is the vector form: the edge values, the coverage
// test and the interpolation of four adjacent pixels in the lanes of one
// register. Each lane does the operations of shade_triangle_pixel in the same
// order, with no fused multiply-add, so each lane holds the bits of the
// scalar form. The depth test and the blend stay one pixel at a time, in lane
// order, with write_fragment_pixel. The columns after the last group of four
// go through shade_triangle_pixel.
@(private = "file")
rasterize_triangle_simd :: proc "contextless" (setup: ^Triangle_Setup, target: ^Fragment_Target) -> (pixels_shaded: u64) {
	v0 := setup.v0
	v1 := setup.v1
	v2 := setup.v2

	// The terms of edge_function that depend on the edge only.
	edge_0_dx := v2.x - v1.x
	edge_0_dy := four_of(v2.y - v1.y)
	edge_1_dx := v0.x - v2.x
	edge_1_dy := four_of(v0.y - v2.y)
	edge_2_dx := v1.x - v0.x
	edge_2_dy := four_of(v1.y - v0.y)
	edge_0_ax := four_of(v1.x)
	edge_1_ax := four_of(v2.x)
	edge_2_ax := four_of(v0.x)

	inverse_area := four_of(setup.inverse_area)
	v0_z, v1_z, v2_z := four_of(v0.z), four_of(v1.z), four_of(v2.z)
	v0_inv_w, v1_inv_w, v2_inv_w := four_of(v0.inv_w), four_of(v1.inv_w), four_of(v2.inv_w)
	v0_r, v1_r, v2_r := four_of(v0.r), four_of(v1.r), four_of(v2.r)
	v0_g, v1_g, v2_g := four_of(v0.g), four_of(v1.g), four_of(v2.g)
	v0_b, v1_b, v2_b := four_of(v0.b), four_of(v1.b), four_of(v2.b)
	v0_a, v1_a, v2_a := four_of(v0.a), four_of(v1.a), four_of(v2.a)
	lane_steps := Four_Integers{0, 1, 2, 3}

	for py := setup.min_y; py < setup.max_y; py += 1 {
		cy := f32(py) + 0.5
		row_base := int(py) * int(target.pass_width)
		// The products of edge_function that depend on the row only.
		row_0 := four_of(edge_0_dx * (cy - v1.y))
		row_1 := four_of(edge_1_dx * (cy - v2.y))
		row_2 := four_of(edge_2_dx * (cy - v0.y))

		px := setup.min_x
		for ; setup.max_x - px >= 4; px += 4 {
			cx := cast(Four_Floats)(Four_Integers{px, px, px, px} + lane_steps) + four_of(0.5)
			w0 := row_0 - edge_0_dy * (cx - edge_0_ax)
			w1 := row_1 - edge_1_dy * (cx - edge_1_ax)
			w2 := row_2 - edge_2_dy * (cx - edge_2_ax)
			refused := intrinsics.simd_bit_or(
				intrinsics.simd_bit_or(edge_refusal(w0, setup.top_left_0), edge_refusal(w1, setup.top_left_1)),
				edge_refusal(w2, setup.top_left_2),
			)
			if intrinsics.simd_reduce_and(refused) != 0 {
				continue
			}

			b0 := w0 * inverse_area
			b1 := w1 * inverse_area
			b2 := w2 * inverse_area
			z := b0 * v0_z + b1 * v1_z + b2 * v2_z
			interp_inv_w := b0 * v0_inv_w + b1 * v1_inv_w + b2 * v2_inv_w
			refused = intrinsics.simd_bit_or(refused, intrinsics.simd_lanes_le(interp_inv_w, four_of(1e-12)))
			if intrinsics.simd_reduce_and(refused) != 0 {
				continue
			}
			// A refused lane divides 1 by 1: its value is never read, and no
			// lane divides by zero.
			w_corr := four_of(1.0) / intrinsics.simd_select(refused, four_of(1.0), interp_inv_w)
			src_r := (b0 * v0_r + b1 * v1_r + b2 * v2_r) * w_corr
			src_g := (b0 * v0_g + b1 * v1_g + b2 * v2_g) * w_corr
			src_b := (b0 * v0_b + b1 * v1_b + b2 * v2_b) * w_corr
			src_a := (b0 * v0_a + b1 * v1_a + b2 * v2_a) * w_corr

			refused_lanes := transmute([4]u32)refused
			z_lanes := transmute([4]f32)z
			r_lanes := transmute([4]f32)src_r
			g_lanes := transmute([4]f32)src_g
			b_lanes := transmute([4]f32)src_b
			a_lanes := transmute([4]f32)src_a
			for lane in 0 ..< 4 {
				if refused_lanes[lane] != 0 {
					continue
				}
				if write_fragment_pixel(target.color_bytes, target.depth_values, target.has_depth, target.format, target.pipeline, row_base + int(px) + lane, z_lanes[lane], r_lanes[lane], g_lanes[lane], b_lanes[lane], a_lanes[lane]) {
					pixels_shaded += 1
				}
			}
		}
		for ; px < setup.max_x; px += 1 {
			if shade_triangle_pixel(setup, target, px, cy, row_base) {
				pixels_shaded += 1
			}
		}
	}
	return pixels_shaded
}

@(private = "file")
rasterize_triangle :: proc "contextless" (
	form: Rasterizer_Form,
	v0, v1, v2: Screen_Vertex,
	color_bytes: []u8,
	depth_values: []u32,
	has_depth: bool,
	format: Texture_Format,
	pipeline: Pipeline_Desc,
	pass_width: u32,
	scissor_x0, scissor_y0, scissor_x1, scissor_y1: i32,
) -> (rasterized: bool, pixels_shaded: u64) {
	setup, ok := triangle_setup(v0, v1, v2, scissor_x0, scissor_y0, scissor_x1, scissor_y1)
	if !ok {
		return false, 0
	}
	target := Fragment_Target{
		color_bytes  = color_bytes,
		depth_values = depth_values,
		has_depth    = has_depth,
		format       = format,
		pipeline     = pipeline,
		pass_width   = pass_width,
	}
	switch form {
	case .Scalar:
		return true, rasterize_triangle_scalar(&setup, &target)
	case .Vector:
		return true, rasterize_triangle_simd(&setup, &target)
	}
	return false, 0
}

@(private = "file")
rasterize_line :: proc "contextless" (
	v0, v1: Screen_Vertex,
	color_bytes: []u8,
	depth_values: []u32,
	has_depth: bool,
	format: Texture_Format,
	pipeline: Pipeline_Desc,
	pass_width: u32,
	scissor_x0, scissor_y0, scissor_x1, scissor_y1: i32,
) -> (pixels_shaded: u64) {
	if !v0.valid || !v1.valid {
		return 0
	}
	dx := v1.x - v0.x
	dy := v1.y - v0.y
	abs_dx := dx < 0.0 ? -dx : dx
	abs_dy := dy < 0.0 ? -dy : dy
	steps_f := max(abs_dx, abs_dy)
	steps := int(steps_f + 1.0)
	if steps <= 0 {
		return 0
	}
	max_steps := int(pass_width) * 4 + 4
	if steps > max_steps {
		steps = max_steps
	}
	for s in 0 ..= steps {
		t := steps > 0 ? f32(s) / f32(steps) : 0.0
		px := floor_to_i32(v0.x + dx * t)
		py := floor_to_i32(v0.y + dy * t)
		if px < scissor_x0 || px >= scissor_x1 || py < scissor_y0 || py >= scissor_y1 {
			continue
		}
		z := v0.z + (v1.z - v0.z) * t
		inv_w := v0.inv_w + (v1.inv_w - v0.inv_w) * t
		if inv_w <= 1e-12 {
			continue
		}
		w_corr := 1.0 / inv_w
		src_r := (v0.r + (v1.r - v0.r) * t) * w_corr
		src_g := (v0.g + (v1.g - v0.g) * t) * w_corr
		src_b := (v0.b + (v1.b - v0.b) * t) * w_corr
		src_a := (v0.a + (v1.a - v0.a) * t) * w_corr
		if write_fragment_pixel(color_bytes, depth_values, has_depth, format, pipeline, int(py) * int(pass_width) + int(px), z, src_r, src_g, src_b, src_a) {
			pixels_shaded += 1
		}
	}
	return pixels_shaded
}

@(private = "file")
read_index_value :: proc "contextless" (index_bytes: []u8, format: Index_Format, index_slot: u32) -> u32 {
	switch format {
	case .None:
		return 0
	case .Uint16:
		return u32(byte_order.read_u16_little_endian(index_bytes, int(index_slot) * 2))
	case .Uint32:
		return byte_order.read_u32_little_endian(index_bytes, int(index_slot) * 4)
	}
	return 0
}

// Pre-validates all backing buffers, textures, shader modes, uniform bindings,
// and every Draw_Indexed index value against the bound vertex buffer before
// software_3d_execute touches any output byte.
@(private = "file")
software_device_and_indices_validate :: proc "contextless" (stream: Gpu_Command_Stream, device: Software_Device) -> Gpu_Refusal {
	res := device.resources
	if len(device.buffers) != len(res.buffers) {
		return .Backing_Buffer_Too_Small
	}
	for desc, i in res.buffers {
		if u64(len(device.buffers[i])) < desc.size {
			return .Backing_Buffer_Too_Small
		}
	}

	if len(device.textures) != len(res.textures) {
		return .Backing_Texture_Too_Small
	}
	for desc, i in res.textures {
		pixel_count := u64(desc.width) * u64(desc.height)
		if desc.format == .Depth24_Plus {
			if u64(len(device.textures[i].depth_values)) < pixel_count {
				return .Backing_Texture_Too_Small
			}
		} else {
			bpp := u64(texture_format_bytes_per_pixel(desc.format))
			if bpp == 0 || u64(len(device.textures[i].color_bytes)) < pixel_count * bpp {
				return .Backing_Texture_Too_Small
			}
		}
	}

	if len(device.pipeline_shaders) != len(res.pipelines) {
		return .Shader_Mode_Invalid
	}
	for mode, i in device.pipeline_shaders {
		decoded, mode_ok := software_shader_mode_of_word(u32(mode))
		if !mode_ok {
			return .Shader_Mode_Invalid
		}
		min_stride: u32 = 0
		switch decoded {
		case .None:
			return .Shader_Mode_Invalid
		case .Solid_Color_2D:
			min_stride = VERTEX_2D_STRIDE
		case .Vertex_Color_3D:
			min_stride = VERTEX_3D_STRIDE
		}
		if res.pipelines[i].vertex_stride < min_stride {
			return .Vertex_Stride_Too_Small
		}
	}

	if len(device.bind_group_uniforms) > 0 {
		if len(device.bind_group_uniforms) != int(res.bind_group_count) {
			return .Backing_Buffer_Too_Small
		}
		for buf_id in device.bind_group_uniforms {
			if buf_id == 0 {
				continue
			}
			if int(buf_id) > len(res.buffers) {
				return .Object_Id_Out_Of_Range
			}
			buf_desc := res.buffers[buf_id - 1]
			if .Uniform not_in buf_desc.usage {
				return .Missing_Usage_Flag
			}
			if buf_desc.size < MATRIX_4X4_BYTES {
				return .Backing_Buffer_Too_Small
			}
		}
	}

	// Verify all Draw_Indexed index entries resolve inside the bound vertex buffer.
	active_stride: u64 = 0
	vb_size: u64 = 0
	ib_buf_id: u32 = 0
	ib_format: Index_Format = .None
	ib_offset: u64 = 0

	record_count := len(stream.bytes) / COMMAND_RECORD_SIZE
	for i in 0 ..< record_count {
		rec := stream.bytes[i * COMMAND_RECORD_SIZE : (i + 1) * COMMAND_RECORD_SIZE]
		kind, _ := gpu_command_kind_of_word(byte_order.read_u32_little_endian(rec, 0))
		switch kind {
		case .None, .Begin_Render_Pass, .Set_Bind_Group, .Set_Scissor_Rect, .Draw, .End_Render_Pass, .Copy_Buffer_To_Buffer, .Copy_Buffer_To_Texture:
			if kind == .Begin_Render_Pass || kind == .End_Render_Pass {
				active_stride = 0
				vb_size = 0
				ib_buf_id = 0
				ib_format = .None
				ib_offset = 0
			}
		case .Set_Pipeline:
			pid := byte_order.read_u32_little_endian(rec, 8)
			active_stride = u64(res.pipelines[pid - 1].vertex_stride)
		case .Set_Vertex_Buffer:
			slot := byte_order.read_u32_little_endian(rec, 8)
			if slot == 0 {
				vb_size = byte_order.read_u64_little_endian(rec, 24)
			}
		case .Set_Index_Buffer:
			ib_buf_id = byte_order.read_u32_little_endian(rec, 8)
			ib_format, _ = index_format_of_word(byte_order.read_u32_little_endian(rec, 12))
			ib_offset = byte_order.read_u64_little_endian(rec, 16)
		case .Draw_Indexed:
			index_count := byte_order.read_u32_little_endian(rec, 8)
			first_index := byte_order.read_u32_little_endian(rec, 16)
			base_vertex := i32(byte_order.read_u32_little_endian(rec, 20))
			index_slice := device.buffers[ib_buf_id - 1][ib_offset:]
			for k in 0 ..< index_count {
				raw_idx := read_index_value(index_slice, ib_format, first_index + k)
				resolved := i64(raw_idx) + i64(base_vertex)
				if resolved < 0 {
					return .Index_Value_Out_Of_Bounds
				}
				v_end := (u64(resolved) + 1) * active_stride
				if v_end > vb_size {
					return .Index_Value_Out_Of_Bounds
				}
			}
		}
	}

	return .None
}

// software_3d_execute validates and executes a WebGPU subset command stream on
// the processor. Refuses invalid streams, undersized backing buffers or
// textures, invalid shader modes, or out-of-bounds vertex indices without
// modifying any pixel or buffer byte.
software_3d_execute :: proc "contextless" (stream: Gpu_Command_Stream, device: Software_Device) -> (summary: Software_Execution_Summary, refusal: Gpu_Refusal) {
	return software_3d_execute_in_form(stream, device, RASTERIZER_FORM_OF_TARGET)
}

// software_3d_execute_in_form lets the host tests run one stream in each form
// of the triangle rasterizer.
@(private)
software_3d_execute_in_form :: proc "contextless" (stream: Gpu_Command_Stream, device: Software_Device, form: Rasterizer_Form) -> (summary: Software_Execution_Summary, refusal: Gpu_Refusal) {
	stream_summary, val_refusal := stream_validate(stream, device.resources)
	if val_refusal != .None {
		return {}, val_refusal
	}
	if dev_refusal := software_device_and_indices_validate(stream, device); dev_refusal != .None {
		return {}, dev_refusal
	}

	summary.stream = stream_summary
	res := device.resources

	// Active render-pass state.
	color_tex_id: u32 = 0
	depth_tex_id: u32 = 0
	pass_width: u32 = 0
	pass_height: u32 = 0
	pass_format: Texture_Format = .None
	scissor_x0: i32 = 0
	scissor_y0: i32 = 0
	scissor_x1: i32 = 0
	scissor_y1: i32 = 0

	pipeline_id: u32 = 0
	vb_buf_id: u32 = 0
	vb_offset: u64 = 0
	ib_buf_id: u32 = 0
	ib_format: Index_Format = .None
	ib_offset: u64 = 0
	active_mvp := matrix_4x4_identity()

	record_count := len(stream.bytes) / COMMAND_RECORD_SIZE
	for i in 0 ..< record_count {
		rec := stream.bytes[i * COMMAND_RECORD_SIZE : (i + 1) * COMMAND_RECORD_SIZE]
		kind, _ := gpu_command_kind_of_word(byte_order.read_u32_little_endian(rec, 0))

		switch kind {
		case .None:
			return {}, .Unknown_Command_Kind

		case .Copy_Buffer_To_Buffer:
			src_id := byte_order.read_u32_little_endian(rec, 8)
			dst_id := byte_order.read_u32_little_endian(rec, 12)
			src_off := int(byte_order.read_u64_little_endian(rec, 16))
			dst_off := int(byte_order.read_u64_little_endian(rec, 24))
			size := int(byte_order.read_u64_little_endian(rec, 32))
			copy(device.buffers[dst_id - 1][dst_off : dst_off + size], device.buffers[src_id - 1][src_off : src_off + size])

		case .Copy_Buffer_To_Texture:
			src_id := byte_order.read_u32_little_endian(rec, 8)
			dst_tex_id := byte_order.read_u32_little_endian(rec, 12)
			src_off := int(byte_order.read_u64_little_endian(rec, 16))
			bytes_per_row := int(byte_order.read_u32_little_endian(rec, 24))
			dst_x := int(byte_order.read_u32_little_endian(rec, 28))
			dst_y := int(byte_order.read_u32_little_endian(rec, 32))
			width := int(byte_order.read_u32_little_endian(rec, 36))
			height := int(byte_order.read_u32_little_endian(rec, 40))
			tex_desc := res.textures[dst_tex_id - 1]
			bpp := int(texture_format_bytes_per_pixel(tex_desc.format))
			dst_stride := int(tex_desc.width) * bpp
			row_bytes := width * bpp
			src_buf := device.buffers[src_id - 1]
			dst_buf := device.textures[dst_tex_id - 1].color_bytes
			for row in 0 ..< height {
				s_start := src_off + row * bytes_per_row
				d_start := (dst_y + row) * dst_stride + dst_x * bpp
				copy(dst_buf[d_start : d_start + row_bytes], src_buf[s_start : s_start + row_bytes])
			}

		case .Begin_Render_Pass:
			color_tex_id = byte_order.read_u32_little_endian(rec, 8)
			depth_tex_id = byte_order.read_u32_little_endian(rec, 12)
			load_op, _ := load_op_of_word(byte_order.read_u32_little_endian(rec, 16))
			color_desc := res.textures[color_tex_id - 1]
			pass_width = color_desc.width
			pass_height = color_desc.height
			pass_format = color_desc.format
			scissor_x0 = 0
			scissor_y0 = 0
			scissor_x1 = i32(pass_width)
			scissor_y1 = i32(pass_height)
			pipeline_id = 0
			vb_buf_id = 0
			vb_offset = 0
			ib_buf_id = 0
			ib_format = .None
			ib_offset = 0
			active_mvp = matrix_4x4_identity()

			if load_op == .Clear {
				cr := linear_to_encoded_u8(transmute(f32)byte_order.read_u32_little_endian(rec, 24))
				cg := linear_to_encoded_u8(transmute(f32)byte_order.read_u32_little_endian(rec, 28))
				cb := linear_to_encoded_u8(transmute(f32)byte_order.read_u32_little_endian(rec, 32))
				ca := alpha_to_u8(transmute(f32)byte_order.read_u32_little_endian(rec, 36))
				pixel_count := int(pass_width) * int(pass_height)
				color_bytes := device.textures[color_tex_id - 1].color_bytes
				switch pass_format {
				case .None, .Depth24_Plus:
				case .R8_Unorm:
					for p in 0 ..< pixel_count {
						color_bytes[p] = cr
					}
				case .RGBA8_Unorm, .RGBA8_Unorm_Srgb:
					for p in 0 ..< pixel_count {
						base := p * 4
						color_bytes[base + 0] = cr
						color_bytes[base + 1] = cg
						color_bytes[base + 2] = cb
						color_bytes[base + 3] = ca
					}
				case .BGRA8_Unorm:
					for p in 0 ..< pixel_count {
						base := p * 4
						color_bytes[base + 0] = cb
						color_bytes[base + 1] = cg
						color_bytes[base + 2] = cr
						color_bytes[base + 3] = ca
					}
				}
				if depth_tex_id != 0 {
					depth_values := device.textures[depth_tex_id - 1].depth_values
					for p in 0 ..< pixel_count {
						depth_values[p] = DEPTH24_MAX
					}
				}
			}

		case .Set_Pipeline:
			pipeline_id = byte_order.read_u32_little_endian(rec, 8)

		case .Set_Vertex_Buffer:
			slot := byte_order.read_u32_little_endian(rec, 8)
			if slot == 0 {
				vb_buf_id = byte_order.read_u32_little_endian(rec, 12)
				vb_offset = byte_order.read_u64_little_endian(rec, 16)
			}

		case .Set_Index_Buffer:
			ib_buf_id = byte_order.read_u32_little_endian(rec, 8)
			ib_format, _ = index_format_of_word(byte_order.read_u32_little_endian(rec, 12))
			ib_offset = byte_order.read_u64_little_endian(rec, 16)

		case .Set_Bind_Group:
			slot := byte_order.read_u32_little_endian(rec, 8)
			bg_id := byte_order.read_u32_little_endian(rec, 12)
			if slot == 0 && len(device.bind_group_uniforms) > 0 {
				u_buf_id := device.bind_group_uniforms[bg_id - 1]
				if u_buf_id != 0 {
					active_mvp = matrix_4x4_decode(device.buffers[u_buf_id - 1], 0)
				} else {
					active_mvp = matrix_4x4_identity()
				}
			}

		case .Set_Scissor_Rect:
			sx := byte_order.read_u32_little_endian(rec, 8)
			sy := byte_order.read_u32_little_endian(rec, 12)
			sw := byte_order.read_u32_little_endian(rec, 16)
			sh := byte_order.read_u32_little_endian(rec, 20)
			scissor_x0 = i32(sx)
			scissor_y0 = i32(sy)
			scissor_x1 = i32(sx + sw)
			scissor_y1 = i32(sy + sh)

		case .Draw:
			vertex_count := byte_order.read_u32_little_endian(rec, 8)
			first_vertex := byte_order.read_u32_little_endian(rec, 16)
			pipe := res.pipelines[pipeline_id - 1]
			shader := device.pipeline_shaders[pipeline_id - 1]
			v_slice := device.buffers[vb_buf_id - 1][vb_offset:]
			color_bytes := device.textures[color_tex_id - 1].color_bytes
			depth_values: []u32
			has_depth := depth_tex_id != 0
			if has_depth {
				depth_values = device.textures[depth_tex_id - 1].depth_values
			}
			stride := int(pipe.vertex_stride)

			switch pipe.topology {
			case .None:
			case .Triangle_List:
				for base := u32(0); base + 2 < vertex_count; base += 3 {
					sv0 := shade_vertex(shader, v_slice, int(first_vertex + base + 0) * stride, active_mvp, pass_width, pass_height)
					sv1 := shade_vertex(shader, v_slice, int(first_vertex + base + 1) * stride, active_mvp, pass_width, pass_height)
					sv2 := shade_vertex(shader, v_slice, int(first_vertex + base + 2) * stride, active_mvp, pass_width, pass_height)
					drawn, shaded := rasterize_triangle(form, sv0, sv1, sv2, color_bytes, depth_values, has_depth, pass_format, pipe, pass_width, scissor_x0, scissor_y0, scissor_x1, scissor_y1)
					if drawn {
						summary.triangles_rasterized += 1
						summary.pixels_shaded += shaded
					}
				}
			case .Triangle_Strip:
				for base := u32(0); base + 2 < vertex_count; base += 1 {
					sv0 := shade_vertex(shader, v_slice, int(first_vertex + base + 0) * stride, active_mvp, pass_width, pass_height)
					sv1 := shade_vertex(shader, v_slice, int(first_vertex + base + 1) * stride, active_mvp, pass_width, pass_height)
					sv2 := shade_vertex(shader, v_slice, int(first_vertex + base + 2) * stride, active_mvp, pass_width, pass_height)
					drawn, shaded := rasterize_triangle(form, sv0, sv1, sv2, color_bytes, depth_values, has_depth, pass_format, pipe, pass_width, scissor_x0, scissor_y0, scissor_x1, scissor_y1)
					if drawn {
						summary.triangles_rasterized += 1
						summary.pixels_shaded += shaded
					}
				}
			case .Line_List:
				for base := u32(0); base + 1 < vertex_count; base += 2 {
					sv0 := shade_vertex(shader, v_slice, int(first_vertex + base + 0) * stride, active_mvp, pass_width, pass_height)
					sv1 := shade_vertex(shader, v_slice, int(first_vertex + base + 1) * stride, active_mvp, pass_width, pass_height)
					summary.pixels_shaded += rasterize_line(sv0, sv1, color_bytes, depth_values, has_depth, pass_format, pipe, pass_width, scissor_x0, scissor_y0, scissor_x1, scissor_y1)
				}
			}

		case .Draw_Indexed:
			index_count := byte_order.read_u32_little_endian(rec, 8)
			first_index := byte_order.read_u32_little_endian(rec, 16)
			base_vertex := i32(byte_order.read_u32_little_endian(rec, 20))
			pipe := res.pipelines[pipeline_id - 1]
			shader := device.pipeline_shaders[pipeline_id - 1]
			v_slice := device.buffers[vb_buf_id - 1][vb_offset:]
			i_slice := device.buffers[ib_buf_id - 1][ib_offset:]
			color_bytes := device.textures[color_tex_id - 1].color_bytes
			depth_values: []u32
			has_depth := depth_tex_id != 0
			if has_depth {
				depth_values = device.textures[depth_tex_id - 1].depth_values
			}
			stride := int(pipe.vertex_stride)

			switch pipe.topology {
			case .None:
			case .Triangle_List:
				for base := u32(0); base + 2 < index_count; base += 3 {
					i0 := int(i64(read_index_value(i_slice, ib_format, first_index + base + 0)) + i64(base_vertex))
					i1 := int(i64(read_index_value(i_slice, ib_format, first_index + base + 1)) + i64(base_vertex))
					i2 := int(i64(read_index_value(i_slice, ib_format, first_index + base + 2)) + i64(base_vertex))
					sv0 := shade_vertex(shader, v_slice, i0 * stride, active_mvp, pass_width, pass_height)
					sv1 := shade_vertex(shader, v_slice, i1 * stride, active_mvp, pass_width, pass_height)
					sv2 := shade_vertex(shader, v_slice, i2 * stride, active_mvp, pass_width, pass_height)
					drawn, shaded := rasterize_triangle(form, sv0, sv1, sv2, color_bytes, depth_values, has_depth, pass_format, pipe, pass_width, scissor_x0, scissor_y0, scissor_x1, scissor_y1)
					if drawn {
						summary.triangles_rasterized += 1
						summary.pixels_shaded += shaded
					}
				}
			case .Triangle_Strip:
				for base := u32(0); base + 2 < index_count; base += 1 {
					i0 := int(i64(read_index_value(i_slice, ib_format, first_index + base + 0)) + i64(base_vertex))
					i1 := int(i64(read_index_value(i_slice, ib_format, first_index + base + 1)) + i64(base_vertex))
					i2 := int(i64(read_index_value(i_slice, ib_format, first_index + base + 2)) + i64(base_vertex))
					sv0 := shade_vertex(shader, v_slice, i0 * stride, active_mvp, pass_width, pass_height)
					sv1 := shade_vertex(shader, v_slice, i1 * stride, active_mvp, pass_width, pass_height)
					sv2 := shade_vertex(shader, v_slice, i2 * stride, active_mvp, pass_width, pass_height)
					drawn, shaded := rasterize_triangle(form, sv0, sv1, sv2, color_bytes, depth_values, has_depth, pass_format, pipe, pass_width, scissor_x0, scissor_y0, scissor_x1, scissor_y1)
					if drawn {
						summary.triangles_rasterized += 1
						summary.pixels_shaded += shaded
					}
				}
			case .Line_List:
				for base := u32(0); base + 1 < index_count; base += 2 {
					i0 := int(i64(read_index_value(i_slice, ib_format, first_index + base + 0)) + i64(base_vertex))
					i1 := int(i64(read_index_value(i_slice, ib_format, first_index + base + 1)) + i64(base_vertex))
					sv0 := shade_vertex(shader, v_slice, i0 * stride, active_mvp, pass_width, pass_height)
					sv1 := shade_vertex(shader, v_slice, i1 * stride, active_mvp, pass_width, pass_height)
					summary.pixels_shaded += rasterize_line(sv0, sv1, color_bytes, depth_values, has_depth, pass_format, pipe, pass_width, scissor_x0, scissor_y0, scissor_x1, scissor_y1)
				}
			}

		case .End_Render_Pass:
			color_tex_id = 0
			depth_tex_id = 0
			pass_width = 0
			pass_height = 0
			pass_format = .None
		}
	}

	return summary, .None
}

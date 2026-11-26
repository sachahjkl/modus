#+build !freestanding
#+build !modus
package webgpu_subset

import "core:fmt"
import "core:math"
import "core:testing"
import "core:time"
import "modus:contract/byte_order"

// The speed measure runs only with -define:MEASURE=true: a test checks no
// speed, it prints it.
MEASURE :: #config(MEASURE, false)

// The widths around a group of four pixels, and a width of one pixel.
@(private = "file")
FORM_TEST_WIDTHS :: [?]u32{1, 3, 5, 17, 63, 64, 65}

@(private = "file")
FORM_TEST_COLOR_FORMATS :: [?]Texture_Format{.RGBA8_Unorm, .BGRA8_Unorm, .R8_Unorm}

// A generator with a fixed seed, so each host gets the same inputs.
@(private = "file")
Generator :: struct {
	state: u64,
}

@(private = "file")
next_word :: proc(generator: ^Generator) -> u64 {
	x := generator.state
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	generator.state = x
	return x
}

// next_unit gives a value in [0, 1).
@(private = "file")
next_unit :: proc(generator: ^Generator) -> f32 {
	return f32(next_word(generator) >> 40) / f32(1 << 24)
}

@(private = "file")
next_between :: proc(generator: ^Generator, low, high: f32) -> f32 {
	return low + (high - low) * next_unit(generator)
}

// One scene: the declared resources, their backing buffers, the stream, and
// whether the color and depth textures start with random content (a pass with
// Load_Op.Load then blends over it and tests against it).
@(private = "file")
Form_Scene :: struct {
	registry:            Resource_Registry,
	buffers:             [][]u8,
	shaders:             []Software_Shader_Mode,
	bind_group_uniforms: []u32,
	stream:              Gpu_Command_Stream,
	start_seed:          u64,
}

// The outputs of one run of a scene in one form.
@(private = "file")
Form_Run :: struct {
	textures: []Software_Texture_Memory,
	summary:  Software_Execution_Summary,
	refusal:  Gpu_Refusal,
}

@(private = "file")
form_run :: proc(scene: Form_Scene, form: Rasterizer_Form) -> (run: Form_Run) {
	generator := Generator{state = scene.start_seed | 1}
	run.textures = make([]Software_Texture_Memory, len(scene.registry.textures))
	for desc, i in scene.registry.textures {
		pixel_count := int(desc.width) * int(desc.height)
		if desc.format == .Depth24_Plus {
			run.textures[i].depth_values = make([]u32, pixel_count)
			for &value in run.textures[i].depth_values {
				value = u32(next_word(&generator)) & DEPTH24_MAX
			}
		} else {
			run.textures[i].color_bytes = make([]u8, pixel_count * int(texture_format_bytes_per_pixel(desc.format)))
			for &value in run.textures[i].color_bytes {
				value = u8(next_word(&generator))
			}
		}
	}
	run.summary, run.refusal = software_3d_execute_in_form(scene.stream, Software_Device{
		resources           = scene.registry,
		buffers             = scene.buffers,
		textures            = run.textures,
		pipeline_shaders    = scene.shaders,
		bind_group_uniforms = scene.bind_group_uniforms,
	}, form)
	return run
}

@(private = "file")
form_run_delete :: proc(run: Form_Run) {
	for memory in run.textures {
		delete(memory.color_bytes)
		delete(memory.depth_values)
	}
	delete(run.textures)
}

// expect_forms_give_the_same_bytes runs the scene in the scalar form and in the
// vector form, and compares each color byte, each depth value and the summary.
// It gives the first wrong place and the value of each form.
@(private = "file")
expect_forms_give_the_same_bytes :: proc(t: ^testing.T, scene: Form_Scene, label: string, loc := #caller_location) -> (scalar_summary: Software_Execution_Summary) {
	scalar := form_run(scene, .Scalar)
	defer form_run_delete(scalar)
	vector := form_run(scene, .Vector)
	defer form_run_delete(vector)

	testing.expectf(t, scalar.refusal == .None, "%s: the scalar form refused the scene: %v", label, scalar.refusal, loc = loc)
	testing.expectf(t, vector.refusal == scalar.refusal, "%s: the scalar form gave %v, the vector form %v", label, scalar.refusal, vector.refusal, loc = loc)
	testing.expectf(t, vector.summary == scalar.summary, "%s: the scalar form gave %v, the vector form %v", label, scalar.summary, vector.summary, loc = loc)
	for i in 0 ..< len(scalar.textures) {
		scalar_color := scalar.textures[i].color_bytes
		vector_color := vector.textures[i].color_bytes
		for j in 0 ..< len(scalar_color) {
			if scalar_color[j] != vector_color[j] {
				testing.expectf(t, false, "%s: texture %d, color byte %d: the scalar form gave %d, the vector form %d", label, i + 1, j, scalar_color[j], vector_color[j], loc = loc)
				break
			}
		}
		scalar_depth := scalar.textures[i].depth_values
		vector_depth := vector.textures[i].depth_values
		for j in 0 ..< len(scalar_depth) {
			if scalar_depth[j] != vector_depth[j] {
				testing.expectf(t, false, "%s: texture %d, depth value %d: the scalar form gave %x, the vector form %x", label, i + 1, j, scalar_depth[j], vector_depth[j], loc = loc)
				break
			}
		}
	}
	return scalar.summary
}

@(private = "file")
vertex_2d_write :: proc(destination: []u8, index: int, x, y, r, g, b, a: f32) {
	offset := index * int(VERTEX_2D_STRIDE)
	byte_order.write_u32_little_endian(destination, offset + 0, transmute(u32)x)
	byte_order.write_u32_little_endian(destination, offset + 4, transmute(u32)y)
	byte_order.write_u32_little_endian(destination, offset + 8, transmute(u32)r)
	byte_order.write_u32_little_endian(destination, offset + 12, transmute(u32)g)
	byte_order.write_u32_little_endian(destination, offset + 16, transmute(u32)b)
	byte_order.write_u32_little_endian(destination, offset + 20, transmute(u32)a)
	byte_order.write_u32_little_endian(destination, offset + 24, 0)
	byte_order.write_u32_little_endian(destination, offset + 28, 0)
}

// matrix_4x4_rotation_y and matrix_4x4_rotation_x take an angle in turns.
@(private = "file")
matrix_4x4_rotation_y :: proc(angle_turns: f32) -> Matrix_4x4 {
	// core:math takes radians.
	c := math.cos(angle_turns * math.TAU)
	s := math.sin(angle_turns * math.TAU)
	return Matrix_4x4{
		c, 0, -s, 0,
		0, 1, 0,  0,
		s, 0, c,  0,
		0, 0, 0,  1,
	}
}

@(private = "file")
matrix_4x4_rotation_x :: proc(angle_turns: f32) -> Matrix_4x4 {
	// core:math takes radians.
	c := math.cos(angle_turns * math.TAU)
	s := math.sin(angle_turns * math.TAU)
	return Matrix_4x4{
		1, 0,  0, 0,
		0, c,  s, 0,
		0, -s, c, 0,
		0, 0,  0, 1,
	}
}

// The eight corners of a cube of side 2 and the 36 indices of its 12 triangles.
@(private = "file")
CUBE_CORNERS :: [8][3]f32{
	{-1, -1, -1}, {1, -1, -1}, {1, 1, -1}, {-1, 1, -1},
	{-1, -1, 1}, {1, -1, 1}, {1, 1, 1}, {-1, 1, 1},
}

@(private = "file")
CUBE_INDICES :: [36]u16{
	0, 2, 1, 0, 3, 2, // back
	4, 5, 6, 4, 6, 7, // front
	0, 1, 5, 0, 5, 4, // bottom
	3, 7, 6, 3, 6, 2, // top
	0, 4, 7, 0, 7, 3, // left
	1, 2, 6, 1, 6, 5, // right
}

// The cube, turned and seen in perspective, drawn with its 24-bit depth buffer.
// A width or a height of one pixel puts the cube partly off the screen.
@(private = "file")
cube_scene_check :: proc(t: ^testing.T, width, height: u32, format: Texture_Format, angle_turns: f32, load_op: Load_Op, seed: u64) -> (pixels_shaded: u64) {
	vertex_bytes: [8 * size_of(Vertex_3D)]u8
	corners := CUBE_CORNERS
	for corner, i in corners {
		_ = vertex_3d_encode(Vertex_3D{
			x = corner[0], y = corner[1], z = corner[2],
			r = 0.5 + 0.5 * corner[0], g = 0.5 + 0.5 * corner[1], b = 0.5 + 0.5 * corner[2], a = 1.0,
		}, vertex_bytes[:], i * size_of(Vertex_3D))
	}
	index_bytes: [36 * 2]u8
	indices := CUBE_INDICES
	for index, i in indices {
		byte_order.write_u16_little_endian(index_bytes[:], i * 2, index)
	}
	model := matrix_4x4_multiply(matrix_4x4_rotation_y(angle_turns), matrix_4x4_rotation_x(angle_turns * 0.37 + 0.05))
	view := matrix_4x4_translate(0.1, -0.05, -4.0)
	projection := matrix_4x4_perspective_zero_to_one(1.7, f32(width) / f32(height), 0.5, 20.0)
	mvp := matrix_4x4_multiply(projection, matrix_4x4_multiply(view, model))
	uniform_bytes: [MATRIX_4X4_BYTES]u8
	_ = matrix_4x4_encode(mvp, uniform_bytes[:], 0)

	buffers := [?]Buffer_Desc{
		{size = u64(len(vertex_bytes)), usage = {.Vertex}},
		{size = u64(len(index_bytes)), usage = {.Index}},
		{size = u64(len(uniform_bytes)), usage = {.Uniform}},
	}
	textures := [?]Texture_Desc{
		{width = width, height = height, format = format, usage = {.Render_Attachment}},
		{width = width, height = height, format = .Depth24_Plus, usage = {.Render_Attachment}},
	}
	pipelines := [?]Pipeline_Desc{
		{topology = .Triangle_List, color_format = format, src_blend = .One, dst_blend = .Zero, vertex_stride = VERTEX_3D_STRIDE},
	}
	command_bytes: [COMMAND_RECORD_SIZE * 8]u8
	encoder := encoder_init(command_bytes[:])
	_ = encode_begin_render_pass(&encoder, 1, 2, load_op, .Store, Clear_Color{r_bits = transmute(u32)f32(0.1), a_bits = transmute(u32)f32(1.0)})
	_ = encode_set_pipeline(&encoder, 1)
	_ = encode_set_vertex_buffer(&encoder, 0, 1, 0, u64(len(vertex_bytes)))
	_ = encode_set_index_buffer(&encoder, 2, .Uint16, 0, u64(len(index_bytes)))
	_ = encode_set_bind_group(&encoder, 0, 1)
	_ = encode_draw_indexed(&encoder, 36, 1, 0, 0, 0)
	_ = encode_end_render_pass(&encoder)

	backing := [?][]u8{vertex_bytes[:], index_bytes[:], uniform_bytes[:]}
	shaders := [?]Software_Shader_Mode{.Vertex_Color_3D}
	uniforms := [?]u32{3}
	label := fmt.tprintf("cube %dx%d %v at %.3f turns, %v", width, height, format, angle_turns, load_op)
	summary := expect_forms_give_the_same_bytes(t, Form_Scene{
		registry            = Resource_Registry{buffers = buffers[:], textures = textures[:], pipelines = pipelines[:], bind_group_count = 1},
		buffers             = backing[:],
		shaders             = shaders[:],
		bind_group_uniforms = uniforms[:],
		stream              = encoder_finish(&encoder),
		start_seed          = seed,
	}, label)
	return summary.pixels_shaded
}

@(test)
cube_forms_give_the_same_bytes :: proc(t: ^testing.T) {
	ANGLES :: [?]f32{0.0, 0.0625, 0.125, 0.2, 0.33, 0.5, 0.71, 0.9}
	seed := u64(0x9E37_79B9_7F4A_7C15)
	total_shaded: u64 = 0
	for width in FORM_TEST_WIDTHS {
		for height in ([?]u32{1, 37}) {
			for format in FORM_TEST_COLOR_FORMATS {
				for angle in ANGLES {
					for load_op in ([?]Load_Op{.Clear, .Load}) {
						seed += 1
						total_shaded += cube_scene_check(t, width, height, format, angle, load_op, seed)
					}
				}
			}
		}
	}
	// A comparison of two empty pictures proves nothing.
	testing.expect(t, total_shaded > 10_000, "the cubes must shade pixels")
}

// Six translucent triangles that overlap in depth, with an alpha for each
// vertex from 0 to 1, blended over random content with and without a depth
// buffer, and some vertices behind the eye.
@(test)
blended_triangle_forms_give_the_same_bytes :: proc(t: ^testing.T) {
	TRIANGLES :: 6
	generator := Generator{state = 0x2545_F491_4F6C_DD1D}
	total_shaded: u64 = 0
	for width in FORM_TEST_WIDTHS {
		for format in FORM_TEST_COLOR_FORMATS {
			for with_depth in ([?]bool{false, true}) {
				for round in 0 ..< 4 {
					vertex_bytes: [TRIANGLES * 3 * size_of(Vertex_3D)]u8
					for i in 0 ..< TRIANGLES * 3 {
						// One vertex in 16 goes behind the eye: its triangle is refused whole.
						behind := next_word(&generator) % 16 == 0
						_ = vertex_3d_encode(Vertex_3D{
							x = next_between(&generator, -2.5, 2.5),
							y = next_between(&generator, -2.5, 2.5),
							z = behind ? 1.0 : next_between(&generator, -6.0, -1.2),
							r = next_unit(&generator),
							g = next_unit(&generator),
							b = next_unit(&generator),
							a = next_between(&generator, -0.1, 1.1),
						}, vertex_bytes[:], i * size_of(Vertex_3D))
					}
					height := u32(9 + round * 11)
					mvp := matrix_4x4_perspective_zero_to_one(1.2, f32(width) / f32(height), 1.0, 10.0)
					uniform_bytes: [MATRIX_4X4_BYTES]u8
					_ = matrix_4x4_encode(mvp, uniform_bytes[:], 0)

					buffers := [?]Buffer_Desc{
						{size = u64(len(vertex_bytes)), usage = {.Vertex}},
						{size = u64(len(uniform_bytes)), usage = {.Uniform}},
					}
					textures := [?]Texture_Desc{
						{width = width, height = height, format = format, usage = {.Render_Attachment}},
						{width = width, height = height, format = .Depth24_Plus, usage = {.Render_Attachment}},
					}
					pipelines := [?]Pipeline_Desc{
						{topology = .Triangle_List, color_format = format, src_blend = .Src_Alpha, dst_blend = .One_Minus_Src_Alpha, vertex_stride = VERTEX_3D_STRIDE},
					}
					command_bytes: [COMMAND_RECORD_SIZE * 8]u8
					encoder := encoder_init(command_bytes[:])
					_ = encode_begin_render_pass(&encoder, 1, with_depth ? 2 : 0, .Load, .Store)
					_ = encode_set_pipeline(&encoder, 1)
					_ = encode_set_vertex_buffer(&encoder, 0, 1, 0, u64(len(vertex_bytes)))
					_ = encode_set_bind_group(&encoder, 0, 1)
					_ = encode_draw(&encoder, TRIANGLES * 3, 1, 0, 0)
					_ = encode_end_render_pass(&encoder)

					backing := [?][]u8{vertex_bytes[:], uniform_bytes[:]}
					shaders := [?]Software_Shader_Mode{.Vertex_Color_3D}
					uniforms := [?]u32{2}
					label := fmt.tprintf("blended %dx%d %v depth %v round %d", width, height, format, with_depth, round)
					summary := expect_forms_give_the_same_bytes(t, Form_Scene{
						registry            = Resource_Registry{buffers = buffers[:], textures = textures[:], pipelines = pipelines[:], bind_group_count = 1},
						buffers             = backing[:],
						shaders             = shaders[:],
						bind_group_uniforms = uniforms[:],
						stream              = encoder_finish(&encoder),
						start_seed          = next_word(&generator),
					}, label)
					total_shaded += summary.pixels_shaded
				}
			}
		}
	}
	testing.expect(t, total_shaded > 1_000, "the blended triangles must shade pixels")
}

// A square of the whole picture cut into triangles that share each edge: a
// fan of four triangles whose center is a pixel center, so its edges pass
// through pixel centers, and a grid of moved points. The top-left rule must
// shade each pixel once: as many pixels shaded as the picture has, with no
// crack and no pixel shaded twice. The color of each pixel must not be the
// clear color, and the two forms must give the same bytes.
@(test)
shared_edge_forms_shade_each_pixel_once :: proc(t: ^testing.T) {
	GRID :: 4
	generator := Generator{state = 0xD1B5_4A32_D192_ED03}
	for width in FORM_TEST_WIDTHS {
		for format in FORM_TEST_COLOR_FORMATS {
			height := width
			for shape in 0 ..< 3 {
				vertex_bytes: [GRID * GRID * 6 * size_of(Vertex_2D)]u8
				vertex_count := 0
				triangle :: proc(destination: []u8, count: ^int, generator: ^Generator, points: [3][2]f32) {
					// Each triangle gets its own opaque color, never the clear color black.
					r := 0.2 + 0.8 * next_unit(generator)
					g := next_unit(generator)
					b := next_unit(generator)
					for point in points {
						vertex_2d_write(destination, count^, point[0], point[1], r, g, b, 1.0)
						count^ += 1
					}
				}
				w := f32(width)
				h := f32(height)
				switch shape {
				case 0:
					// A fan around a pixel center, its diagonals through pixel centers.
					center := [2]f32{f32(width / 2) + 0.5, f32(height / 2) + 0.5}
					corners := [4][2]f32{{0, 0}, {w, 0}, {w, h}, {0, h}}
					for i in 0 ..< 4 {
						triangle(vertex_bytes[:], &vertex_count, &generator, {center, corners[i], corners[(i + 1) % 4]})
					}
				case 1:
					// Two triangles along the diagonal of the square, which passes through pixel centers.
					triangle(vertex_bytes[:], &vertex_count, &generator, {{0, 0}, {w, 0}, {w, h}})
					triangle(vertex_bytes[:], &vertex_count, &generator, {{0, 0}, {w, h}, {0, h}})
				case 2:
					// A grid whose inner points move by up to a third of a cell, and some fall on pixel centers.
					points: [GRID + 1][GRID + 1][2]f32
					for row in 0 ..= GRID {
						for column in 0 ..= GRID {
							x := w * f32(column) / GRID
							y := h * f32(row) / GRID
							if row > 0 && row < GRID && column > 0 && column < GRID {
								// A point moves to a pixel center only inside a third of a
								// cell, so the triangles never fold over each other.
								center_x := f32(i32(x)) + 0.5
								center_y := f32(i32(y)) + 0.5
								if next_word(&generator) % 3 == 0 && abs(center_x - x) <= w / (3 * GRID) && abs(center_y - y) <= h / (3 * GRID) {
									x = center_x
									y = center_y
								} else {
									x += next_between(&generator, -w / (3 * GRID), w / (3 * GRID))
									y += next_between(&generator, -h / (3 * GRID), h / (3 * GRID))
								}
							}
							points[row][column] = {x, y}
						}
					}
					for row in 0 ..< GRID {
						for column in 0 ..< GRID {
							a := points[row][column]
							b := points[row][column + 1]
							c := points[row + 1][column + 1]
							d := points[row + 1][column]
							triangle(vertex_bytes[:], &vertex_count, &generator, {a, b, c})
							triangle(vertex_bytes[:], &vertex_count, &generator, {a, c, d})
						}
					}
				}

				buffers := [?]Buffer_Desc{{size = u64(len(vertex_bytes)), usage = {.Vertex}}}
				textures := [?]Texture_Desc{{width = width, height = height, format = format, usage = {.Render_Attachment}}}
				pipelines := [?]Pipeline_Desc{
					{topology = .Triangle_List, color_format = format, src_blend = .One, dst_blend = .Zero, vertex_stride = VERTEX_2D_STRIDE},
				}
				command_bytes: [COMMAND_RECORD_SIZE * 8]u8
				encoder := encoder_init(command_bytes[:])
				_ = encode_begin_render_pass(&encoder, 1, 0, .Clear, .Store)
				_ = encode_set_pipeline(&encoder, 1)
				_ = encode_set_vertex_buffer(&encoder, 0, 1, 0, u64(len(vertex_bytes)))
				_ = encode_draw(&encoder, u32(vertex_count), 1, 0, 0)
				_ = encode_end_render_pass(&encoder)
				stream := encoder_finish(&encoder)

				backing := [?][]u8{vertex_bytes[:]}
				shaders := [?]Software_Shader_Mode{.Solid_Color_2D}
				scene := Form_Scene{
					registry   = Resource_Registry{buffers = buffers[:], textures = textures[:], pipelines = pipelines[:]},
					buffers    = backing[:],
					shaders    = shaders[:],
					stream     = stream,
					start_seed = next_word(&generator),
				}
				label := fmt.tprintf("shared edges %dx%d %v shape %d", width, height, format, shape)
				summary := expect_forms_give_the_same_bytes(t, scene, label)
				testing.expectf(t, summary.pixels_shaded == u64(width) * u64(height), "%s: %d pixels shaded for %d pixels", label, summary.pixels_shaded, width * height)

				// Each pixel holds a color of a triangle, never the clear black: no crack.
				run := form_run(scene, RASTERIZER_FORM_OF_TARGET)
				defer form_run_delete(run)
				bytes_per_pixel := int(texture_format_bytes_per_pixel(format))
				red_place := format == .BGRA8_Unorm ? 2 : 0
				color := run.textures[0].color_bytes
				for pixel in 0 ..< int(width * height) {
					if color[pixel * bytes_per_pixel + red_place] == 0 {
						testing.expectf(t, false, "%s: pixel %d is not shaded", label, pixel)
						break
					}
				}
			}
		}
	}
}

// Random triangles with places from far off the screen to inside it, with
// scissor rectangles, degenerate triangles (a repeated vertex, three points on
// a line, an area under the bound), tiny triangles, huge places, and triangle
// strips, in 2D and 3D.
@(test)
edge_case_forms_give_the_same_bytes :: proc(t: ^testing.T) {
	TRIANGLES :: 24
	generator := Generator{state = 0x94D0_49BB_1331_11EB}
	total_shaded: u64 = 0
	for width in FORM_TEST_WIDTHS {
		for format in FORM_TEST_COLOR_FORMATS {
			for round in 0 ..< 6 {
				height := u32(1 + round * 7)
				w := f32(width)
				h := f32(height)
				vertex_bytes: [TRIANGLES * 3 * size_of(Vertex_2D)]u8
				for triangle in 0 ..< TRIANGLES {
					kind := next_word(&generator) % 8
					points: [3][2]f32
					for &point in points {
						point = {next_between(&generator, -w, 2 * w), next_between(&generator, -h, 2 * h)}
					}
					switch kind {
					case 0:
						// A repeated vertex.
						points[2] = points[0]
					case 1:
						// Three points on a line.
						points[2] = {2 * points[1][0] - points[0][0], 2 * points[1][1] - points[0][1]}
					case 2:
						// An area just around the bound of a degenerate triangle.
						points[1] = {points[0][0] + 1e-3, points[0][1]}
						points[2] = {points[0][0], points[0][1] + next_between(&generator, 1e-4, 4e-3)}
					case 3:
						// A tiny triangle around a pixel center.
						cx := f32(next_word(&generator) % u64(width)) + 0.5
						cy := f32(next_word(&generator) % u64(height)) + 0.5
						points = {{cx - 0.3, cy - 0.2}, {cx + 0.4, cy}, {cx, cy + 0.5}}
					case 4:
						// Huge places: the box clips to the scissor.
						points[0] = {-1e7, -1e7}
						points[1] = {1e7, next_between(&generator, -1e3, 1e3)}
					case 5:
						// Vertices on pixel centers and on pixel corners.
						for &point in points {
							point = {f32(i32(point[0])) + 0.5 * f32(next_word(&generator) % 2), f32(i32(point[1])) + 0.5 * f32(next_word(&generator) % 2)}
						}
					case:
					}
					a := next_between(&generator, 0.3, 1.0)
					for point, i in points {
						vertex_2d_write(vertex_bytes[:], triangle * 3 + i, point[0], point[1], next_unit(&generator), next_unit(&generator), next_unit(&generator), a)
					}
				}

				scissor_x := u32(next_word(&generator) % u64(width))
				scissor_y := u32(next_word(&generator) % u64(height))
				scissor_width := 1 + u32(next_word(&generator) % u64(width - scissor_x))
				scissor_height := 1 + u32(next_word(&generator) % u64(height - scissor_y))

				buffers := [?]Buffer_Desc{{size = u64(len(vertex_bytes)), usage = {.Vertex}}}
				textures := [?]Texture_Desc{{width = width, height = height, format = format, usage = {.Render_Attachment}}}
				pipelines := [?]Pipeline_Desc{
					{topology = .Triangle_List, color_format = format, src_blend = .Src_Alpha, dst_blend = .One_Minus_Src_Alpha, vertex_stride = VERTEX_2D_STRIDE},
					{topology = .Triangle_Strip, color_format = format, src_blend = .One, dst_blend = .Zero, vertex_stride = VERTEX_2D_STRIDE},
				}
				command_bytes: [COMMAND_RECORD_SIZE * 12]u8
				encoder := encoder_init(command_bytes[:])
				_ = encode_begin_render_pass(&encoder, 1, 0, .Load, .Store)
				_ = encode_set_pipeline(&encoder, 1)
				_ = encode_set_vertex_buffer(&encoder, 0, 1, 0, u64(len(vertex_bytes)))
				_ = encode_draw(&encoder, TRIANGLES * 3 / 2, 1, 0, 0)
				_ = encode_set_scissor_rect(&encoder, scissor_x, scissor_y, scissor_width, scissor_height)
				_ = encode_draw(&encoder, TRIANGLES * 3 / 2, 1, TRIANGLES * 3 / 2, 0)
				_ = encode_set_pipeline(&encoder, 2)
				_ = encode_draw(&encoder, 12, 1, 3, 0)
				_ = encode_end_render_pass(&encoder)

				backing := [?][]u8{vertex_bytes[:]}
				shaders := [?]Software_Shader_Mode{.Solid_Color_2D, .Solid_Color_2D}
				label := fmt.tprintf("edge cases %dx%d %v round %d", width, height, format, round)
				summary := expect_forms_give_the_same_bytes(t, Form_Scene{
					registry   = Resource_Registry{buffers = buffers[:], textures = textures[:], pipelines = pipelines[:]},
					buffers    = backing[:],
					shaders    = shaders[:],
					stream     = encoder_finish(&encoder),
					start_seed = next_word(&generator),
				}, label)
				total_shaded += summary.pixels_shaded
			}
		}
	}
	testing.expect(t, total_shaded > 1_000, "the edge cases must shade pixels")
}

// Prints the time of each form for frames of the turning cube at 640x480. It
// fails only when the two forms give different counts; a time is a measure,
// never a bound. Opt-in: runs only with -define:MEASURE=true.
@(test)
cube_speed_of_each_form :: proc(t: ^testing.T) {
	if !MEASURE {
		return
	}
	WIDTH :: 640
	HEIGHT :: 480
	FRAMES :: 60
	for format in FORM_TEST_COLOR_FORMATS {
		shaded: [Rasterizer_Form]u64
		spent: [Rasterizer_Form]time.Duration
		for form in Rasterizer_Form {
			best := time.Duration(max(i64))
			for _ in 0 ..< 5 {
				started := time.tick_now()
				shaded[form] = 0
				for frame in 0 ..< FRAMES {
					shaded[form] += cube_frame_shaded(WIDTH, HEIGHT, format, f32(frame) / FRAMES, form)
				}
				best = min(best, time.tick_since(started))
			}
			spent[form] = best
		}
		testing.expectf(t, shaded[.Scalar] == shaded[.Vector], "%v: the scalar form shaded %d pixels, the vector form %d", format, shaded[.Scalar], shaded[.Vector])
		frame_milliseconds :: proc(spent: time.Duration) -> f64 {
			return time.duration_milliseconds(spent) / FRAMES
		}
		fmt.printfln("webgpu_subset: the cube at %dx%d %v, %d pixels a frame, the least of 5 runs of %d frames: the scalar form %.3f ms a frame, the vector form %.3f ms, %.2f times", WIDTH, HEIGHT, format, shaded[.Scalar] / FRAMES, FRAMES, frame_milliseconds(spent[.Scalar]), frame_milliseconds(spent[.Vector]), f64(spent[.Scalar]) / max(f64(spent[.Vector]), 1))
	}
}

// One frame of the cube for the measure: a large cube that fills most of the picture.
@(private = "file")
cube_frame_shaded :: proc(width, height: u32, format: Texture_Format, angle_turns: f32, form: Rasterizer_Form) -> u64 {
	@(static) color: [640 * 480 * 4]u8
	@(static) depth: [640 * 480]u32
	vertex_bytes: [8 * size_of(Vertex_3D)]u8
	corners := CUBE_CORNERS
	for corner, i in corners {
		_ = vertex_3d_encode(Vertex_3D{
			x = corner[0], y = corner[1], z = corner[2],
			r = 0.5 + 0.5 * corner[0], g = 0.5 + 0.5 * corner[1], b = 0.5 + 0.5 * corner[2], a = 1.0,
		}, vertex_bytes[:], i * size_of(Vertex_3D))
	}
	index_bytes: [36 * 2]u8
	indices := CUBE_INDICES
	for index, i in indices {
		byte_order.write_u16_little_endian(index_bytes[:], i * 2, index)
	}
	model := matrix_4x4_multiply(matrix_4x4_rotation_y(angle_turns), matrix_4x4_rotation_x(angle_turns * 0.37 + 0.05))
	mvp := matrix_4x4_multiply(matrix_4x4_perspective_zero_to_one(1.7, f32(width) / f32(height), 0.5, 20.0), matrix_4x4_multiply(matrix_4x4_translate(0, 0, -3.2), model))
	uniform_bytes: [MATRIX_4X4_BYTES]u8
	_ = matrix_4x4_encode(mvp, uniform_bytes[:], 0)
	buffers := [?]Buffer_Desc{
		{size = u64(len(vertex_bytes)), usage = {.Vertex}},
		{size = u64(len(index_bytes)), usage = {.Index}},
		{size = u64(len(uniform_bytes)), usage = {.Uniform}},
	}
	textures := [?]Texture_Desc{
		{width = width, height = height, format = format, usage = {.Render_Attachment}},
		{width = width, height = height, format = .Depth24_Plus, usage = {.Render_Attachment}},
	}
	pipelines := [?]Pipeline_Desc{
		{topology = .Triangle_List, color_format = format, src_blend = .One, dst_blend = .Zero, vertex_stride = VERTEX_3D_STRIDE},
	}
	command_bytes: [COMMAND_RECORD_SIZE * 8]u8
	encoder := encoder_init(command_bytes[:])
	_ = encode_begin_render_pass(&encoder, 1, 2, .Clear, .Store)
	_ = encode_set_pipeline(&encoder, 1)
	_ = encode_set_vertex_buffer(&encoder, 0, 1, 0, u64(len(vertex_bytes)))
	_ = encode_set_index_buffer(&encoder, 2, .Uint16, 0, u64(len(index_bytes)))
	_ = encode_set_bind_group(&encoder, 0, 1)
	_ = encode_draw_indexed(&encoder, 36, 1, 0, 0, 0)
	_ = encode_end_render_pass(&encoder)
	backing := [?][]u8{vertex_bytes[:], index_bytes[:], uniform_bytes[:]}
	memory := [?]Software_Texture_Memory{
		{color_bytes = color[:int(width * height * texture_format_bytes_per_pixel(format))]},
		{depth_values = depth[:int(width * height)]},
	}
	shaders := [?]Software_Shader_Mode{.Vertex_Color_3D}
	uniforms := [?]u32{3}
	summary, _ := software_3d_execute_in_form(encoder_finish(&encoder), Software_Device{
		resources           = Resource_Registry{buffers = buffers[:], textures = textures[:], pipelines = pipelines[:], bind_group_count = 1},
		buffers             = backing[:],
		textures            = memory[:],
		pipeline_shaders    = shaders[:],
		bind_group_uniforms = uniforms[:],
	}, form)
	return summary.pixels_shaded
}

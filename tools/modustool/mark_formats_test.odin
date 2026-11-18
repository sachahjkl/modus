package modustool

import "core:fmt"
import "core:strings"
import "core:testing"
import "modus:support/mark"
import "modustool:foundation"

// The value of an attribute of an element of a vector file, or "".
@(private = "file")
vector_attribute :: proc(tag, name: string) -> string {
	start_text := strings.concatenate({" ", name, "=\""}, context.temp_allocator)
	start := strings.index(tag, start_text)
	if start < 0 {
		return ""
	}
	rest := tag[start + len(start_text):]
	end := strings.index_byte(rest, '"')
	if end < 0 {
		return ""
	}
	return rest[:end]
}

// A whole number of decimal digits; -1 for a text that is not one.
@(private = "file")
vector_number :: proc(text: string) -> int {
	if text == "" || len(text) > 9 {
		return -1
	}
	value := 0
	for character in transmute([]u8)text {
		if character < '0' || character > '9' {
			return -1
		}
		value = value * 10 + int(character - '0')
	}
	return value
}

// A color written "#rrggbb".
@(private = "file")
vector_color :: proc(text: string) -> (color: u32, ok: bool) {
	if len(text) != 7 || text[0] != '#' {
		return 0, false
	}
	for character in transmute([]u8)text[1:] {
		digit: u32
		switch character {
		case '0' ..= '9':
			digit = u32(character - '0')
		case 'a' ..= 'f':
			digit = u32(character - 'a') + 10
		case:
			return 0, false
		}
		color = color << 4 | digit
	}
	return color, true
}

// vector_pixels draws a vector file of the generator into pixels of four
// bytes, as a reader of the file does: each rectangle with its fill, or,
// for a reader that asks for the dark scheme, with the fill of the rule of
// its class. problem is the sentence of a file that the generator does not
// write: a rectangle outside the picture, a pixel in two rectangles, a
// class with no rule.
@(private = "file")
vector_pixels :: proc(svg: string, dark: bool) -> (pixels: []u8, width, height: int, problem: string) {
	open_end := strings.index_byte(svg, '>')
	if !strings.has_prefix(svg, "<svg ") || open_end < 0 || !strings.contains(svg[:open_end], "shape-rendering=\"crispEdges\"") {
		return nil, 0, 0, "no svg element with sharp edges"
	}
	width = vector_number(vector_attribute(svg[:open_end], "width"))
	height = vector_number(vector_attribute(svg[:open_end], "height"))
	if width <= 0 || height <= 0 || vector_attribute(svg[:open_end], "viewBox") != fmt.tprintf("0 0 %d %d", width, height) {
		return nil, 0, 0, "the size and the box of the file do not agree"
	}
	pixels = make([]u8, width * height * 4, context.temp_allocator)
	rest := svg
	for {
		start := strings.index(rest, "<rect ")
		if start < 0 {
			break
		}
		end := strings.index(rest[start:], "/>")
		if end < 0 {
			return nil, 0, 0, "a rectangle with no end"
		}
		tag := rest[start:start + end]
		rest = rest[start + end:]
		x := vector_number(vector_attribute(tag, "x"))
		y := vector_number(vector_attribute(tag, "y"))
		rectangle_width := vector_number(vector_attribute(tag, "width"))
		rectangle_height := vector_number(vector_attribute(tag, "height"))
		color, color_ok := vector_color(vector_attribute(tag, "fill"))
		if x < 0 || y < 0 || rectangle_width <= 0 || rectangle_height <= 0 || x + rectangle_width > width || y + rectangle_height > height || !color_ok {
			return nil, 0, 0, fmt.tprintf("the rectangle %q is not inside the picture, or has no color", tag)
		}
		if class := vector_attribute(tag, "class"); class != "" && dark {
			rule_start := strings.concatenate({".", class, " { fill: "}, context.temp_allocator)
			rule := strings.index(svg, rule_start)
			if rule < 0 || rule + len(rule_start) + 7 > len(svg) {
				return nil, 0, 0, fmt.tprintf("the class %s has no rule", class)
			}
			color, color_ok = vector_color(svg[rule + len(rule_start):][:7])
			if !color_ok {
				return nil, 0, 0, fmt.tprintf("the rule of the class %s has no color", class)
			}
		}
		for row in y ..< y + rectangle_height {
			for column in x ..< x + rectangle_width {
				pixel := pixels[(row * width + column) * 4:][:4]
				if pixel[3] != 0 {
					return nil, 0, 0, fmt.tprintf("the pixel %d, %d is in two rectangles", column, row)
				}
				pixel[0], pixel[1], pixel[2], pixel[3] = u8(color >> 16), u8(color >> 8), u8(color), 0xFF
			}
		}
	}
	return pixels, width, height, ""
}

// vector_is_picture tells whether a vector file, as a reader of a color
// scheme draws it, has the pixels of a picture: the same size, the same
// covered pixels, the same color in each.
@(private = "file")
vector_is_picture :: proc(t: ^testing.T, svg: string, dark: bool, picture: Mark_Picture, cells: ^mark.Heron_Cells) -> bool {
	drawn, width, height, problem := vector_pixels(svg, dark)
	if problem != "" {
		testing.expectf(t, false, "the vector file of %s: %s", picture.file_name, problem)
		return false
	}
	expected_width, expected_height := mark_picture_size(picture)
	if width != expected_width || height != expected_height {
		return false
	}
	channels := mark_picture_channels(picture)
	expected := mark_picture_pixels(picture, cells)
	for index in 0 ..< width * height {
		pixel := expected[index * channels:][:channels]
		covered := channels == 3 || pixel[3] != 0
		got := drawn[index * 4:][:4]
		if covered != (got[3] != 0) || (covered && (got[0] != pixel[0] || got[1] != pixel[1] || got[2] != pixel[2])) {
			return false
		}
	}
	return true
}

// The count of the rectangles of a vector file.
@(private = "file")
vector_rectangle_count :: proc(svg: string) -> int {
	return strings.count(svg, "<rect ")
}

// An icon file of the generator holds, for each entry, the PNG file that
// the generator writes for the picture of the entry, byte for byte. The
// icon file of the site is the rows of favicon.ico of the table of the
// uses, and the same request to the generator gives the same bytes.
@(test)
mark_icon_file_holds_the_png_file_of_each_entry :: proc(t: ^testing.T) {
	file, ok := mark_use_file(SITE_FAVICON)
	testing.expect(t, ok)
	rows, kind := mark_use_entries(SITE_FAVICON)
	testing.expect_value(t, kind, Mark_Use_Kind.Icon_File_Entry)
	directory, problem := mark_ico_read(file)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(directory), len(rows))
	if len(directory) != len(rows) || len(rows) != 2 {
		return
	}
	still := mark.still_cells()
	for row, index in rows {
		entry := directory[index]
		width, height := mark_picture_size(row)
		testing.expect_value(t, entry.width, width)
		testing.expect_value(t, entry.height, height)
		data := file[entry.offset:][:entry.bytes]
		alone, alone_ok := mark_picture_png(row)
		testing.expect(t, alone_ok && string(alone) == string(data), "an entry of the icon file is not the PNG file of its picture")
		testing.expect(t, png_has_pixels(data, width, height, 4, mark_picture_pixels(row, &still)))
	}
	testing.expect_value(t, directory[0].width, 32)
	testing.expect_value(t, directory[1].width, 48)
	// The same file as one request.
	request := Mark_Request{what = .Still, format = .ICO, picture = rows[0], entries = rows[1:]}
	requested, refusal := mark_generate(request)
	testing.expect_value(t, refusal, "")
	testing.expect(t, string(requested) == string(file), "the request for the icon file of the site gives other bytes")
	// One entry, of a frame: the cells of the frame, not of the still heron.
	frame := Mark_Request{what = .Frame, format = .ICO, has_animation = true, animation = .Dash, frame = 2, picture = Mark_Picture{file_name = "test.ico", variant = .Cells, heron_cell = 1, on_light = true, width = 32, height = 32}}
	frame_file, frame_refusal := mark_generate(frame)
	testing.expect_value(t, frame_refusal, "")
	frame_directory, frame_problem := mark_ico_read(frame_file)
	testing.expect_value(t, frame_problem, "")
	testing.expect_value(t, len(frame_directory), 1)
	if len(frame_directory) == 1 {
		run, _ := mark.animation_frame_cells(.Dash, 2)
		data := frame_file[frame_directory[0].offset:][:frame_directory[0].bytes]
		testing.expect(t, png_has_pixels(data, 32, 32, 4, mark_picture_pixels(frame.picture, &run)))
		testing.expect(t, !png_has_pixels(data, 32, 32, 4, mark_picture_pixels(frame.picture, &still)))
	}
}

// A vector file of the generator is exact: drawn as a reader draws it, it
// has the pixels of the PNG file of the same request, in the light scheme
// and, with the rule of the dark scheme, in the dark scheme. A cell is one
// rectangle or a part of one at each cell size.
@(test)
mark_vector_file_has_the_pixels_of_its_picture :: proc(t: ^testing.T) {
	still := mark.still_cells()
	// The vector icon of the site: the row of the table of the uses.
	icon, icon_found := mark_use_picture(SITE_ICON_SVG)
	testing.expect(t, icon_found && icon.on_light && icon.variant == .Cells)
	icon_file, icon_ok := mark_use_file(SITE_ICON_SVG)
	testing.expect(t, icon_ok)
	icon_svg := string(icon_file)
	icon_dark := icon
	icon_dark.on_light = false
	testing.expect(t, vector_is_picture(t, icon_svg, false, icon, &still), "the vector icon is not the cells of the light scheme")
	testing.expect(t, vector_is_picture(t, icon_svg, true, icon_dark, &still), "the vector icon, for a reader of the dark scheme, is not the cells of the dark scheme")
	// The two schemes differ (the neck), so the file has the rule, and a
	// reader of the light scheme does not see the dark colors.
	testing.expect(t, strings.contains(icon_svg, "@media (prefers-color-scheme: dark)"))
	testing.expect(t, !vector_is_picture(t, icon_svg, false, icon_dark, &still))
	// The same request with no rule: the light scheme only, no style.
	request := Mark_Request{what = .Still, format = .SVG, picture = icon}
	plain_file, plain_refusal := mark_generate(request)
	testing.expect_value(t, plain_refusal, "")
	testing.expect(t, !strings.contains(string(plain_file), "<style>") && !strings.contains(string(plain_file), "class="))
	testing.expect(t, vector_is_picture(t, string(plain_file), false, icon, &still))
	testing.expect(t, vector_is_picture(t, string(plain_file), true, icon, &still))
	request.dark_rule = true
	ruled_file, ruled_refusal := mark_generate(request)
	testing.expect_value(t, ruled_refusal, "")
	testing.expect(t, string(ruled_file) == icon_svg, "the request for the vector icon of the site gives other bytes")
	// At 4 pixels for a cell the file has the same rectangles, each 4
	// times as large: a cell is never cut into pixels.
	large := icon
	large.heron_cell = 4
	large_file, large_refusal := mark_generate(Mark_Request{what = .Still, format = .SVG, picture = large})
	testing.expect_value(t, large_refusal, "")
	testing.expect(t, vector_is_picture(t, string(large_file), false, large, &still))
	testing.expect_value(t, vector_rectangle_count(string(large_file)), vector_rectangle_count(string(plain_file)))
	testing.expect(t, strings.has_prefix(string(large_file), "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 96 96\" width=\"96\" height=\"96\""))
	// The whole of a picture: the name under the heron, on the background
	// of the scheme, centred in a larger picture; and its dark scheme by
	// the rule, where the background and the name differ too.
	whole := Mark_Picture{file_name = "test.svg", variant = .Cells, heron_cell = 4, name_cell = 2, gap = 6, on_light = true, opaque = true, width = 128, height = 160}
	whole_dark := whole
	whole_dark.on_light = false
	whole_file, whole_refusal := mark_generate(Mark_Request{what = .Still, format = .SVG, picture = whole, dark_rule = true})
	testing.expect_value(t, whole_refusal, "")
	testing.expect(t, vector_is_picture(t, string(whole_file), false, whole, &still))
	testing.expect(t, vector_is_picture(t, string(whole_file), true, whole_dark, &still))
	// A frame: the cells of the frame.
	frame := Mark_Request{what = .Frame, format = .SVG, has_animation = true, animation = .Dash, frame = 2, picture = icon}
	frame_file, frame_refusal := mark_generate(frame)
	testing.expect_value(t, frame_refusal, "")
	run, _ := mark.animation_frame_cells(.Dash, 2)
	testing.expect(t, vector_is_picture(t, string(frame_file), false, icon, &run))
	testing.expect(t, !vector_is_picture(t, string(frame_file), false, icon, &still))
}

// The requests for a format that have no sense are refused with a
// sentence: the smooth variant as a vector file, the rule of the dark
// scheme outside a vector file of the light scheme, an icon file with an
// entry that its directory cannot hold or with two entries of one size,
// and a format that does not hold what is asked.
@(test)
mark_generator_refuses_a_format_with_no_sense :: proc(t: ^testing.T) {
	Case :: struct {
		request: Mark_Request,
		words:   string, // Words of the sentence of the refusal.
	}
	cells_light := Mark_Picture{file_name = "test", variant = .Cells, heron_cell = 1, on_light = true}
	smooth := Mark_Picture{file_name = "test", variant = .Smooth, heron_cell = 8}
	cells_dark := cells_light
	cells_dark.on_light = false
	entry_32 := cells_light
	entry_32.width, entry_32.height = 32, 32
	entry_512 := smooth
	entry_512.width, entry_512.height = 512, 512
	cases := [?]Case {
		{{what = .Still, format = .SVG, picture = smooth}, "a vector file holds the cells variant only"},
		{{what = .Still, format = .SVG, picture = cells_dark, dark_rule = true}, "ask for the light scheme"},
		{{what = .Still, format = .PNG, picture = cells_light, dark_rule = true}, "only a vector file holds the rule of the dark scheme"},
		{{what = .Still, picture = cells_light, entries = []Mark_Picture{entry_32}}, "only an icon file has more entries"},
		{{what = .Still, format = .ICO, picture = entry_512}, "at most 256 pixels on a side"},
		{{what = .Still, format = .ICO, picture = entry_32, entries = []Mark_Picture{entry_512}}, "at most 256 pixels on a side"},
		{{what = .Still, format = .ICO, picture = entry_32, entries = []Mark_Picture{entry_32}}, "two entries of an icon file"},
		{{what = .Still, format = .ICO, picture = entry_32, entries = []Mark_Picture{Mark_Picture{variant = .Smooth, heron_cell = 1, width = 48, height = 48}}}, "the smooth variant needs at least 2 pixels for a cell"},
		{{what = .Still, format = .APNG, picture = smooth}, "does not hold what is asked"},
		{{what = .Still, format = .JSON, picture = smooth}, "does not hold what is asked"},
		{{what = .Tile_Map, format = .SVG, picture = cells_light}, "does not hold what is asked"},
		{{what = .Table, format = .PNG, picture = smooth}, "does not hold what is asked"},
		{{what = .Animation, format = .PNG, picture = smooth, has_animation = true, animation = .Dash}, "does not hold what is asked"},
		{{what = .Animation, picture = smooth}, "name the animation"},
		{{what = .Animation, picture = smooth, has_animation = true, animation = .Dash, frame = 2}, "it takes no frame"},
	}
	for entry, index in cases {
		file, refusal := mark_generate(entry.request)
		testing.expectf(t, file == nil && strings.contains(refusal, entry.words), "the case %d: the refusal is %q", index, refusal)
	}
	// The same with sense are served.
	testing.expect_value(t, mark_request_refusal(Mark_Request{what = .Still, format = .SVG, picture = cells_light, dark_rule = true}), "")
	testing.expect_value(t, mark_request_refusal(Mark_Request{what = .Still, format = .SVG, picture = cells_dark}), "")
	testing.expect_value(t, mark_request_refusal(Mark_Request{what = .Still, format = .ICO, picture = entry_32}), "")
	testing.expect_value(t, mark_request_refusal(Mark_Request{what = .Still, format = .PNG, picture = smooth}), "")
	testing.expect_value(t, mark_request_refusal(Mark_Request{what = .Table, format = .JSON, picture = smooth}), "")
	// With no format, each kind of request has its usual format.
	testing.expect_value(t, mark_request_format(Mark_Request{what = .Still}), Mark_Format.PNG)
	testing.expect_value(t, mark_request_format(Mark_Request{what = .Frame}), Mark_Format.PNG)
	testing.expect_value(t, mark_request_format(Mark_Request{what = .Tile_Map}), Mark_Format.PNG)
	testing.expect_value(t, mark_request_format(Mark_Request{what = .Table}), Mark_Format.JSON)
	testing.expect_value(t, mark_request_format(Mark_Request{what = .Animation}), Mark_Format.APNG)
}

// The four bytes of a chunk of a PNG file, as a number.
@(private = "file")
chunk_number :: proc(bytes: []u8) -> int {
	return int(bytes[0]) << 24 | int(bytes[1]) << 16 | int(bytes[2]) << 8 | int(bytes[3])
}

// An animated PNG file of the generator holds each frame of its animation,
// in the order of the animation, for the time of the table of the
// animations, with the pixels of the picture of that frame. The chunks are
// in the order that the format asks, their numbers of order count from 0
// with no gap, and each sum is right. The test reads the file back: it
// builds one PNG file from the data of each frame and decodes it.
@(test)
mark_animated_file_holds_each_frame_for_its_time :: proc(t: ^testing.T) {
	picture := Mark_Picture{file_name = "test.apng", variant = .Smooth, heron_cell = 2}
	request := Mark_Request{what = .Animation, has_animation = true, animation = .Dash, picture = picture}
	file, refusal := mark_generate(request)
	testing.expect_value(t, refusal, "")
	chunks, readable := mark_png_chunks(file)
	testing.expect(t, readable)
	frame_count := mark.animation_frame_count(.Dash)
	if !readable || len(chunks) < 2 + 2 * frame_count + 1 {
		testing.expect(t, false, "the animated file has too few chunks")
		return
	}
	for chunk in chunks {
		testing.expectf(t, chunk.sum_is_right, "the sum of a chunk %s is wrong", chunk.type)
	}
	testing.expect_value(t, chunks[0].type, "IHDR")
	testing.expect_value(t, chunks[1].type, "acTL")
	testing.expect_value(t, chunks[len(chunks) - 1].type, "IEND")
	if chunks[0].type != "IHDR" || chunks[1].type != "acTL" || len(chunks[0].data) != 13 || len(chunks[1].data) != 8 {
		return
	}
	testing.expect_value(t, chunk_number(chunks[0].data[0:4]), 48)
	testing.expect_value(t, chunk_number(chunks[0].data[4:8]), 48)
	testing.expect_value(t, chunk_number(chunks[1].data[0:4]), frame_count)
	testing.expect_value(t, chunk_number(chunks[1].data[4:8]), MARK_APNG_PLAYS)
	// The frames: a control chunk, then the data of the frame.
	at := 2
	sequence := 0
	total := 0
	for frame in 1 ..= frame_count {
		if at >= len(chunks) || chunks[at].type != "fcTL" || len(chunks[at].data) != MARK_APNG_FRAME_CONTROL_SIZE {
			testing.expectf(t, false, "the frame %d has no control chunk", frame)
			return
		}
		control := chunks[at].data
		at += 1
		row, _ := mark.animation_frame(.Dash, frame)
		testing.expect_value(t, chunk_number(control[0:4]), sequence)
		sequence += 1
		testing.expect_value(t, chunk_number(control[4:8]), 48)
		testing.expect_value(t, chunk_number(control[8:12]), 48)
		testing.expect_value(t, chunk_number(control[12:16]), 0)
		testing.expect_value(t, chunk_number(control[16:20]), 0)
		testing.expect_value(t, int(control[20]) << 8 | int(control[21]), int(row.duration_milliseconds))
		testing.expect_value(t, int(control[22]) << 8 | int(control[23]), 1000)
		testing.expect_value(t, control[24], 0)
		testing.expect_value(t, control[25], 0)
		total += int(control[20]) << 8 | int(control[21])
		// One PNG file of this frame: the header of the file, the data of
		// the frame, the end.
		rebuilt := make([dynamic]u8, context.temp_allocator)
		append_string(&rebuilt, PNG_SIGNATURE)
		mark_png_chunk_write(&rebuilt, "IHDR", chunks[0].data)
		data_chunks := 0
		for at < len(chunks) && (chunks[at].type == "IDAT" || chunks[at].type == "fdAT") {
			chunk := chunks[at]
			at += 1
			data_chunks += 1
			if frame == 1 {
				testing.expect_value(t, chunk.type, "IDAT")
				mark_png_chunk_write(&rebuilt, "IDAT", chunk.data)
				continue
			}
			testing.expect_value(t, chunk.type, "fdAT")
			if chunk.type != "fdAT" || len(chunk.data) < 4 {
				return
			}
			testing.expect_value(t, chunk_number(chunk.data[0:4]), sequence)
			sequence += 1
			mark_png_chunk_write(&rebuilt, "IDAT", chunk.data[4:])
		}
		testing.expectf(t, data_chunks > 0, "the frame %d has no data", frame)
		mark_png_chunk_write(&rebuilt, "IEND", nil)
		cells, _ := mark.animation_frame_cells(.Dash, frame)
		testing.expectf(t, png_has_pixels(rebuilt[:], 48, 48, 4, mark_picture_pixels(picture, &cells)), "the frame %d of the animated file is not the picture of the frame %d of the dash", frame, frame)
	}
	testing.expect_value(t, at, len(chunks) - 1)
	testing.expect_value(t, total, mark.animation_duration(.Dash))
	// The same request gives the same bytes.
	again, _ := mark_generate(request)
	testing.expect(t, string(again) == string(file), "two animated files of one animation differ")
}

// The chunks of a PNG file read back as they were written, and a damaged
// file is refused: a cut file, another signature, a length past the end.
@(test)
mark_png_chunks_read_back :: proc(t: ^testing.T) {
	file := make([dynamic]u8, context.temp_allocator)
	append_string(&file, PNG_SIGNATURE)
	mark_png_chunk_write(&file, "abCd", []u8{1, 2, 3})
	mark_png_chunk_write(&file, "IEND", nil)
	chunks, ok := mark_png_chunks(file[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(chunks), 2)
	if len(chunks) == 2 {
		testing.expect_value(t, chunks[0].type, "abCd")
		testing.expect(t, string(chunks[0].data) == "\x01\x02\x03" && chunks[0].sum_is_right)
		testing.expect(t, chunks[1].type == "IEND" && len(chunks[1].data) == 0 && chunks[1].sum_is_right)
	}
	// The end chunk of every PNG file has this sum.
	testing.expect(t, string(file[len(file) - 4:]) == "\xAE\x42\x60\x82")
	_, cut_ok := mark_png_chunks(file[:len(file) - 1])
	testing.expect(t, !cut_ok)
	_, signature_ok := mark_png_chunks(file[1:])
	testing.expect(t, !signature_ok)
	changed := make([]u8, len(file), context.temp_allocator)
	copy(changed, file[:])
	changed[len(PNG_SIGNATURE) + 8] = 9 // A byte of the data of the first chunk.
	changed_chunks, changed_ok := mark_png_chunks(changed)
	testing.expect(t, changed_ok && len(changed_chunks) == 2 && !changed_chunks[0].sum_is_right)
	long := make([]u8, len(file), context.temp_allocator)
	copy(long, file[:])
	long[len(PNG_SIGNATURE) + 3] = 200 // The length of the first chunk.
	_, long_ok := mark_png_chunks(long)
	testing.expect(t, !long_ok)
}

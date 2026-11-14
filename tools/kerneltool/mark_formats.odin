// The formats of a file of the mark, a part of the generator of the
// pictures of the mark (mark_pictures.odin; docs/TOOLS.md, "The pictures
// of the mark"). Each format starts from the pixels of one picture, which
// mark_picture_pixels draws:
//   an icon file (ICO) is several PNG files of the generator, one for each
//     size, behind a directory;
//   a vector file (SVG) is the pixels of a picture in the cells variant,
//     cut into rectangles of one color;
//   an animated PNG file (APNG) is the PNG data of each frame of one
//     animation, with the time of each frame.
// So a format adds no second way to compute a color of the heron, and a
// test reads each format back into the pixels of the picture.
package kerneltool

import "core:fmt"
import "core:hash"
import "core:strings"
import "modus:support/mark"

// The format of the file of a request.
Mark_Format :: enum {
	Usual, // The format of what is asked: a PNG file for a picture and a tile map, an animated PNG file for an animation, JSON for a table.
	PNG, // One picture.
	ICO, // An icon file: one PNG entry for each size.
	SVG, // A vector file: the cells as rectangles.
	APNG, // An animated PNG file: the frames of one animation.
	JSON, // The text of a table.
}

// The name of each format, as the command reads it. The command does not
// read the first one: it is what a request with no format has.
mark_format_names := [Mark_Format]string {
	.Usual = "usual",
	.PNG   = "png",
	.ICO   = "ico",
	.SVG   = "svg",
	.APNG  = "apng",
	.JSON  = "json",
}

// The end of the name of a file of each format.
mark_format_extensions := [Mark_Format]string {
	.Usual = "",
	.PNG   = ".png",
	.ICO   = ".ico",
	.SVG   = ".svg",
	.APNG  = ".apng",
	.JSON  = ".json",
}

// The longest side of an entry of an icon file: the directory holds a side
// in one byte, where 0 is 256.
MARK_ICON_FILE_SIDE_MOST :: 256

// mark_icon_file_refusal gives the sentence that says why the entries
// cannot be one icon file, or "".
mark_icon_file_refusal :: proc(entries: []Mark_Picture) -> string {
	if len(entries) == 0 {
		return "an icon file has at least one entry"
	}
	for entry, index in entries {
		if refusal := mark_picture_refusal(entry); refusal != "" {
			return refusal
		}
		width, height := mark_picture_size(entry)
		if width > MARK_ICON_FILE_SIDE_MOST || height > MARK_ICON_FILE_SIDE_MOST {
			return fmt.tprintf("an entry of an icon file is at most %d pixels on a side, not %d by %d", MARK_ICON_FILE_SIDE_MOST, width, height)
		}
		for other in entries[:index] {
			other_width, other_height := mark_picture_size(other)
			if other_width == width && other_height == height {
				return fmt.tprintf("two entries of an icon file are %d by %d pixels: a reader chooses an entry by its size", width, height)
			}
		}
	}
	return ""
}

// mark_icon_file gives an icon file whose entries are the pictures, each
// drawn with the same cells and encoded as the PNG file of the generator.
// The caller asks mark_icon_file_refusal first.
mark_icon_file :: proc(entries: []Mark_Picture, cells: ^mark.Heron_Cells) -> (file: []u8, ok: bool) {
	pictures := make([dynamic][]u8, context.temp_allocator)
	for entry in entries {
		data := mark_frame_png(entry, cells) or_return
		append(&pictures, data)
	}
	return mark_ico_encode(pictures[:])
}

// One entry of the directory of an ICO file.
Mark_Icon_File_Entry :: struct {
	width:  int,
	height: int,
	bytes:  int,
	offset: int,
}

MARK_ICO_HEADER_SIZE :: 6
MARK_ICO_ENTRY_SIZE :: 16

// mark_ico_encode gives an ICO file whose entries are PNG files: a header
// of 6 bytes (0, the type 1, the count), one entry of 16 bytes for each
// picture (width, height, 0 colors, 0, 1 plane, 32 bits, the bytes, the
// offset; little endian; a size of 256 is written 0), then the PNG files.
mark_ico_encode :: proc(pictures: [][]u8) -> (file: []u8, ok: bool) {
	if len(pictures) == 0 || len(pictures) > 0xFFFF {
		return nil, false
	}
	output := make([dynamic]u8, context.temp_allocator)
	little_16 :: proc(output: ^[dynamic]u8, value: int) {
		append(output, u8(value), u8(value >> 8))
	}
	little_32 :: proc(output: ^[dynamic]u8, value: int) {
		append(output, u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24))
	}
	little_16(&output, 0)
	little_16(&output, 1)
	little_16(&output, len(pictures))
	offset := MARK_ICO_HEADER_SIZE + MARK_ICO_ENTRY_SIZE * len(pictures)
	for picture in pictures {
		width, height, is_png := site_png_size(picture)
		if !is_png || width < 1 || width > MARK_ICON_FILE_SIDE_MOST || height < 1 || height > MARK_ICON_FILE_SIDE_MOST {
			return nil, false
		}
		append(&output, u8(width & 0xFF), u8(height & 0xFF), 0, 0)
		little_16(&output, 1)
		little_16(&output, 32)
		little_32(&output, len(picture))
		little_32(&output, offset)
		offset += len(picture)
	}
	for picture in pictures {
		append(&output, ..picture)
	}
	return output[:], true
}

// mark_ico_read reads the directory of an ICO file, and checks that each
// entry lies inside the file and is a PNG file of the size of its entry.
mark_ico_read :: proc(file: []u8) -> (entries: []Mark_Icon_File_Entry, problem: string) {
	little :: proc(bytes: []u8) -> int {
		value := 0
		for index := len(bytes) - 1; index >= 0; index -= 1 {
			value = value << 8 | int(bytes[index])
		}
		return value
	}
	if len(file) < MARK_ICO_HEADER_SIZE || little(file[0:2]) != 0 || little(file[2:4]) != 1 {
		return nil, "not an ICO file"
	}
	count := little(file[4:6])
	if count == 0 || len(file) < MARK_ICO_HEADER_SIZE + MARK_ICO_ENTRY_SIZE * count {
		return nil, "no entry, or a directory longer than the file"
	}
	list := make([]Mark_Icon_File_Entry, count, context.temp_allocator)
	for index in 0 ..< count {
		entry_bytes := file[MARK_ICO_HEADER_SIZE + MARK_ICO_ENTRY_SIZE * index:][:MARK_ICO_ENTRY_SIZE]
		entry := Mark_Icon_File_Entry {
			width  = int(entry_bytes[0]) == 0 ? 256 : int(entry_bytes[0]),
			height = int(entry_bytes[1]) == 0 ? 256 : int(entry_bytes[1]),
			bytes  = little(entry_bytes[8:12]),
			offset = little(entry_bytes[12:16]),
		}
		if entry.offset < 0 || entry.bytes <= 0 || entry.offset > len(file) || entry.bytes > len(file) - entry.offset {
			return nil, fmt.tprintf("the entry %d lies outside the file", index)
		}
		width, height, is_png := site_png_size(file[entry.offset:][:entry.bytes])
		if !is_png || width != entry.width || height != entry.height {
			return nil, fmt.tprintf("the entry %d is not a PNG file of %d by %d", index, entry.width, entry.height)
		}
		list[index] = entry
	}
	return list, ""
}

// mark_color_hex gives "#rrggbb".
mark_color_hex :: proc(color: u32) -> string {
	return fmt.tprintf("#%06x", color & 0xFFFFFF)
}

// The start of the name of the class of a rectangle of a vector file whose
// color is another one in the dark scheme; a number follows it.
MARK_VECTOR_DARK_CLASS :: "dark-"

// mark_vector_refusal gives the sentence that says why a picture cannot be
// a vector file, or "".
//
// The smooth variant is refused. Its gradient is linear across the
// picture, and a vector file can state a linear gradient; but the reader of
// the file would then compute each color, between two rounded colors and
// with its own rounding, and some pixels would be one unit away from the
// colors of the mark. In the cells variant a cell is one color that the
// tool computed, and a rectangle of one color is exact in every reader.
mark_vector_refusal :: proc(picture: Mark_Picture, dark_rule: bool) -> string {
	if refusal := mark_picture_refusal(picture); refusal != "" {
		return refusal
	}
	if picture.variant != .Cells {
		return "a vector file holds the cells variant only: each cell is a rectangle of one color that the tool computed; in the smooth variant the reader of the file would compute the gradient of each part, and round it in its own way; ask for the cells variant, or for a PNG file"
	}
	if dark_rule && !picture.on_light {
		return "the rule of the dark scheme gives the dark colors to a picture of the light scheme: ask for the light scheme"
	}
	return ""
}

// mark_pixel_color gives the color of the pixel number index of pixels of
// 3 or 4 bytes, and whether the pixel is covered: a pixel with an alpha of
// 0 is not.
@(private = "file")
mark_pixel_color :: proc(pixels: []u8, channels, index: int) -> (color: u32, covered: bool) {
	pixel := pixels[index * channels:][:channels]
	if channels == 4 && pixel[3] == 0 {
		return 0, false
	}
	return u32(pixel[0]) << 16 | u32(pixel[1]) << 8 | u32(pixel[2]), true
}

// mark_picture_svg gives a picture as a vector file: the pixels of the
// picture, cut into rectangles of one color. A run of pixels of one color
// in a row is one rectangle, and the rows that follow with the same pixels
// make it higher: at one pixel for a cell a rectangle is a run of cells,
// and at a larger cell size it has the height of a cell. One unit of the
// file is one pixel of the picture. The reader of the file draws the edges
// of the rectangles sharp.
//
// With the rule of the dark scheme, the fill of each rectangle is its
// color in the light scheme, and a rule of style gives its color in the
// dark scheme to a reader that asks for dark, when the two differ. A
// reader that does not apply the rule shows the light scheme.
//
// The caller asks mark_vector_refusal first.
mark_picture_svg :: proc(picture: Mark_Picture, cells: ^mark.Heron_Cells, dark_rule: bool) -> string {
	width, height := mark_picture_size(picture)
	channels := mark_picture_channels(picture)
	row_bytes := width * channels
	pixels := mark_picture_pixels(picture, cells)
	// The same picture in the dark scheme: the same pixels are covered.
	dark_pixels := pixels
	if dark_rule {
		dark_picture := picture
		dark_picture.on_light = false
		dark_pixels = mark_picture_pixels(dark_picture, cells)
	}
	rectangles := strings.builder_make(context.temp_allocator)
	dark_colors := make([dynamic]u32, context.temp_allocator) // The dark color of each class.
	light_colors := make([dynamic]u32, context.temp_allocator) // The light color of the rectangles of each class.
	y := 0
	for y < height {
		// The rows after this one that have its pixels, in both schemes.
		band_end := y + 1
		for band_end < height {
			same := string(pixels[band_end * row_bytes:][:row_bytes]) == string(pixels[y * row_bytes:][:row_bytes])
			same &&= string(dark_pixels[band_end * row_bytes:][:row_bytes]) == string(dark_pixels[y * row_bytes:][:row_bytes])
			if !same {
				break
			}
			band_end += 1
		}
		x := 0
		for x < width {
			color, covered := mark_pixel_color(pixels, channels, y * width + x)
			if !covered {
				x += 1
				continue
			}
			dark_color, _ := mark_pixel_color(dark_pixels, channels, y * width + x)
			run_end := x + 1
			for run_end < width {
				next_color, next_covered := mark_pixel_color(pixels, channels, y * width + run_end)
				next_dark_color, _ := mark_pixel_color(dark_pixels, channels, y * width + run_end)
				if !next_covered || next_color != color || next_dark_color != dark_color {
					break
				}
				run_end += 1
			}
			fmt.sbprintf(&rectangles, "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\"", x, y, run_end - x, band_end - y)
			if dark_color != color {
				class := -1
				for known, index in dark_colors {
					if known == dark_color && light_colors[index] == color {
						class = index
						break
					}
				}
				if class < 0 {
					class = len(dark_colors)
					append(&dark_colors, dark_color)
					append(&light_colors, color)
				}
				fmt.sbprintf(&rectangles, " class=\"%s%d\"", MARK_VECTOR_DARK_CLASS, class)
			}
			fmt.sbprintf(&rectangles, " fill=\"%s\"/>\n", mark_color_hex(color))
			x = run_end
		}
		y = band_end
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 %d %d\" width=\"%d\" height=\"%d\" shape-rendering=\"crispEdges\">\n", width, height, width, height)
	if len(dark_colors) > 0 {
		// The braces are written as text, never through a format of fmt.
		strings.write_string(&b, "<style>\n@media (prefers-color-scheme: dark) {\n")
		for dark_color, class in dark_colors {
			fmt.sbprintf(&b, ".%s%d ", MARK_VECTOR_DARK_CLASS, class)
			strings.write_string(&b, "{ fill: ")
			strings.write_string(&b, mark_color_hex(dark_color))
			strings.write_string(&b, "; }\n")
		}
		strings.write_string(&b, "}\n</style>\n")
	}
	strings.write_string(&b, strings.to_string(rectangles))
	strings.write_string(&b, "</svg>\n")
	return strings.to_string(b)
}

// One chunk of a PNG file: its type of four letters, its data, and whether
// the sum at its end is the sum of its type and its data.
Mark_Png_Chunk :: struct {
	type:         string,
	data:         []u8,
	sum_is_right: bool,
}

// mark_png_chunks reads the chunks of a PNG file: after the signature,
// each chunk is the length of its data (4 bytes, big endian), its type,
// its data and a sum of 4 bytes. Each length is checked against the size
// of the file before its use. The type and the data are views of the file.
mark_png_chunks :: proc(file: []u8) -> (chunks: []Mark_Png_Chunk, ok: bool) {
	if len(file) < len(PNG_SIGNATURE) || string(file[:len(PNG_SIGNATURE)]) != PNG_SIGNATURE {
		return nil, false
	}
	big_32 :: proc(bytes: []u8) -> int {
		return int(bytes[0]) << 24 | int(bytes[1]) << 16 | int(bytes[2]) << 8 | int(bytes[3])
	}
	list := make([dynamic]Mark_Png_Chunk, context.temp_allocator)
	at := len(PNG_SIGNATURE)
	for at < len(file) {
		if len(file) - at < 12 {
			return nil, false
		}
		length := big_32(file[at:][:4])
		if length > len(file) - at - 12 {
			return nil, false
		}
		summed := file[at + 4:][:4 + length]
		append(&list, Mark_Png_Chunk{type = string(summed[:4]), data = summed[4:], sum_is_right = int(hash.crc32(summed)) == big_32(file[at + 8 + length:][:4])})
		at += 12 + length
	}
	return list[:], true
}

// mark_png_chunk_write adds one chunk to a PNG file: the length of the
// data, the type, the data, and the sum of the type and the data.
mark_png_chunk_write :: proc(output: ^[dynamic]u8, type: string, data: []u8) {
	big_32 :: proc(output: ^[dynamic]u8, value: int) {
		append(output, u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value))
	}
	big_32(output, len(data))
	start := len(output)
	append_string(output, type)
	append(output, ..data)
	big_32(output, int(hash.crc32(output[start:])))
}

// The size of the data of the chunk that says how one frame of an animated
// PNG file is shown.
MARK_APNG_FRAME_CONTROL_SIZE :: 26
// How many times a reader plays an animated PNG file of the mark: 0 is
// with no end.
MARK_APNG_PLAYS :: 0

// mark_animation_png gives an animated PNG file of one animation: each
// frame of the animation as one picture, in its place, for the time that
// the table of the animations gives it. It does not show the move of the
// heron across a page.
//
// The file is a PNG file with three more kinds of chunk. `acTL`, after the
// header, holds the count of the frames and of the plays. `fcTL`, before
// the data of each frame, holds a number of order, the size and the place
// of the frame, and its time as a fraction of a second. The data of the
// first frame is in `IDAT` chunks, so a reader that does not know the
// animation shows the first frame; the data of each next frame is in
// `fdAT` chunks, each with a number of order before the data. The data of
// a frame is the data of the PNG file that the generator writes for that
// frame: no pixel is computed here. Each frame has the whole size and
// replaces the frame before it.
mark_animation_png :: proc(picture: Mark_Picture, animation: mark.Animation) -> (file: []u8, ok: bool) {
	big_16 :: proc(output: ^[dynamic]u8, value: int) {
		append(output, u8(value >> 8), u8(value))
	}
	big_32 :: proc(output: ^[dynamic]u8, value: int) {
		append(output, u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value))
	}
	count := mark.animation_frame_count(animation)
	width, height := mark_picture_size(picture)
	output := make([dynamic]u8, context.temp_allocator)
	append_string(&output, PNG_SIGNATURE)
	header: []u8
	sequence := 0
	for frame in 1 ..= count {
		cells, cells_found := mark.animation_frame_cells(animation, frame)
		row, row_found := mark.animation_frame(animation, frame)
		if !cells_found || !row_found {
			fmt.eprintfln("kerneltool: the animation %s of the mark has no frame %d", mark.animation_names[animation], frame)
			return nil, false
		}
		data := mark_frame_png(picture, &cells) or_return
		chunks := mark_png_chunks(data) or_return
		if len(chunks) == 0 || chunks[0].type != "IHDR" {
			fmt.eprintfln("kerneltool: the PNG file of the frame %d of %s has no header", frame, picture.file_name)
			return nil, false
		}
		if frame == 1 {
			header = chunks[0].data
			mark_png_chunk_write(&output, "IHDR", header)
			animation_control := make([dynamic]u8, context.temp_allocator)
			big_32(&animation_control, count)
			big_32(&animation_control, MARK_APNG_PLAYS)
			mark_png_chunk_write(&output, "acTL", animation_control[:])
		} else if string(chunks[0].data) != string(header) {
			// One header serves every frame: the kind of the pixels of a
			// frame cannot differ from the first.
			fmt.eprintfln("kerneltool: the PNG file of the frame %d of %s has another header than the first frame", frame, picture.file_name)
			return nil, false
		}
		frame_control := make([dynamic]u8, context.temp_allocator)
		big_32(&frame_control, sequence)
		sequence += 1
		big_32(&frame_control, width)
		big_32(&frame_control, height)
		big_32(&frame_control, 0) // The frame starts at the left edge
		big_32(&frame_control, 0) // and at the top.
		big_16(&frame_control, int(row.duration_milliseconds)) // The time: this many
		big_16(&frame_control, 1000) // thousandths of a second.
		append(&frame_control, 0) // After its time the frame stays until the next one is drawn.
		append(&frame_control, 0) // The next frame replaces every pixel, also with a transparent one.
		assert(len(frame_control) == MARK_APNG_FRAME_CONTROL_SIZE)
		mark_png_chunk_write(&output, "fcTL", frame_control[:])
		for chunk in chunks[1:] {
			switch chunk.type {
			case "IDAT":
				if frame == 1 {
					mark_png_chunk_write(&output, "IDAT", chunk.data)
					continue
				}
				frame_data := make([dynamic]u8, context.temp_allocator)
				big_32(&frame_data, sequence)
				sequence += 1
				append(&frame_data, ..chunk.data)
				mark_png_chunk_write(&output, "fdAT", frame_data[:])
			case "IEND":
			case:
				// A chunk whose type starts with a capital letter is one
				// that a reader needs for the pixels, a palette for one:
				// the frames would then not share one header.
				if chunk.type[0] >= 'A' && chunk.type[0] <= 'Z' {
					fmt.eprintfln("kerneltool: the PNG file of the frame %d of %s has a chunk %s that an animated file cannot hold for one frame", frame, picture.file_name, chunk.type)
					return nil, false
				}
			}
		}
	}
	mark_png_chunk_write(&output, "IEND", nil)
	return output[:], true
}

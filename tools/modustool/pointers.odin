package modustool

import "modus:contract/pointer_pictures"
import "modus:support/graphics"
import "modus:support/vector_font"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// The pointer themes (docs/POINTERS.md). The command "pointers" reads a
// pointer manifest of resources/pointers, and for a manifest with sources
// the folder of an Xcursor theme, and writes one pointer theme file for
// each theme in build/pointers. A shape with no source is an outline: the
// tool draws its contours at each size with the rasterizer of the vector font,
// so the theme of the system has smooth edges and no pixel in the
// repository. `build` runs the same code: each theme file is a resource of
// the boot image.
//
// The folder of the theme of the owner comes from the flake: the variable
// POINTER_THEME_SOURCE, or a path after the command. With neither, the
// tool makes the theme of the system only.

POINTER_THEME_SOURCE_VARIABLE :: "POINTER_THEME_SOURCE"
POINTER_BUILD_FOLDER :: BUILD_FOLDER + "/pointers"
SYSTEM_POINTER_MANIFEST :: "resources/pointers/system.manifest" // The outlines of the theme of the system.
LINK_DEPTH_LIMIT :: 8
// A coordinate of an outline is a number of units with at most three
// decimals, kept in thousandths: integers only, so that every machine
// makes the same pixels.
OUTLINE_COORDINATE_SCALE :: 1000
OUTLINE_COORDINATE_DECIMALS :: 3
// The two colors of an outline: the dark of the desktop and white. The dark
// form has a white fill in a dark edge, for a dark desktop; the light form
// a dark fill in a white edge, for a light desktop (docs/POINTERS.md, "5. The
// two themes").
POINTER_DARK_COLOR :: u32(graphics.COLOR_BACKGROUND)
POINTER_LIGHT_COLOR :: u32(graphics.COLOR_WHITE)
// The edge of an outline is 1 pixel at every size: drawn from the contours,
// so a larger size has a finer edge, not a thicker one.
OUTLINE_EDGE_SUBUNITS :: vector_font.SUBUNITS_PER_PIXEL

// The fill and the edge of each form.
Pointer_Form_Colors :: struct {
	fill: u32,
	edge: u32,
}

POINTER_FORM_COLORS := [pointer_pictures.Pointer_Form]Pointer_Form_Colors {
	.Dark  = {fill = POINTER_LIGHT_COLOR, edge = POINTER_DARK_COLOR},
	.Light = {fill = POINTER_DARK_COLOR, edge = POINTER_LIGHT_COLOR},
}

// An accent of a pointer: a color token of the design rules (the name of
// its constant in modus:support/graphics, with no COLOR_), with its value
// for a dark surround and for a light surround. An accent inside the fill
// has the fill around it; an accent with an edge has the edge around it.
// The value for a light surround is the value that the light form of the
// site gives the token: a darker shade, which keeps 3 to 1 on white.
Pointer_Accent :: struct {
	name:     string,
	on_dark:  u32,
	on_light: u32,
}

// pointer_accents gives the tokens that a manifest can name.
pointer_accents :: proc() -> [3]Pointer_Accent {
	return {
		// The blue of the title bar and of the focus.
		{name = "title", on_dark = graphics.COLOR_TITLE, on_light = graphics.shade(graphics.COLOR_TITLE, 85)},
		// The red of "stop a program": its bright form under the pointer on
		// a dark surround, its deep form on a light one.
		{name = "stop_program", on_dark = graphics.COLOR_STOP_PROGRAM_POINTER_OVER, on_light = graphics.COLOR_STOP_PROGRAM},
		// The amber of a match, as the search of the site marks it.
		{name = "boot_program", on_dark = graphics.COLOR_BOOT_PROGRAM, on_light = graphics.shade(graphics.COLOR_BOOT_PROGRAM, 50)},
	}
}

// pointer_layer_color gives the color of a layer in a form: an accent takes
// the value of its token for the color around it.
pointer_layer_color :: proc(layer: Outline_Layer, form: pointer_pictures.Pointer_Form) -> u32 {
	colors := POINTER_FORM_COLORS[form]
	switch layer.paint {
	case .Fill:
		return colors.fill
	case .Edge:
		return colors.edge
	case .Accent:
		around := layer.inside ? colors.fill : colors.edge
		accents := pointer_accents()
		accent := accents[layer.accent]
		value := around == POINTER_DARK_COLOR ? accent.on_dark : accent.on_light
		// A faded accent: the token mixed into the color around it, so a
		// sweep of one token needs no color of its own.
		return graphics.mix(around, value, layer.strength * 255 / 100)
	case .Clear:
	}
	return 0
}

// One pointer theme that the build makes.
//   resource: its name in the resource table of the boot image.
//   needs_source: the manifest names files of an Xcursor theme.
Pointer_Theme_Build :: struct {
	resource:     string,
	manifest:     string,
	output:       string,
	needs_source: bool,
}

pointer_theme_builds := [?]Pointer_Theme_Build {
	{resource = pointer_pictures.RESOURCE_OF_THE_OWNER, manifest = "resources/pointers/posy.manifest", output = POINTER_BUILD_FOLDER + "/posy.pointers", needs_source = true},
	{resource = pointer_pictures.RESOURCE_OF_THE_SYSTEM, manifest = SYSTEM_POINTER_MANIFEST, output = POINTER_BUILD_FOLDER + "/system.pointers"},
}

// The build makes the theme of the owner when its source is there. The
// command `release image` sets this to false: the license of that theme
// does not allow a public download, so a release image holds the theme of
// the system only (src/md/infrastructure/release_image.md).
build_pointer_theme_of_the_owner := true

// pointer_theme_source_of_the_build gives the Xcursor folder for the theme
// of the owner, or "" when this build makes the theme of the system only.
pointer_theme_source_of_the_build :: proc() -> string {
	if !build_pointer_theme_of_the_owner {
		return ""
	}
	return os.get_env(POINTER_THEME_SOURCE_VARIABLE, context.temp_allocator)
}

// A theme file that the build made: a resource of the boot image.
Resource_File :: struct {
	name: string,
	path: string,
}

run_pointers :: proc(args: []string) -> int {
	if len(args) > 0 && args[0] == "preview" {
		if len(args) != 2 {
			fmt.eprintln("modustool: pointers preview <file.png>: draws each shape of the theme of the system in one picture")
			return EXIT_FAILURE
		}
		return run_pointers_preview(args[1]) // pointers_preview.odin
	}
	source := len(args) > 0 ? args[0] : os.get_env(POINTER_THEME_SOURCE_VARIABLE, context.temp_allocator)
	_, ok := build_pointer_themes(source, true)
	return ok ? 0 : EXIT_FAILURE
}

// build_pointer_themes makes each theme of pointer_theme_builds whose
// source is there. With print_tables, it prints a table for each theme.
build_pointer_themes :: proc(source: string, print_tables: bool) -> (resources: []Resource_File, ok: bool) {
	if err := os.make_directory_all(POINTER_BUILD_FOLDER); err != nil && err != .Exist {
		fmt.eprintfln("modustool: cannot make %s: %v", POINTER_BUILD_FOLDER, err)
		return nil, false
	}
	list := make([dynamic]Resource_File, context.temp_allocator)
	for build in pointer_theme_builds {
		if build.needs_source && !build_pointer_theme_of_the_owner {
			fmt.printfln("modustool: pointers: a release image holds the theme of the system only: the boot image has no %s", build.resource)
			continue
		}
		if build.needs_source && source == "" {
			fmt.printfln("modustool: pointers: %s is not set: the boot image has no %s, only the theme of the system", POINTER_THEME_SOURCE_VARIABLE, build.resource)
			continue
		}
		text, read_ok := read_file(build.manifest)
		if !read_ok {
			return nil, false
		}
		start := time.tick_now()
		manifest, problem := manifest_parse(build.manifest, string(text))
		if problem != "" {
			fmt.eprintfln("modustool: %s", problem)
			return nil, false
		}
		file, rows, made_problem := pointer_theme_make(manifest, build.needs_source ? source : "")
		if made_problem != "" {
			fmt.eprintfln("modustool: %s: %s", build.manifest, made_problem)
			return nil, false
		}
		spent := time.tick_since(start)
		if err := os.write_entire_file(build.output, file); err != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", build.output, err)
			return nil, false
		}
		head := pointer_pictures.header(file)
		fmt.printfln("modustool: pointers: %s: %d shapes, %d pictures, %d bytes, from %s in %.1f ms", build.resource, head.shape_count, head.picture_count, len(file), build.manifest, time.duration_milliseconds(spent))
		if print_tables {
			fmt.printfln("  %-30s %-26s %-10s %6s %9s", "shape", "source", "sizes", "frames", "bytes")
			for row in rows {
				fmt.printfln("  %-30s %-26s %-10s %6s %9s", row.shape, row.source, row.sizes, fmt.tprint(row.frames), fmt.tprint(row.bytes))
			}
		}
		append(&list, Resource_File{name = build.resource, path = build.output})
	}
	return list[:], true
}

// ---- The Xcursor reader ----

XCURSOR_MAGIC :: 0x72756358 // The bytes "Xcur".
XCURSOR_FILE_HEADER :: 16
XCURSOR_IMAGE_TYPE :: 0xFFFD0002
XCURSOR_IMAGE_HEADER :: 36
XCURSOR_SIDE_LIMIT :: 0x7FFF
XCURSOR_ENTRY_LIMIT :: 1 << 16

// One image chunk of an Xcursor file.
Xcursor_Image :: struct {
	nominal_size: u32,
	width:        u32,
	height:       u32,
	hot_spot_x:   u32,
	hot_spot_y:   u32,
	delay:        u32,
	pixels:       []u32,
}

@(private = "file")
word_at :: proc(file: []u8, offset: u64) -> u32 {
	return u32(file[offset]) | u32(file[offset + 1]) << 8 | u32(file[offset + 2]) << 16 | u32(file[offset + 3]) << 24
}

// xcursor_read reads the image chunks of an Xcursor file, in the order of
// its table of contents. The file is hostile input: each offset and count
// is checked before a read. It gives "" or the sentence of the first
// problem, with its byte.
xcursor_read :: proc(file: []u8, images: ^[dynamic]Xcursor_Image) -> string {
	length := u64(len(file))
	if length < XCURSOR_FILE_HEADER {
		return fmt.tprintf("the file has %d bytes; the header of an Xcursor file has 16", length)
	}
	if magic := word_at(file, 0); magic != XCURSOR_MAGIC {
		return fmt.tprintf("byte 0: the magic is 0x%08x, not \"Xcur\"", magic)
	}
	header := u64(word_at(file, 4))
	if header < XCURSOR_FILE_HEADER || header > length {
		return fmt.tprintf("byte 4: the header has %d bytes: not 16 to the size of the file (%d)", header, length)
	}
	entries := u64(word_at(file, 12))
	if entries > XCURSOR_ENTRY_LIMIT || entries * 12 > length - header {
		return fmt.tprintf("byte 12: %d entries of the table of contents do not fit in the %d bytes after the header", entries, length - header)
	}
	for entry in 0 ..< entries {
		at := header + entry * 12
		kind := word_at(file, at)
		subtype := word_at(file, at + 4)
		position := u64(word_at(file, at + 8))
		if kind != XCURSOR_IMAGE_TYPE {
			continue // A comment, or a chunk of another kind.
		}
		if position > length || length - position < XCURSOR_IMAGE_HEADER {
			return fmt.tprintf("byte %d: entry %d puts an image at byte %d, past the end of the file (%d bytes)", at + 8, entry, position, length)
		}
		chunk_header := word_at(file, position)
		chunk_kind := word_at(file, position + 4)
		chunk_subtype := word_at(file, position + 8)
		version := word_at(file, position + 12)
		image := Xcursor_Image {
			nominal_size = chunk_subtype,
			width        = word_at(file, position + 16),
			height       = word_at(file, position + 20),
			hot_spot_x   = word_at(file, position + 24),
			hot_spot_y   = word_at(file, position + 28),
			delay        = word_at(file, position + 32),
		}
		switch {
		case chunk_header != XCURSOR_IMAGE_HEADER:
			return fmt.tprintf("byte %d: the image header has %d bytes, not 36", position, chunk_header)
		case chunk_kind != kind || chunk_subtype != subtype:
			return fmt.tprintf("byte %d: the image has the type 0x%08x and the size %d; the table of contents says 0x%08x and %d", position + 4, chunk_kind, chunk_subtype, kind, subtype)
		case version != 1:
			return fmt.tprintf("byte %d: the image has the version %d, not 1", position + 12, version)
		case image.width == 0 || image.width > XCURSOR_SIDE_LIMIT || image.height == 0 || image.height > XCURSOR_SIDE_LIMIT:
			return fmt.tprintf("byte %d: the image is %d x %d: each side must be 1 to 32767", position + 16, image.width, image.height)
		case image.hot_spot_x >= image.width || image.hot_spot_y >= image.height:
			return fmt.tprintf("byte %d: the hot spot %d,%d is not a pixel of the image of %d x %d", position + 24, image.hot_spot_x, image.hot_spot_y, image.width, image.height)
		}
		count := u64(image.width) * u64(image.height)
		if count * 4 > length - position - XCURSOR_IMAGE_HEADER {
			return fmt.tprintf("byte %d: %d x %d pixels pass the end of the file (%d bytes)", position + 36, image.width, image.height, length)
		}
		image.pixels = make([]u32, count, context.temp_allocator)
		for &pixel, index in image.pixels {
			pixel = word_at(file, position + XCURSOR_IMAGE_HEADER + u64(index) * 4)
		}
		append(images, image)
	}
	if len(images) == 0 {
		return "the file has no image"
	}
	return ""
}

// ---- The manifest ----

// The paint of a layer of an outline, by its role: the fill and the edge of
// the form, an accent, or Clear, which makes its contours transparent again.
// The colors of a role are in each form (POINTER_FORM_COLORS).
Outline_Paint :: enum u8 {
	Fill,
	Accent,
	Edge,
	Clear,
}

// One piece of a contour: a line to a point, or a quadratic curve with its
// control point. Coordinates are in thousandths of a unit.
Outline_Segment :: struct {
	control: [2]i64,
	to:      [2]i64,
	curve:   bool,
}

// A closed contour: from its start through its segments, and a line back
// to its start.
Outline_Contour :: struct {
	start:       [2]i64,
	segments:    [dynamic]Outline_Segment,
	line:        int, // The line of its statement, for the errors after the parse.
	from_circle: bool, // A statement "circle" made it: "line" and "curve" add nothing to it.
}

// The contours of one paint. The contours of one layer are a union.
//   accent: the place of its token in pointer_accents, for an accent.
//   inside: a fill or an accent with no edge of its own, inside the fill.
//   strength: for an accent, the percent of its token over the color around
//   it: 100 is the token, less fades it into that color.
Outline_Layer :: struct {
	paint:    Outline_Paint,
	accent:   int,
	inside:   bool,
	strength: u32,
	contours: [dynamic]Outline_Contour,
	line:     int,
}

// One frame of an animated outline: its delay, and the layers that it adds
// over the layers of every frame.
Outline_Frame :: struct {
	delay:  u32,
	layers: [dynamic]Outline_Layer,
}

Manifest_Shape :: struct {
	shape:        pointer_pictures.Pointer_Shape,
	line:         int, // The line of the statement "shape", for the errors after the parse.
	sources:      [dynamic]string,
	hot_spot:     [2]u32,
	has_hot_spot: bool,
	sizes:        [dynamic]u32, // Empty: the sizes of the manifest.
	layers:       [dynamic]Outline_Layer, // An outline: the layers of every frame, before the first "frame".
	frames:       [dynamic]Outline_Frame, // An animated outline: two frames at least. Empty: one frame.
}

Manifest :: struct {
	path:        string,
	theme_name:  string,
	license:     string,
	attribution: string,
	sizes:       [dynamic]u32,
	shapes:      [dynamic]Manifest_Shape,
}

// A word of a line: its text and its column (from 1).
@(private = "file")
Word :: struct {
	text:   string,
	column: int,
}

@(private = "file")
words_of :: proc(line: string) -> []Word {
	words := make([dynamic]Word, context.temp_allocator)
	index := 0
	for index < len(line) {
		if line[index] == ' ' {
			index += 1
			continue
		}
		start := index
		for index < len(line) && line[index] != ' ' {
			index += 1
		}
		append(&words, Word{text = line[start:index], column = start + 1})
	}
	return words[:]
}

// The sentence of an error of a manifest.
@(private = "file")
manifest_fail :: proc(path: string, line, column: int, expected: string, found: string) -> string {
	return fmt.tprintf("%s:%d:%d: expected %s; found %s", path, line, column, expected, found)
}

@(private = "file")
manifest_quoted :: proc(text: string) -> string {
	return len(text) == 0 ? "the end of the line" : fmt.tprintf("\"%s\"", text)
}

// manifest_parse reads a pointer manifest (docs/POINTERS.md, section 4).
// An error is one sentence: "path:line:column: expected ...; found ...".
manifest_parse :: proc(path: string, text: string) -> (manifest: Manifest, problem: string) {
	manifest.path = path
	manifest.sizes = make([dynamic]u32, context.temp_allocator)
	manifest.shapes = make([dynamic]Manifest_Shape, context.temp_allocator)
	attribution := strings.builder_make(context.temp_allocator)
	fail :: manifest_fail
	quoted :: manifest_quoted
	number_of :: proc(word: Word, low, high: u64) -> (value: u32, ok: bool) {
		parsed, parsed_ok := strconv.parse_u64_of_base(word.text, 10)
		if !parsed_ok || parsed < low || parsed > high {
			return 0, false
		}
		return u32(parsed), true
	}
	sizes_of :: proc(path: string, line: int, words: []Word, end_column: int, sizes: ^[dynamic]u32) -> (rest: []Word, problem: string) {
		index := 0
		for index < len(words) {
			value, ok := number_of(words[index], 1, pointer_pictures.PICTURE_SIDE_LIMIT)
			if !ok {
				break
			}
			if len(sizes) > 0 && value <= sizes[len(sizes) - 1] {
				return nil, fail(path, line, words[index].column, fmt.tprintf("a size larger than %d", sizes[len(sizes) - 1]), quoted(words[index].text))
			}
			append(sizes, value)
			index += 1
		}
		if index == 0 {
			column := len(words) > 0 ? words[0].column : end_column
			return nil, fail(path, line, column, "a nominal size from 1 to 256", quoted(len(words) > 0 ? words[0].text : ""))
		}
		return words[index:], ""
	}

	shape: ^Manifest_Shape
	line_number := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_number += 1
		for index in 0 ..< len(line) {
			if line[index] < 32 || line[index] > 126 {
				return {}, fail(path, line_number, index + 1, "a character of ASCII 32 to 126", fmt.tprintf("the byte %d", line[index]))
			}
		}
		statement := line
		if comment := strings.index_byte(statement, '#'); comment >= 0 {
			statement = statement[:comment]
		}
		words := words_of(statement)
		if len(words) == 0 {
			continue
		}
		keyword := words[0]
		if manifest.theme_name == "" && keyword.text != "theme" {
			return {}, fail(path, line_number, keyword.column, "the statement \"theme\" first", quoted(keyword.text))
		}
		switch keyword.text {
		case "theme", "attribution":
			value := strings.trim_space(statement[keyword.column - 1 + len(keyword.text):])
			if keyword.text == "attribution" {
				if strings.builder_len(attribution) > 0 {
					strings.write_byte(&attribution, ' ')
				}
				strings.write_string(&attribution, value)
				if strings.builder_len(attribution) > pointer_pictures.ATTRIBUTION_CAPACITY - 1 {
					return {}, fail(path, line_number, keyword.column, "at most 399 characters of attribution in all", fmt.tprintf("%d", strings.builder_len(attribution)))
				}
				continue
			}
			if manifest.theme_name != "" {
				return {}, fail(path, line_number, keyword.column, "one statement \"theme\"", "a second one")
			}
			if len(value) == 0 || len(value) > pointer_pictures.NAME_CAPACITY - 1 {
				return {}, fail(path, line_number, len(words) > 1 ? words[1].column : len(line) + 1, "a theme name of 1 to 31 characters", quoted(value))
			}
			manifest.theme_name = value
		case "license":
			if manifest.license != "" {
				return {}, fail(path, line_number, keyword.column, "one statement \"license\"", "a second one")
			}
			if len(words) != 2 || len(words[1].text) > pointer_pictures.LICENSE_CAPACITY - 1 {
				return {}, fail(path, line_number, len(words) > 1 ? words[1].column : len(line) + 1, "one SPDX identifier of 1 to 31 characters", quoted(len(words) > 1 ? statement[words[1].column - 1:] : ""))
			}
			manifest.license = words[1].text
		case "sizes":
			if len(manifest.sizes) > 0 || len(manifest.shapes) > 0 {
				return {}, fail(path, line_number, keyword.column, "one statement \"sizes\", before the shapes", quoted(keyword.text))
			}
			after, sizes_problem := sizes_of(path, line_number, words[1:], len(statement) + 1, &manifest.sizes)
			if sizes_problem != "" {
				return {}, sizes_problem
			}
			if len(after) > 0 {
				return {}, fail(path, line_number, after[0].column, "a nominal size from 1 to 256, or the end of the line", quoted(after[0].text))
			}
		case "shape":
			if len(manifest.sizes) == 0 {
				return {}, fail(path, line_number, keyword.column, "the statement \"sizes\" before the shapes", quoted(keyword.text))
			}
			if len(words) < 2 {
				return {}, fail(path, line_number, len(line) + 1, "a pointer shape name such as \"arrow\"", "the end of the line")
			}
			found, known := pointer_pictures.shape_of_name(words[1].text)
			if !known {
				return {}, fail(path, line_number, words[1].column, "a pointer shape name such as \"arrow\"", quoted(words[1].text))
			}
			for &other in manifest.shapes {
				if other.shape == found {
					return {}, fail(path, line_number, words[1].column, fmt.tprintf("a shape that line %d does not name", other.line), quoted(words[1].text))
				}
			}
			if shape_problem := shape_check_end(&manifest, shape); shape_problem != "" {
				return {}, shape_problem
			}
			append(&manifest.shapes, Manifest_Shape{shape = found, line = line_number, sources = make([dynamic]string, context.temp_allocator), sizes = make([dynamic]u32, context.temp_allocator), layers = make([dynamic]Outline_Layer, context.temp_allocator), frames = make([dynamic]Outline_Frame, context.temp_allocator)})
			shape = &manifest.shapes[len(manifest.shapes) - 1]
			index := 2
			for index < len(words) {
				word := words[index]
				switch word.text {
				case "hot":
					if shape.has_hot_spot {
						return {}, fail(path, line_number, word.column, "one option \"hot\"", "a second one")
					}
					if index + 2 >= len(words) {
						column := index + 1 < len(words) ? words[index + 1].column : len(statement) + 1
						return {}, fail(path, line_number, column, "two numbers after \"hot\"", quoted(strings.trim_space(statement[column - 1:])))
					}
					x, x_ok := number_of(words[index + 1], 0, pointer_pictures.PICTURE_SIDE_LIMIT - 1)
					y, y_ok := number_of(words[index + 2], 0, pointer_pictures.PICTURE_SIDE_LIMIT - 1)
					if !x_ok || !y_ok {
						bad := !x_ok ? words[index + 1] : words[index + 2]
						return {}, fail(path, line_number, bad.column, "a number from 0 to 255", quoted(bad.text))
					}
					shape.hot_spot = {x, y}
					shape.has_hot_spot = true
					index += 3
				case "sizes":
					if len(shape.sizes) > 0 {
						return {}, fail(path, line_number, word.column, "one option \"sizes\"", "a second one")
					}
					after, sizes_problem := sizes_of(path, line_number, words[index + 1:], len(statement) + 1, &shape.sizes)
					if sizes_problem != "" {
						return {}, sizes_problem
					}
					index = len(words) - len(after)
				case:
					if shape.has_hot_spot || len(shape.sizes) > 0 {
						return {}, fail(path, line_number, word.column, "an option \"hot\" or \"sizes\" after the options", quoted(word.text))
					}
					for character in word.text {
						if !(character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' || character == '_' || character == '-') {
							return {}, fail(path, line_number, word.column, "a file name of letters, digits, \"_\" and \"-\"", quoted(word.text))
						}
					}
					append(&shape.sources, word.text)
					index += 1
				}
			}
		case "frame":
			if shape == nil || len(shape.sources) > 0 {
				return {}, fail(path, line_number, keyword.column, "a statement \"frame\" only after a statement \"shape\" with no source", quoted(keyword.text))
			}
			if len(words) != 2 {
				return {}, fail(path, line_number, len(words) > 1 ? words[2].column : len(line) + 1, "one delay in milliseconds", quoted(len(words) > 2 ? words[2].text : ""))
			}
			delay, ok := number_of(words[1], 1, pointer_pictures.DELAY_LIMIT)
			if !ok {
				return {}, fail(path, line_number, words[1].column, "a delay of 1 to 60000 milliseconds", quoted(words[1].text))
			}
			if len(shape.frames) == pointer_pictures.FRAME_COUNT_LIMIT {
				return {}, fail(path, line_number, keyword.column, "at most 256 frames", "one more")
			}
			append(&shape.frames, Outline_Frame{delay = delay, layers = make([dynamic]Outline_Layer, context.temp_allocator)})
		case "layer":
			if shape == nil || len(shape.sources) > 0 {
				return {}, fail(path, line_number, keyword.column, "an outline only after a statement \"shape\" with no source", quoted(keyword.text))
			}
			layer := Outline_Layer {
				contours = make([dynamic]Outline_Contour, context.temp_allocator),
				line     = line_number,
				strength = 100,
			}
			// The words after the paint: the token of an accent, then
			// "inside" for a fill or an accent.
			next := 2
			switch len(words) > 1 ? words[1].text : "" {
			case "fill":
				layer.paint = .Fill
			case "edge":
				layer.paint = .Edge
			case "clear":
				layer.paint = .Clear
			case "accent":
				layer.paint = .Accent
				known := false
				accents := pointer_accents()
				if len(words) > 2 {
					for accent, index in accents {
						if accent.name == words[2].text {
							layer.accent = index
							known = true
						}
					}
				}
				if !known {
					return {}, fail(path, line_number, len(words) > 2 ? words[2].column : len(statement) + 1, "the name of an accent: \"title\", \"stop_program\" or \"boot_program\"", quoted(len(words) > 2 ? words[2].text : ""))
				}
				next = 3
			case:
				return {}, fail(path, line_number, len(words) > 1 ? words[1].column : len(statement) + 1, "a paint \"fill\", \"accent\", \"edge\" or \"clear\"", quoted(len(words) > 1 ? words[1].text : ""))
			}
			if next < len(words) && words[next].text == "inside" && (layer.paint == .Fill || layer.paint == .Accent) {
				layer.inside = true
				next += 1
			}
			if next < len(words) && words[next].text == "fade" && layer.paint == .Accent {
				strength: u32
				strength_ok := false
				if next + 1 < len(words) {
					strength, strength_ok = number_of(words[next + 1], 1, 100)
				}
				if !strength_ok {
					column := next + 1 < len(words) ? words[next + 1].column : len(statement) + 1
					return {}, fail(path, line_number, column, "a strength of 1 to 100 percent after \"fade\"", quoted(next + 1 < len(words) ? words[next + 1].text : ""))
				}
				layer.strength = strength
				next += 2
			}
			if next < len(words) {
				return {}, fail(path, line_number, words[next].column, "the end of the line", quoted(words[next].text))
			}
			append(outline_layers_now(shape), layer)
		case "contour", "line", "curve", "circle":
			if outline_problem := outline_statement_parse(path, line_number, words, len(statement) + 1, &manifest, shape); outline_problem != "" {
				return {}, outline_problem
			}
		case:
			return {}, fail(path, line_number, keyword.column, "a statement \"theme\", \"license\", \"attribution\", \"sizes\", \"shape\", \"frame\", \"layer\", \"contour\", \"line\", \"curve\" or \"circle\"", quoted(keyword.text))
		}
	}
	if shape_problem := shape_check_end(&manifest, shape); shape_problem != "" {
		return {}, shape_problem
	}
	end := line_number + 1
	switch {
	case manifest.theme_name == "":
		return {}, fail(path, end, 1, "the statement \"theme\"", "the end of the file")
	case manifest.license == "":
		return {}, fail(path, end, 1, "the statement \"license\"", "the end of the file")
	case len(manifest.shapes) == 0:
		return {}, fail(path, end, 1, "a statement \"shape\"", "the end of the file")
	}
	has_arrow := false
	for &item in manifest.shapes {
		has_arrow ||= item.shape == .Arrow
	}
	if !has_arrow {
		return {}, fail(path, end, 1, "the shape \"arrow\": the shape that the compositor shows by default", "the end of the file")
	}
	manifest.attribution = strings.to_string(attribution)
	return manifest, ""
}

// shape_check_end checks a shape when the statement after it starts: a
// shape with no source has an outline with a hot spot inside its square,
// each layer has a contour, each contour two segments at least, and an
// animation has two frames at least, each with a layer.
@(private = "file")
shape_check_end :: proc(manifest: ^Manifest, shape: ^Manifest_Shape) -> string {
	if shape == nil {
		return ""
	}
	at :: proc(manifest: ^Manifest, shape: ^Manifest_Shape, expected: string) -> string {
		return fmt.tprintf("%s:%d:1: expected %s; found the shape %s with none", manifest.path, shape.line, expected, pointer_pictures.SHAPE_NAMES[shape.shape])
	}
	layers_check :: proc(manifest: ^Manifest, layers: []Outline_Layer) -> string {
		for layer in layers {
			if len(layer.contours) == 0 {
				return fmt.tprintf("%s:%d:1: expected a contour after the statement \"layer\"; found none", manifest.path, layer.line)
			}
			for item in layer.contours {
				if len(item.segments) < 2 {
					return fmt.tprintf("%s:%d:1: expected a contour of 2 segments at least; found %d", manifest.path, item.line, len(item.segments))
				}
			}
		}
		return ""
	}
	if len(shape.sources) > 0 {
		return ""
	}
	if len(shape.layers) == 0 && len(shape.frames) == 0 {
		return at(manifest, shape, "a source file or an outline")
	}
	if !shape.has_hot_spot {
		return at(manifest, shape, "the option \"hot\" for an outline")
	}
	if len(shape.frames) == 1 {
		return at(manifest, shape, "2 statements \"frame\" at least for an animation")
	}
	design := outline_design_size(manifest, shape)
	if shape.hot_spot.x >= design || shape.hot_spot.y >= design {
		return fmt.tprintf("%s:%d:1: expected a hot spot inside the square of %d units; found %d,%d", manifest.path, shape.line, design, shape.hot_spot.x, shape.hot_spot.y)
	}
	if layers_problem := layers_check(manifest, shape.layers[:]); layers_problem != "" {
		return layers_problem
	}
	for frame in shape.frames {
		if len(frame.layers) == 0 {
			return at(manifest, shape, "the layers of an outline after each \"frame\"")
		}
		if frame_problem := layers_check(manifest, frame.layers[:]); frame_problem != "" {
			return frame_problem
		}
	}
	return ""
}

// outline_design_size gives the size whose pixels are the units of an
// outline: the first size of the shape.
@(private = "file")
outline_design_size :: proc(manifest: ^Manifest, shape: ^Manifest_Shape) -> u32 {
	return len(shape.sizes) > 0 ? shape.sizes[0] : manifest.sizes[0]
}

// outline_layers_now gives the layers that a statement "layer" adds to: the
// layers of the last frame, or the layers of every frame before the first
// statement "frame".
@(private = "file")
outline_layers_now :: proc(shape: ^Manifest_Shape) -> ^[dynamic]Outline_Layer {
	if len(shape.frames) > 0 {
		return &shape.frames[len(shape.frames) - 1].layers
	}
	return &shape.layers
}

// coordinate_of reads a coordinate of an outline: 1 to 3 digits, then
// optionally a point and 1 to 3 decimals. It gives thousandths of a unit,
// and false for another word or a value above the limit.
@(private = "file")
coordinate_of :: proc(text: string, limit: i64) -> (value: i64, ok: bool) {
	whole, fraction := text, ""
	if dot := strings.index_byte(text, '.'); dot >= 0 {
		whole, fraction = text[:dot], text[dot + 1:]
		if len(fraction) == 0 {
			return 0, false
		}
	}
	if len(whole) == 0 || len(whole) > 3 || len(fraction) > OUTLINE_COORDINATE_DECIMALS {
		return 0, false
	}
	for character in whole {
		if character < '0' || character > '9' {
			return 0, false
		}
		value = value * 10 + i64(character - '0')
	}
	value *= OUTLINE_COORDINATE_SCALE
	place: i64 = OUTLINE_COORDINATE_SCALE / 10
	for character in fraction {
		if character < '0' || character > '9' {
			return 0, false
		}
		value += i64(character - '0') * place
		place /= 10
	}
	return value, value <= limit
}

// outline_statement_parse reads a line of contour statements: "contour x
// y", "line x y", "curve cx cy x y" and "circle x y radius", one after the
// other. A contour goes in the last layer; each point is inside the square
// of the design size, so no picture is cut.
@(private = "file")
outline_statement_parse :: proc(path: string, line_number: int, words: []Word, end_column: int, manifest: ^Manifest, shape: ^Manifest_Shape) -> string {
	if shape == nil || len(shape.sources) > 0 {
		return manifest_fail(path, line_number, words[0].column, "an outline only after a statement \"shape\" with no source", manifest_quoted(words[0].text))
	}
	layers := outline_layers_now(shape)
	if len(layers) == 0 {
		return manifest_fail(path, line_number, words[0].column, "the statement \"layer\" before a contour", manifest_quoted(words[0].text))
	}
	layer := &layers[len(layers) - 1]
	design := outline_design_size(manifest, shape)
	limit := i64(design) * OUTLINE_COORDINATE_SCALE
	expected := fmt.tprintf("a coordinate from 0 to %d with at most 3 decimals", design)
	index := 0
	for index < len(words) {
		word := words[index]
		count := 0
		switch word.text {
		case "contour", "line":
			count = 2
		case "curve":
			count = 4
		case "circle":
			count = 3
		case:
			return manifest_fail(path, line_number, word.column, "\"contour\", \"line\", \"curve\" or \"circle\"", manifest_quoted(word.text))
		}
		values: [4]i64
		for value_index in 0 ..< count {
			at := index + 1 + value_index
			if at >= len(words) {
				return manifest_fail(path, line_number, end_column, expected, "the end of the line")
			}
			value, ok := coordinate_of(words[at].text, limit)
			if !ok {
				return manifest_fail(path, line_number, words[at].column, expected, manifest_quoted(words[at].text))
			}
			values[value_index] = value
		}
		switch word.text {
		case "contour":
			append(&layer.contours, Outline_Contour{start = {values[0], values[1]}, segments = make([dynamic]Outline_Segment, context.temp_allocator), line = line_number})
		case "line", "curve":
			if len(layer.contours) == 0 || layer.contours[len(layer.contours) - 1].from_circle {
				return manifest_fail(path, line_number, word.column, fmt.tprintf("a statement \"contour\" before \"%s\"", word.text), manifest_quoted(word.text))
			}
			current := &layer.contours[len(layer.contours) - 1]
			if word.text == "line" {
				append(&current.segments, Outline_Segment{to = {values[0], values[1]}})
			} else {
				append(&current.segments, Outline_Segment{control = {values[0], values[1]}, to = {values[2], values[3]}, curve = true})
			}
		case "circle":
			center_x, center_y, radius := values[0], values[1], values[2]
			if radius == 0 || radius > center_x || radius > center_y || center_x + radius > limit || center_y + radius > limit {
				return manifest_fail(path, line_number, words[index + 3].column, fmt.tprintf("a radius above 0 that keeps the circle inside the square of %d units", design), manifest_quoted(words[index + 3].text))
			}
			append(&layer.contours, outline_circle(center_x, center_y, radius, line_number))
		}
		index += 1 + count
	}
	return ""
}

// outline_circle gives a circle as eight quadratic curves of 45 degrees,
// each with its control point on the tangents at its ends: the distance of
// the curve from the circle is at most 0.3 % of the radius, under 1/30 of a
// pixel for the circles of a pointer. The two constants are cos 45 and
// tan 22.5 in parts of 10 000.
@(private = "file")
outline_circle :: proc(center_x, center_y, radius: i64, line: int) -> Outline_Contour {
	diagonal := vector_font.divide_rounded(radius * 7071, 10_000)
	tangent := vector_font.divide_rounded(radius * 4142, 10_000)
	// The control point, then the end, of each curve, around from the right.
	offsets := [16][2]i64 {
		{radius, tangent},
		{diagonal, diagonal},
		{tangent, radius},
		{0, radius},
		{-tangent, radius},
		{-diagonal, diagonal},
		{-radius, tangent},
		{-radius, 0},
		{-radius, -tangent},
		{-diagonal, -diagonal},
		{-tangent, -radius},
		{0, -radius},
		{tangent, -radius},
		{diagonal, -diagonal},
		{radius, -tangent},
		{radius, 0},
	}
	center := [2]i64{center_x, center_y}
	circle := Outline_Contour {
		start       = center + [2]i64{radius, 0},
		segments    = make([dynamic]Outline_Segment, context.temp_allocator),
		line        = line,
		from_circle = true,
	}
	for index := 0; index < len(offsets); index += 2 {
		append(&circle.segments, Outline_Segment{control = center + offsets[index], to = center + offsets[index + 1], curve = true})
	}
	return circle
}

// outline_contour_add adds one contour to an accumulation, in pixels of the
// size: a unit is size / design pixels.
@(private = "file")
outline_contour_add :: proc(target: ^vector_font.Accumulation, item: Outline_Contour, design, size: i64) {
	// The contours of one layer are a union. The rasterizer adds signed
	// areas, so two contours in opposite directions would cancel where they
	// overlap: each contour is added in the direction that gives its control
	// polygon a positive area.
	twice_area: i64 = 0
	from := item.start
	for segment in item.segments {
		if segment.curve {
			twice_area += from.x * segment.control.y - segment.control.x * from.y
			twice_area += segment.control.x * segment.to.y - segment.to.x * segment.control.y
		} else {
			twice_area += from.x * segment.to.y - segment.to.x * from.y
		}
		from = segment.to
	}
	twice_area += from.x * item.start.y - item.start.x * from.y
	reverse := twice_area < 0
	place :: proc(value, design, size: i64) -> i32 {
		return i32(vector_font.divide_rounded(value * size * vector_font.SUBUNITS_PER_PIXEL, design * OUTLINE_COORDINATE_SCALE))
	}
	closing := Outline_Segment {
		to = item.start,
	}
	from = item.start
	for index in 0 ..= len(item.segments) {
		segment := index < len(item.segments) ? item.segments[index] : closing
		x0, y0 := place(from.x, design, size), place(from.y, design, size)
		x1, y1 := place(segment.to.x, design, size), place(segment.to.y, design, size)
		if reverse {
			x0, y0, x1, y1 = x1, y1, x0, y0
		}
		if segment.curve {
			vector_font.quadratic_add(target, x0, y0, place(segment.control.x, design, size), place(segment.control.y, design, size), x1, y1)
		} else {
			vector_font.line_add(target, x0, y0, x1, y1)
		}
		from = segment.to
	}
}

// One point of a contour in subunits, as a real number, for an offset.
@(private = "file")
Offset_Point :: [2]f64

@(private = "file")
cross_of :: proc(first, second: Offset_Point) -> f64 {
	return first.x * second.y - first.y * second.x
}

@(private = "file")
direction_of :: proc(vector: Offset_Point) -> Offset_Point {
	length := math.sqrt(vector.x * vector.x + vector.y * vector.y)
	return length == 0 ? Offset_Point{} : vector / length
}

// outline_contour_offset_add adds one contour moved out by a distance in
// subunits (inward for a negative distance) to an accumulation. Each side
// moves along its normal; two sides meet where their moved lines cross, and
// a curve keeps its control point where its two moved tangents cross: a
// circle stays a circle. The arithmetic is IEEE double precision, whose
// operations and square root are exact roundings: each machine makes the
// same points. A contour that the move turns inside out (a part thinner
// than twice the distance) adds nothing.
@(private = "file")
outline_contour_offset_add :: proc(target: ^vector_font.Accumulation, item: Outline_Contour, design, size: i64, distance: f64) {
	scale := f64(size * vector_font.SUBUNITS_PER_PIXEL) / f64(design * OUTLINE_COORDINATE_SCALE)
	point_of :: proc(value: [2]i64, factor: f64) -> Offset_Point {
		return {f64(value.x) * factor, f64(value.y) * factor}
	}
	// The segments with the closing line, with no segment of length 0.
	Piece :: struct {
		from, control, to: Offset_Point,
		curve:             bool,
	}
	pieces := make([dynamic]Piece, context.temp_allocator)
	from := point_of(item.start, scale)
	for index in 0 ..= len(item.segments) {
		segment := index < len(item.segments) ? item.segments[index] : Outline_Segment{to = item.start}
		to := point_of(segment.to, scale)
		control := point_of(segment.control, scale)
		if to != from || (segment.curve && control != from) {
			append(&pieces, Piece{from = from, control = control, to = to, curve = segment.curve})
		}
		from = to
	}
	count := len(pieces)
	if count < 2 {
		return
	}
	// The tangent at the start and at the end of each piece, and the area
	// of the control polygon: its sign says which side is outside.
	starts := make([]Offset_Point, count, context.temp_allocator)
	ends := make([]Offset_Point, count, context.temp_allocator)
	area: f64 = 0
	for piece, index in pieces {
		if piece.curve {
			starts[index] = direction_of(piece.control != piece.from ? piece.control - piece.from : piece.to - piece.from)
			ends[index] = direction_of(piece.control != piece.to ? piece.to - piece.control : piece.to - piece.from)
			area += cross_of(piece.from, piece.control) + cross_of(piece.control, piece.to)
		} else {
			starts[index] = direction_of(piece.to - piece.from)
			ends[index] = starts[index]
			area += cross_of(piece.from, piece.to)
		}
	}
	side: f64 = area > 0 ? 1 : -1
	outward :: proc(tangent: Offset_Point, sign: f64) -> Offset_Point {
		return {tangent.y * sign, -tangent.x * sign}
	}
	// Where the moved line through a with the direction u crosses the moved
	// line through b with the direction v; b when they are parallel.
	crossing :: proc(a, u, b, v: Offset_Point) -> (Offset_Point, bool) {
		turn := cross_of(u, v)
		if abs(turn) < 1e-9 {
			return b, false
		}
		return a + u * (cross_of(b - a, v) / turn), true
	}
	joins := make([]Offset_Point, count, context.temp_allocator)
	limit := 4 * abs(distance) // A join no farther than this from its corner.
	for index in 0 ..< count {
		before := (index + count - 1) % count
		corner := pieces[index].from
		join, _ := crossing(corner + outward(ends[before], side) * distance, ends[before], corner + outward(starts[index], side) * distance, starts[index])
		if reach := join - corner; reach.x * reach.x + reach.y * reach.y > limit * limit {
			join = corner + direction_of(reach) * limit
		}
		joins[index] = join
	}
	// The moved contour, and its area: a sign that differs from the
	// contour says that the move turned it inside out.
	moved := make([]Piece, count, context.temp_allocator)
	moved_area: f64 = 0
	for piece, index in pieces {
		start, end := joins[index], joins[(index + 1) % count]
		control := (start + end) / 2
		if piece.curve {
			if found, ok := crossing(start, starts[index], end, ends[index]); ok {
				control = found
			}
			moved_area += cross_of(start, control) + cross_of(control, end)
		} else {
			moved_area += cross_of(start, end)
		}
		moved[index] = Piece{from = start, control = control, to = end, curve = piece.curve}
	}
	if moved_area * area <= 0 {
		return
	}
	// One direction for every contour of a layer: the union.
	round :: proc(value: f64) -> i32 {
		return i32(math.floor(value + 0.5))
	}
	for piece in moved {
		a, b := piece.from, piece.to
		if side < 0 {
			a, b = b, a
		}
		if piece.curve {
			vector_font.quadratic_add(target, round(a.x), round(a.y), round(piece.control.x), round(piece.control.y), round(b.x), round(b.y))
		} else {
			vector_font.line_add(target, round(a.x), round(a.y), round(b.x), round(b.y))
		}
	}
}

// outline_coverage gives the coverage of the union of the contours of a
// layer, each moved out by a distance in subunits (0: as they are).
@(private = "file")
outline_coverage :: proc(cells: []i32, coverage: []u8, layer: Outline_Layer, design, size: u32, distance: i64) {
	target, ok := vector_font.accumulation_of(cells, int(size), int(size))
	if !ok {
		return // The caller gives (size + 1) * size cells: this does not happen.
	}
	for item in layer.contours {
		if distance == 0 {
			outline_contour_add(&target, item, i64(design), i64(size))
		} else {
			outline_contour_offset_add(&target, item, i64(design), i64(size), f64(distance))
		}
	}
	vector_font.coverage_finish(&target, coverage)
}

// outline_layer_draw draws one layer in a form over a canvas of size x size
// premultiplied pixels. A fill or an accent is its contours in the edge
// color, then the same contours moved in by the edge in its color: the edge
// is inside the contours, so the contours are the whole shape at every size
// and the hot spot stays on them. An inside layer and the edge are their
// contours in their color. A clear layer is the edge around its contours,
// then its contours transparent.
@(private = "file")
outline_layer_draw :: proc(canvas: []u32, cells: []i32, coverage: []u8, layer: Outline_Layer, form: pointer_pictures.Pointer_Form, design, size: u32) {
	edge := POINTER_FORM_COLORS[form].edge
	switch {
	case layer.paint == .Clear:
		outline_coverage(cells, coverage, layer, design, size, OUTLINE_EDGE_SUBUNITS)
		outline_paint(canvas, coverage, 0xFF000000 | edge)
		outline_coverage(cells, coverage, layer, design, size, 0)
		outline_paint(canvas, coverage, 0)
	case layer.paint == .Edge || layer.inside:
		outline_coverage(cells, coverage, layer, design, size, 0)
		outline_paint(canvas, coverage, 0xFF000000 | pointer_layer_color(layer, form))
	case:
		outline_coverage(cells, coverage, layer, design, size, 0)
		outline_paint(canvas, coverage, 0xFF000000 | edge)
		outline_coverage(cells, coverage, layer, design, size, -OUTLINE_EDGE_SUBUNITS)
		outline_paint(canvas, coverage, 0xFF000000 | pointer_layer_color(layer, form))
	}
}

// outline_paint puts a premultiplied paint (0: transparent) over each pixel
// of a canvas with the coverage of the pixel as its weight.
@(private = "file")
outline_paint :: proc(canvas: []u32, coverage: []u8, paint: u32) {
	for &pixel, index in canvas {
		covered := u32(coverage[index])
		if covered == 0 {
			continue
		}
		kept := 255 - covered
		// Each channel and the alpha: the paint with the coverage, over what
		// the coverage leaves. A channel never passes its alpha, as a
		// premultiplied pixel needs.
		result: u32 = 0
		for shift in ([?]u32{0, 8, 16, 24}) {
			source := (paint >> shift) & 0xFF
			before := (pixel >> shift) & 0xFF
			result |= ((source * covered + before * kept + 127) / 255) << shift
		}
		pixel = result
	}
}

// outline_pictures_add draws each frame of an outline at one size in one
// form, and adds its pictures. The pictures of one size have one box: the
// pixels that a frame draws, and the hot spot.
@(private = "file")
outline_pictures_add :: proc(pictures: ^[dynamic]Made_Picture, item: Manifest_Shape, design, size: u32, form: pointer_pictures.Pointer_Form) {
	side := int(size)
	frame_count := max(len(item.frames), 1)
	cells := make([]i32, (side + 1) * side, context.temp_allocator)
	coverage := make([]u8, side * side, context.temp_allocator)
	canvases := make([][]u32, frame_count, context.temp_allocator)
	for &canvas, frame_index in canvases {
		canvas = make([]u32, side * side, context.temp_allocator)
		for layer in item.layers {
			outline_layer_draw(canvas, cells, coverage, layer, form, design, size)
		}
		if len(item.frames) > 0 {
			for layer in item.frames[frame_index].layers {
				outline_layer_draw(canvas, cells, coverage, layer, form, design, size)
			}
		}
	}
	hot_x, hot_y := item.hot_spot.x * size / design, item.hot_spot.y * size / design
	left, top, right, bottom := int(hot_x), int(hot_y), int(hot_x), int(hot_y)
	for canvas in canvases {
		for y in 0 ..< side {
			for x in 0 ..< side {
				if canvas[y * side + x] >> 24 != 0 {
					left, right = min(left, x), max(right, x)
					top, bottom = min(top, y), max(bottom, y)
				}
			}
		}
	}
	width, height := right - left + 1, bottom - top + 1
	for canvas, frame_index in canvases {
		picture := Made_Picture {
			entry = {nominal_size = size, width = u32(width), height = u32(height), hot_spot_x = hot_x - u32(left), hot_spot_y = hot_y - u32(top), delay_milliseconds = len(item.frames) > 0 ? item.frames[frame_index].delay : 0},
		}
		picture.pixels = make([]u32, width * height, context.temp_allocator)
		for y in 0 ..< height {
			copy(picture.pixels[y * width:][:width], canvas[(top + y) * side + left:][:width])
		}
		append(pictures, picture)
	}
}

// ---- The conversion ----

// One row of the table that the command prints.
Pointer_Table_Row :: struct {
	shape:  string,
	source: string,
	sizes:  string,
	frames: int,
	bytes:  int,
}

// One picture before the file is written.
@(private = "file")
Made_Picture :: struct {
	entry:  pointer_pictures.Picture_Entry,
	pixels: []u32,
}

// source_resolve finds the first source of a shape in the folder, and
// follows its links inside the folder. It gives the name of the file at the
// end of the links.
@(private = "file")
source_resolve :: proc(folder: string, sources: []string) -> (name: string, data: []u8, problem: string) {
	for source in sources {
		name = source
		for depth := 0; ; depth += 1 {
			path := join(folder, "/", name)
			info, err := os.lstat(path, context.temp_allocator)
			if err != nil {
				name = ""
				break
			}
			if info.type != .Symlink {
				read_err: os.Error
				data, read_err = os.read_entire_file(path, context.temp_allocator)
				if read_err != nil {
					return "", nil, fmt.tprintf("cannot read %s: %v", path, read_err)
				}
				return name, data, ""
			}
			if depth == LINK_DEPTH_LIMIT {
				return "", nil, fmt.tprintf("%s: more than %d links", source, LINK_DEPTH_LIMIT)
			}
			target, link_err := os.read_link(path, context.temp_allocator)
			if link_err != nil {
				return "", nil, fmt.tprintf("cannot read the link %s: %v", path, link_err)
			}
			if strings.contains_rune(target, '/') || target == "" {
				return "", nil, fmt.tprintf("the link %s names %s, out of the folder", path, target)
			}
			name = target
		}
	}
	return "", nil, fmt.tprintf("none of the sources %v is in %s", sources, folder)
}

// pointer_theme_make makes a pointer theme file from a manifest. The folder
// is the Xcursor theme of the sources ("" for a manifest of outlines). The
// file passes pointer_pictures.validate before it is given.
pointer_theme_make :: proc(manifest: Manifest, folder: string) -> (file: []u8, rows: []Pointer_Table_Row, problem: string) {
	shapes := make([dynamic]pointer_pictures.Shape_Entry, context.temp_allocator)
	pictures := make([dynamic]Made_Picture, context.temp_allocator)
	table := make([dynamic]Pointer_Table_Row, context.temp_allocator)
	// Two shapes from one file with the same options share their pictures.
	Made_Source :: struct {
		key:   string,
		entry: pointer_pictures.Shape_Entry,
	}
	made := make([dynamic]Made_Source, context.temp_allocator)
	ordered := slice.clone(manifest.shapes[:], context.temp_allocator)
	slice.sort_by(ordered, proc(a, b: Manifest_Shape) -> bool {return a.shape < b.shape})
	for &item in ordered {
		name := pointer_pictures.SHAPE_NAMES[item.shape]
		sizes := len(item.sizes) > 0 ? item.sizes[:] : manifest.sizes[:]
		sizes_text := strings.builder_make(context.temp_allocator)
		for size, index in sizes {
			fmt.sbprintf(&sizes_text, "%s%d", index > 0 ? " " : "", size)
		}
		entry := pointer_pictures.Shape_Entry{shape = u32(item.shape), first_picture = u32(len(pictures)), size_count = u32(len(sizes))}
		row := Pointer_Table_Row{shape = name, sizes = strings.to_string(sizes_text)}
		bytes_before := 0
		for picture in pictures {
			bytes_before += len(picture.pixels) * 4
		}
		if len(item.sources) == 0 {
			// An outline: a unit is a pixel of the first size.
			entry.frame_count = u32(max(len(item.frames), 1))
			for size in sizes {
				outline_pictures_add(&pictures, item, sizes[0], size, .Dark)
			}
			row.source = len(item.frames) > 0 ? "an outline, animated" : "an outline"
		} else {
			resolved, data, source_problem := source_resolve(folder, item.sources[:])
			if source_problem != "" {
				return nil, nil, fmt.tprintf("line %d: %s", item.line, source_problem)
			}
			row.source = resolved
			key := fmt.tprintf("%s %v %v %s", resolved, item.has_hot_spot, item.hot_spot, row.sizes)
			shared := false
			for previous in made {
				if previous.key == key {
					entry.first_picture = previous.entry.first_picture
					entry.frame_count = previous.entry.frame_count
					shared = true
				}
			}
			if shared {
				row.source = fmt.tprintf("%s (shared)", resolved)
				row.frames = int(entry.frame_count)
				append(&shapes, entry)
				append(&table, row)
				continue
			}
			images := make([dynamic]Xcursor_Image, context.temp_allocator)
			if read_problem := xcursor_read(data, &images); read_problem != "" {
				return nil, nil, fmt.tprintf("line %d: %s/%s: %s", item.line, folder, resolved, read_problem)
			}
			for size, size_index in sizes {
				frames := 0
				for image in images {
					if image.nominal_size != size {
						continue
					}
					frames += 1
					if image.width > pointer_pictures.PICTURE_SIDE_LIMIT || image.height > pointer_pictures.PICTURE_SIDE_LIMIT {
						return nil, nil, fmt.tprintf("line %d: %s: a picture of %d x %d is larger than 256", item.line, resolved, image.width, image.height)
					}
					picture := Made_Picture {
						entry = {nominal_size = size, width = image.width, height = image.height, hot_spot_x = image.hot_spot_x, hot_spot_y = image.hot_spot_y, delay_milliseconds = image.delay},
						pixels = image.pixels,
					}
					if item.has_hot_spot {
						// In pixels of the smallest size: the other sizes scale it.
						picture.entry.hot_spot_x = item.hot_spot.x * size / sizes[0]
						picture.entry.hot_spot_y = item.hot_spot.y * size / sizes[0]
						if picture.entry.hot_spot_x >= image.width || picture.entry.hot_spot_y >= image.height {
							return nil, nil, fmt.tprintf("line %d: the hot spot %d,%d is not a pixel of the picture of %d x %d at the size %d", item.line, picture.entry.hot_spot_x, picture.entry.hot_spot_y, image.width, image.height, size)
						}
					}
					append(&pictures, picture)
				}
				if frames == 0 {
					have := make([dynamic]u32, context.temp_allocator)
					for image in images {
						if !slice.contains(have[:], image.nominal_size) {
							append(&have, image.nominal_size)
						}
					}
					return nil, nil, fmt.tprintf("line %d: %s has no picture of the size %d; it has %v", item.line, resolved, size, have[:])
				}
				if size_index == 0 {
					entry.frame_count = u32(frames)
				} else if u32(frames) != entry.frame_count {
					return nil, nil, fmt.tprintf("line %d: %s has %d frames at the size %d and %d at the size %d", item.line, resolved, entry.frame_count, sizes[0], frames, size)
				}
			}
			if entry.frame_count == 1 {
				for &picture in pictures[entry.first_picture:] {
					picture.entry.delay_milliseconds = 0
				}
			}
			append(&made, Made_Source{key = key, entry = entry})
		}
		row.frames = int(entry.frame_count)
		after := 0
		for picture in pictures {
			after += len(picture.pixels) * 4
		}
		row.bytes = after - bytes_before
		append(&shapes, entry)
		append(&table, row)
	}

	// The light form, when the theme has an outline: each outline drawn
	// again in the colors of the light form; a shape from a source keeps
	// its pictures, which have one form.
	form_count := 1
	for &item in ordered {
		if len(item.sources) == 0 {
			form_count = len(pointer_pictures.Pointer_Form)
		}
	}
	if form_count > 1 {
		dark_entries := slice.clone(shapes[:], context.temp_allocator)
		for &item, index in ordered {
			entry := dark_entries[index]
			if len(item.sources) == 0 {
				sizes := len(item.sizes) > 0 ? item.sizes[:] : manifest.sizes[:]
				entry.first_picture = u32(len(pictures))
				bytes_before := 0
				for picture in pictures {
					bytes_before += len(picture.pixels) * 4
				}
				for size in sizes {
					outline_pictures_add(&pictures, item, sizes[0], size, .Light)
				}
				after := 0
				for picture in pictures {
					after += len(picture.pixels) * 4
				}
				table[index].bytes += after - bytes_before
			}
			append(&shapes, entry)
		}
	}

	// The file: the header, the two tables, the pixels.
	offset := pointer_pictures.pixel_offset_for(u64(len(shapes)), u64(len(pictures)))
	pixel_size: u64 = 0
	for &picture in pictures {
		picture.entry.pixel_offset = pixel_size
		pixel_size += u64(len(picture.pixels)) * 4
	}
	// Aligned: the validation reads the tables in place, as the compositor does.
	file, _ = mem.alloc_bytes(int(offset + pixel_size), pointer_pictures.PIXEL_ALIGNMENT, context.temp_allocator)
	head := (^pointer_pictures.Header)(raw_data(file))
	head^ = {magic = pointer_pictures.MAGIC, version = pointer_pictures.VERSION, shape_count = u32(len(ordered)), picture_count = u32(len(pictures)), form_count = u32(form_count), pixel_offset = offset, pixel_size = pixel_size, file_size = u64(len(file))}
	copy(head.theme_name[:], manifest.theme_name)
	copy(head.license[:], manifest.license)
	copy(head.attribution[:], manifest.attribution)
	shape_table := ([^]pointer_pictures.Shape_Entry)(raw_data(file[pointer_pictures.HEADER_SIZE:]))[:len(shapes)]
	copy(shape_table, shapes[:])
	picture_table := ([^]pointer_pictures.Picture_Entry)(raw_data(file[pointer_pictures.HEADER_SIZE + len(shapes) * pointer_pictures.SHAPE_ENTRY_SIZE:]))[:len(pictures)]
	for picture, index in pictures {
		picture_table[index] = picture.entry
		copy(([^]u32)(raw_data(file[offset + picture.entry.pixel_offset:]))[:len(picture.pixels)], picture.pixels)
	}
	if found := pointer_pictures.validate(file); found.kind != .None {
		buffer: [256]u8
		return nil, nil, fmt.tprintf("the theme file is not valid: %s", pointer_pictures.sentence(found, buffer[:]))
	}
	return file, table[:], ""
}

// The generator of the pictures of the mark (docs/TOOLS.md, "The pictures
// of the mark"). Every picture file of the mark comes from here: the files
// of the repository, the pictures of the site, its icons, its tile maps,
// and what the command `modustool mark` writes. A request says what to
// draw and how; the generator gives the bytes of the file, or the sentence
// of a refusal. The data of the mark is in src/library/support/mark; no other file of
// the tool calls its drawing procedures for a picture file.
//
// The parts of the generator:
//   this file: one picture (the still mark, a frame, the mark with its
//     name), the request of the command, the PNG encoder, and the table of
//     the uses: the list of the files that `modustool logo` and
//     `modustool site` ask for;
//   mark_formats.odin: the formats besides one PNG picture: the icon file
//     of several sizes, the vector file, the animated PNG file;
//   mark_tile_map.odin: the tile map of the animations (the sprites of the
//     frames, the drawn forms of the moves, their table);
//   mark_developer_picture.odin: the picture of every frame for a
//     developer;
//   mark_command.odin: the command.
package resources

import "core:fmt"
import "core:image/png"
import "core:strings"
import "modus:support/mark"

// One picture of the mark: how it is drawn. The heron is in a variant that
// the request names (docs/DESIGN.md, "The variants of the mark"), at a
// whole count of pixels for a cell, in the colors of a color scheme, alone
// or with the name under it, on nothing or on the background of its
// scheme, at its own size or centred in a larger picture.
Mark_Picture :: struct {
	file_name:  string, // The file: a path of the repository, or a name in the picture folder or at the root of the site.
	variant:    mark.Variant, // Smooth or cells.
	heron_cell: int, // The pixels of a side of a cell of the heron.
	name_cell:  int, // The pixels of a side of a cell of the name; 0: the heron alone.
	gap:        int, // Pixels between the heron and the name.
	on_light:   bool, // The colors of the light scheme: the darker neck, the dark name.
	opaque:     bool, // On the background of its scheme, not transparent.
	width:      int, // 0: the size of the drawing. Else the drawing is centred in width by height.
	height:     int,
}

// The longest side of a picture that the generator draws: the longest that
// a browser decodes.
MARK_PICTURE_SIDE_MOST :: 8192

// mark_picture_refusal gives the sentence that says why a picture cannot
// be drawn, or "" for a picture that can. The generator guesses nothing: a
// request with no sense is refused, not bent into another one.
mark_picture_refusal :: proc(picture: Mark_Picture) -> string {
	if !mark.cell_size_is_accepted(picture.heron_cell) {
		return fmt.tprintf("a cell of the heron is a whole count of pixels from 1 to %d, not %d", mark.CELL_SIZE_LIMIT, picture.heron_cell)
	}
	if !mark.variant_is_drawn(picture.variant, picture.heron_cell) {
		return fmt.tprintf("the smooth variant needs at least %d pixels for a cell: with %d, a cell is one color, and that picture is the cells variant; ask for the cells variant", mark.SMOOTH_CELL_SIZE_LEAST, picture.heron_cell)
	}
	if picture.name_cell < 0 || picture.gap < 0 || (picture.name_cell > 0 && !mark.cell_size_is_accepted(picture.name_cell)) {
		return "the cell of the name and the gap under the heron are whole counts of pixels, 0 or more"
	}
	if picture.name_cell == 0 && picture.gap != 0 {
		return "a gap under the heron needs the name: the picture of the heron alone has no gap"
	}
	if (picture.width == 0) != (picture.height == 0) || picture.width < 0 || picture.height < 0 {
		return "a picture has a width and a height, or neither: then it has the size of its drawing"
	}
	drawing_width, drawing_height := mark_picture_drawing_size(picture)
	if picture.width > 0 && (picture.width < drawing_width || picture.height < drawing_height) {
		return fmt.tprintf("the picture is %d by %d pixels and its drawing is %d by %d: the drawing does not fit", picture.width, picture.height, drawing_width, drawing_height)
	}
	width, height := mark_picture_size(picture)
	if width > MARK_PICTURE_SIDE_MOST || height > MARK_PICTURE_SIDE_MOST {
		return fmt.tprintf("the picture is %d by %d pixels: a side is at most %d", width, height, MARK_PICTURE_SIDE_MOST)
	}
	return ""
}

// mark_picture_drawing_size gives the size of the heron and the name under
// it.
mark_picture_drawing_size :: proc(picture: Mark_Picture) -> (width, height: int) {
	heron := mark.heron_size(picture.heron_cell)
	width, height = heron, heron
	if picture.name_cell > 0 {
		name_width, name_height := mark.name_size(picture.name_cell)
		width = max(width, name_width)
		height = heron + picture.gap + name_height
	}
	return
}

// mark_picture_size gives the size of a picture.
mark_picture_size :: proc(picture: Mark_Picture) -> (width, height: int) {
	if picture.width > 0 {
		return picture.width, picture.height
	}
	return mark_picture_drawing_size(picture)
}

// mark_picture_channels gives the bytes of a pixel of a picture: red,
// green and blue, and alpha when it is transparent.
mark_picture_channels :: proc(picture: Mark_Picture) -> int {
	return 3 if picture.opaque else 4
}

// mark_picture_pixels draws one picture with the cells of one frame of the
// heron (the still heron, or a frame of an animation): the bytes of each
// pixel, row by row. The caller asks mark_picture_refusal first.
mark_picture_pixels :: proc(picture: Mark_Picture, cells: ^mark.Heron_Cells) -> []u8 {
	width, height := mark_picture_size(picture)
	drawing_width, drawing_height := mark_picture_drawing_size(picture)
	left := (width - drawing_width) / 2
	top := (height - drawing_height) / 2
	heron := mark.heron_size(picture.heron_cell)
	heron_left := left + (drawing_width - heron) / 2
	name_width := 0
	if picture.name_cell > 0 {
		name_width, _ = mark.name_size(picture.name_cell)
	}
	name_left := left + (drawing_width - name_width) / 2
	name_top := top + heron + picture.gap
	channels := mark_picture_channels(picture)
	pixels := make([]u8, width * height * channels, context.temp_allocator)
	for y in 0 ..< height {
		for x in 0 ..< width {
			color, covered := mark.cells_pixel(cells, picture.heron_cell, x - heron_left, y - top, picture.variant, picture.on_light)
			if !covered && picture.name_cell > 0 {
				color, covered = mark.name_pixel(picture.name_cell, x - name_left, y - name_top, picture.on_light)
			}
			if !covered && picture.opaque {
				color, covered = mark.background_color(picture.on_light), true
			}
			if !covered {
				continue // Transparent: the four bytes stay 0.
			}
			pixel := pixels[(y * width + x) * channels:][:channels]
			pixel[0] = u8(color >> 16)
			pixel[1] = u8(color >> 8)
			pixel[2] = u8(color)
			if channels == 4 {
				pixel[3] = 0xFF
			}
		}
	}
	return pixels
}

// mark_pixels_png gives the smallest PNG file that the encoder of the
// standard library writes for pixels of 3 or 4 bytes: the highest level of
// its deflate, and each of its row filters in turn (none, sub, up,
// average, Paeth, and the one chosen row by row), the smallest file kept.
// The pixels are the same in each: nothing is lost. Which filter wins
// depends on the pixels only, so the same pixels give the same bytes. The
// name is for the message of a failure.
mark_pixels_png :: proc(name: string, width, height, channels: int, pixels: []u8) -> (file: []u8, ok: bool) {
	image := png.Image {
		width    = width,
		height   = height,
		channels = channels,
		depth    = 8,
	}
	image.pixels = make([dynamic]u8, len(pixels), len(pixels), context.temp_allocator)
	copy(image.pixels[:], pixels)
	for strategy in png.Filter_Strategy {
		output := make([dynamic]u8, context.temp_allocator)
		if err := png.save_to_buffer(&output, &image, level = .Best, filter = strategy, allocator = context.temp_allocator); err != nil {
			fmt.eprintfln("modustool: cannot encode %s: %v", name, err)
			return nil, false
		}
		if file == nil || len(output) < len(file) {
			file = output[:]
		}
	}
	return file, true
}

// mark_pixels_png_quick gives a PNG file of the same pixels at the common
// level of the encoder, in one pass: for the large picture for a
// developer, which is written often and loaded by no reader of the site.
mark_pixels_png_quick :: proc(name: string, width, height, channels: int, pixels: []u8) -> (file: []u8, ok: bool) {
	image := png.Image {
		width    = width,
		height   = height,
		channels = channels,
		depth    = 8,
	}
	image.pixels = make([dynamic]u8, len(pixels), len(pixels), context.temp_allocator)
	copy(image.pixels[:], pixels)
	output := make([dynamic]u8, context.temp_allocator)
	if err := png.save_to_buffer(&output, &image, allocator = context.temp_allocator); err != nil {
		fmt.eprintfln("modustool: cannot encode %s: %v", name, err)
		return nil, false
	}
	return output[:], true
}

// mark_picture_png draws the still mark as one picture and gives its PNG
// file. A picture that is refused gives no file, and its sentence on the
// standard error.
mark_picture_png :: proc(picture: Mark_Picture) -> (file: []u8, ok: bool) {
	still := mark.still_cells()
	return mark_frame_png(picture, &still)
}

// mark_frame_png draws one picture with the cells of a frame and gives its
// PNG file.
mark_frame_png :: proc(picture: Mark_Picture, cells: ^mark.Heron_Cells) -> (file: []u8, ok: bool) {
	if refusal := mark_picture_refusal(picture); refusal != "" {
		fmt.eprintfln("modustool: the picture %s of the mark is refused: %s", picture.file_name, refusal)
		return nil, false
	}
	width, height := mark_picture_size(picture)
	return mark_pixels_png(picture.file_name, width, height, mark_picture_channels(picture), mark_picture_pixels(picture, cells))
}

// Where a file of the mark goes.
Mark_Use_Place :: enum {
	Repository, // A file of the repository: `modustool logo` writes it, `modustool check` compares it.
	Site, // A file of the picture folder of the site: `modustool site` writes it.
	Site_Root, // A file of the root of the site, where a browser asks for it by default: `modustool site` writes it.
}

// What a file of the mark holds.
Mark_Use_Kind :: enum {
	Picture, // The still mark, as a PNG file.
	Tile_Map, // The tile map of every animation: the frames and the drawn forms of the moves.
	Tile_Map_Of_Frames, // The tile map of the frames only: for a place that shows no move.
	Icon_File_Entry, // The still mark, as one entry of an icon file: the rows with the name of the file, in the order of the table, are the file.
	Vector_Of_Both_Schemes, // The still mark as a vector file, with the rule that gives the colors of the dark scheme to a reader that asks for dark.
}

// One use of the mark that is a file: where it goes, what it holds, and
// how it is drawn. The name of the file is in the picture.
Mark_Use :: struct {
	place:   Mark_Use_Place,
	kind:    Mark_Use_Kind,
	picture: Mark_Picture,
}

// The folder of the files of the mark in the repository, and the mark of
// the project, where the other projects of the same publisher keep theirs.
LOGO_FOLDER :: "resources/logo"
PROJECT_IMAGE :: ".project/image.png"

SITE_MARK_HOME :: "mark_home.png"
SITE_MARK_HOME_LIGHT :: "mark_home_light.png"
SITE_MARK_BAR :: "mark_bar.png"
SITE_MARK_BAR_LIGHT :: "mark_bar_light.png"
SITE_MARK_CARD :: "mark_card.png"
SITE_MARK_ANIMATION_HOME :: "mark_animation_home.png"
SITE_MARK_ANIMATION_HOME_LIGHT :: "mark_animation_home_light.png"
SITE_MARK_ANIMATION_ICON :: "mark_animation_icon.png"
// The icons of the site (docs/SITE.md, "The icons"): the icon file at the
// root, the vector icon, the icon of a phone and the icons of the manifest.
SITE_FAVICON :: "favicon.ico"
SITE_ICON_SVG :: "icon.svg"
SITE_ICON_TOUCH :: "icon_180.png"
SITE_ICON_192 :: "icon_192.png"
SITE_ICON_512 :: "icon_512.png"
SITE_ICON_MASKABLE :: "icon_512_maskable.png"

// The table of the uses: each file of the mark, with the variant that its
// place wants (docs/DESIGN.md, "The variants of the mark", quotes it). The
// rule of the variant: a picture is smooth; a small icon, one pixel for a
// cell, is the cells variant. This is the one table of the files of the
// mark: an icon of the site is a row as a picture is. `modustool logo`
// writes the rows of the repository and `modustool site` the rows of the
// site; neither holds a number of a picture of its own. What the system
// draws is not a file and has no row; it follows the same rule: the window
// of the process `heron` and the boot display are smooth, the bar of the
// desktop is cells.
//
// The repository: the mark with the name at cells of 24 and 20 pixels with
// 44 pixels between them, centred in 1024 by 1024, on the dark background,
// on the light one, and on nothing in the colors of each; the heron alone
// at five cell sizes; the mark of the project, centred on the dark
// background.
//
// The site: the head of the home and its tile maps are pictures, smooth,
// 8 pixels for a cell, one for each color scheme. The bar is a small icon.
// The tile map of the icon of the tab holds the frames at one pixel for a
// cell in the light scheme, as the icon of 32 pixels of favicon.ico. The
// card for other sites holds the name, on the dark background.
//
// The icons of the site: each is the heron at a whole cell size, centred
// with an even margin. The cell size says which variant an icon is: at one
// pixel for a cell it is a small icon, the cells variant; at two pixels or
// more it is a picture, the smooth variant. The entries of favicon.ico: 32
// is the heron at cells of 1 with a margin of 4; 48 at cells of 2. The
// others: 180 at 7 (168) with a margin of 6; 192 at 8; 512 at 21 (504)
// with a margin of 4. The maskable icon is at 12 (288) with a margin of
// 112: a phone can cut it to a circle of 80 percent of its width, and the
// whole grid of the heron is inside that circle. 16 pixels cannot hold the
// 24 cells: there is no icon of 16, and a browser scales the 32. The
// vector icon is the cells, one unit for a cell.
//
// A transparent icon shows on the tab of a browser, light or dark: it
// takes the colors of the light scheme, whose darker neck reads on both.
// The icon of a phone and the maskable icon are opaque, on the dark
// background of the system, in the dark scheme: a phone fills or cuts the
// transparent part.
mark_uses := [?]Mark_Use {
	{.Repository, .Picture, {file_name = LOGO_FOLDER + "/modus.png", variant = .Smooth, heron_cell = 24, name_cell = 20, gap = 44, opaque = true, width = 1024, height = 1024}},
	{.Repository, .Picture, {file_name = LOGO_FOLDER + "/modus_light.png", variant = .Smooth, heron_cell = 24, name_cell = 20, gap = 44, on_light = true, opaque = true, width = 1024, height = 1024}},
	{.Repository, .Picture, {file_name = LOGO_FOLDER + "/modus_transparent.png", variant = .Smooth, heron_cell = 24, name_cell = 20, gap = 44, width = 1024, height = 1024}},
	{.Repository, .Picture, {file_name = LOGO_FOLDER + "/modus_light_transparent.png", variant = .Smooth, heron_cell = 24, name_cell = 20, gap = 44, on_light = true, width = 1024, height = 1024}},
	{.Repository, .Picture, {file_name = LOGO_FOLDER + "/heron_768.png", variant = .Smooth, heron_cell = 32}},
	{.Repository, .Picture, {file_name = LOGO_FOLDER + "/heron_24.png", variant = .Cells, heron_cell = 1}},
	{.Repository, .Picture, {file_name = LOGO_FOLDER + "/heron_48.png", variant = .Smooth, heron_cell = 2}},
	{.Repository, .Picture, {file_name = LOGO_FOLDER + "/heron_96.png", variant = .Smooth, heron_cell = 4}},
	{.Repository, .Picture, {file_name = LOGO_FOLDER + "/heron_192.png", variant = .Smooth, heron_cell = 8}},
	{.Repository, .Picture, {file_name = PROJECT_IMAGE, variant = .Smooth, heron_cell = 16, opaque = true, width = 512, height = 512}},
	{.Site, .Picture, {file_name = SITE_MARK_HOME, variant = .Smooth, heron_cell = 8}},
	{.Site, .Picture, {file_name = SITE_MARK_HOME_LIGHT, variant = .Smooth, heron_cell = 8, on_light = true}},
	{.Site, .Picture, {file_name = SITE_MARK_BAR, variant = .Cells, heron_cell = 1}},
	{.Site, .Picture, {file_name = SITE_MARK_BAR_LIGHT, variant = .Cells, heron_cell = 1, on_light = true}},
	{.Site, .Picture, {file_name = SITE_MARK_CARD, variant = .Smooth, heron_cell = 16, name_cell = 12, gap = 32, opaque = true, width = 1200, height = 630}},
	{.Site, .Tile_Map, {file_name = SITE_MARK_ANIMATION_HOME, variant = .Smooth, heron_cell = 8}},
	{.Site, .Tile_Map, {file_name = SITE_MARK_ANIMATION_HOME_LIGHT, variant = .Smooth, heron_cell = 8, on_light = true}},
	{.Site, .Tile_Map_Of_Frames, {file_name = SITE_MARK_ANIMATION_ICON, variant = .Cells, heron_cell = 1, on_light = true}},
	{.Site_Root, .Icon_File_Entry, {file_name = SITE_FAVICON, variant = .Cells, heron_cell = 1, on_light = true, width = 32, height = 32}},
	{.Site_Root, .Icon_File_Entry, {file_name = SITE_FAVICON, variant = .Smooth, heron_cell = 2, on_light = true, width = 48, height = 48}},
	{.Site, .Vector_Of_Both_Schemes, {file_name = SITE_ICON_SVG, variant = .Cells, heron_cell = 1, on_light = true}},
	{.Site, .Picture, {file_name = SITE_ICON_TOUCH, variant = .Smooth, heron_cell = 7, opaque = true, width = 180, height = 180}},
	{.Site, .Picture, {file_name = SITE_ICON_192, variant = .Smooth, heron_cell = 8, on_light = true, width = 192, height = 192}},
	{.Site, .Picture, {file_name = SITE_ICON_512, variant = .Smooth, heron_cell = 21, on_light = true, width = 512, height = 512}},
	{.Site, .Picture, {file_name = SITE_ICON_MASKABLE, variant = .Smooth, heron_cell = 12, opaque = true, width = 512, height = 512}},
}

// mark_uses_pictures gives the pictures of the uses of one place and one
// kind, in the order of the table.
mark_uses_pictures :: proc(place: Mark_Use_Place, kind: Mark_Use_Kind) -> []Mark_Picture {
	pictures := make([dynamic]Mark_Picture, context.temp_allocator)
	for use in mark_uses {
		if use.place == place && use.kind == kind {
			append(&pictures, use.picture)
		}
	}
	return pictures[:]
}

// mark_use_picture gives the picture of the use of a file.
mark_use_picture :: proc(file_name: string) -> (picture: Mark_Picture, found: bool) {
	for use in mark_uses {
		if use.picture.file_name == file_name {
			return use.picture, true
		}
	}
	return {}, false
}

// mark_use_entries gives the pictures of the rows of one file, in the
// order of the table, and the kind of the first: one picture, but for an
// icon file, which has one row for each entry.
mark_use_entries :: proc(file_name: string) -> (entries: []Mark_Picture, kind: Mark_Use_Kind) {
	list := make([dynamic]Mark_Picture, context.temp_allocator)
	for use in mark_uses {
		if use.picture.file_name != file_name {
			continue
		}
		if len(list) == 0 {
			kind = use.kind
		}
		append(&list, use.picture)
	}
	return list[:], kind
}

// mark_use_file gives the bytes of one file of the table of the uses: the
// PNG file of a picture or of a tile map, the icon file of its entries, or
// the vector file. A file that is not in the table, or that is refused,
// gives no file and a sentence on the standard error.
mark_use_file :: proc(file_name: string) -> (file: []u8, ok: bool) {
	entries, kind := mark_use_entries(file_name)
	if len(entries) == 0 {
		fmt.eprintfln("modustool: %s is not a file of the table of the uses of the mark", file_name)
		return nil, false
	}
	still := mark.still_cells()
	refusal := ""
	switch kind {
	case .Picture:
		return mark_picture_png(entries[0])
	case .Tile_Map, .Tile_Map_Of_Frames:
		tile_map := mark_tile_map_build(entries[0], false, .Blink, kind == .Tile_Map, 0) or_return
		return mark_tile_map_png(&tile_map)
	case .Icon_File_Entry:
		refusal = mark_icon_file_refusal(entries)
		if refusal == "" {
			return mark_icon_file(entries, &still)
		}
	case .Vector_Of_Both_Schemes:
		refusal = mark_vector_refusal(entries[0], true)
		if refusal == "" {
			return transmute([]u8)mark_picture_svg(entries[0], &still, true), true
		}
	}
	fmt.eprintfln("modustool: the file %s of the mark is refused: %s", file_name, refusal)
	return nil, false
}

// mark_use_site_path gives the path in the site of a file of a row of the
// site: in the picture folder, or at the root.
mark_use_site_path :: proc(use: Mark_Use) -> string {
	if use.place == .Site_Root {
		return use.picture.file_name
	}
	return strings.concatenate({SITE_PICTURE_FOLDER, "/", use.picture.file_name}, context.temp_allocator)
}

// mark_site_files gives each file of the mark of the site that is not a
// tile map, by its path in the site: the pictures, the icons, the icon
// file and the vector icon. The tile maps go with the script that plays
// them (site_mark_animation.odin), which asks for them.
mark_site_files :: proc() -> (files: map[string][]u8, ok: bool) {
	files = make(map[string][]u8, context.temp_allocator)
	for use in mark_uses {
		if use.place == .Repository || use.kind == .Tile_Map || use.kind == .Tile_Map_Of_Frames {
			continue
		}
		path := mark_use_site_path(use)
		if path in files {
			continue // A next entry of an icon file: the file is made.
		}
		files[path] = mark_use_file(use.picture.file_name) or_return
	}
	return files, true
}

// What a request of the command asks for.
Mark_What :: enum {
	Still, // The still mark, as one picture.
	Frame, // One frame of an animation, as one picture.
	Animation, // Every frame of one animation, each for its time, as one animated file.
	Tile_Map, // The tile map of one animation or of all: the frames, and the drawn forms of the moves.
	Table, // The table of a tile map, as JSON: the place and the size of each tile, the times, the moves in cells.
}

// The name of each kind of request, as the command reads it.
mark_what_names := [Mark_What]string {
	.Still     = "still",
	.Frame     = "frame",
	.Animation = "animation",
	.Tile_Map  = "tile_map",
	.Table     = "table",
}

// A request: what to draw, and how. The picture says how the heron is
// drawn. A frame names its animation and its number. A tile map and its
// table are of one animation or of all, with the drawn forms or without,
// in rows that are at most a width in pixels. The still mark and a frame
// can be an icon file, whose entries are the picture and then the other
// entries, or a vector file, with or without the rule of the dark scheme.
Mark_Request :: struct {
	what:          Mark_What,
	picture:       Mark_Picture,
	has_animation: bool, // The animation is named: a frame and an animation need it; a tile map is then of that animation only.
	animation:     mark.Animation,
	frame:         int, // The frame of the animation, from 1; 0 with a frame: the still heron.
	with_forms:    bool, // A tile map with the drawn forms of the moves.
	width_most:    int, // The widest tile map, in pixels; 0: rows of MARK_TILE_MAP_COLUMNS tiles.
	format:        Mark_Format, // The format of the file (mark_formats.odin).
	entries:       []Mark_Picture, // The entries of an icon file after the picture.
	dark_rule:     bool, // A vector file with the rule that gives the colors of the dark scheme.
}

// mark_request_format gives the format of the file of a request: the one
// that it names, or the usual one of what it asks.
mark_request_format :: proc(request: Mark_Request) -> Mark_Format {
	if request.format != .Usual {
		return request.format
	}
	switch request.what {
	case .Still, .Frame, .Tile_Map:
		return .PNG
	case .Animation:
		return .APNG
	case .Table:
		return .JSON
	}
	return .PNG
}

// mark_request_entries gives the entries of the icon file of a request:
// the picture, then the other entries.
mark_request_entries :: proc(request: Mark_Request) -> []Mark_Picture {
	entries := make([dynamic]Mark_Picture, context.temp_allocator)
	append(&entries, request.picture)
	append(&entries, ..request.entries)
	return entries[:]
}

// mark_request_refusal gives the sentence that says why a request cannot
// be served, or "".
mark_request_refusal :: proc(request: Mark_Request) -> string {
	if refusal := mark_picture_refusal(request.picture); refusal != "" {
		return refusal
	}
	format := mark_request_format(request)
	format_fits := false
	switch request.what {
	case .Still, .Frame:
		format_fits = format == .PNG || format == .ICO || format == .SVG
	case .Animation:
		format_fits = format == .APNG
	case .Tile_Map:
		format_fits = format == .PNG
	case .Table:
		format_fits = format == .JSON
	}
	if !format_fits {
		return fmt.tprintf("the format %s does not hold what is asked: the still mark and a frame are a PNG file, an icon file (ico) or a vector file (svg); an animation is an animated PNG file (apng); a tile map is a PNG file; a table is JSON", mark_format_names[format])
	}
	if len(request.entries) > 0 && format != .ICO {
		return "only an icon file has more entries than one picture: ask for the format ico"
	}
	if request.dark_rule && format != .SVG {
		return "only a vector file holds the rule of the dark scheme: a file of pixels has the colors of one scheme; ask for the format svg"
	}
	switch request.what {
	case .Still:
		if request.has_animation || request.frame != 0 {
			return "the still mark has no animation and no frame: ask for a frame"
		}
	case .Frame:
		if !request.has_animation {
			return "a frame is a frame of an animation: name the animation"
		}
		if request.frame < 0 || request.frame > mark.animation_frame_count(request.animation) {
			return fmt.tprintf("the animation %s has the frames 1 to %d, and 0 is the still heron: not %d", mark.animation_names[request.animation], mark.animation_frame_count(request.animation), request.frame)
		}
	case .Animation:
		if !request.has_animation {
			return "an animated file holds one animation: name the animation"
		}
		if request.frame != 0 {
			return "an animated file holds every frame of its animation: it takes no frame"
		}
	case .Tile_Map, .Table:
		picture := request.picture
		if picture.name_cell > 0 || picture.opaque || picture.width > 0 {
			return "a tile map holds the heron alone, each tile at the size of the heron, on a transparent background: a script lays a tile over a page"
		}
		if request.frame != 0 {
			return "a tile map holds every frame of its animations: it takes no frame"
		}
		widest_tile := mark.heron_size(picture.heron_cell)
		if request.with_forms {
			widest_tile = MARK_FORM_BOX_COLUMNS * picture.heron_cell
		}
		if request.width_most != 0 && request.width_most < widest_tile {
			return fmt.tprintf("the widest tile map is %d pixels, and one tile is wider", request.width_most)
		}
		if request.width_most < 0 || request.width_most > MARK_PICTURE_SIDE_MOST {
			return fmt.tprintf("the width of a tile map is at most %d pixels", MARK_PICTURE_SIDE_MOST)
		}
	}
	// The format last: what is asked is then known to have sense.
	if format == .ICO {
		return mark_icon_file_refusal(mark_request_entries(request))
	}
	if format == .SVG {
		return mark_vector_refusal(request.picture, request.dark_rule)
	}
	return ""
}

// mark_cells_file gives the file of a request for one picture, drawn with
// the cells of the still heron or of a frame, in the format of the
// request.
mark_cells_file :: proc(request: Mark_Request, cells: ^mark.Heron_Cells) -> (file: []u8, ok: bool) {
	switch mark_request_format(request) {
	case .ICO:
		return mark_icon_file(mark_request_entries(request), cells)
	case .SVG:
		return transmute([]u8)mark_picture_svg(request.picture, cells, request.dark_rule), true
	case .Usual, .PNG, .APNG, .JSON:
	}
	return mark_frame_png(request.picture, cells)
}

// mark_generate serves a request: it gives the bytes of the file (a PNG
// picture, an icon file, a vector file, an animated PNG file or the JSON
// text of a table), or the sentence of a refusal. This is the one entry of
// the generator for a request that is not a row of the table of the uses.
mark_generate :: proc(request: Mark_Request) -> (file: []u8, refusal: string) {
	if sentence := mark_request_refusal(request); sentence != "" {
		return nil, sentence
	}
	ok: bool
	switch request.what {
	case .Still:
		still := mark.still_cells()
		file, ok = mark_cells_file(request, &still)
	case .Frame:
		cells, found := mark.animation_frame_cells(request.animation, request.frame)
		if !found {
			return nil, "the frame is not in the table of the animations"
		}
		file, ok = mark_cells_file(request, &cells)
	case .Animation:
		file, ok = mark_animation_png(request.picture, request.animation)
	case .Tile_Map:
		tile_map, built := mark_tile_map_build(request.picture, request.has_animation, request.animation, request.with_forms, request.width_most)
		if !built {
			return nil, "the tile map cannot be built from the tables of the animations"
		}
		file, ok = mark_tile_map_png(&tile_map)
	case .Table:
		tile_map, built := mark_tile_map_build(request.picture, request.has_animation, request.animation, request.with_forms, request.width_most)
		if !built {
			return nil, "the tile map cannot be built from the tables of the animations"
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "{")
		mark_tile_map_table_fields_write(&b, &tile_map)
		strings.write_string(&b, "}\n")
		file, ok = transmute([]u8)strings.to_string(b), true
	}
	if !ok {
		return nil, "the encoder of the picture failed"
	}
	return file, ""
}

// The folder of the pictures of the site, under the folder of the site: a
// use of the mark of the place Site is a file there.
SITE_PICTURE_FOLDER :: "pictures"

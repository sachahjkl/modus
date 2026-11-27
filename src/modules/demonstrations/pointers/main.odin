// The pointer themes of the boot image, as a table that a reader reads
// (docs/POINTERS.md): each pointer shape of a theme at each of its sizes, in
// each of its forms (the light form on a light track), its hot spot marked,
// its frames, and the theme with its license and its attribution.
//
// The process holds a read-only storage grant for the `pointer_themes` image
// subtree, without holding a handle to the whole boot image. It maps each
// pointer theme file through `storage.map_object`, checks the hash of each one
// against the hash returned by storage (the identity of a file is the hash of
// its content), validates it with the validation of the compositor,
// and shows one theme at a time: a button for each theme, the theme of the
// system first, changes the theme. The window
// is built with the interface package; the pointer pictures are drawn into
// the canvas directly, inside the area of each tile, because the package
// has no record of a picture of pixels. Over a tile, the process asks the
// compositor for the shape of the tile (display.pointer_shape_set): the
// pointer over this surface shows it.
//
// **What it is for.** It is the check, by eye, of a resource of the boot
// image: a reader sees each picture that the compositor can show, at each
// size, with its license, before it trusts the theme. It also shows the
// identity rule of a resource: a file whose bytes do not have the hash of
// its entry is shown as not valid, with the reason.
//
// **Start**: `start("pointers")` in the console, or the bar of the desktop.
//
// **Grants**, as the root service gives them:
//
// - **Read_Only_Trees** (`pointer_themes`): a connection to the storage
//   service with read-only access to the `pointer_themes` image subtree. With
//   no storage connection it writes "pointers: no boot image" and stops with
//   `Failed`.
//
// **What a reader sees**: the tiles of one theme; a button for each theme
// changes the theme, and a press writes "pointers: the theme NAME is
// shown". A release image holds the theme of the system only, so it shows
// one button. The log has one line for each theme ("pointers: NAME: the theme,
// its license, N shapes, M pictures, ...; the hash and the validation in T
// us", or "... is not valid: ..."), then "pointers: ok, N themes; ...", and
// "pointers: the pointer is over the tile ..." when the pointer enters a
// tile.
//
// The design: `docs/POINTERS.md`.
package pointers

import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/pointer_pictures"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:storage"
import "modus:system"

// The logical picture in which the window draws by hand before its first frame.
HAND_PICTURE_PAGES :: 671
#assert(HAND_PICTURE_PAGES == (WIDTH * HEIGHT * 4 + system.PAGE_SIZE - 1) / system.PAGE_SIZE)
// The hand-drawn window picture allocated before ready.
MODULE_START_OBJECTS :: [?]system.Start_Object{HAND_PICTURE_PAGES}
// The tool counts the module, its stack, its window at the largest scale and
// the hand picture in MODULE_START_OBJECTS.
MODULE_BUDGET :: system.Stated_Budget{window_width = WIDTH, window_height = HEIGHT}

// The picture of the window, in its logical pixels (interface.Hand_Picture).
hand_picture: interface.Hand_Picture

WIDTH :: 976
HEIGHT :: 704
COLUMNS :: 5 // Tiles in a line.
TILE_WIDTH :: 184
TILE_HEIGHT :: 144
TILE_GAP :: 8
TILES_TOP :: 216 // The first line of tiles, in the window.
PICTURE_TOP :: 56 // The pictures, in a tile, under two lines of the name and a line of facts.
NAME_LIMIT :: (TILE_WIDTH - 16) / 8 // The characters of a line of a tile.
THEME_CAPACITY :: 4

// A theme file mapped read-only from storage that the process checked.
Theme :: struct {
	resource:   string,
	mapped:     storage.Mapped_Object,
	file:       []u8,
	hash:       [32]u8,
	valid:      bool,
	problem:    [256]u8, // The sentence of the problem when it is not valid.
	problem_count: int,
	check_time: u64, // Nanoseconds: the hash and the validation.
}

// Exact image-tree paths mapped through storage, in compositor preference order.
Theme_Target :: struct {
	resource: string, // Display and log label matching pointer_pictures.RESOURCE_PREFERENCE.
	path:     string, // Exact '/' object path in the granted pointer_themes subtree.
}

@(rodata)
THEME_TARGETS := [?]Theme_Target {
	{resource = pointer_pictures.RESOURCE_OF_THE_OWNER, path = "pointer_themes/posy"},
	{resource = pointer_pictures.RESOURCE_OF_THE_SYSTEM, path = "pointer_themes/system"},
}

themes: [THEME_CAPACITY]Theme
theme_count: int
shown: int // The theme on the screen.
table_records: [1024]interface.Draw_Record
table_text: [16384]u8
table: interface.Draw_Table
state: interface.Interface_State
input: interface.Input
asked_shape := pointer_pictures.Pointer_Shape.Arrow // The last shape that this process asked for.
tile_under_pointer := -1

// The area of the tile of the shape at a place of the shape table.
tile_area :: proc "contextless" (index: int) -> interface.Area {
	column := index % COLUMNS
	line := index / COLUMNS
	return {16 + column * (TILE_WIDTH + TILE_GAP), TILES_TOP + line * (TILE_HEIGHT + TILE_GAP), TILE_WIDTH, TILE_HEIGHT}
}

hexadecimal :: proc "contextless" (builder: ^interface.Text_Builder, bytes: []u8) {
	digits := "0123456789abcdef"
	for byte in bytes {
		pair := [2]u8{digits[byte >> 4], digits[byte & 15]}
		interface.text_put(builder, string(pair[:]))
	}
}

// build describes the window for one frame. It gives the tile under the
// pointer, or -1.
build :: proc "contextless" (frame: ^interface.Frame) -> int {
	builder: interface.Text_Builder
	interface.background(frame, {0, 0, WIDTH, HEIGHT})
	theme := &themes[shown]
	head := pointer_pictures.header(theme.file)
	count: interface.Text_Builder
	interface.text_put_number(&count, u64(shown + 1))
	interface.text_put(&count, " of ")
	interface.text_put_number(&count, u64(theme_count))
	content := interface.card(frame, {8, 8, WIDTH - 16, TILES_TOP - 16}, "POINTER THEME", "resource table of the boot image", graphics.colors.machine, interface.text_of(&count))
	column := interface.column_of(content, 0)

	// The buttons that choose the theme, the last theme of the preference
	// first: the theme of the system, which every boot image holds, keeps
	// the first place, with or without the theme of the owner. A press
	// writes its line even on the theme shown, so a reader and a test see
	// the press with one theme as with two.
	buttons := interface.column_take(&column, 24)
	for index in 0 ..< theme_count {
		label := themes[index].resource
		place := theme_count - 1 - index
		area := interface.Area{buttons.x + place * 200, buttons.y, 192, 24}
		result := interface.button(frame, area, interface.identity_with(interface.identity("theme"), index), label, index == shown)
		if result.activated {
			shown = index
			system.log_fact(.Info, Theme_Shown{theme = resource_field(label)})
		}
	}
	interface.column_take(&column, 8)
	if !theme.valid {
		interface.label_value_line(frame, interface.column_take(&column, 16), "not valid", string(theme.problem[:theme.problem_count]), graphics.colors.failed, 128)
		return -1
	}
	interface.label_value_line(frame, interface.column_take(&column, 16), "theme", pointer_pictures.text_of(head.theme_name[:]), graphics.colors.text, 128)
	interface.text_put(&builder, pointer_pictures.text_of(head.license[:]))
	interface.label_value_line(frame, interface.column_take(&column, 16), "license", interface.text_of(&builder), graphics.colors.text, 128)
	builder = {}
	interface.text_put_number(&builder, u64(head.shape_count))
	interface.text_put(&builder, " shapes, ")
	interface.text_put_number(&builder, u64(head.picture_count))
	interface.text_put(&builder, " pictures, ")
	interface.text_put_number(&builder, head.file_size)
	interface.text_put(&builder, " bytes; blake3 ")
	hexadecimal(&builder, theme.hash[:12])
	interface.text_put(&builder, "..., as its entry")
	interface.label_value_line(frame, interface.column_take(&column, 16), "file", interface.text_of(&builder), graphics.colors.text, 128)
	// The attribution, in lines of at most 98 characters, cut at a space.
	attribution := pointer_pictures.text_of(head.attribution[:])
	first := true
	for len(attribution) > 0 {
		cut := len(attribution)
		if cut > 98 {
			cut = 98
			for cut > 0 && attribution[cut] != ' ' {
				cut -= 1
			}
			if cut == 0 {
				cut = 98
			}
		}
		interface.label_value_line(frame, interface.column_take(&column, 16), first ? "attribution" : "", attribution[:cut], graphics.colors.text, 128)
		first = false
		attribution = attribution[min(cut + 1, len(attribution)):]
	}

	// The tiles: one for each shape of the theme.
	under := -1
	pictures := pointer_pictures.picture_entries(theme.file)
	for entry, index in pointer_pictures.shape_entries(theme.file, .Dark) {
		area := tile_area(index)
		if input.pointer_known && interface.area_contains(area, input.pointer_x, input.pointer_y) {
			under = index
		}
		interface.draw_vertical_gradient(frame.table, area.x, area.y, area.width, area.height, under == index ? graphics.shade(graphics.colors.card_top, 140) : graphics.colors.card_top, graphics.colors.card_bottom)
		interface.draw_rectangle(frame.table, area.x, area.y, area.width, 1, graphics.shade(graphics.colors.machine, under == index ? 60 : 28))
		// The name, on two lines when it is longer than a line: cut after
		// an underscore.
		name := pointer_pictures.shape_name(entry.shape)
		name_color := graphics.Color(under == index ? graphics.COLOR_WHITE : graphics.colors.text)
		if len(name) <= NAME_LIMIT {
			interface.draw_text(frame.table, area.x + 8, area.y + 4, name, name_color)
		} else {
			cut := NAME_LIMIT
			for cut > 0 && name[cut - 1] != '_' {
				cut -= 1
			}
			cut = cut == 0 ? NAME_LIMIT : cut
			interface.draw_text(frame.table, area.x + 8, area.y + 4, name[:cut], name_color)
			interface.draw_text(frame.table, area.x + 8, area.y + 20, name[cut:], name_color)
		}
		// The facts: the hot spot of the first size, and the frames.
		first_picture := pictures[entry.first_picture]
		builder = {}
		interface.text_put(&builder, "hot ")
		interface.text_put_number(&builder, u64(first_picture.hot_spot_x))
		interface.text_put(&builder, ",")
		interface.text_put_number(&builder, u64(first_picture.hot_spot_y))
		interface.draw_text(frame.table, area.x + 8, area.y + 36, interface.text_of(&builder), graphics.colors.boot_program)
		if entry.frame_count > 1 {
			builder = {}
			interface.text_put_number(&builder, u64(entry.frame_count))
			interface.text_put(&builder, " x ")
			interface.text_put_number(&builder, u64(first_picture.delay_milliseconds))
			interface.text_put(&builder, " ms")
			interface.draw_text_right(frame.table, area.x + area.width - 8, area.y + 36, interface.text_of(&builder), graphics.colors.dim)
		}
		// A track behind each size of each form, with the lines of the hot
		// spot: the dark form on a dark track, the light form on a light one.
		x := area.x + 8
		// The theme file holds the word of the shape: a word that names no
		// shape draws no track.
		entry_shape, entry_shape_ok := enum_word.member_of_word(pointer_pictures.Pointer_Shape, u64(entry.shape))
		for form in forms_of(theme.file) {
			form_entry, found := pointer_pictures.shape_entry_of(theme.file, form, entry_shape)
			if !entry_shape_ok || !found {
				continue
			}
			for size in 0 ..< form_entry.size_count {
				picture := pictures[form_entry.first_picture + size * form_entry.frame_count]
				side := int(picture.nominal_size)
				if x + side > area.x + area.width - 8 {
					break
				}
				interface.draw_rectangle(frame.table, x, area.y + PICTURE_TOP, side, side, TRACK_OF_FORM[form])
				interface.draw_rectangle(frame.table, x + int(picture.hot_spot_x), area.y + PICTURE_TOP, 1, side, graphics.colors.boot_program)
				interface.draw_rectangle(frame.table, x, area.y + PICTURE_TOP + int(picture.hot_spot_y), side, 1, graphics.colors.boot_program)
				builder = {}
				interface.text_put_number(&builder, u64(picture.nominal_size))
				interface.draw_text(frame.table, x, area.y + PICTURE_TOP + side + 4, interface.text_of(&builder), graphics.colors.dim)
				x += side + 8
			}
		}
	}
	builder = {}
	interface.text_put(&builder, "the lines in amber cross at the hot spot; over a tile, this process asks the compositor for its shape")
	interface.draw_text(frame.table, 16, HEIGHT - 24, interface.text_of(&builder), graphics.colors.dim)
	return under
}

// pictures_draw draws the first frame of each picture of each tile, over
// its track: the pixels, which no draw record holds.
pictures_draw :: proc "contextless" (canvas: graphics.Canvas) {
	theme := &themes[shown]
	if !theme.valid {
		return
	}
	pictures := pointer_pictures.picture_entries(theme.file)
	for entry, index in pointer_pictures.shape_entries(theme.file, .Dark) {
		area := tile_area(index)
		x := area.x + 8
		// The theme file holds the word of the shape: a word that names no
		// shape draws no track.
		entry_shape, entry_shape_ok := enum_word.member_of_word(pointer_pictures.Pointer_Shape, u64(entry.shape))
		for form in forms_of(theme.file) {
			form_entry, found := pointer_pictures.shape_entry_of(theme.file, form, entry_shape)
			if !entry_shape_ok || !found {
				continue
			}
			for size in 0 ..< form_entry.size_count {
				picture := pictures[form_entry.first_picture + size * form_entry.frame_count]
				side := int(picture.nominal_size)
				if x + side > area.x + area.width - 8 {
					break
				}
				pixels := pointer_pictures.pixels_of(theme.file, picture)
				// The picture in the square of its nominal size: a picture larger
				// than its size is cut to the square.
				square := graphics.view(canvas, x, area.y + PICTURE_TOP, side, side)
				graphics.blend_premultiplied_alpha(square, 0, 0, {pixels = raw_data(pixels), width = int(picture.width), height = int(picture.height), stride = int(picture.width)})
				x += side + 8
			}
		}
	}
}

// The track behind the pictures of each form: the track of the appearance
// of that form, whatever the appearance in force: each form is seen on the
// surfaces it is drawn for.
TRACK_OF_FORM := [pointer_pictures.Pointer_Form]graphics.Color {
	.Dark  = graphics.DARK_COLOR_TOKENS.track,
	.Light = graphics.LIGHT_COLOR_TOKENS.track,
}

// The forms in their order, for forms_of.
@(rodata)
ALL_FORMS := [?]pointer_pictures.Pointer_Form{.Dark, .Light}

// forms_of gives the forms that a theme holds, the dark form first.
forms_of :: proc "contextless" (file: []u8) -> []pointer_pictures.Pointer_Form {
	return ALL_FORMS[:min(int(pointer_pictures.header(file).form_count), len(ALL_FORMS))]
}

// frame_draw builds the window, draws it whole, then the pictures, and
// presents it. The window changes only with an event.
frame_draw :: proc "contextless" (window: ^display.Window) -> u64 {
	start := system.nanoseconds()
	frame := interface.frame_begin(&table, &state, &input)
	before := shown
	under := build(&frame)
	interface.frame_end(&frame)
	interface.input_clear(&input)
	if shown != before {
		// A button changed the theme: the frame shows the other theme.
		frame = interface.frame_begin(&table, &state, &input)
		under = build(&frame)
		interface.frame_end(&frame)
	}
	// The canvas is the picture that the compositor does not read, after
	// it took the picture before. It holds an older frame: the whole
	// canvas is drawn.
	// The pictures of the pointers are drawn by hand, in a picture of the
	// logical size of the window, which the drawing module puts on the
	// screen at the scale (interface.Hand_Picture).
	if display.canvas_wait(window) {
		graphics.clear(hand_picture.canvas, graphics.colors.background)
		interface.execute(&table, hand_picture.canvas)
		pictures_draw(hand_picture.canvas)
		interface.hand_picture_show(&hand_picture, window)
	}
	// Over a tile, the pointer takes the shape of the tile.
	shape := pointer_pictures.Pointer_Shape.Arrow
	if under >= 0 && themes[shown].valid {
		// A tile whose word names no shape keeps the arrow.
		if tile_shape, tile_shape_ok := enum_word.member_of_word(pointer_pictures.Pointer_Shape, u64(pointer_pictures.shape_entries(themes[shown].file, .Dark)[under].shape)); tile_shape_ok {
			shape = tile_shape
		}
	}
	if shape != asked_shape {
		asked_shape = shape
		display.pointer_shape_set(window, shape)
	}
	if under != tile_under_pointer {
		tile_under_pointer = under
		if under >= 0 {
			system.log_fact(.Info, Pointer_Over_Tile{shape = value_kinds.text_field(pointer_pictures.SHAPE_NAMES[shape], SHAPE_FIELD_BYTES)})
		}
	}
	return system.nanoseconds() - start
}

// The entry of pointers: it checks each pointer theme mapped read-only through
// the storage service, then shows them until the principal closes the window.
//
// It opens its storage connection (Read_Only_Trees for `pointer_themes`) and
// maps the themes in the order in which the compositor prefers them. For each
// theme it computes the hash, compares it with the hash returned by storage,
// validates the file with the validation of the compositor, and writes one
// line on the log. With no theme it stops with `Failed`; with no window it
// stops with `Failed`. Then it draws, and draws again after each event that
// changes the window.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	client, storage_ok := storage.open(ctx)
	if !storage_ok {
		system.log_fact(.Info, No_Boot_Image{})
		system.stop(.Failed)
	}
	// The themes, in the order in which the compositor prefers them.
	for target in THEME_TARGETS {
		if theme_count == THEME_CAPACITY {
			break
		}
		mapped, _, map_status, _ := storage.map_object(&client, target.path)
		if map_status != .Ok {
			continue
		}
		theme := &themes[theme_count]
		theme_count += 1
		theme.resource = target.resource
		theme.mapped = mapped
		theme.file = mapped.bytes
		start := system.nanoseconds()
		theme.hash = blake3.hash(theme.file)
		problem := pointer_pictures.validate(theme.file)
		theme.check_time = system.nanoseconds() - start
		theme.valid = theme.hash == mapped.hash && problem.kind == .None
		if theme.hash != mapped.hash {
			theme.problem_count = copy(theme.problem[:], "the bytes do not have the hash of the entry of the resource")
		} else if problem.kind != .None {
			theme.problem_count = len(pointer_pictures.sentence(problem, theme.problem[:]))
		}
		if theme.valid {
			head := pointer_pictures.header(theme.file)
			system.log_fact(.Info, Theme_Valid{shapes = u64(head.shape_count), pictures = u64(head.picture_count), file_size = value_kinds.Size_In_Bytes(mapped.size), check = value_kinds.Time_In_Microseconds(theme.check_time / 1000), theme = resource_field(target.resource), theme_name = theme_text_field(pointer_pictures.text_of(head.theme_name[:])), license = theme_text_field(pointer_pictures.text_of(head.license[:]))})
		} else {
			theme_not_valid_log(target.resource, theme.hash != mapped.hash, problem)
		}
	}
	// Release the temporary storage connection handles while keeping the
	// read-only pointer theme mappings alive for the lifetime of this window.
	storage.close(&client)
	if theme_count == 0 {
		system.log_fact(.Info, No_Pointer_Theme{})
		system.stop(.Failed)
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "pointers")
	if !ok || interface.hand_picture_open(&hand_picture, &window) != .Succeeded {
		system.stop(.Failed)
	}
	table = {records = table_records[:], text = table_text[:]}
	spent := frame_draw(&window)
	system.log_fact(.Info, Window_Drawn{themes = u64(theme_count), drawing = value_kinds.Time_In_Microseconds(spent / 1000), theme = resource_field(themes[shown].resource)})
	for {
		display.wait(&window)
		came := false
		// The elements of the frame are in the coordinates of the layout,
		// which the window scrolls when it does not fit.
		for event in interface.window_next_event(&hand_picture.drawing, &window) {
			came = interface.input_add(&input, event) || came
		}
		came ||= interface.window_scroll_frame_take(&hand_picture.drawing)
		if came {
			frame_draw(&window)
		}
	}
}

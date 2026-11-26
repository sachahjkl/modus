package compositor

// The pointer (docs/POINTERS.md): the compositor maps the pointer theme file
// that the root service gives, validates it once, chooses the pointer shape
// from what is under the pointer, and draws its pointer picture with a blend
// of premultiplied alpha, at the place of the pointer less the hot spot.
//
// The place of the pointer (pointer_x, pointer_y, and compositor.pointer())
// is the point where a press acts; the hot spot of the picture is drawn
// there. An animated shape wakes the compositor at the time of its next
// frame, and only while it shows.

import "modus:contract/enum_word"
import op "modus:contract/operation"
import "modus:contract/pointer_pictures"
import "modus:contract/ring"
import "modus:contract/settings"
import "modus:contract/value_kinds"
import "internal:compositor/bar"
import "modus:graphics"
import "modus:interface"
import "internal:compositor/palette"
import "modus:system"

// The values of the context that give the theme file, mapped read-only.
VALUE_POINTER_THEME_ADDRESS :: 6
VALUE_POINTER_THEME_SIZE :: 7
// The places of the address and the size of each theme: the second one is
// at the values that modus:contract/operation names for it.
POINTER_THEME_VALUES := [2][2]int{{VALUE_POINTER_THEME_ADDRESS, VALUE_POINTER_THEME_SIZE}, {op.CONTEXT_VALUE_SECOND_POINTER_THEME_ADDRESS, op.CONTEXT_VALUE_SECOND_POINTER_THEME_SIZE}}
// The nominal size of the pointer in logical pixels. The compositor asks
// for it in pixels of the screen at the scale: the smallest size of the
// theme that is at least that one. The theme of the system has 24, 30, 33
// and 48 (resources/pointers/system.manifest): a scale with no size of its
// own gets the next larger one, 30 at 1.125 and 48 at 1.5 to 1.875.
POINTER_NOMINAL_SIZE :: 24

// pointer_size_asked gives the nominal size in pixels of the screen at the
// scale of the desktop.
pointer_size_asked :: proc "contextless" () -> u32 {
	return u32(screen_pixel_of(POINTER_NOMINAL_SIZE))
}

// pointer_screen_place gives the pixel of the screen of the place of the
// pointer: the hot spot of its picture is drawn there.
pointer_screen_place :: proc "contextless" () -> (x, y: int) {
	return screen_pixel_of(pointer_x), screen_pixel_of(pointer_y)
}
// The frames of a pointer that the measure of its cost counts, before it
// writes the log line.
POINTER_MEASURE_FRAMES :: 256

// The arrow of squares of docs/DESIGN.md, for a compositor with no valid
// theme file: X is a black square of 2 pixels, . a white one, the point is
// the top left square.
@(rodata)
pointer_arrow_without_theme := [?]string {
	"X       ",
	"XX      ",
	"X.X     ",
	"X..X    ",
	"X...X   ",
	"X....X  ",
	"X.....X ",
	"X......X",
	"X..XXXXX",
	"X.X     ",
	"XX      ",
}
POINTER_ARROW_SQUARE :: 2

pointer_theme: []u8 // A theme file that pointer_pictures.validate accepted, or nil.
pointer_form: pointer_pictures.Pointer_Form // The form of the theme for the appearance in force.
pointer_shape: pointer_pictures.Pointer_Shape // The shape that the screen shows.
pointer_chosen: pointer_pictures.Chosen // Its picture, which the next frame draws.
pointer_drawn: Rectangle // The rectangle of the picture on the screen.
pointer_drawn_valid: bool
// The measure of the cost of the pointer in a frame: the time of its blend
// in each damage rectangle that holds it, summed for a frame.
pointer_measure_frames, pointer_measure_time, pointer_measure_longest: u64
pointer_frame_time: u64

// The theme files that the root service gives, in the order of
// pointer_pictures.RESOURCE_PREFERENCE, and the state of each one. A file
// is validated at its first use, once: the boot validates the theme that
// the setting chooses, not both (on the software processor of a browser
// machine the two took 11 s).
Pointer_Theme_State :: enum u8 {
	Absent    = 0, // The root service gave no file there.
	Unchecked = 1, // Mapped, never validated.
	Valid     = 2,
	Refused   = 3, // Not valid: never used.
}
pointer_theme_files: [len(pointer_pictures.RESOURCE_PREFERENCE)][]u8
pointer_theme_states: [len(pointer_pictures.RESOURCE_PREFERENCE)]Pointer_Theme_State

// pointer_theme_open maps nothing: the root service mapped the files, the
// first one at the values 6 and 7, the second at the values that
// modus:contract/operation names for it. It chooses the theme of the
// owner, which validates that file only.
pointer_theme_open :: proc "contextless" (ctx: ^system.Context) {
	for index in 0 ..< len(pointer_theme_files) {
		address := ctx.values[POINTER_THEME_VALUES[index][0]]
		size := ctx.values[POINTER_THEME_VALUES[index][1]]
		if address == 0 || size == 0 {
			continue
		}
		pointer_theme_files[index] = ([^]u8)(uintptr(address))[:size]
		pointer_theme_states[index] = .Unchecked
	}
	pointer_theme_choose(.Of_The_Owner)
	if pointer_theme == nil {
		system.log_fact(.Warning, No_Pointer_Theme{})
		pointer_update(0)
	}
}

// pointer_theme_valid validates the theme file at an index at its first
// use, and says whether it is valid. A file that is not valid is refused
// for good, with its line on the log.
pointer_theme_valid :: proc "contextless" (index: int) -> bool {
	switch pointer_theme_states[index] {
	case .Absent, .Refused:
		return false
	case .Valid:
		return true
	case .Unchecked:
	}
	file := pointer_theme_files[index]
	start := system.nanoseconds()
	problem := pointer_pictures.validate(file)
	spent := system.nanoseconds() - start
	if problem.kind != .None {
		pointer_theme_states[index] = .Refused
		system.log_fact(.Warning, Pointer_Theme_Refused{problem_kind = pointer_pictures.Problem_Kind_Word(problem.kind), theme_part = pointer_pictures.Part_Word(problem.part), theme_field = pointer_pictures.Field_Word(problem.field), place_index = problem.index, value = problem.value, limit = problem.limit, theme_file = value_kinds.text_field(pointer_pictures.RESOURCE_PREFERENCE[index], THEME_FILE_FIELD_BYTES)})
		return false
	}
	pointer_theme_states[index] = .Valid
	head := pointer_pictures.header(file)
	system.log_fact(.Info, Pointer_Theme_Validated{shapes = u64(head.shape_count), pictures = u64(head.picture_count), size = value_kinds.Size_In_Bytes(u64(len(file))), elapsed = value_kinds.Time_In_Microseconds(spent / 1000), theme = value_kinds.text_field(pointer_pictures.text_of(head.theme_name[:]), THEME_TEXT_FIELD_BYTES), license = value_kinds.text_field(pointer_pictures.text_of(head.license[:]), THEME_TEXT_FIELD_BYTES)})
	return true
}

// pointer_form_in_force gives the form of the pointer for the appearance in
// force: the dark form on a dark desktop, the light form on a light one
// (docs/POINTERS.md, "5. The two themes"). The settings page holds the
// appearance in force, which the rule of the day can change with no new
// setting; the compositor reads the page again at that change, so the
// pointer changes its form at the next frame.
pointer_form_in_force :: proc "contextless" (choice: settings.Choice) -> pointer_pictures.Pointer_Form {
	return choice.appearance_in_force == .Light ? .Light : .Dark
}

// pointer_form_name gives the name of a form, as the log and pointer() write it.
pointer_form_name :: proc "contextless" (form: pointer_pictures.Pointer_Form) -> string {
	return form == .Light ? "light" : "dark"
}

// pointer_form_choose takes a form and draws the pointer again with it.
pointer_form_choose :: proc "contextless" (form: pointer_pictures.Pointer_Form) {
	if form == pointer_form {
		return
	}
	pointer_form = form
	pointer_drawn_valid = false // The next update chooses its picture in the new form.
	pointer_update(0)
	system.log_fact(.Info, Pointer_Form_In_Use{pointer_form = value_kinds.text_field(pointer_form_name(form), POINTER_FORM_FIELD_BYTES)})
}

// pointer_theme_choose takes the theme of the setting: the first theme of
// the list that the root service gave (the theme of the owner when the
// boot image has it), or the theme of the system. It draws the pointer
// again with it.
pointer_theme_choose :: proc "contextless" (setting: settings.Pointer_Theme) {
	chosen: []u8
	last := len(pointer_theme_files) - 1
	if setting == .Of_The_System && pointer_theme_valid(last) {
		chosen = pointer_theme_files[last]
	}
	for index in 0 ..< len(pointer_theme_files) {
		if chosen == nil && pointer_theme_valid(index) {
			chosen = pointer_theme_files[index]
		}
	}
	if raw_data(chosen) == raw_data(pointer_theme) && len(chosen) == len(pointer_theme) {
		return
	}
	pointer_theme = chosen
	pointer_drawn_valid = false // The next update chooses its picture in the new theme.
	pointer_update(0)
	if chosen != nil {
		system.log_fact(.Info, Pointer_Theme_In_Use{theme = value_kinds.text_field(pointer_pictures.text_of(pointer_pictures.header(chosen).theme_name[:]), THEME_TEXT_FIELD_BYTES)})
	}
}

// pointer_shape_under gives the shape for what is under the pointer.
pointer_shape_under :: proc "contextless" () -> pointer_pictures.Pointer_Shape {
	if dragging >= 0 {
		return .Move
	}
	if resizing >= 0 {
		return resize_shape_of(resize_start.edges) // window_resize.odin
	}
	if palette_is_open() {
		// The input band is a text; an entry of the list and a candidate
		// of a form can be pressed. The scroll bar of the list is on no
		// row: the pointer over it is the arrow.
		left, top := palette_place()
		if palette.part_at(left, top, pointer_x, pointer_y) == .Input_Band {
			return .Text
		}
		if palette.row_is_entry(&palette_panel, palette.row_at(&palette_panel, left, top, pointer_x, pointer_y)) {
			return .Pointing_Hand
		}
		if palette.candidate_at(&palette_panel, left, top, pointer_x, pointer_y) != palette.NO_ROW {
			return .Pointing_Hand
		}
		return .Arrow
	}
	if capture_viewer_popover.open && capture_viewer_popover.hovered_index >= 0 {
		return .Pointing_Hand
	}
	if capture_mark_contains(pointer_x, pointer_y) {
		return .Pointing_Hand
	}
	if menu_open != .None && (menu_line >= 0 || menu_action != .None) {
		return .Pointing_Hand
	}
	if interface.context_menu_row_at(&desktop_context_menu, pointer_x, pointer_y) >= 0 {
		return .Pointing_Hand
	}
	if bar.button_at(bar_layout, pointer_x, pointer_y) != .None {
		return .Pointing_Hand
	}
	if bar.inside_bar(bar_layout, pointer_y) {
		return .Arrow
	}
	// An edge of a resizable window: a press there drags it.
	if _, edges := resize_edges_under_pointer(); edges != {} {
		return resize_shape_of(edges)
	}
	for position := order_count - 1; position >= 0; position -= 1 {
		client := &clients[order[position]]
		outer_width := client.width + 2 * BORDER
		if !inside(pointer_x, pointer_y, client.x, client.y, outer_width, client.height + TITLE_HEIGHT + BORDER) {
			continue
		}
		switch {
		case inside(pointer_x, pointer_y, client.x + outer_width - BORDER - CLOSE_SIZE, client.y, CLOSE_SIZE, TITLE_HEIGHT):
			return .Pointing_Hand
		case pointer_y < client.y + TITLE_HEIGHT:
			return .Move
		case inside(pointer_x, pointer_y, client.x + BORDER, client.y + TITLE_HEIGHT, client.width, client.height):
			// The surface of the window in front at this place: the shape that
			// its process asked for, over its own surface only: a process must not
// change the pointer over the window of another process.
			return client.pointer_shape
		}
		return .Arrow // The border.
	}
	return .Arrow
}

// pointer_update chooses the shape and its picture for the place of the
// pointer and the time now, and damages the old and the new rectangle when
// the picture or its place changed.
pointer_update :: proc "contextless" (now: u64) {
	if pointer_lock_is_active() {
		if pointer_drawn_valid {
			damage_screen_add(pointer_drawn.left, pointer_drawn.top, pointer_drawn.right - pointer_drawn.left, pointer_drawn.bottom - pointer_drawn.top)
			pointer_drawn_valid = false
		}
		return
	}
	shape := pointer_shape_under()
	chosen := pointer_chosen
	if pointer_theme != nil && (shape != pointer_shape || !pointer_drawn_valid || (chosen.next_frame != 0 && now >= chosen.next_frame)) {
		chosen = pointer_pictures.choose(pointer_theme, pointer_form, shape, pointer_size_asked(), now)
	}
	place := pointer_rectangle(chosen)
	if pointer_drawn_valid && place == pointer_drawn && shape == pointer_shape && chosen.picture == pointer_chosen.picture {
		return
	}
	// The picture is in pixels of the screen.
	if pointer_drawn_valid {
		damage_screen_add(pointer_drawn.left, pointer_drawn.top, pointer_drawn.right - pointer_drawn.left, pointer_drawn.bottom - pointer_drawn.top)
	}
	damage_screen_add(place.left, place.top, place.right - place.left, place.bottom - place.top)
	pointer_shape = shape
	pointer_chosen = chosen
	pointer_drawn = place
	pointer_drawn_valid = true
}

// pointer_rectangle gives the rectangle of a picture on the screen, in
// pixels of the screen: its hot spot at the screen place of the pointer.
pointer_rectangle :: proc "contextless" (chosen: pointer_pictures.Chosen) -> Rectangle {
	x, y := pointer_screen_place()
	if pointer_theme == nil {
		return {x, y, x + 8 * POINTER_ARROW_SQUARE, y + len(pointer_arrow_without_theme) * POINTER_ARROW_SQUARE}
	}
	left := x - int(chosen.picture.hot_spot_x)
	top := y - int(chosen.picture.hot_spot_y)
	return {left, top, left + int(chosen.picture.width), top + int(chosen.picture.height)}
}

// pointer_wake gives the time of the next frame of an animated shape on
// the screen, or 0: no wake for the pointer.
pointer_wake :: proc "contextless" () -> u64 {
	return pointer_chosen.next_frame
}

// pointer_shape_request takes the display command Pointer_Shape of a
// process: the shape of its surface. A word that names no shape is
// refused, with a line: the surface keeps its shape.
pointer_shape_request :: proc "contextless" (client: ^Client, record: ring.Record) {
	shape, shape_ok := enum_word.member_of_word(pointer_pictures.Pointer_Shape, record.values[0])
	if !shape_ok {
		system.log_fact(.Warning, Pointer_Shape_Refused{window = window_field(client.title[:]), shape = record.values[0]})
		return
	}
	client.pointer_shape = shape
	system.log_fact(.Info, Pointer_Shape_Asked{shape_name = value_kinds.text_field(pointer_pictures.SHAPE_NAMES[client.pointer_shape], SHAPE_NAME_FIELD_BYTES), window = window_field(client.title[:])})
}

// pointer_draw draws the pointer in one damage rectangle: the canvas is the
// part of the frame in it.
pointer_draw :: proc "contextless" (canvas: graphics.Canvas, origin_x, origin_y: int) {
	if pointer_lock_is_active() {
		return
	}
	if pointer_theme == nil {
		screen_x, screen_y := pointer_screen_place()
		for row, y in pointer_arrow_without_theme {
			for column in 0 ..< len(row) {
				color: graphics.Color
				switch row[column] {
				case 'X':
					color = graphics.COLOR_BLACK
				case '.':
					color = graphics.COLOR_WHITE
				case:
					continue
				}
				graphics.fill(canvas, screen_x + column * POINTER_ARROW_SQUARE + origin_x, screen_y + y * POINTER_ARROW_SQUARE + origin_y, POINTER_ARROW_SQUARE, POINTER_ARROW_SQUARE, color)
			}
		}
		return
	}
	place := pointer_drawn
	if place.right + origin_x <= 0 || place.bottom + origin_y <= 0 || place.left + origin_x >= canvas.width || place.top + origin_y >= canvas.height {
		return
	}
	start := system.nanoseconds()
	picture := graphics.Canvas{pixels = raw_data(pointer_chosen.pixels), width = int(pointer_chosen.picture.width), height = int(pointer_chosen.picture.height), stride = int(pointer_chosen.picture.width)}
	graphics.blend_premultiplied_alpha(canvas, place.left + origin_x, place.top + origin_y, picture)
	pointer_frame_time += system.nanoseconds() - start
}

// pointer_frame_end counts the time of the pointer in the frame that was
// drawn, and writes the measure on the log after POINTER_MEASURE_FRAMES
// frames that drew it.
pointer_frame_end :: proc "contextless" () {
	if pointer_frame_time == 0 {
		return
	}
	pointer_measure_frames += 1
	pointer_measure_time += pointer_frame_time
	pointer_measure_longest = max(pointer_measure_longest, pointer_frame_time)
	pointer_frame_time = 0
	if pointer_measure_frames == POINTER_MEASURE_FRAMES {
		system.log_fact(.Info, Pointer_Picture_Measured{frames = u64(POINTER_MEASURE_FRAMES), mean_time = value_kinds.Time_In_Nanoseconds(pointer_measure_time / POINTER_MEASURE_FRAMES), longest_time = value_kinds.Time_In_Nanoseconds(pointer_measure_longest)})
	}
}

// The rate of the frames while the pointer moves: a series of frames that
// each show a pointer record that came after the frame before, with no gap
// of more than POINTER_MOTION_GAP_NANOSECONDS between two of them. After
// POINTER_MOTION_FRAMES frames, the log has the rate of the series, and a
// new series starts. A gap ends a series with no line: the pointer stopped.
POINTER_MOTION_FRAMES :: 120
POINTER_MOTION_GAP_NANOSECONDS :: 250_000_000
pointer_motion_moves_seen: u64 // pointer_moves at the frame before.
pointer_motion_frames: u64 // The frames of the series after its first one.
pointer_motion_records: u64 // The pointer records of those frames.
pointer_motion_first, pointer_motion_last: u64 // The flips of the first and of the last frame of the series.

// pointer_motion_frame_end counts a frame of the series of a pointer that
// moves: flipped is the time of its flip.
pointer_motion_frame_end :: proc "contextless" (flipped: u64) {
	moved := pointer_moves - pointer_motion_moves_seen
	pointer_motion_moves_seen = pointer_moves
	if moved == 0 {
		return
	}
	if pointer_motion_first == 0 || flipped - pointer_motion_last > POINTER_MOTION_GAP_NANOSECONDS {
		// The first frame starts the series: the records that it shows
		// came before the series.
		pointer_motion_first, pointer_motion_last = flipped, flipped
		pointer_motion_frames, pointer_motion_records = 0, 0
		return
	}
	pointer_motion_frames += 1
	pointer_motion_records += moved
	pointer_motion_last = flipped
	if pointer_motion_frames < POINTER_MOTION_FRAMES {
		return
	}
	span := pointer_motion_last - pointer_motion_first
	system.log_fact(.Info, Pointer_Motion_Measured{frames = pointer_motion_frames, span = value_kinds.Nanoseconds_As_Microseconds(span), frames_each_second = pointer_motion_frames * 1_000_000_000 / max(span, 1), records = pointer_motion_records})
	pointer_motion_first = 0
}

// pointer_blend_measure measures the blend of the arrow of the theme, and
// of each picture size of the theme, on the frame, before the first frame:
// nanoseconds for one picture, and a copy of the same size with no alpha.
pointer_blend_measure :: proc "contextless" () {
	ROUNDS :: 2000
	chosen := pointer_pictures.choose(pointer_theme, pointer_form, .Arrow, pointer_size_asked(), 0)
	picture := graphics.Canvas{pixels = raw_data(chosen.pixels), width = int(chosen.picture.width), height = int(chosen.picture.height), stride = int(chosen.picture.width)}
	start := system.nanoseconds()
	for round in 0 ..< ROUNDS {
		graphics.blend_premultiplied_alpha(frame, 100 + round % 7, 100, picture)
	}
	blend := (system.nanoseconds() - start) / ROUNDS
	opaque := graphics.Canvas{pixels = background.pixels, width = picture.width, height = picture.height, stride = background.stride}
	start = system.nanoseconds()
	for round in 0 ..< ROUNDS {
		graphics.copy(frame, 100 + round % 7, 100, opaque)
	}
	copied := (system.nanoseconds() - start) / ROUNDS
	transparent := 0
	for pixel in chosen.pixels {
		if pixel >> 24 == 0 {
			transparent += 1
		}
	}
	system.log_fact(.Info, Arrow_Blend_Measured{width = u64(picture.width), height = u64(picture.height), transparent_pixels = u64(transparent), pixels = u64(len(chosen.pixels)), blend_time = value_kinds.Time_In_Nanoseconds(blend), copy_time = value_kinds.Time_In_Nanoseconds(copied)})
}

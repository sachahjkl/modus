// The boot display: how the machine started, as a picture. It is the model
// of the design rules (docs/DESIGN.md).
//
// It draws one record, Data. Each part of Data is a record of the kernel:
// the boot record (the stages and their times, the memory that the firmware
// gave, the firmware, the framebuffer), the state of the memory, the
// processors, the processes, and the modules of the boot image.
//
// Three parts of the system draw it. The boot program draws what it knows before the
// kernel exists. The root service draws it while it starts the first
// processes: if the start fails, the display stays, with the failure. The
// process `boot` draws it in a window at any time. Each one calls
// draw_screen with its whole canvas: the display takes the scale of that
// canvas (scale.odin), so one size gives one scale in each drawer.
//
// The layout is in logical pixels, a panel of WIDTH x HEIGHT; each place
// becomes a screen place at the one border of the drawing procedures of
// this file (src/md/features/boot_display_scale.md). Each text is Spleen,
// at the size of the scale, in each drawer (spleen_cells.odin).
//
// A record that is all zero is valid: its card shows that the fact is
// not known yet. This package uses no kernel operation: package collect
// fills Data.
//
// ```odin
// data: bootscreen.Data
// collect.data(&data, machine) // Fills it from the reports of the kernel.
// bootscreen.draw_screen(canvas, &data)
// ```
//
// See [boot display](term:boot-display).
package bootscreen

import info "modus:contract/boot_info"
import "modus:bootscreen/image_card"
import "modus:graphics"
import "modus:interface"
import "modus:mark"
import op "modus:contract/operation"
import "base:intrinsics"

WIDTH :: 976 // The logical size of the panel: the size of the display at scale 1.
HEIGHT :: 708 // Logical pixels: a window of this height fits the window bound of 768 lines under the bar and its title.
PROCESSOR_ROWS :: 16 // The processors that the card of the processors shows.
PROCESS_ROWS :: 12 // The processes that the card of the processes shows.

// The state of the start, which the title of the display says.
State :: enum {
	Running, // The machine starts.
	Ready, // The desktop runs.
	Failed, // The start stopped: `Data.message` says why.
}

// The steps of the start, in their order. The process that draws says
// which step the machine does now: the steps before it are done.
Step :: enum {
	Firmware, // The firmware runs the boot program.
	Boot_Image, // The boot program copies the boot image and checks its system description, the kernel and each file of it.
	Kernel_Module, // The boot program loads the kernel module.
	Memory_Map, // The boot program reads the memory map.
	Kernel, // The boot program ends the firmware and jumps.
	Processors, // The kernel starts the other processors.
	Root, // The root service starts.
	Input, // The root service starts the input service.
	Compositor, // The root service starts the compositor.
	Desktop, // The root service starts the desktop.
}

// One row of the card of the processes.
Process :: struct {
	slot:   u64, // The process slot.
	report: op.Process_Report, // Its report.
}

// What the display shows: the reports of the kernel, the boot image and the
// state of the start. The zero value is valid.
Data :: struct {
	boot:            op.Boot_Report, // The boot record.
	machine:         op.System_Report, // The memory and the counts.
	processors:      [PROCESSOR_ROWS]op.Processor_Report, // The first processors.
	processes:        [PROCESS_ROWS]Process, // By slot.
	process_count:   int, // The entries of `processes` in use.
	process_total:   int, // All the processes: processes has the first ones.
	image:           []u8, // The boot image.
	processor_name:  [48]u8, // The name that the processor gives of itself.
	message:         string, // What the machine does now.
	failed_name:     string, // The file that failed the check of its hash: the card of the boot image names it.
	state:           State,
	step:            Step, // The step that the machine does now.
	red_first:       bool, // The pixels of the canvas have red in the low byte.
}

LINE :: graphics.LINE_HEIGHT // One line of text.
MARGIN :: graphics.GAP // The gap around the cards.
CELL :: graphics.CELL_WIDTH // The logical width of one character of the text.
LARGE_CELL :: 2 * CELL // The logical width of one large digit.

// The state of the draw that runs: one draw at a time in each drawer.
// The order of the channels of the canvas: the boot program draws on a
// framebuffer that can have red in the low byte.
@(private)
red_first: bool
// The canvas of the panel, in screen pixels.
@(private)
panel: graphics.Canvas
// The scale of the panel, in eighths.
@(private)
scale_eighths: int = SCALE_ONE

// A part of the panel, in logical pixels from its top left: the whole
// panel, or the content of a card. A place inside an area is the place of
// the area plus the place in it, rounded once.
@(private)
Area :: struct {
	x, y, width, height: int,
}

@(private)
WHOLE :: Area{0, 0, WIDTH, HEIGHT}

// The kind of a box that a draw records for the host test.
Box_Kind :: enum u8 {
	Element, // A rectangle, a gradient or the mark.
	Text, // The cells of a text.
}

// One box that a draw drew, in screen pixels from the top left of the
// panel, with the area that held it.
Drawn_Box :: struct {
	kind:                     Box_Kind,
	left, top, right, bottom: int,
	area_left, area_top:      int,
	area_right, area_bottom:  int,
}

// The capacity of the record: the header and the grid of points are many
// small rectangles.
DRAWN_BOX_CAPACITY :: 1 << 15

// The boxes of one draw, for the host test that checks the layout at each
// scale. lost counts the boxes past the capacity.
Drawn_Boxes :: struct {
	boxes: [DRAWN_BOX_CAPACITY]Drawn_Box,
	count: int,
	lost:  int,
}

// The record of the boxes of the next draws: nil in each drawer, so a draw
// records nothing. The host test sets it.
drawn_boxes: ^Drawn_Boxes

// to_screen gives the screen place of a logical place of the panel.
@(private)
to_screen :: #force_inline proc "contextless" (logical: int) -> int {
	return scaled(logical, scale_eighths)
}

// box_record notes a box of the draw for the host test.
@(private)
box_record :: proc "contextless" (kind: Box_Kind, area: Area, left, top, right, bottom: int) {
	record := drawn_boxes
	if record == nil {
		return
	}
	if record.count == len(record.boxes) {
		record.lost += 1
		return
	}
	record.boxes[record.count] = {
		kind        = kind,
		left        = left,
		top         = top,
		right       = right,
		bottom      = bottom,
		area_left   = to_screen(area.x),
		area_top    = to_screen(area.y),
		area_right  = to_screen(area.x + area.width),
		area_bottom = to_screen(area.y + area.height),
	}
	record.count += 1
}

// view_cut gives the part of a canvas in a rectangle, cut to the canvas:
// graphics.view needs a rectangle inside it.
@(private)
view_cut :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int) -> graphics.Canvas {
	left, top := clamp(x, 0, canvas.width), clamp(y, 0, canvas.height)
	right, bottom := clamp(x + width, left, canvas.width), clamp(y + height, top, canvas.height)
	return graphics.view(canvas, left, top, right - left, bottom - top)
}

// area_canvas gives the canvas of an area, and the screen place of its top
// left in the panel.
@(private)
area_canvas :: proc "contextless" (area: Area) -> (canvas: graphics.Canvas, left, top: int) {
	left, top = to_screen(area.x), to_screen(area.y)
	canvas = view_cut(panel, left, top, to_screen(area.x + area.width) - left, to_screen(area.y + area.height) - top)
	return
}

// tone gives a color in the order of the channels of the canvas.
@(private)
tone :: #force_inline proc "contextless" (color: graphics.Color) -> graphics.Color {
	return red_first ? color >> 16 & 0xFF | color & 0xFF00 | color << 16 & 0xFF0000 : color
}

// fill paints a rectangle of an area in a color, in the order of the canvas.
@(private)
fill :: proc "contextless" (area: Area, x, y, width, height: int, color: graphics.Color) {
	canvas, left, top := area_canvas(area)
	x0, y0 := to_screen(area.x + x), to_screen(area.y + y)
	x1, y1 := to_screen(area.x + x + width), to_screen(area.y + y + height)
	box_record(.Element, area, x0, y0, x1, y1)
	graphics.fill(canvas, x0 - left, y0 - top, x1 - x0, y1 - y0, tone(color))
}

// block draws a rectangle of an area. Its color goes from top_color, on
// its first screen line, to bottom_color, on its last.
@(private)
block :: proc "contextless" (area: Area, x, y, width, height: int, top_color, bottom_color: graphics.Color) {
	canvas, left, top := area_canvas(area)
	x0, y0 := to_screen(area.x + x), to_screen(area.y + y)
	x1, y1 := to_screen(area.x + x + width), to_screen(area.y + y + height)
	box_record(.Element, area, x0, y0, x1, y1)
	rows := y1 - y0
	for row in 0 ..< rows {
		graphics.fill(canvas, x0 - left, y0 - top + row, x1 - x0, 1, tone(graphics.mix(top_color, bottom_color, u32(row * 255 / max(rows - 1, 1)))))
	}
}

// A short text that the display builds from parts.
Text :: struct {
	bytes: [120]u8, // The text; the bytes that do not fit are dropped.
	count: int, // The bytes in use.
}

// put adds a text.
put :: proc "contextless" (text: ^Text, part: string) {
	for index in 0 ..< len(part) {
		if text.count < len(text.bytes) {
			text.bytes[text.count] = part[index]
			text.count += 1
		}
	}
}

// put_name adds the bytes of a name before its first zero byte.
put_name :: proc "contextless" (text: ^Text, name: []u8) {
	for character in name {
		if character == 0 {
			break
		}
		put(text, string([]u8{character}))
	}
}

// put_number adds a number in decimal, with at least minimum_digits digits.
put_number :: proc "contextless" (text: ^Text, value: u64, minimum_digits := 1) {
	digits: [20]u8
	count := 0
	for rest := value; rest != 0 || count < minimum_digits; rest /= 10 {
		digits[count] = '0' + u8(rest % 10)
		count += 1
	}
	for count > 0 {
		count -= 1
		put(text, string(digits[count:][:1]))
	}
}

// put_hex adds the low `digits` hexadecimal digits of a number.
put_hex :: proc "contextless" (text: ^Text, value: u64, digits: int) {
	characters := "0123456789abcdef"
	for index := digits - 1; index >= 0; index -= 1 {
		put(text, characters[value >> (uint(index) * 4) & 15:][:1])
	}
}

// put_duration adds a time of microseconds with its unit.
put_duration :: proc "contextless" (text: ^Text, microseconds: u64) {
	switch {
	case microseconds < 1000:
		put_number(text, microseconds)
		put(text, " us")
	case microseconds < 1_000_000:
		put_number(text, microseconds / 1000)
		put(text, ".")
		put_number(text, microseconds % 1000 / 100)
		put(text, " ms")
	case:
		put_number(text, microseconds / 1_000_000)
		put(text, ".")
		put_number(text, microseconds % 1_000_000 / 10_000, 2)
		put(text, " s")
	}
}

// put_size adds a size of bytes with its unit.
put_size :: proc "contextless" (text: ^Text, bytes: u64) {
	switch {
	case bytes < 1 << 10:
		put_number(text, bytes)
		put(text, " B")
	case bytes < 1 << 20:
		put_number(text, bytes >> 10)
		put(text, ".")
		put_number(text, (bytes & (1 << 10 - 1)) * 10 >> 10)
		put(text, " KiB")
	case:
		put_number(text, bytes >> 20)
		put(text, ".")
		put_number(text, (bytes & (1 << 20 - 1)) * 10 >> 20)
		put(text, " MiB")
	}
}

// show draws a text and empties it. It gives the logical x after the text.
@(private)
show :: proc "contextless" (area: Area, x, y: int, text: ^Text, color: graphics.Color) -> int {
	after := write(area, x, y, string(text.bytes[:text.count]), color)
	text.count = 0
	return after
}

// write_in_cells draws a text of an area in cells of cell logical pixels,
// and gives the logical x after it.
@(private)
write_in_cells :: proc "contextless" (area: Area, x, y: int, characters: string, color: graphics.Color, cell: int) -> int {
	count := text_count(characters)
	if count == 0 {
		return x
	}
	canvas, left, top := area_canvas(area)
	x0, y0 := to_screen(area.x + x), to_screen(area.y + y)
	// A cell of 8 logical pixels is eighths screen pixels exactly: the cells
	// of a text are whole and the same at each place.
	cell_width := cell * scale_eighths / SCALE_ONE
	box_record(.Text, area, x0, y0, x0 + count * cell_width, y0 + 2 * cell_width)
	spleen_text_draw(canvas, x0 - left, y0 - top, characters, tone(color), cell_width)
	return x + count * cell
}

// text_count gives the cells of a text: one for each character of the
// UTF-8 text, and one for each invalid sequence.
@(private)
text_count :: proc "contextless" (characters: string) -> int {
	return graphics.text_width(characters) / graphics.CELL_WIDTH
}

// write draws a text in the font of the cells, in the order of the canvas.
// It gives the logical x after the text.
@(private)
write :: proc "contextless" (area: Area, x, y: int, characters: string, color: graphics.Color) -> int {
	return write_in_cells(area, x, y, characters, color, CELL)
}

// show_right draws a text that ends at x.
@(private)
show_right :: proc "contextless" (area: Area, x, y: int, text: ^Text, color: graphics.Color) {
	show(area, x - text.count * CELL, y, text, color)
}

// write_large draws characters in cells of twice the size of a cell: the
// large digits of the times. It gives the logical x after the last
// character.
@(private)
write_large :: proc "contextless" (area: Area, x, y: int, characters: string, color: graphics.Color) -> int {
	return write_in_cells(area, x, y, characters, color, LARGE_CELL)
}

CARD_MARGIN :: graphics.MARGIN // The margin inside a card.
CARD_TITLE :: graphics.TITLE // The height of the title of a card.

// write_name draws a name cut to room, in the cells of Spleen as each text
// of the display, and gives the logical x after it. The whole name is on
// the log or in another card: text_fit is the rule of such a name.
@(private)
write_name :: proc "contextless" (area: Area, x, y: int, name: string, room: int, color: graphics.Color) -> int {
	return write(area, x, y, interface.text_fit(nil, {}, name, room), color)
}

// card draws the frame of one part of the display, as the card of the
// interface package (the same card as in each window) at the scale: a
// border of 1 logical pixel in its accent, the surface, a bar of 4 x 16 and
// the title in the accent, the caption of its record in the dim color. It
// keeps reserved logical pixels free at the right of the title row, for
// the number that the display writes there, and gives the area of its
// content.
@(private)
card :: proc "contextless" (x, y, width, height: int, title, caption: string, accent: graphics.Color, reserved := 0) -> Area {
	block(WHOLE, x, y, width, height, graphics.shade(accent, 28), graphics.shade(accent, 14))
	block(WHOLE, x + 1, y + 1, width - 2, height - 2, graphics.DARK_CARD_TOP, graphics.DARK_CARD_BOTTOM)
	block(WHOLE, x + CARD_MARGIN, y + 12, 4, 16, graphics.shade(accent, 130), accent)
	title_left := x + CARD_MARGIN + 12
	right := x + width - CARD_MARGIN
	if reserved > 0 {
		right -= reserved + 16
	}
	after := write_name(WHOLE, title_left, y + 12, title, right - title_left, accent)
	write_name(WHOLE, after + 16, y + 12, caption, right - (after + 16), graphics.DARK_DIM)
	return {x + CARD_MARGIN, y + CARD_TITLE, width - 2 * CARD_MARGIN, height - CARD_TITLE - 8}
}

// fact draws "name value", and gives the count of the lines of the value.
// A value wider than the card is whole, on the lines that it needs (the
// rule of interface.text_wrap_line): the caller places the next fact under
// them. The value is empty after the call.
@(private)
fact :: proc "contextless" (area: Area, y: int, name: string, value: ^Text, color: graphics.Color = graphics.DARK_TEXT) -> (lines: int) {
	write_name(area, 0, y, name, FACT_VALUE - 8, graphics.DARK_DIM)
	if value.count == 0 {
		put(value, "not known yet")
		show(area, FACT_VALUE, y, value, graphics.DARK_DIM)
		return 1
	}
	rest := string(value.bytes[:value.count])
	for len(rest) > 0 {
		line: string
		line, rest = interface.text_wrap_line(nil, {}, rest, area.width - FACT_VALUE)
		write(area, FACT_VALUE, y + lines * LINE, line, color)
		lines += 1
	}
	value.count = 0
	return lines
}

FACT_VALUE :: 120 // The x of the value of a fact, in its card.

// processor_name reads the name that the processor gives of itself.
processor_name :: proc "contextless" () -> (name: [48]u8) {
	highest, _, _, _ := intrinsics.x86_cpuid(0x8000_0000, 0)
	if highest < 0x8000_0004 {
		return
	}
	for leaf in u32(0) ..< 3 {
		a, b, c, d := intrinsics.x86_cpuid(0x8000_0002 + leaf, 0)
		for word, index in ([4]u32{a, b, c, d}) {
			for byte in u32(0) ..< 4 {
				name[int(leaf) * 16 + index * 4 + int(byte)] = u8(word >> (byte * 8))
			}
		}
	}
	name[len(name) - 1] = 0
	// The name can start with spaces.
	first := 0
	for first < len(name) && name[first] == ' ' {
		first += 1
	}
	intrinsics.mem_copy(&name[0], &name[first], len(name) - first)
	return
}

// stage_color gives the color of a stage: the color of the party that
// does it (the firmware, the boot program, the kernel), in one of four
// shades, so that two stages that touch do not have one color.
@(private)
stage_color :: proc "contextless" (name: []u8, index: int) -> graphics.Color {
	shades := [4]u32{118, 92, 136, 76}
	switch name[0] {
	case 'f':
		return graphics.DARK_FIRMWARE
	case 'b':
		return graphics.shade(graphics.DARK_BOOT_PROGRAM, shades[index & 3])
	}
	return graphics.shade(graphics.DARK_KERNEL, shades[index & 3])
}

// The words of each step, for the message of the display.
@(private, rodata)
step_names := [Step]string {
	.Firmware      = "the firmware",
	.Boot_Image    = "the boot image",
	.Kernel_Module = "the kernel module",
	.Memory_Map    = "the memory map",
	.Kernel        = "the kernel",
	.Processors    = "the processors",
	.Root          = "the root service",
	.Input         = "the input service",
	.Compositor    = "the compositor",
	.Desktop       = "the desktop",
}

// The card of the boot image (docs/DESIGN.md, section 12): the size
// strip, the rows of names by kind, the line of the check and the line of
// the trust. Package image_card computes the places, in logical pixels.
IMAGE_STRIP_HEIGHT :: 12
IMAGE_ROWS_Y :: 20 // The y of the first row of names, in the card.
IMAGE_ROW_PITCH :: 18 // The distance between two rows of names.
IMAGE_LABEL_ROOM :: 80 // The name of a kind: "resources" takes 9 cells.
IMAGE_COUNT_RIGHT :: 128 // The count of a kind ends here: 4 digits after the name.
IMAGE_BYTES_RIGHT :: 208 // The bytes of a kind end here.
IMAGE_NAMES_X :: 216 // The tiles of the names start here.
IMAGE_CHECK_Y :: 96 // The y of the line of the check.
IMAGE_TRUST_Y :: 114 // The y of the line of the trust.

// The layout is large for a stack: one copy serves each draw of the process.
@(private)
image_layout: image_card.Layout

// The name of each kind of file of the boot image.
@(private, rodata)
image_kind_names := [image_card.File_Kind]string {
	.Entry    = "entry",
	.No_Entry = "no entry",
	.Resource = "resources",
}

// The color of each kind of file of the boot image.
@(private, rodata)
image_kind_colors := [image_card.File_Kind]graphics.Color {
	.Entry    = graphics.DARK_PROCESS,
	.No_Entry = graphics.DARK_NO_ENTRY,
	.Resource = graphics.DARK_RESOURCE,
}

// draw_panel draws the display on the canvas of its panel, at a scale of
// eighths: the canvas has the panel at that scale, cut by the screen when
// the screen is smaller.
@(private)
draw_panel :: proc "contextless" (canvas: graphics.Canvas, data: ^Data, eighths: int) {
	red_first = data.red_first
	panel = canvas
	scale_eighths = eighths
	text: Text
	boot := &data.boot
	HEADER :: 72
	fill(WHOLE, 0, HEADER, WIDTH, HEIGHT - HEADER, graphics.DARK_BACKGROUND)
	// A grid of points under the cards.
	for y := HEADER + 12; y < HEIGHT; y += 24 {
		for x := 12; x < WIDTH; x += 24 {
			fill(WHOLE, x, y, 2, 2, graphics.DARK_POINT)
		}
	}

	// The head: the name of the system, what the machine does now, the time.
	for column in 0 ..< WIDTH {
		level := u32(column * 255 / WIDTH)
		top := graphics.mix(0x24509A, 0x0C1830, level)
		for row := 0; row < HEADER; row += 8 {
			fill(WHOLE, column, row, 1, 8, graphics.mix(top, graphics.shade(top, 62), u32(row * 255 / HEADER)))
		}
	}
	// The mark of the system where the name of the system was: the heron
	// in a box of 48 by 48 (cells of 2 pixels at scale 1, the height of the
	// large text that was there), and the name of the mark (cells of 3
	// pixels at scale 1) at the right of the box, its bottom on the bottom
	// of the heron. A cell of the mark is whole pixels, so each takes the
	// largest whole cell inside its box at the scale. Both end before the
	// path of the steps.
	{
		MARK_LEFT :: 20
		MARK_TOP :: 12
		MARK_SIDE :: 48
		NAME_GAP :: 12
		heron_cell := max(2 * scale_eighths / SCALE_ONE, 1)
		name_cell := max(3 * scale_eighths / SCALE_ONE, 1)
		channel_order := mark.Channel_Order.Red_In_Low_Byte if red_first else mark.Channel_Order.Red_In_High_Byte
		box_left, box_top := to_screen(MARK_LEFT), to_screen(MARK_TOP)
		box_side := to_screen(MARK_TOP + MARK_SIDE) - box_top
		heron_side := mark.heron_size(heron_cell)
		heron_left := box_left + (box_side - heron_side) / 2
		heron_top := box_top + (box_side - heron_side) / 2
		// A cell of more than one pixel: the smooth variant.
		mark.mark_draw(panel, heron_left, heron_top, heron_cell, .Smooth, false, channel_order)
		box_record(.Element, WHOLE, heron_left, heron_top, heron_left + heron_side, heron_top + heron_side)
		name_width, name_height := mark.name_size(name_cell)
		name_left := to_screen(MARK_LEFT + MARK_SIDE + NAME_GAP)
		name_top := heron_top + heron_side - name_height
		mark.name_draw(panel, name_left, name_top, name_cell, false, channel_order)
		box_record(.Element, WHOLE, name_left, name_top, name_left + name_width, name_top + name_height)
	}
	state_color := graphics.Color(graphics.DARK_BOOT_PROGRAM)
	switch data.state {
	case .Running:
	case .Ready:
		state_color = graphics.DARK_PROCESS
	case .Failed:
		state_color = graphics.DARK_FAILED
	}
	// The time since the machine started, at the right of the head: the
	// message of the line of the steps ends before its words.
	SINCE_WORDS :: "since the machine started"
	SINCE_RIGHT :: WIDTH - 20
	since_left := SINCE_RIGHT - len(SINCE_WORDS) * CELL
	// The steps of the start as a path: a point for each step. A step that
	// is done is full, the step of now has a ring, a step to come is empty.
	message_fits := true
	{
		PATH_X :: 208
		PATH_Y :: 26
		PATH_STEP :: 52
		now := data.state == .Ready ? len(Step) : int(data.step)
		for step in 0 ..< len(Step) {
			x := PATH_X + step * PATH_STEP
			if step != 0 {
				fill(WHOLE, x - PATH_STEP + 8, PATH_Y - 1, PATH_STEP - 16, 2, step <= now ? graphics.shade(graphics.DARK_PROCESS, 80) : 0x33507C)
			}
			switch {
			case step < now:
				block(WHOLE, x - 5, PATH_Y - 5, 10, 10, graphics.shade(graphics.DARK_PROCESS, 130), graphics.DARK_PROCESS)
			case step == now:
				block(WHOLE, x - 8, PATH_Y - 8, 16, 16, graphics.shade(state_color, 140), state_color)
				block(WHOLE, x - 5, PATH_Y - 5, 10, 10, 0x10203C, 0x10203C)
				block(WHOLE, x - 2, PATH_Y - 2, 4, 4, graphics.shade(state_color, 140), state_color)
			case:
				block(WHOLE, x - 5, PATH_Y - 5, 10, 10, 0x33507C, 0x33507C)
				block(WHOLE, x - 3, PATH_Y - 3, 6, 6, 0x162C54, 0x162C54)
			}
		}
		put_number(&text, u64(min(now + 1, len(Step))))
		put(&text, "/")
		put_number(&text, len(Step))
		after_count := show(WHOLE, PATH_X - 8, 44, &text, 0x9CB8E0)
		message_after := write(WHOLE, after_count + 12, 44, data.message, graphics.shade(state_color, 135))
		message_fits = message_after + 12 <= since_left
	}
	if boot.time != 0 {
		put_duration(&text, boot.time)
		write_large(WHOLE, SINCE_RIGHT - text.count * LARGE_CELL, 8, string(text.bytes[:text.count]), graphics.COLOR_WHITE)
		text.count = 0
		// A long message takes the line: the words go, the large time stays.
		if message_fits {
			put(&text, SINCE_WORDS)
			show_right(WHOLE, SINCE_RIGHT, 46, &text, 0x9CB8E0)
		}
	}
	// A line of the color of the state, that fades to the right.
	for column := 0; column < WIDTH; column += 4 {
		fill(WHOLE, column, HEADER, 4, 2, graphics.mix(state_color, graphics.DARK_BACKGROUND, u32(column * 255 / WIDTH)))
	}

	// The stages, on one line of time. The line starts with the boot
	// program: the firmware before it takes most of the time.
	{
		origin := boot.stage_count > 1 ? boot.stages[1].start : 0
		last := origin
		for stage in boot.stages[:boot.stage_count] {
			last = max(last, stage.start + stage.duration)
		}
		// The processes of the start: the ones that started in the second
		// after the kernel.
		kernel_end := last
		for process in data.processes[:data.process_count] {
			if process.report.start_time <= kernel_end + 1_000_000 {
				last = max(last, process.report.start_time)
			}
		}
		span := max(last - origin, 1)
		place :: proc "contextless" (time, origin, span: u64, width: int) -> int {
			return time <= origin ? 0 : int(min(time - origin, span) * u64(width) / span)
		}
		// The time from the boot program to the last process, in large
		// digits in the title row of the card: the card keeps their room.
		span_text: Text
		if boot.stage_count != 0 {
			put_duration(&span_text, span)
		}
		// 236: the six rows of names end at the bottom of its content; the
		// card of the boot image takes the rest for the line of the trust.
		area := card(MARGIN, 84, WIDTH - 2 * MARGIN, 236, "THE LINE OF TIME", "Boot_Report.stages, Process_Report.start_time: the cycle counter", graphics.DARK_KERNEL, span_text.count * LARGE_CELL)
		if span_text.count != 0 {
			write_large(WHOLE, WIDTH - MARGIN - CARD_MARGIN - span_text.count * LARGE_CELL, 84 + 6, string(span_text.bytes[:span_text.count]), graphics.DARK_TEXT)
		}

		// The tube: the firmware as a short part with lines, then the line of time.
		TUBE_Y :: 14
		TUBE_HEIGHT :: 40
		FIRMWARE_WIDTH :: 72
		track_x := FIRMWARE_WIDTH + 8
		track_width := area.width - track_x
		inner := track_width - 8
		block(area, 0, TUBE_Y, FIRMWARE_WIDTH, TUBE_HEIGHT, graphics.shade(graphics.DARK_FIRMWARE, 46), graphics.shade(graphics.DARK_FIRMWARE, 30))
		for line := 8; line < FIRMWARE_WIDTH - 8; line += 8 {
			for step in 0 ..< TUBE_HEIGHT - 16 {
				fill(area, line + step / 4, TUBE_Y + 8 + step, 2, 1, graphics.shade(graphics.DARK_FIRMWARE, 78))
			}
		}
		block(area, track_x, TUBE_Y, track_width, TUBE_HEIGHT, graphics.DARK_TRACK, graphics.shade(graphics.DARK_TRACK, 80))
		if boot.stage_count == 0 {
			write(area, track_x + 16, TUBE_Y + 12, "The kernel does not run yet: it measures the stages.", graphics.DARK_DIM)
			// Until the stages have a time, the steps of the start, as a list.
			for name, step in step_names {
				x := int(step) / 5 * (area.width / 2)
				y := 92 + int(step) % 5 * LINE
				switch {
				case step < data.step:
					block(area, x, y + 3, 10, 10, graphics.shade(graphics.DARK_PROCESS, 130), graphics.DARK_PROCESS)
					write(area, x + 18, y, name, graphics.DARK_TEXT)
					write(area, x + 200, y, "done", graphics.DARK_PROCESS)
				case step == data.step:
					block(area, x, y + 3, 10, 10, graphics.shade(state_color, 140), state_color)
					block(area, x + 3, y + 6, 4, 4, graphics.DARK_CARD_BOTTOM, graphics.DARK_CARD_BOTTOM)
					write(area, x + 18, y, name, graphics.shade(state_color, 135))
					write(area, x + 200, y, data.state == .Failed ? "failed" : "now", graphics.shade(state_color, 135))
				case:
					block(area, x, y + 3, 10, 10, graphics.DARK_TRACK, graphics.DARK_TRACK)
					write(area, x + 18, y, name, graphics.DARK_DIM)
				}
			}
		}
		for &stage, index in boot.stages[:boot.stage_count] {
			if index == 0 {
				continue
			}
			color := stage_color(stage.name[:], index)
			left := place(stage.start, origin, span, inner)
			right := place(stage.start + stage.duration, origin, span, inner)
			width := max(right - left - 1, 2)
			block(area, track_x + 4 + left, TUBE_Y + 4, width, TUBE_HEIGHT - 8, graphics.shade(color, 125), graphics.shade(color, 78))
			put_duration(&text, stage.duration)
			if text.count * CELL + 8 <= width {
				show(area, track_x + 4 + left + (width - text.count * CELL) / 2, TUBE_Y + 12, &text, graphics.DARK_BACKGROUND)
			}
			text.count = 0
		}
		// Each process of the start: a mark on the line of time, at its creation.
		marks := 0
		for &process in data.processes[:data.process_count] {
			if process.report.start_time > kernel_end + 1_000_000 {
				continue
			}
			x := track_x + 4 + min(place(process.report.start_time, origin, span, inner), inner - 2)
			color := graphics.shade(graphics.DARK_PROCESS, u32(130 - 14 * (marks & 3)))
			fill(area, x, TUBE_Y - 4, 2, TUBE_HEIGHT + 8, color)
			block(area, x - 3, TUBE_Y - 12, 8, 8, color, color)
			marks += 1
		}
		// The scale of time, under the tube.
		if boot.stage_count != 0 {
			steps := [?]u64{100, 200, 500, 1000, 2000, 5000, 10_000, 20_000, 50_000, 100_000, 200_000, 500_000, 1_000_000, 2_000_000, 5_000_000}
			step := steps[len(steps) - 1]
			for candidate in steps {
				if span / candidate <= 9 {
					step = candidate
					break
				}
			}
			for time := u64(0); time <= span; time += step {
				x := track_x + 4 + int(time * u64(inner) / span)
				fill(area, x, TUBE_Y + TUBE_HEIGHT + 4, 1, 5, graphics.DARK_DIM)
				if time == 0 {
					write(area, x - 3, TUBE_Y + TUBE_HEIGHT + 10, "0", graphics.DARK_DIM)
				} else {
					put_duration(&text, time)
					if x + text.count * CELL / 2 <= area.width {
						show(area, x - text.count * CELL / 2, TUBE_Y + TUBE_HEIGHT + 10, &text, graphics.DARK_DIM)
					}
					text.count = 0
				}
			}
			write(area, 0, TUBE_Y + TUBE_HEIGHT + 10, "firmware", graphics.DARK_DIM)
		}

		// The names: each stage and each process of the start, with its
		// color and its time, in two columns.
		NAMES_Y :: 92
		NAME_ROWS :: 6
		column_width := area.width / 2
		entry := 0
		for &stage, index in boot.stages[:boot.stage_count] {
			if entry >= 2 * NAME_ROWS {
				break
			}
			x := entry / NAME_ROWS * column_width
			y := NAMES_Y + entry % NAME_ROWS * LINE
			color := stage_color(stage.name[:], index)
			block(area, x, y + 3, 10, 10, graphics.shade(color, 125), graphics.shade(color, 78))
			put_name(&text, stage.name[:])
			show(area, x + 18, y, &text, graphics.DARK_TEXT)
			put_duration(&text, stage.duration)
			show_right(area, x + column_width - 24, y, &text, color)
			entry += 1
		}
		marks = 0
		for &process in data.processes[:data.process_count] {
			if process.report.start_time > kernel_end + 1_000_000 {
				continue
			}
			color := graphics.shade(graphics.DARK_PROCESS, u32(130 - 14 * (marks & 3)))
			marks += 1
			if entry >= 2 * NAME_ROWS {
				continue
			}
			x := entry / NAME_ROWS * column_width
			y := NAMES_Y + entry % NAME_ROWS * LINE
			block(area, x + 1, y + 4, 8, 8, color, color)
			put(&text, "process ")
			put_name(&text, process.report.name[:])
			put(&text, ": created")
			show(area, x + 18, y, &text, graphics.DARK_TEXT)
			put(&text, "at ")
			put_duration(&text, process.report.start_time - min(origin, process.report.start_time))
			show_right(area, x + column_width - 24, y, &text, color)
			entry += 1
		}
	}

	// The memory.
	LEFT_WIDTH :: 568
	MIDDLE_Y :: 328
	MIDDLE_HEIGHT :: 186 // The card of the machine: the squares of the processors, then seven lines of facts.
	{
		area := card(MARGIN, MIDDLE_Y, LEFT_WIDTH, MIDDLE_HEIGHT, "MEMORY", "Boot_Report.ranges, System_Report", graphics.DARK_MEMORY)
		top: u64
		totals: [3]u64
		for range in boot.ranges[:boot.range_count] {
			if range.kind != u64(info.Memory_Kind.Reserved) {
				top = max(top, range.start + range.page_count * info.PAGE_SIZE)
			}
		}
		colors := [3]graphics.Color{graphics.DARK_NOT_USABLE, graphics.DARK_MEMORY, graphics.DARK_BOOT_PROGRAM}
		BAND :: 26
		block(area, 0, 0, area.width, BAND, graphics.DARK_TRACK, graphics.shade(graphics.DARK_TRACK, 80))
		inner := area.width - 8
		for range in boot.ranges[:boot.range_count] {
			if range.start >= top || range.kind > 2 {
				continue
			}
			totals[range.kind] += range.page_count * info.PAGE_SIZE
			left := int(range.start * u64(inner) / top)
			right := int(min(range.start + range.page_count * info.PAGE_SIZE, top) * u64(inner) / top)
			color := colors[range.kind]
			block(area, 4 + left, 4, max(right - left, 1), BAND - 8, graphics.shade(color, 120), graphics.shade(color, 78))
		}
		write(area, 0, BAND + 4, "address 0", graphics.DARK_DIM)
		put_hex(&text, top, 12)
		show_right(area, area.width, BAND + 4, &text, graphics.DARK_DIM)
		names := [3]string{"not usable", "free", "boot program"}
		x := 0
		if boot.range_count == 0 {
			write(area, 0, BAND + 28, "ranges: not known yet", graphics.DARK_DIM)
		}
		for kind in ([3]int{1, 2, 0}) {
			if boot.range_count == 0 {
				break
			}
			block(area, x, BAND + 28 + 3, 10, 10, graphics.shade(colors[kind], 120), graphics.shade(colors[kind], 78))
			put(&text, names[kind])
			put(&text, " ")
			put_size(&text, totals[kind])
			x = show(area, x + 16, BAND + 28, &text, graphics.DARK_TEXT) + 20
		}
		// Now: the page frames of the kernel.
		y := BAND + 52
		block(area, 0, y, area.width, 8, graphics.DARK_TRACK, graphics.DARK_TRACK)
		if data.machine.page_count != 0 {
			used := data.machine.page_count - data.machine.free_pages
			block(area, 0, y, max(int(used * u64(area.width) / data.machine.page_count), 8), 8, graphics.shade(graphics.DARK_KERNEL, 125), graphics.DARK_KERNEL)
			put(&text, "now: ")
			put_size(&text, used * info.PAGE_SIZE)
			put(&text, " of ")
			put_size(&text, data.machine.page_count * info.PAGE_SIZE)
			put(&text, " used, ")
			put_number(&text, data.machine.region_count)
			put(&text, " objects, budgets ")
			// As a size: the count of pages of a machine of 1 GiB passes the card.
			put_size(&text, data.machine.budget_pages * info.PAGE_SIZE)
			show(area, 0, y + 12, &text, graphics.DARK_TEXT)
		} else {
			write(area, 0, y + 12, "now: not known yet", graphics.DARK_DIM)
		}
		if boot.range_count != 0 {
			put_number(&text, boot.firmware_ranges)
			put(&text, " firmware ranges, ")
			put_number(&text, boot.range_count)
			put(&text, " joined")
			if boot.direct_map_size != 0 {
				put(&text, ", direct map ")
				put_size(&text, boot.direct_map_size)
			}
			show(area, 0, y + 12 + LINE, &text, graphics.DARK_DIM)
		}
	}

	// The machine.
	RIGHT_X :: 2 * MARGIN + LEFT_WIDTH
	{
		area := card(RIGHT_X, MIDDLE_Y, WIDTH - RIGHT_X - MARGIN, MIDDLE_HEIGHT, "MACHINE", "Boot_Report, cpuid", graphics.DARK_MACHINE)
		// One square for each processor that runs, with its number.
		write(area, 0, 2, "processors", graphics.DARK_DIM)
		if data.machine.processors == 0 {
			write(area, FACT_VALUE, 2, "not known yet", graphics.DARK_DIM)
		}
		SQUARES :: 10
		for processor, index in data.processors[:min(data.machine.processors, PROCESSOR_ROWS)] {
			x := FACT_VALUE + index * 23
			if index >= SQUARES {
				put(&text, "+")
				put_number(&text, data.machine.processors - SQUARES)
				show(area, x, 2, &text, graphics.DARK_MACHINE)
				break
			}
			block(area, x, 0, 20, 20, graphics.shade(graphics.DARK_MACHINE, 112), graphics.shade(graphics.DARK_MACHINE, 66))
			put_number(&text, processor.apic_id)
			show(area, x + 10 - text.count * CELL / 2, 2, &text, graphics.DARK_BACKGROUND)
		}
		// The six facts, each under the lines of the fact before it. The
		// name that a processor gives of itself has up to 47 characters,
		// and the box of a value 29: the card has the height of one fact
		// of two lines (MIDDLE_HEIGHT).
		fact_y := 22
		put_name(&text, boot.firmware_vendor[:])
		if text.count != 0 {
			put(&text, " ")
			put_number(&text, boot.firmware_revision >> 16)
			put(&text, ".")
			put_number(&text, boot.firmware_revision & 0xFFFF)
		}
		fact_y += LINE * fact(area, fact_y, "firmware", &text)
		if boot.framebuffer_width != 0 {
			put_number(&text, boot.framebuffer_width)
			put(&text, "x")
			put_number(&text, boot.framebuffer_height)
			put(&text, boot.framebuffer_format == u64(info.Pixel_Format.Red_Green_Blue_X) ? " red first" : " blue first")
		}
		fact_y += LINE * fact(area, fact_y, "framebuffer", &text)
		put_name(&text, data.processor_name[:])
		fact_y += LINE * fact(area, fact_y, "processor", &text)
		if boot.cycle_frequency != 0 {
			put_number(&text, boot.cycle_frequency / 1_000_000)
			put(&text, " MHz")
		}
		fact_y += LINE * fact(area, fact_y, "cycle counter", &text)
		if boot.timer_frequency != 0 {
			put_number(&text, boot.timer_frequency / 1_000_000)
			put(&text, " MHz, 1000 ticks/s")
		}
		fact_y += LINE * fact(area, fact_y, "timer", &text)
		if boot.kernel_size != 0 {
			put_size(&text, boot.kernel_size)
			put(&text, " (file ")
			put_size(&text, boot.kernel_file_size)
			put(&text, ")")
		}
		fact(area, fact_y, "kernel", &text)
	}

	// The files of the boot image: the size strip, then the kinds with
	// their largest files by name, the check and the trust.
	BOTTOM_Y :: MIDDLE_Y + MIDDLE_HEIGHT + MARGIN
	BOTTOM_HEIGHT :: HEIGHT - BOTTOM_Y - MARGIN
	{
		CONTENT_WIDTH :: LEFT_WIDTH - 2 * CARD_MARGIN
		layout := &image_layout
		image_card.layout_compute(layout, data.image, data.failed_name, CONTENT_WIDTH, CONTENT_WIDTH - IMAGE_NAMES_X)
		// The count of the files, at the right of the title row.
		count_text: Text
		if layout.valid {
			put_number(&count_text, u64(image_card.file_total(layout)))
			put(&count_text, " files, ")
			put_size(&count_text, u64(len(data.image)))
		}
		area := card(MARGIN, BOTTOM_Y, LEFT_WIDTH, BOTTOM_HEIGHT, "BOOT IMAGE", "Image_Entry, Boot_Report.trust", graphics.DARK_BOOT_PROGRAM, count_text.count * CELL)
		if layout.valid {
			image_card_draw(area, layout)
			show_right(WHOLE, MARGIN + LEFT_WIDTH - CARD_MARGIN, BOTTOM_Y + 13, &count_text, graphics.DARK_TEXT)
		} else {
			write(area, 0, 0, "not known yet", graphics.DARK_DIM)
		}
		check_line(area, IMAGE_CHECK_Y, data)
		trust_line(area, IMAGE_TRUST_Y, data)
	}

	// The processes.
	{
		total_text: Text
		if data.process_count != 0 {
			put_number(&total_text, u64(data.process_total))
		}
		area := card(RIGHT_X, BOTTOM_Y, WIDTH - RIGHT_X - MARGIN, BOTTOM_HEIGHT, "PROCESSES", "threads, pages, created", graphics.DARK_PROCESS, total_text.count * CELL)
		if data.process_count == 0 {
			write(area, 0, 0, "No process runs yet.", graphics.DARK_DIM)
		} else {
			show_right(WHOLE, WIDTH - MARGIN - CARD_MARGIN, BOTTOM_Y + 13, &total_text, graphics.DARK_TEXT)
		}
		most: u64 = 1
		for &process in data.processes[:data.process_count] {
			most = max(most, process.report.mapped_pages)
		}
		for &process, index in data.processes[:data.process_count] {
			if (index + 1) * LINE > area.height {
				break
			}
			y := index * LINE
			put_number(&text, process.slot)
			show_right(area, 16, y, &text, graphics.DARK_DIM)
			put_name(&text, process.report.name[:])
			text.count = min(text.count, 12)
			show(area, 28, y, &text, process.report.state == .Stopped ? graphics.DARK_FAILED : graphics.DARK_TEXT)
			put_number(&text, process.report.thread_count)
			show_right(area, 150, y, &text, graphics.DARK_TEXT)
			// The pages of the process, as a bar against the largest process.
			block(area, 162, y + 5, 56, 6, graphics.DARK_TRACK, graphics.DARK_TRACK)
			block(area, 162, y + 5, max(int(process.report.mapped_pages * 56 / most), 4), 6, graphics.shade(graphics.DARK_PROCESS, 120), graphics.shade(graphics.DARK_PROCESS, 80))
			put_number(&text, process.report.mapped_pages)
			show_right(area, 264, y, &text, graphics.DARK_TEXT)
			put_duration(&text, process.report.start_time)
			show_right(area, area.width, y, &text, graphics.DARK_PROCESS)
		}
	}
}

// put_hex_bytes adds two hexadecimal digits for each byte.
put_hex_bytes :: proc "contextless" (text: ^Text, bytes: []u8) {
	characters := "0123456789abcdef"
	for value in bytes {
		put(text, characters[value >> 4:][:1])
		put(text, characters[value & 15:][:1])
	}
}

// image_card_draw draws the size strip and the rows of names of the card
// of the boot image. Two parts that touch take two shades of their kind;
// the failed file is in the color of a failure, in the strip and on its
// tile.
@(private)
image_card_draw :: proc "contextless" (area: Area, layout: ^image_card.Layout) {
	text: Text
	block(area, 0, 0, area.width, IMAGE_STRIP_HEIGHT, graphics.DARK_TRACK, graphics.DARK_TRACK)
	for &file, index in layout.files[:layout.file_count] {
		if file.strip_width == 0 {
			continue
		}
		color := file.failed ? graphics.DARK_FAILED : image_kind_colors[file.kind]
		top := u32((index & 1) == 0 ? 120 : 96)
		block(area, file.strip_x, 0, file.strip_width, IMAGE_STRIP_HEIGHT, graphics.shade(color, top), graphics.shade(color, top - 42))
	}
	names_width := area.width - IMAGE_NAMES_X
	for kind in image_card.File_Kind {
		summary := &layout.kinds[kind]
		if summary.row_count == 0 {
			continue
		}
		color := image_kind_colors[kind]
		y := IMAGE_ROWS_Y + summary.first_row * IMAGE_ROW_PITCH
		block(area, 0, y + 3, 10, 10, graphics.shade(color, 125), graphics.shade(color, 78))
		write_name(area, 16, y, image_kind_names[kind], IMAGE_LABEL_ROOM, graphics.DARK_DIM)
		put_number(&text, u64(summary.count))
		show_right(area, IMAGE_COUNT_RIGHT, y, &text, graphics.DARK_TEXT)
		put_size(&text, summary.bytes)
		show_right(area, IMAGE_BYTES_RIGHT, y, &text, color)
		// The count of the files of the kind with no tile, after its tiles.
		hidden := summary.count - summary.named
		if hidden > 0 && summary.more_x + image_card.more_width(hidden) <= names_width {
			put(&text, "+")
			put_number(&text, u64(hidden))
			show(area, IMAGE_NAMES_X + summary.more_x, IMAGE_ROWS_Y + summary.more_row * IMAGE_ROW_PITCH, &text, graphics.DARK_DIM)
		}
	}
	for &tile in layout.tiles[:layout.tile_count] {
		file := &layout.files[tile.file]
		color := file.failed ? graphics.DARK_FAILED : image_kind_colors[file.kind]
		x := IMAGE_NAMES_X + tile.x
		y := IMAGE_ROWS_Y + tile.row * IMAGE_ROW_PITCH
		block(area, x, y, tile.width, LINE, graphics.shade(color, u32(file.failed ? 70 : 46)), graphics.shade(color, u32(file.failed ? 48 : 30)))
		write(area, x + image_card.TILE_PADDING, y, file.name, graphics.shade(color, 175))
	}
}

// check_line draws what the check of the hashes found: the count of the
// files that have the hash of the system description, or the whole name of
// the file that failed, in the color of a failure.
@(private)
check_line :: proc "contextless" (area: Area, y: int, data: ^Data) {
	text: Text
	x := write_name(area, 0, y, "check", FACT_VALUE - 8, graphics.DARK_DIM)
	x = max(x + 8, 56)
	trust := &data.boot.trust
	verifier, verifier_ok := info.verifier_of_word(trust.verifier)
	key_kind, key_kind_ok := info.signing_key_kind_of_word(trust.key_kind)
	file_check, file_check_ok := info.file_check_of_word(trust.file_check)
	switch {
	case len(data.failed_name) != 0:
		put(&text, "failed: ")
		put(&text, data.failed_name)
		show(area, x, y, &text, graphics.DARK_FAILED)
	case file_check_ok && file_check == .Root_Service_At_Load:
		// The root service checks each file at its first use: no count of
		// verified files is true at the start.
		write(area, x, y, "at first use", graphics.DARK_DIM)
	case verifier_ok && verifier != .None:
		put_number(&text, trust.entry_count)
		put(&text, " verified, the kernel included")
		show(area, x, y, &text, graphics.DARK_PROCESS)
	case data.state == .Failed && key_kind_ok && key_kind != .None:
		write(area, x, y, "no file verified", graphics.DARK_FAILED)
	case:
		write(area, x, y, "not verified yet", graphics.DARK_DIM)
	}
}

// trust_part draws one part of the line of the trust, with a comma after
// it unless it is the last, and gives the x of the next part.
@(private)
trust_part :: proc "contextless" (area: Area, x, y: int, text: ^Text, color: graphics.Color, last: bool) -> int {
	if !last {
		put(text, ",")
	}
	return show(area, x, y, text, color) + (last ? 0 : CELL)
}

// trust_line draws the trust record in one line (docs/TRUSTED_BOOT.md,
// "What a failure shows"): which key signed the system description, what
// verified it, and the measure, each in short words and in its own color.
// The long forms are on the log. A test key, a boot program that nothing
// verified and a refused measure are said in plain words: a reader must not
// take such a system for a trusted one.
@(private)
trust_line :: proc "contextless" (area: Area, y: int, data: ^Data) {
	trust := &data.boot.trust
	text: Text
	x := write_name(area, 0, y, "trust", FACT_VALUE - 8, graphics.DARK_DIM)
	x = max(x + 8, 56)
	color := graphics.Color(graphics.DARK_DIM)
	key_kind, key_kind_ok := info.signing_key_kind_of_word(trust.key_kind)
	if !key_kind_ok {
		put(&text, "unknown key kind")
		color = graphics.DARK_FAILED
	} else {
		switch key_kind {
		case .None:
			put(&text, "not signed")
		case .Test:
			put(&text, "TEST key")
			color = graphics.DARK_FAILED
		case .Person:
			put(&text, "key ")
			put_hex_bytes(&text, trust.public_key[:4])
			color = graphics.DARK_TEXT
		}
	}
	x = trust_part(area, x, y, &text, color, false)
	color = graphics.DARK_DIM
	verifier, verifier_ok := info.verifier_of_word(trust.verifier)
	if !verifier_ok {
		put(&text, "unknown verifier")
		color = graphics.DARK_FAILED
	} else {
		switch verifier {
		case .None:
			if data.state == .Failed && key_kind_ok && key_kind != .None {
				put(&text, "check failed")
				color = graphics.DARK_FAILED
			} else {
				put(&text, "not verified yet")
			}
		case .Boot_Program:
			put(&text, "boot program only")
			color = graphics.DARK_BOOT_PROGRAM
		case .Firmware_And_Boot_Program:
			put(&text, "Secure Boot")
			color = graphics.DARK_PROCESS
		}
	}
	x = trust_part(area, x, y, &text, color, false)
	color = graphics.DARK_DIM
	measure, measure_ok := info.measure_state_of_word(trust.measure)
	if !measure_ok {
		put(&text, "unknown measure state")
		color = graphics.DARK_FAILED
	} else {
		switch measure {
		case .None:
			put(&text, "not measured yet")
		case .Measured:
			put(&text, "PCR ")
			put_number(&text, trust.measure_register)
			put(&text, " ")
			put_hex_bytes(&text, trust.measure_value[:4])
			color = graphics.DARK_PROCESS
		case .No_Tpm:
			put(&text, "no TPM")
			color = graphics.DARK_BOOT_PROGRAM
		case .Refused:
			put(&text, "TPM refused the measure")
			color = graphics.DARK_FAILED
		case .Not_Read:
			put(&text, "PCR not read")
			color = graphics.DARK_FAILED
		}
	}
	_ = trust_part(area, x, y, &text, color, true)
}

// draw_screen draws the display on a whole canvas: a screen, or the
// canvas of a window. It takes the place and the scale of display_place,
// fills the canvas outside the panel, and draws the panel. A canvas of no
// pixels draws nothing.
draw_screen :: proc "contextless" (screen_canvas: graphics.Canvas, data: ^Data) {
	place, ok := display_place(screen_canvas.width, screen_canvas.height)
	if !ok {
		return
	}
	red_first = data.red_first
	background := tone(graphics.DARK_BACKGROUND)
	right, bottom := place.x + place.width, place.y + place.height
	graphics.fill(screen_canvas, 0, 0, screen_canvas.width, place.y, background)
	graphics.fill(screen_canvas, 0, bottom, screen_canvas.width, screen_canvas.height - bottom, background)
	graphics.fill(screen_canvas, 0, place.y, place.x, place.height, background)
	graphics.fill(screen_canvas, right, place.y, screen_canvas.width - right, place.height, background)
	draw_panel(view_cut(screen_canvas, place.x, place.y, place.width, place.height), data, place.eighths)
}

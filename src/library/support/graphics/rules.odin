// The design rules (docs/DESIGN.md) as one table of constants: the grid,
// the surfaces, the colors of the concepts and the colors of the desktop.
// The boot display, the compositor and the other modules read this one table.
package graphics

// The grid (DESIGN.md, section 6).
GRID :: 8 // A position and a size are multiples of GRID, or of GRID / 2 inside a form.
LINE_HEIGHT :: 16 // One line of text.
CARD_GAP :: 8 // The space between two cards.
CARD_MARGIN :: 16 // The margin inside a card.
CARD_TITLE :: 40 // The height of the title of a card.

POINT_SIZE :: 2 // The side of one point of the grid, in pixels.
POINT_STEP :: 24 // The distance between two points of the grid, in pixels.

// The two appearances of the desktop (src/md/features/appearance.md). The
// settings page says which one is in force; display gives it to
// appearance_use.
Appearance :: enum u8 {
	Dark  = 0, // The appearance of the boot display: light text on a dark background.
	Light = 1, // Dark text on the light background of the site.
}

// The color tokens: each named color of the rules, as one record. A drawer
// reads a token from `colors`, the record of the appearance in force, so a
// change of the appearance changes every color that a frame draws next.
Color_Tokens :: struct {
	// The surfaces (section 3).
	background:  Color, // Under all cards.
	point:       Color, // The grid of points on the background.
	card_top:    Color, // A card goes from this color at the top...
	card_bottom: Color, // ...to this color at the bottom.
	track:       Color, // The empty part of a bar, a band or a tube; a button.
	// The colors of the concepts (section 4). One color is one concept.
	firmware:     Color, // The firmware.
	boot_program: Color, // Also the state "starts".
	kernel:       Color, // The kernel.
	process:      Color, // Also the state "runs", and an expected answer.
	memory:       Color, // Memory, and the values that count it.
	machine:      Color, // The machine and its devices.
	no_entry:     Color, // A module with no entry export: other modules import it.
	resource:     Color, // A resource of the boot image: a file that is not a module.
	failed:       Color, // A failure: a check that did not pass, a process that stopped on a fault.
	not_usable:   Color, // Something that is there and cannot be used: reserved memory, a disabled control.
	text:         Color, // The text.
	dim:          Color, // A text of less weight: a unit, a caption.
	text_strong:  Color, // The text that an input types, and the outline of the focus: more than the text.
	// A state that asks for attention and is not a failure: a warning of
	// the log, a ring that is full. A yellow apart from the orange of the
	// boot program, so that "starts" and "take care" stay two colors.
	warning:      Color,
	link:         Color, // A name that leads to another page: a link of a page of `manual`.
	// The series colors: they tell apart the members of one series, several
	// things of one kind that no concept of the rules tells apart (the
	// threads of a process, the processes of the log, the records of a ring,
	// the protections of a page). A member takes the color of its number in
	// the series; a series of more members starts again at the first.
	series:       [SERIES_COLOR_COUNT]Color,
	// The desktop (section 9). The title bar of the window that has the
	// focus goes from title at the left to title_end at the right; the
	// title bar of another window from title_quiet to title_quiet_end.
	title:           Color, // The blue of the title bar.
	title_end:       Color, // shade(title, 36).
	// A chosen row of a list or a menu, with its text in white: the title
	// blue at 96 %, shade(title, 96). White has 4.67 to 1 on it; on the
	// title blue itself white has only 4.29, under the 4.5 that a text
	// needs. A matched character of a chosen row is the reverse: this blue
	// on white.
	chosen:          Color,
	title_quiet:     Color, // The left end of the title bar of a window that has not the focus.
	title_quiet_end: Color, // Its right end.
	// The concept "stop a process": the close button of a window, in a
	// rich red, so that the cross that closes a window is seen at once. A
	// deep red, not the coral of `failed`: to stop a process is not a
	// failure.
	stop_process:              Color, // On the window that has the focus.
	stop_process_pointer_over: Color, // The pointer is over the button.
	stop_process_quiet:        Color, // On a window that is not in front.
	stop_process_quiet_mark:   Color, // The x on the quiet button.
}

// The values of the dark appearance, as constants: the accents of the
// concepts for constant tables (the colors of code and of values, the
// mark), and what is always dark (the boot display, the mark). A window
// reads `colors`, never these: a window that named one would stay dark in
// the light appearance.
DARK_BACKGROUND :: 0x0B1018
DARK_POINT :: 0x18212D
DARK_CARD_TOP :: 0x17212E
DARK_CARD_BOTTOM :: 0x111822
DARK_TRACK :: 0x1C2633
DARK_FIRMWARE :: 0x8E7CC3
DARK_BOOT_PROGRAM :: 0xE0A040
DARK_KERNEL :: 0x4A9CF0
DARK_PROCESS :: 0x58D878
DARK_MEMORY :: 0x38C0B0
DARK_MACHINE :: 0xD070B0
DARK_NO_ENTRY :: 0xC8C058
DARK_RESOURCE :: 0x9AA8C8
DARK_FAILED :: 0xF06060
DARK_NOT_USABLE :: 0x4A5563
DARK_TEXT :: 0xDCE4EC
DARK_DIM :: 0x7C8A99
DARK_WARNING :: 0xF0C050
DARK_LINK :: 0x6CB4F0
SERIES_COLOR_COUNT :: 8
// The series colors of the dark appearance. A process that computes a
// picture in the color of a member reads these: a picture keeps its pixels
// in both appearances, and its legend takes the color of the same hue.
DARK_SERIES :: [SERIES_COLOR_COUNT]Color{0x4696FF, 0xFF963C, 0x5AE66E, 0xDC64FA, 0xE06890, 0x60D8D0, 0xD8D860, 0x9CC040}
DARK_TITLE :: 0x3F7CC4
DARK_TITLE_END :: 0x162C45
DARK_CHOSEN :: 0x3C76BB
DARK_TITLE_QUIET :: 0x2A3442
DARK_TITLE_QUIET_END :: 0x161D27
DARK_STOP_PROCESS :: 0xB82232
DARK_STOP_PROCESS_POINTER_OVER :: 0xE0343F
DARK_STOP_PROCESS_QUIET :: 0x4E2229
DARK_STOP_PROCESS_QUIET_MARK :: 0xC09098

COLOR_BLACK :: 0x000000 // Black: no surface of the design uses it as a background. Not a token: the pointer is black and white in both appearances.
COLOR_WHITE :: 0xFFFFFF // White: a text on the chosen blue, on the title blue and on the red of the close button, in both appearances.
// The darkest color of the rules: the background of the dark appearance and
// the text of the light one. A text on a fill of white has it in both.
COLOR_INK :: 0x0B1018

// The dark appearance: the boot display is its model.
DARK_COLOR_TOKENS :: Color_Tokens {
	background                = DARK_BACKGROUND,
	point                     = DARK_POINT,
	card_top                  = DARK_CARD_TOP,
	card_bottom               = DARK_CARD_BOTTOM,
	track                     = DARK_TRACK,
	firmware                  = DARK_FIRMWARE,
	boot_program              = DARK_BOOT_PROGRAM,
	kernel                    = DARK_KERNEL,
	process                   = DARK_PROCESS,
	memory                    = DARK_MEMORY,
	machine                   = DARK_MACHINE,
	no_entry                  = DARK_NO_ENTRY,
	resource                  = DARK_RESOURCE,
	failed                    = DARK_FAILED,
	not_usable                = DARK_NOT_USABLE,
	text                      = DARK_TEXT,
	dim                       = DARK_DIM,
	text_strong               = COLOR_WHITE,
	warning                   = DARK_WARNING,
	link                      = DARK_LINK,
	series                    = DARK_SERIES,
	title                     = DARK_TITLE,
	title_end                 = DARK_TITLE_END,
	chosen                    = DARK_CHOSEN,
	title_quiet               = DARK_TITLE_QUIET,
	title_quiet_end           = DARK_TITLE_QUIET_END,
	stop_process              = DARK_STOP_PROCESS,
	stop_process_pointer_over = DARK_STOP_PROCESS_POINTER_OVER,
	stop_process_quiet        = DARK_STOP_PROCESS_QUIET,
	stop_process_quiet_mark   = DARK_STOP_PROCESS_QUIET_MARK,
}

// The light appearance: the light form of the site. The background is the
// light background of the mark, a card goes from white to the middle of
// white and the background, the track is the background with 25 % of the
// dark dim color, the text is COLOR_INK and the dim text the dark dim color
// at 60 %. Each concept is its accent at the shade that keeps 4.5 to 1 on
// these surfaces: the shade of its value kind on the light page of the site
// (value_colors.odin). The blues and the reds of the desktop keep their
// values: white keeps its contrast on them.
LIGHT_COLOR_TOKENS :: Color_Tokens {
	background                = 0xF4F6F8,
	point                     = 0xDDE2E8,
	card_top                  = 0xFFFFFF,
	card_bottom               = 0xF9FAFB, // mix(white, background, 50 %).
	track                     = 0xD6DBE0, // mix(background, DARK_DIM, 25 %).
	firmware                  = 0x7566A1, // shade(DARK_FIRMWARE, 83).
	boot_program              = 0x906729, // shade(DARK_BOOT_PROGRAM, 65).
	kernel                    = 0x3571AF, // shade(DARK_KERNEL, 73).
	process                   = 0x327C45, // shade(DARK_PROCESS, 58).
	memory                    = 0x247C71, // shade(DARK_MEMORY, 65).
	machine                   = 0xA15688, // shade(DARK_MACHINE, 78).
	no_entry                  = 0x6D6930, // shade(DARK_NO_ENTRY, 55).
	resource                  = 0x5C6478, // shade(DARK_RESOURCE, 60).
	failed                    = 0xBA4A4A, // shade(DARK_FAILED, 78).
	not_usable                = 0xA9B2BD,
	text                      = COLOR_INK,
	dim                       = 0x4A525B, // shade(DARK_DIM, 60).
	text_strong               = COLOR_BLACK,
	warning                   = 0x886D2D, // shade(DARK_WARNING, 57).
	// shade(DARK_LINK, 55): a focused link is on the track, so the link
	// keeps 4.5 to 1 there too.
	link                      = 0x3B6283,
	// Each at the shade that keeps 4.5 to 1 on the light surfaces:
	// shade(DARK_SERIES[n], 76, 64, 56, 75, 79, 57, 54, 63).
	series                    = {0x3471C1, 0xA35F26, 0x32803D, 0xA44ABB, 0xB05171, 0x367A76, 0x747433, 0x617828},
	title                     = DARK_TITLE,
	title_end                 = DARK_TITLE_END,
	chosen                    = DARK_CHOSEN,
	title_quiet               = 0xE4E8ED,
	title_quiet_end           = 0xD3D9E0,
	stop_process              = DARK_STOP_PROCESS,
	stop_process_pointer_over = DARK_STOP_PROCESS_POINTER_OVER,
	stop_process_quiet        = 0xF2D5D9,
	stop_process_quiet_mark   = 0x8E3A47,
}

// The tokens of the appearance in force in this process. Each process, and
// each copy of the drawing module, has its own: display sets it from the
// settings page. A process with no settings page keeps the dark appearance.
colors := DARK_COLOR_TOKENS
// The appearance in force in this process: the one whose tokens `colors` holds.
appearance: Appearance

// color_tokens_of gives the tokens of one appearance.
color_tokens_of :: proc "contextless" (of: Appearance) -> Color_Tokens {
	switch of {
	case .Light:
		return LIGHT_COLOR_TOKENS
	case .Dark:
	}
	return DARK_COLOR_TOKENS
}

// appearance_use makes one appearance the appearance in force of this
// process: each draw after it reads its tokens. The caller draws its whole
// window again: a frame that kept a part of the picture before would show
// two appearances.
appearance_use :: proc "contextless" (of: Appearance) {
	appearance = of
	colors = color_tokens_of(of)
}

// mix gives a color between two colors: level 0 is the first, 255 the second.
mix :: proc "contextless" (first, second: Color, level: u32) -> Color {
	part :: proc "contextless" (a, b, level: u32) -> u32 {
		return (a * (255 - level) + b * level) / 255
	}
	return rgb(part(first >> 16 & 0xFF, second >> 16 & 0xFF, level), part(first >> 8 & 0xFF, second >> 8 & 0xFF, level), part(first & 0xFF, second & 0xFF, level))
}

// mix_with_alpha gives a color between two colors with straight alpha,
// 0xAARRGGBB: the alpha mixes as mix mixes each channel, in the encoded
// values, and the red, the green and the blue are those of mix.
mix_with_alpha :: proc "contextless" (first, second: u32, level: u32) -> u32 {
	alpha := ((first >> 24) * (255 - level) + (second >> 24) * level) / 255
	return alpha << 24 | mix(first, second, level)
}

// shade gives a color nearer to black (percent under 100) or nearer to
// white (percent from 100 to 200).
shade :: proc "contextless" (color: Color, percent: u32) -> Color {
	return percent <= 100 ? mix(COLOR_BLACK, color, percent * 255 / 100) : mix(color, COLOR_WHITE, (min(percent, 200) - 100) * 255 / 100)
}

// hue_color gives one color of the circle of colors, of middle strength.
// The site colors the tile of a module with the first byte of its hash:
// a module that changes takes a new color.
hue_color :: proc "contextless" (hue: u8) -> Color {
	LOW :: 64
	HIGH :: 208
	part := u32(hue) * 6 % 256
	rise := LOW + (HIGH - LOW) * part / 255
	fall := HIGH - (HIGH - LOW) * part / 255
	switch u32(hue) * 6 / 256 {
	case 0:
		return rgb(HIGH, rise, LOW)
	case 1:
		return rgb(fall, HIGH, LOW)
	case 2:
		return rgb(LOW, HIGH, rise)
	case 3:
		return rgb(LOW, fall, HIGH)
	case 4:
		return rgb(rise, LOW, HIGH)
	}
	return rgb(HIGH, LOW, fall)
}

// block draws a rectangle whose color goes from top, on its first line, to
// bottom, on its last line: the sign of depth of the rules.
block :: proc "contextless" (canvas: Canvas, x, y, width, height: int, top, bottom: Color) {
	for row in 0 ..< height {
		fill(canvas, x, y + row, width, 1, mix(top, bottom, u32(row * 255 / max(height - 1, 1))))
	}
}

// gradient puts in row the colors of the columns first ..< first + len(row)
// of a line of total columns, whose color goes from start, at column 0, to
// end, at column total - 1. Each channel steps by a fixed-point number: no
// division for each pixel.
gradient :: proc "contextless" (row: []Color, start, end: Color, total, first: int) {
	steps := i64(max(total - 1, 1))
	value, step: [3]i64
	for channel in 0 ..< 3 {
		shift := uint(16 - 8 * channel)
		from, to := i64(start >> shift & 0xFF), i64(end >> shift & 0xFF)
		step[channel] = (to - from) * 65536 / steps
		value[channel] = from * 65536 + step[channel] * i64(first) + 32768
	}
	for &color in row {
		color = rgb(u32(value[0] >> 16), u32(value[1] >> 16), u32(value[2] >> 16))
		value += step
	}
}

// gradient_with_alpha is gradient for two colors with straight alpha,
// 0xAARRGGBB: the alpha steps as each channel does, and the red, the green
// and the blue of each column are those of gradient.
gradient_with_alpha :: proc "contextless" (row: []u32, start, end: u32, total, first: int) {
	gradient(row, start, end, total, first)
	steps := i64(max(total - 1, 1))
	from, to := i64(start >> 24), i64(end >> 24)
	step := (to - from) * 65536 / steps
	value := from * 65536 + step * i64(first) + 32768
	for &color in row {
		color |= u32(value >> 16) << 24
		value += step
	}
}

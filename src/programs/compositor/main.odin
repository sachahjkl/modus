// The compositor (docs/ARCHITECTURE.md, "U8. Graphics: WebGPU library and compositor"): the service that owns the
// display. It combines the surfaces of programs into the framebuffer, and it
// sends input to the program that has focus. It is also the desktop shell of
// this first version: a bar with the menu of the programs and the menu of
// the windows, and windows that the input moves. It follows the design
// rules (docs/DESIGN.md): rectangles only, the grid of 8 pixels, the colors
// of src/library/support/graphics.
//
// **What it is for.** No program writes to the screen. A program asks the
// compositor for a [surface](term:surface): memory that the program and the
// compositor share. The program draws into it and sends `Present`; the
// compositor copies the changed rectangle into its frame, then the frame to
// the screen page that the display does not show, and flips
// (src/md/infrastructure/whole_frame.md). The compositor is the only holder of the framebuffer and
// of the ring of the [input service](term:input-service), so no program
// reads the keys of another window or draws over it.
//
// **What a reader sees.** The whole screen: the background with its grid
// of points, the [bar](term:bar) at the top (the
// [menu of the programs](term:menu-of-the-programs), the
// [menu of the windows](term:menu-of-the-windows), the hint of the
// [palette](term:palette), the date and the time), the windows with their
// [title bar](term:title-bar) and their close button, and the
// [pointer](term:pointer). The input can:
//
// - press a line of the menu of the programs: the compositor asks the root
//   service to start that program;
// - press the key super: the palette opens; typed letters narrow one list
//   of the programs and of the windows, and Enter starts the chosen
//   program or brings the chosen window to the front (palette.odin);
// - drag a title bar: the window moves; a press on a window brings it to the
//   front and gives it the [focus](term:focus);
// - press the close button: the root service stops the program.
//
// The keys go to the window in front, unless the palette is open.
//
// **Its lines in the log**: `compositor: two screen pages: each frame
// reaches the screen whole, by a page flip` (or `one screen page` on a
// display with no page flip), `compositor: ok <width>x<height>` at the start,
// `compositor: first frame`, then, on the channel `surfaces`, one line for
// each new surface, each move and each window brought to the front, the
// time of a full frame, and the events of the palette.
//
// **Its two threads.** The first thread runs the loop below. The second
// one makes the lists of the palette: it collects the entries, copies and
// checks the table of the [palette provider](term:palette-provider), and
// ranks them for the typed part, so the loop never does that work
// (palette.odin).
//
// **How it starts.** The root service starts it at each boot, after the
// input service and before the console. Its context is not the context of
// the other programs: the handles 0 to 2 are the framebuffer, the ring of
// the input service, and a control ring to the root service; on the
// standard VGA of the test machine, the handle 0 holds two
// [screen pages](term:screen-page) and the handle 3 is the memory of the
// registers of the VGA, for the [page flip](term:page-flip); the values 0
// to 3 are the width, the height, the pixels of a line and the pixel format
// of the screen. The root service also maps its own file (for its exports),
// two [pointer themes](term:pointer-theme), the
// [settings page](term:settings-page), the glyph caches and the
// [date page](term:date-page). Its row of `program_roles` has the grants
// Serve and System_Part: the root service gives these handles by name.
//
// **Its exports**: `pointer` and `windows`, to a caller that
// [acts for the principal](term:acts-for-the-principal) (`exports.odin`).
// The machine test reads them through the remote service before each press,
// so that a press lands where the scenario wants it.
//
// **What it does not prove.** The compositor draws with the processor,
// into memory: it is not the graphics interface of the system, which is
// WebGPU with WGSL and is not built. A full frame of the screen takes a few
// milliseconds of one processor; the log gives the measure.
//
// **How it draws.** The windows, the bar and the palette are draw tables,
// drawn by the [drawing module](term:drawing-module), which the compositor
// imports as each program with a window does. A call of the module takes
// one picture memory, and each surface is a memory of its own, so the
// screen table is in parts: one for each window, with its surface, and one
// for the bar, with its heron. A damage rectangle is one call for each
// part that it meets (src/md/api/picture.md).
//
// The design of the desktop is in docs/DESIGN.md, "9. The desktop"; the
// pointer is in docs/POINTERS.md.
package compositor

import "modus:support/bochs_display"
import "modus:support/display"
import "modus:contract/errors"
import "modus:contract/settings"
import "modus:contract/date"
import "modus:support/calendar"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:private/compositor/bar"
import "modus:support/mark"
import "modus:private/compositor/palette"
import "modus:contract/ring"
import "modus:support/key_path"
import "modus:support/system"
import "modus:contract/pointer_pictures"
import program_page "modus:contract/disk_program_page"
import "base:intrinsics"

// Its loop, and the thread that makes the lists of the palette. The
// working memory: its surfaces, its tables and the screen. The device
// memory of the screen costs no page, but its page tables do: the two
// screen pages (1536 pages, 6 MiB) need up to 4 page tables where the one
// framebuffer needed up to 3, and the page of the display registers needs
// a page table and a page directory: 4 pages more.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 3803, programs = 1, threads = 2}

// The context of this service.
GRANT_FRAMEBUFFER :: 0 // The framebuffer of the firmware, or the memory of two screen pages.
GRANT_INPUT :: 1
GRANT_CONTROL :: 2
GRANT_DISPLAY_REGISTERS :: 3 // The registers of the standard VGA, with the memory of two screen pages. 0: no page flip.
VALUE_WIDTH :: 0
VALUE_HEIGHT :: 1
VALUE_PIXELS_PER_LINE :: 2
VALUE_FORMAT :: 3
FORMAT_RED_FIRST :: 2 // boot_info.Pixel_Format.Red_Green_Blue_X

FRAME_INTERVAL :: 16 // Milliseconds.
BAR_HEIGHT :: bar.HEIGHT
// The frame of a window: a title bar over the surface, and a border of
// BORDER pixels at the left, the right and the bottom. The machine test
// reads these numbers (tools/modustool/machine.odin, WINDOW_*).
TITLE_HEIGHT :: 24
BORDER :: 2
CLOSE_SIZE :: 24 // The close button: a square at the right end of the title bar.
// A new window: the first one at (PLACE_X, PLACE_Y), each next one lower
// and to the right, by PLACE_STEP_X and PLACE_STEP_Y.
// The places of new windows. Each corner of a window is on the grid of 8
// pixels (docs/DESIGN.md, section 6).
PLACE_X :: 64
PLACE_Y :: 56
PLACE_STEP_X :: 40
PLACE_STEP_Y :: 32
CLIENT_CAPACITY :: 32 // The root service starts 32 programs at most.
DAMAGE_CAPACITY :: 8
CLOCK_WIDTH :: 19 * 8 // "2026-11-11 16:30:05", or the time since boot "00:00:00" when the system has no date.
// The hint of the palette in the bar, at the left of the time: "palette: super".
PALETTE_HINT_NAME :: "palette: "
PALETTE_HINT_KEY :: "super"

Client :: struct {
	ring_memory: system.Handle, // 0: the slot is free.
	ring:        ring.Ring,
	surface:     graphics.Canvas, // pixels is nil until the program creates its surface.
	pictures:    [^]graphics.Color, // The memory of the surface: two pictures. surface is one of them.
	shown:       int, // The picture that surface is: the one that the last Present named.
	// The proof that the window shows whole frames: the frames that read a
	// picture of the window, and the Present records that named the
	// picture that the compositor already read. A program that draws in
	// the picture on the screen has no other complete picture to name.
	frames:      u64,
	pictures_drawn_again: u64,
	presents_refused: u64, // The Present records whose picture number names no picture of the surface.
	commands_refused: u64, // The records whose kind names no command, or None: the first one writes a line.
	x, y:        int,
	title:       system.Name,
	// A disk program: the root service gave its nickname and the first
	// bytes of the hash of its file in Client_Add. The window has the
	// nickname as its title, and the menu of the windows shows the hash
	// prefix beside it.
	from_disk:   bool,
	nickname:    system.Name,
	hash_prefix: [program_page.HASH_PREFIX_DIGITS]u8,
	pointer_shape: pointer_pictures.Pointer_Shape, // The shape that the program asked for over its surface (pointer_picture.odin).
	pointer_over: bool, // The last pointer event of the program was over its surface, or with a button down: the program gets one event more when the pointer leaves.
	presents:    u64, // The Present records that the program sent since it created its surface.
	present_waits: bool, // A Present changed a part of the screen, and no frame drew it yet.
	picture_due:   bool, // The program said that a change waits for its next picture (display.Command.Picture_Due), and no Present came after.
	// The act names of the window, as the last checked record Act_Names
	// gave them: the palette offers to go there (palette.odin). They go with
	// the window: client_remove clears the slot.
	act_names:   palette.Act_Name_Set,
	act_name_sets_logged: int, // The sets that the log named: the first ACT_NAME_SETS_LOGGED only.
}

// A rectangle of the screen. right and bottom are not in the rectangle.
Rectangle :: struct {
	left, top, right, bottom: int,
}

screen: graphics.Canvas // The framebuffer of the machine: the screen page 0.
red_first: bool
// The screen pages (src/md/infrastructure/whole_frame.md). With two, each
// frame goes into the page
// that the display does not show, then a page flip shows it whole. With
// one, each frame is written into the page that the display shows.
screen_pages: [bochs_display.PAGE_COUNT]graphics.Canvas
screen_page_count: int
screen_page_shown: int
display_registers: rawptr // The display registers of Bochs, mapped. nil with one screen page.
// What each screen page owes: the rectangles where it differs from the
// frame in memory. The rule of the two pictures of a surface.
screen_page_debts: interface.Picture_Debts
page_flips: u64 // The page flips since the start.
frames_on_the_shown_page: u64 // The frames written into the screen page that the display showed.
frame: graphics.Canvas // The picture that the compositor builds, then copies to the screen.
background: graphics.Canvas
background_appearance: graphics.Appearance // The appearance of the pixels of `background` and of the mark of the bar.
clients: [CLIENT_CAPACITY]Client
order: [CLIENT_CAPACITY]int // The clients that have a surface, from back to front. The last one has focus.
order_count: int
placed: int
input: ring.Ring
control: ring.Ring
pointer_x, pointer_y: int
buttons: u32
dragging := -1
// A menu of the bar.
Menu :: enum {
	None,
	Programs, // The menu of the programs: a press on a line starts the program.
	Windows, // One line for each window, in the order of the client table: a press brings the window to the front.
}

menu_open: Menu // The menu that is on the screen.
menu_line := -1 // The line of the menu under the pointer.
drag_x, drag_y: int
damage: [DAMAGE_CAPACITY]Rectangle // The parts of the screen that the next frame draws again.
damage_count: int
frames: u64
presents: u64 // The Present records of all the programs since the start.
// A change of the desktop itself (the pointer, the bar, a menu, the
// palette, a window that appeared, moved or closed) is damage that no
// frame drew yet. The damage of a Present is counted for its window, not
// here: a caller tells a window that draws with no end from the rest.
desktop_change_waits: bool
// The measures of the time of a frame (docs/DESIGN.md, section 7). A full
// frame draws the whole screen: the first frame, and the frame after the
// input puts a window down. The frames of a move are the frames while the
// input drags a window.
full_measure: bool // The next frame draws the whole screen, and the log has its time.
move_frames, move_time, move_longest: u64 // Nanoseconds.
// The colors of one line of a title bar, and of its lighter top line.
title_row, title_light: [display.SURFACE_LIMIT + 2 * BORDER]graphics.Color

// damage_add records that the desktop itself changed a rectangle of the
// screen: each change but the Present of a program.
damage_add :: proc "contextless" (x, y, width, height: int) {
	if damage_rectangle_add(x, y, width, height) {
		desktop_change_waits = true
	}
}

// damage_rectangle_add records that a rectangle of the screen changed.
// Rectangles that touch become one rectangle. If there is no room, the new
// rectangle joins the first one. false: the rectangle is not on the screen,
// and nothing waits for a frame.
damage_rectangle_add :: proc "contextless" (x, y, width, height: int) -> bool {
	area := Rectangle{max(x, 0), max(y, 0), min(x + width, screen.width), min(y + height, screen.height)}
	if area.left >= area.right || area.top >= area.bottom {
		return false
	}
	index := 0
	for index < damage_count {
		other := damage[index]
		apart := area.left > other.right || other.left > area.right || area.top > other.bottom || other.top > area.bottom
		if apart && damage_count < DAMAGE_CAPACITY {
			index += 1
			continue
		}
		area = {min(area.left, other.left), min(area.top, other.top), max(area.right, other.right), max(area.bottom, other.bottom)}
		damage_count -= 1
		damage[index] = damage[damage_count]
		index = 0 // The larger rectangle can touch one that it did not touch before.
	}
	damage[damage_count] = area
	damage_count += 1
	return true
}

// damage_window records the rectangle of a window.
damage_window :: proc "contextless" (client: ^Client) {
	if client.surface.pixels != nil {
		damage_add(client.x, client.y, client.surface.width + 2 * BORDER, client.surface.height + TITLE_HEIGHT + BORDER)
	}
}

// damage_focus records the window that has focus: its title changes color
// when the focus changes.
damage_focus :: proc "contextless" () {
	if order_count > 0 {
		damage_window(&clients[order[order_count - 1]])
	}
}

// damage_menu records the buttons of the bar and their menus.
damage_menu :: proc "contextless" () {
	damage_menu_of(bar_layout)
}

// damage_menu_of records the buttons and the menus of one layout of the
// bar: a change of the font damages the places of the old layout and of
// the new one.
damage_menu_of :: proc "contextless" (layout: bar.Layout) {
	x, y, width, height := bar.button(layout)
	damage_add(x, y, width, height)
	x, y, width, height = bar.menu(layout)
	damage_add(x, y, width, height)
	x, y, width, height = bar.windows_button(layout)
	damage_add(x, y, width, height)
	x, y, width, height = bar.windows_menu(layout, CLIENT_CAPACITY) // A window can leave while the menu is open.
	damage_add(x, y, width, height)
}

// The texts that the compositor draws itself follow the rule of the two
// fonts (docs/DESIGN.md, section 5): the names (the buttons of the bar, the
// lines of the menus, the titles of the windows, the names of the
// palette, a hint) in the interface font; the values (the clock, the date,
// the text that the input types, a count) in the font of the cells. The
// interface font is the one of src/library/support/display (interface_font_load); with
// none, or with the setting Spleen 8x16, each text is in the font of the
// cells with the same layout rules.
bar_layout: bar.Layout
bar_layout_known: bool
bar_in_interface_font: bool

// bar_measure writes once in the log the time of one whole frame of the
// bar with the menu of the programs open, built and drawn, in the font of
// the cells and in the interface font: the least of 20 rounds, so that a
// round that the host stops in its middle does not count. It runs before
// the first frame, which draws the whole screen after it.
bar_measure :: proc "contextless" () {
	ROUNDS :: 20
	font := display.interface_font_of()
	saved_layout, saved_menu := bar_layout, menu_open
	menu_open = .Programs
	fonts := [2]^display.Interface_Font{nil, font}
	least := [2]u64{max(u64), max(u64)}
	measured := 0
	for measured_font in fonts {
		if measured == 1 && (font == nil || graphics.text_state.font != .Vector) {
			break
		}
		bar_layout = bar.layout_of(measured_font != nil ? &measured_font.regular : nil)
		_, menu_top, _, menu_height := bar.menu(bar_layout)
		areas := [1]Rectangle{{0, 0, frame.width, max(BAR_HEIGHT, menu_top + menu_height)}}
		for _ in 0 ..< ROUNDS {
			start := system.nanoseconds()
			screen_build(0, measured_font)
			screen_draw(areas[:])
			least[measured] = min(least[measured], system.nanoseconds() - start)
		}
		measured += 1
	}
	bar_layout, menu_open = saved_layout, saved_menu
	if measured < 2 {
		system.log("compositor: the bar and the menu of the programs, built and drawn (the least of 20): the font of the cells ", least[0] / 1000, ".", least[0] / 100 % 10, " us; no interface font")
		return
	}
	system.log("compositor: the bar and the menu of the programs, built and drawn (the least of 20): the font of the cells ", least[0] / 1000, ".", least[0] / 100 % 10, " us, the interface font ", least[1] / 1000, ".", least[1] / 100 % 10, " us")
}

// bar_layout_update measures the bar in the font that draws it now, and
// writes in the log which font it is when it changes: the modus tool reads
// that line to find the places of the bar. The places of the old and of
// the new layout are damaged.
bar_layout_update :: proc "contextless" () {
	font := display.interface_font_of()
	in_interface_font := font != nil && graphics.text_state.font == .Vector
	layout := bar.layout_of(in_interface_font ? &font.regular : nil)
	if bar_layout_known && layout == bar_layout && in_interface_font == bar_in_interface_font {
		return
	}
	if bar_layout_known {
		damage_menu_of(bar_layout)
	}
	bar_layout, bar_layout_known, bar_in_interface_font = layout, true, in_interface_font
	damage_add(0, 0, screen.width, BAR_HEIGHT)
	damage_menu_of(bar_layout)
	if in_interface_font {
		system.log("compositor: the bar is in the interface font: programs ", u64(layout.label_width), " pixels, windows ", u64(layout.windows_label_width), ", the widest name ", u64(layout.longest_name_width))
	} else {
		system.log("compositor: the bar is in the font of the cells")
	}
}

// window_of_line gives the client of a line of the menu of the windows, or -1.
window_of_line :: proc "contextless" (line: int) -> int {
	count := 0
	for &client, index in clients {
		if client.surface.pixels == nil {
			continue
		}
		if count == line {
			return index
		}
		count += 1
	}
	return -1
}

// windows_log writes the lines of the menu of the windows on the log, in
// their order: "compositor: windows: console, life, monitor".
windows_log :: proc "contextless" () {
	buffer: [CLIENT_CAPACITY * (size_of(system.Name) + 2)]u8
	count := 0
	for &client in clients {
		if client.surface.pixels == nil {
			continue
		}
		if count > 0 {
			count += copy(buffer[count:], ", ")
		}
		count += copy(buffer[count:], system.name_of(client.title[:]))
	}
	system.log_in("surfaces", .Info, "compositor: windows: ", string(buffer[:count]))
	// The line of a disk program shows the hash prefix that the root
	// service gave, faded beside its nickname.
	for &client in clients {
		if client.surface.pixels != nil && client.from_disk {
			system.log_in("surfaces", .Info, "compositor: the menu of the windows shows the disk program ", system.name_of(client.title[:]), " with the hash prefix ", string(client.hash_prefix[:]), ", from the root service")
		}
	}
}

// The bar shows the local date and time of day (src/library/contract/date):
// the date of UTC and the time zone of the date page. A zone is whole
// minutes, so the second changes at the same moments as in UTC. With no
// date the bar shows the time since boot. second_of_bar gives the
// second that it shows at the time `now` of the system, and
// next_second_of_bar the time of the system when it changes after `now`:
// always later than `now`, and at most one second later, also when the date
// first appears between two frames (the second shown then jumps from the
// time since boot to the date, and the next frame shows it).
date_page: ^date.Page
// The zone of the last line "the bar shows the local time", which the
// machine test checks: a line at each change of the zone, and none for the
// default, UTC, at the first date. The log has a fixed room, and a line at
// each boot that says nothing new takes it from the records that a reader
// needs.
bar_zone_logged: i64

second_of_bar :: proc "contextless" (now: u64) -> u64 {
	if milliseconds, known := date.milliseconds_now(date_page, now); known {
		return u64(milliseconds / 1000)
	}
	return now / 1000
}

next_second_of_bar :: proc "contextless" (now: u64) -> u64 {
	if milliseconds, known := date.milliseconds_now(date_page, now); known {
		return now + u64(1000 - milliseconds % 1000) // milliseconds_now gives a date after 1970 only: positive.
	}
	return (now / 1000 + 1) * 1000
}

damage_clock :: proc "contextless" () {
	damage_add(screen.width - CLOCK_WIDTH - 16, 8, CLOCK_WIDTH, graphics.CELL_HEIGHT)
}

canvas_create :: proc "contextless" (width, height: int) -> graphics.Canvas {
	memory, status := system.memory_create((u64(width * height * 4) + system.PAGE_SIZE - 1) / system.PAGE_SIZE)
	address: rawptr
	if status == .Ok {
		address, status = system.memory_map(memory)
	}
	if status != .Ok {
		system.log("compositor: no memory")
		system.stop(1)
	}
	return {pixels = ([^]graphics.Color)(address), width = width, height = height, stride = width}
}

// screen_pages_open finds the second screen page: the memory of the
// handle 0 holds two screens, and the display registers of the handle 3
// say the mode of the screen with room for two pages. It writes one line
// that says which form holds.
screen_pages_open :: proc "contextless" (ctx: ^system.Context) {
	screen_pages[0] = screen
	screen_page_count = 1
	page_pixels := screen.stride * screen.height
	registers := ctx.handles[GRANT_DISPLAY_REGISTERS]
	// A refused handle has no pages: the screen keeps one page.
	framebuffer_pages, _ := system.memory_size(ctx.handles[GRANT_FRAMEBUFFER])
	if registers != 0 && framebuffer_pages * system.PAGE_SIZE >= u64(bochs_display.PAGE_COUNT * page_pixels * size_of(graphics.Color)) {
		if address, status := system.memory_map(registers); status == .Ok {
			display_registers = rawptr(uintptr(address) + bochs_display.DISPLAY_REGISTERS_OFFSET)
			if bochs_display.screen_pages(display_registers, u64(screen.width), u64(screen.height), u64(screen.stride)) == bochs_display.PAGE_COUNT {
				screen_pages[1] = {pixels = screen.pixels[page_pixels:], width = screen.width, height = screen.height, stride = screen.stride}
				screen_page_count = bochs_display.PAGE_COUNT
			}
		}
	}
	if screen_page_count == bochs_display.PAGE_COUNT {
		system.log("compositor: two screen pages: each frame reaches the screen whole, by a page flip")
	} else {
		display_registers = nil
		system.log("compositor: one screen page: each frame is written into the screen page that the display shows")
	}
}

// entry starts the compositor and runs its one loop: it draws the screen
// until the machine stops.
//
// **What it sets up**: the framebuffer, the ring of the input service and
// the control ring of the root service; the frame and the background,
// each the size of the screen; the mark of the bar; the pointer theme; the
// service ring of its exports; the text settings and the interface font.
// It writes `compositor: ok <width>x<height>` and the measures of the bar
// and of a title bar.
//
// **The loop.** One wait covers the control ring, the input ring, the
// service ring, the ring of each window and the change count of the
// settings page. The deadline is the next frame when the screen has
// damage, else the next second of the clock in the bar, or the next frame
// of an animated pointer. After the wait, in this order:
//
// 1. A change of the settings: the new font, the new pointer theme, and an
//    event to each window, which draws again.
// 2. The control ring: a window to add or to remove, the palette provider
//    to add or to remove.
// 3. The input ring: a key goes to the palette, or to the window in
//    front; a move or a button of the pointer moves the pointer, drags a
//    window, opens a menu or starts a program. Before the new records, the
//    records that wait for a window whose ring was full go to it, in order
//    (window_events.odin).
// 4. The ring of each window: `Surface_Create`, `Present` (the changed
//    rectangle becomes damage), and `Pointer_Shape`.
// 5. The calls of `pointer`, `windows` and `screen`, after the input and
//    after the rings of the windows, so that they give the place of now
//    and count each `Present` that a program sent before the call.
// 6. A frame, at most one each 16 ms, when the screen has damage.
//
// **The stop.** With no framebuffer or no ring, the compositor writes
// `compositor: no framebuffer` and stops with the code 1. Without the
// memory of its frame, it writes `compositor: no memory` and stops. Else it
// never returns.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	width := int(ctx.values[VALUE_WIDTH])
	height := int(ctx.values[VALUE_HEIGHT])
	date_page = date.page_of(ctx)
	address, status := system.memory_map(ctx.handles[GRANT_FRAMEBUFFER])
	input_status, control_status: system.Status
	input, input_status = system.ring_open(ctx.handles[GRANT_INPUT])
	control, control_status = system.ring_open(ctx.handles[GRANT_CONTROL])
	if status != .Ok || input_status != .Ok || control_status != .Ok || width == 0 {
		system.log("compositor: no framebuffer")
		system.stop(1)
	}
	screen = {pixels = ([^]graphics.Color)(address), width = width, height = height, stride = int(ctx.values[VALUE_PIXELS_PER_LINE])}
	screen_pages_open(ctx)
	red_first = ctx.values[VALUE_FORMAT] == FORMAT_RED_FIRST
	frame = canvas_create(width, height)
	background = canvas_create(width, height)
	// The background, the mark of the bar and the measures draw in the dark
	// appearance: the settings are read below, and a change of the
	// appearance draws the background and the mark again.
	background_build()
	pointer_x, pointer_y = width / 2, height / 2
	bar_mark_build()
	memory_measure()
	title_measure()
	pointer_theme_open(ctx) // pointer_picture.odin
	damage_add(0, 0, width, height)
	full_measure = true
	system.log("compositor: ok ", u64(width), "x", u64(height))
	service_start(ctx) // exports.odin
	// The text of the desktop: the settings of the principal and the glyph cache
	// (modus:contract/settings); a change of the settings wakes this loop.
	display.text_settings_open(ctx)
	display.interface_font_load(ctx)
	palette_start() // palette.odin
	bar_layout_update()
	bar_measure()
	settings_seen: u32
	// settings_seen starts at 0: when the boot pass of settings wrote the page
	// before this read, the first turn of the loop sees a change and tells
	// each window, also the ones that read the page before the boot pass.
	// After that first time, a new count tells the windows only when the
	// values differ from the values that they were told last: `settings`
	// can change the count with no end and the same values, and each told
	// window gets one record in the ring that also carries its keys.
	settings_told: settings.Choice
	settings_told_once: bool
	if display.settings_page != nil {
		// A refused page gives the defaults: the compositor draws with
		// them, as with a page that never stays stable.
		first_choice, _ := settings.read(display.settings_page)
		pointer_theme_choose(first_choice.pointer_theme)
		pointer_form_choose(pointer_form_in_force(first_choice)) // pointer_picture.odin
	}

	next_frame: u64
	shown_second: u64
	for {
		wait: system.Wait
		system.wait_records(&wait, &control.commands)
		system.wait_records(&wait, &input.commands)
		system.service_wait(&wait, &service)
		for &client in clients {
			if client.ring.head != nil {
				system.wait_records(&wait, &client.ring.commands)
			}
		}
		window_events_wait(&wait) // window_events.odin
		deadline := damage_count > 0 ? max(next_frame, 1) : next_second_of_bar(system.time())
		if wake := pointer_wake(); wake != 0 {
			deadline = min(deadline, wake) // An animated pointer shape shows.
		}
		if wake := palette_wake(); wake != 0 {
			deadline = min(deadline, wake) // A held arrow button of the scroll bar of the palette takes its next step.
		}
		if display.settings_page != nil {
			system.wait_word(&wait, &display.settings_page.change_count, settings_seen)
		}
		palette_wait(&wait) // palette.odin
		now := system.wait_end(&wait, deadline)
		if display.settings_page != nil {
			// The root service changes the appearance in force alone, with
			// no new change count, and wakes this loop.
			// A refused page gives the defaults with its count: the windows
			// draw with them, as with a page that never stays stable.
			if choice, _ := settings.read(display.settings_page); choice.change_count != settings_seen || choice.appearance_in_force != settings_told.appearance_in_force {
				settings_seen = choice.change_count
				if !settings_told_once || settings.values_differ(choice, settings_told) {
					settings_told = choice
					settings_told_once = true
					settings_changed(choice)
				}
			}
		}
		for record in system.receive(&control.commands) {
			kind, kind_ok := display.control_of_ring_word(record.kind)
			if !kind_ok {
				system.log("compositor: the root service sent the control word ", u64(record.kind), ", which names no control command")
				continue
			}
			switch kind {
			case .Client_Add:
				client_add(record)
			case .Client_Remove:
				client_remove(system.Handle(record.values[0]))
			case .Palette_Provider_Add:
				palette_provider_add(system.Handle(record.values[0]), system.Handle(record.values[1])) // palette.odin
			case .Palette_Provider_Remove:
				palette_provider_remove()
			case .None, .Start, .Stop:
				// The border refused None above. Start and Stop go from the
				// compositor to the root service, never to the compositor.
				system.log("compositor: the root service sent the control command ", u64(record.kind), ", which the compositor does not take")
			}
		}
		window_events_pass() // The records that wait go before the new ones.
		for record in system.receive(&input.commands) {
			kind, kind_ok := display.input_of_ring_word(record.kind)
			if !kind_ok {
				system.log("compositor: the input service sent the word ", u64(record.kind), ", which names no input")
				continue
			}
			switch kind {
			case .None:
				// The border refused None above.
			case .Key:
				key_records += 1
				if !palette_key(u32(record.values[0]), display.key_character_of(record.values[1]), record.values[2] != 0, u32(record.values[3])) && order_count > 0 {
					send(&clients[order[order_count - 1]], .Key, record.values)
				}
			case .Pointer:
				// The input service is a program: a count of notches far
				// past a hand is cut, as the window layer cuts it.
				wheel := int(clamp(i64(record.values[3]), -key_path.WHEEL_NOTCHES_LIMIT, key_path.WHEEL_NOTCHES_LIMIT))
				pointer_moved(int(i64(record.values[0])), int(i64(record.values[1])), u32(record.values[2]), wheel)
				pointer_moves += 1
			}
		}
		for &client, index in clients {
			if client.ring.head == nil {
				continue
			}
			// One turn takes the records that the ring holds at its start,
			// and no more: a program that writes records as fast as this
			// loop reads them must not keep this loop from the frame, the
			// input and the other windows. The records that come during
			// the turn end the next wait at once.
			taken := false
			for _ in 0 ..< system.records_of_turn(&client.ring.commands) {
				record := system.receive(&client.ring.commands) or_break
				taken = true
				// A program writes the word: a word of no command, and None,
				// are counted, and the first one of a window writes a line,
				// so a window that writes many cannot fill the log of the
				// compositor.
				command, command_ok := display.command_of_ring_word(record.kind)
				if !command_ok {
					if client.commands_refused == 0 {
						system.log("compositor: a window sent the word ", u64(record.kind), ", which names no command; the next ones are counted, and the count comes when the window closes")
					}
					client.commands_refused += 1
					continue
				}
				switch command {
				case .None:
					// Refused above: None is no command.
				case .Surface_Create:
					surface_create(index, record)
				case .Present:
					// The picture that was due comes with this Present.
					client.picture_due = false
					if client.surface.pixels != nil {
						// The program names the picture that is complete.
						// From here on the compositor reads only that one,
						// and the program draws the other. A number that
						// names no picture is refused and counted: the
						// window keeps the last picture that was named,
						// and shows none before a first one.
						picture := record.values[0]
						if picture >= display.PICTURE_COUNT {
							client.presents_refused += 1
							continue
						}
						if client.presents > 0 && int(picture) == client.shown {
							client.pictures_drawn_again += 1
						}
						client.shown = int(picture)
						client.surface.pixels = client.pictures[client.shown * client.surface.width * client.surface.height:]
						// The program can name the rectangle that changed; the
						// numbers are its own: they are cut to the surface.
						left, top := int(min(record.values[1], u64(client.surface.width))), int(min(record.values[2], u64(client.surface.height)))
						// The first picture of the window: the screen shows
						// none of it yet, so each pixel of it changed.
						// From this picture on, the window is on the screen
						// and in the menu of the windows: a step that opens
						// that menu waits for this line, not for the line of
						// the surface, which comes before any picture.
						if client.presents == 0 {
							left, top = 0, 0
							system.log_in("surfaces", .Info, "compositor: window ", system.name_of(client.title[:]), " is shown")
						}
						// Width 0: from (left, top) to the end of the surface.
						changed_width, changed_height := client.surface.width - left, client.surface.height - top
						if record.values[3] != 0 && client.presents > 0 {
							changed_width = int(min(record.values[3], u64(client.surface.width - left)))
							changed_height = int(min(record.values[4], u64(client.surface.height - top)))
						}
						client.presents += 1
						presents += 1
						if damage_rectangle_add(client.x + BORDER + left, client.y + TITLE_HEIGHT + top, changed_width, changed_height) {
							client.present_waits = true
						}
					}
				case .Picture_Due:
					client.picture_due = record.values[0] != 0
				case .Pointer_Shape:
					pointer_shape_request(&client, record) // pointer_picture.odin
				case .Act_Names:
					palette_act_names_take(&client, record) // palette.odin
				}
			}
			// The program can wait until this loop took its last picture
			// (display.canvas_wait): it draws the next one in the picture
			// that this loop read until now. No frame is drawn between
			// the record and this wake.
			if taken && client.ring.head != nil {
				system.wake_writer(&client.ring.commands)
			}
		}
		palette_turn() // A list of the ranking thread, an answer of the palette provider.
		// The calls read the place of the pointer after the input records,
		// and the state of the screen after each Present that a program
		// sent before the call: a caller that reads "nothing waits" then
		// knows that the screen shows what the programs sent.
		system.service_run(&service)
		pointer_update(now) // After each change of what is under the pointer.
		if second_of_bar(now) != shown_second {
			shown_second = second_of_bar(now)
			damage_clock()
		}
		if damage_count > 0 && now >= next_frame {
			draw(now)
			next_frame = now + FRAME_INTERVAL
			frames += 1
			if frames == 1 {
				system.log("compositor: first frame")
			}
		}
	}
}

// settings_changed gives the new font to the text of the desktop, draws the
// whole screen again, and tells each window: its program draws again
// (src/library/support/display gives it the new font before the event).
settings_changed :: proc "contextless" (choice: settings.Choice) {
	display.text_settings_apply()
	// A new appearance: the background and the mark of the bar are pixels
	// that the compositor keeps, so it draws them again; each record of the
	// screen reads the tokens at its next frame.
	if graphics.appearance != background_appearance {
		background_build()
		bar_mark_build()
	}
	bar_layout_update()
	pointer_theme_choose(choice.pointer_theme) // pointer_picture.odin
	pointer_form_choose(pointer_form_in_force(choice))
	told := 0
	for &client in clients {
		if client.ring.head != nil {
			send(&client, .Settings_Changed, {0 = u64(choice.change_count)})
			told += 1
		}
	}
	damage_add(0, 0, screen.width, screen.height)
	palette_refresh() // An open panel is measured again in the new font.
	buffer: [256]u8
	writer := system.Writer{buffer = buffer[:]}
	values := settings.values_of(choice)
	for setting in settings.Setting {
		description := settings.descriptions[setting]
		system.write_part(&writer, setting == .Font ? "" : ", ")
		system.write_part(&writer, description.title)
		system.write_part(&writer, " ")
		system.write_part(&writer, description.value_names[values[setting]])
	}
	system.write_part(&writer, "; the appearance in force ")
	system.write_part(&writer, settings.appearance_in_force_names[choice.appearance_in_force])
	zone_buffer: [settings.ZONE_TEXT_SIZE]u8
	system.write_part(&writer, "; the time zone ")
	system.write_part(&writer, settings.zone_text(zone_buffer[:], choice.zone_offset_minutes))
	system.log("compositor: the settings changed: ", system.written(&writer), "; ", u64(told), " windows draw again")
}

// send gives an event to a window. A full ring loses no key: the event
// waits for the window in the compositor (window_events.odin). The kind is
// a member: the compositor writes the word of the record here, and reads
// no word back to know the class of the event.
send :: proc "contextless" (client: ^Client, kind: display.Event_Kind, values: [7]u64) {
	window_event_send(client, kind, values)
}

// client_add takes the ring of a new program from the root service. For a
// disk program the record also holds its nickname and the first bytes of
// the hash of its file: the window takes that nickname, not the title that
// the program sends.
client_add :: proc "contextless" (record: ring.Record) {
	memory := system.Handle(record.values[0])
	for &client in clients {
		if client.ring_memory != 0 {
			continue
		}
		opened, status := system.ring_open(memory)
		if status != .Ok {
			break
		}
		client = {ring_memory = memory, ring = opened}
		nickname := program_page.nickname_of({record.values[1], record.values[2], record.values[3]})
		if nickname.length > 0 {
			client.from_disk = true
			copy(client.nickname[:len(client.nickname) - 1], program_page.nickname_text(&nickname))
			program_page.hash_prefix_write(&client.hash_prefix, record.values[4])
		}
		return
	}
	system.close(memory)
}

client_remove :: proc "contextless" (memory: system.Handle) {
	for &client, index in clients {
		if client.ring_memory != memory {
			continue
		}
		for position in 0 ..< order_count {
			if order[position] == index {
				copy(order[position:order_count - 1], order[position + 1:order_count]) // The last place has no next one.
				order_count -= 1
				break
			}
		}
		if dragging == index {
			dragging = -1
		}
		damage_window(&client)
		damage_focus()
		if client.surface.pixels != nil {
			system.memory_unmap(client.pictures)
		}
		if client.commands_refused != 0 {
			system.log("compositor: window ", system.name_of(client.title[:]), " closed after ", client.commands_refused, " records whose word names no command")
		}
		window_queue_close(index) // window_events.odin
		system.ring_close(&client.ring)
		system.close(client.ring_memory)
		client = {}
		palette_entries_refresh() // A window left.
		return
	}
}

surface_create :: proc "contextless" (index: int, record: ring.Record) {
	client := &clients[index]
	// The program wrote the number of the handle: it can name any handle of
	// the compositor, among them the surface or the ring of another client.
	// The kernel proves that this program gave the handle through its own
	// ring (src/library/support/system, handle_state). A number with no proof is not a
	// gift of this program: the compositor neither uses it nor closes it.
	memory := system.Handle(record.values[0])
	kind, rights, through := system.handle_state(memory, client.ring_memory)
	// No log line: a program could send this command without end.
	if !through {
		return
	}
	// The handle is a gift of this program: each return below closes it.
	defer system.close(memory)
	width, height := record.values[1], record.values[2]
	// The program chose these numbers: check them against the memory itself.
	if kind != .Memory || .Read not_in rights || client.surface.pixels != nil || width == 0 || height == 0 || width > display.SURFACE_LIMIT || height > display.SURFACE_LIMIT {
		return
	}
	// A surface has two pictures: the program draws one while this service
	// reads the other. Memory for less is refused.
	pages, size_status := system.memory_size(memory)
	size := pages * system.PAGE_SIZE
	if size_status != .Ok || size < display.PICTURE_COUNT * width * height * size_of(graphics.Color) {
		return
	}
	address, status := system.memory_map(memory, {}) // Read only.
	if status != .Ok {
		return
	}
	client.pictures = ([^]graphics.Color)(address)
	client.surface = {pixels = client.pictures, width = int(width), height = int(height), stride = int(width)}
	// A disk program could title its window as a program of the system: its
	// window has the nickname that the root service gave.
	client.title = client.from_disk ? client.nickname : system.name_unpack({record.values[3], record.values[4], record.values[5], record.values[6]})
	client.x = PLACE_X + placed % 8 * PLACE_STEP_X
	client.y = PLACE_Y + placed % 8 * PLACE_STEP_Y
	// A large window moves up and left until the screen shows all of it; a
	// window wider than the screen keeps its close button on the screen.
	client.x, client.y = bar.new_window_place(client.x, client.y, window_frame_of(client), int(height), screen.width, screen.height)
	placed += 1
	pointer_leaves_front()
	damage_focus()
	order[order_count] = index
	order_count += 1
	damage_window(client)
	system.log_in("surfaces", .Info, "compositor: surface ", system.name_of(client.title[:]), " ", width, "x", height, " at ", u64(client.x), ",", u64(client.y))
	palette_entries_refresh() // A window appeared.
}

raise :: proc "contextless" (position: int) {
	index := order[position]
	if position == order_count - 1 {
		return
	}
	pointer_leaves_front()
	damage_focus()
	damage_window(&clients[index])
	copy(order[position:order_count - 1], order[position + 1:order_count]) // The last place has no next one.
	order[order_count - 1] = index
	palette_entries_refresh() // Another window is in front.
}

inside :: proc "contextless" (x, y, left, top, width, height: int) -> bool {
	return x >= left && y >= top && x < left + width && y < top + height
}

// pointer_moved takes one pointer record of the input service: a move, the
// buttons, and the notches of the wheel. The wheel goes where the pointer
// goes: to the palette while it is open, else to the program of the window
// in front when the pointer is over its surface. A window behind gets no
// notch: the input goes only to the program that has the focus, so no
// program reads input that the principal gave to another one.
pointer_moved :: proc "contextless" (motion_x, motion_y: int, new_buttons: u32, wheel: int) {
	close_before := close_button_under_pointer()
	pointer_x = clamp(pointer_x + motion_x, 0, screen.width - 1)
	pointer_y = clamp(pointer_y + motion_y, 0, screen.height - 1)
	// The close button under the pointer is brighter: draw again the
	// button that the pointer leaves and the one that it reaches.
	if close_after := close_button_under_pointer(); close_after != close_before {
		for client in ([2]^Client{close_before, close_after}) {
			if client != nil {
				damage_add(client.x + client.surface.width + BORDER - CLOSE_SIZE, client.y, CLOSE_SIZE, TITLE_HEIGHT)
			}
		}
	}
	pressed := new_buttons & display.BUTTON_LEFT != 0 && buttons & display.BUTTON_LEFT == 0
	released := new_buttons & display.BUTTON_LEFT == 0 && buttons & display.BUTTON_LEFT != 0
	held := buttons != 0 || new_buttons != 0
	buttons = new_buttons
	// The place of each press is a fact that only the compositor has: the
	// input service joins the moves that find its ring full, and the edges
	// of the screen cut the joined move where they would not cut each move
	// alone. A test that moves the pointer with no other way to read it
	// learns from this line where the press landed.
	if pressed {
		system.log_in("surfaces", .Info, "compositor: a press of the left button at ", u64(pointer_x), ",", u64(pointer_y))
	}

	if palette_is_open() {
		// The panel takes the pointer: no menu and no window receives it.
		palette_pointer(motion_x != 0 || motion_y != 0, pressed, released, wheel)
		return
	}
	if dragging >= 0 {
		if buttons & display.BUTTON_LEFT != 0 {
			damage_window(&clients[dragging])
			// The window follows the pointer on the grid of 8, and a part
			// of its title stays on the screen at each edge.
			clients[dragging].x, clients[dragging].y = bar.dragged_window_place(pointer_x, pointer_y, drag_x, drag_y, window_frame_of(&clients[dragging]), screen.width, screen.height)
			damage_window(&clients[dragging])
		} else {
			// The input put the window down: the log has its new place.
			client := &clients[dragging]
			system.log_in("surfaces", .Info, "compositor: window ", system.name_of(client.title[:]), " moved to ", u64(max(client.x, 0)), ",", u64(client.y))
			system.log_in("surfaces", .Info, "compositor: the move of ", system.name_of(client.title[:]), ": ", move_frames, " frames, ", move_time / max(move_frames, 1) / 1000, " us per frame, ", move_longest / 1000, " us the longest")
			move_frames, move_time, move_longest = 0, 0, 0
			dragging = -1
			damage_add(0, 0, screen.width, screen.height)
			full_measure = true
		}
		return
	}
	// The menu of the programs: its button opens it. A press on a line
	// starts the program. Any press closes the menu.
	// The menu of the windows: its button opens it, and a press on a line
	// brings the window to the front.
	if menu_open != .None {
		over := menu_open == .Programs ? bar.line_at(bar_layout, pointer_x, pointer_y) : bar.windows_line_at(bar_layout, order_count, pointer_x, pointer_y)
		if over != menu_line {
			menu_line = over
			damage_menu()
		}
	}
	if pressed {
		was_open := menu_open
		if menu_open != .None {
			if menu_open == .Programs && menu_line >= 0 {
				packed := system.name_pack(bar.names[menu_line])
				system.send(&control.completions, ring.Record{kind = u32(display.Control.Start), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
			}
			if index := window_of_line(menu_line); menu_open == .Windows && menu_line >= 0 && index >= 0 {
				for position in 0 ..< order_count {
					if order[position] == index {
						raise(position)
						break
					}
				}
				system.log_in("surfaces", .Info, "compositor: window ", system.name_of(clients[index].title[:]), " in front")
			}
			menu_open = .None
			menu_line = -1
			damage_menu()
		}
		under := bar.button_at(bar_layout, pointer_x, pointer_y)
		if under == .Programs && was_open != .Programs {
			menu_open = .Programs
			system.log_in("surfaces", .Info, "compositor: the menu of the programs is open")
			damage_menu()
		}
		if under == .Windows && was_open != .Windows {
			menu_open = .Windows
			windows_log()
			damage_menu()
		}
		if was_open != .None || pointer_y < BAR_HEIGHT {
			return
		}
		for position := order_count - 1; position >= 0; position -= 1 {
			client := &clients[order[position]]
			outer_width := client.surface.width + 2 * BORDER
			if !inside(pointer_x, pointer_y, client.x, client.y, outer_width, client.surface.height + TITLE_HEIGHT + BORDER) {
				continue
			}
			raise(position)
			if inside(pointer_x, pointer_y, client.x + outer_width - BORDER - CLOSE_SIZE, client.y, CLOSE_SIZE, TITLE_HEIGHT) {
				system.send(&control.completions, ring.Record{kind = u32(display.Control.Stop), values = {0 = u64(client.ring_memory)}})
				return
			}
			if pointer_y < client.y + TITLE_HEIGHT {
				dragging = order[order_count - 1]
				drag_x, drag_y = pointer_x - client.x, pointer_y - client.y
				return
			}
			break
		}
	}
	// The program with focus receives the pointer when it is over its surface,
	// and while a button is down.
	if order_count > 0 {
		client := &clients[order[order_count - 1]]
		x := pointer_x - client.x - BORDER
		y := pointer_y - client.y - TITLE_HEIGHT
		// One event more when the pointer leaves the surface: the program
		// then draws at rest what the pointer was over (a scroll bar).
		on_surface := inside(x, y, 0, 0, client.surface.width, client.surface.height)
		over := held || on_surface
		if over || client.pointer_over {
			// The notches go only with a pointer over the surface: not
			// while a held button sends the pointer from outside it, and
			// not in the event that says that the pointer left.
			notches := on_surface ? wheel : 0
			send(client, .Pointer, {0 = u64(i64(x)), 1 = u64(i64(y)), 2 = u64(buttons), 3 = u64(i64(notches))})
		}
		client.pointer_over = over
	}
}

// pointer_leaves_front tells the program of the window in front that the
// pointer is no longer over its surface, before another window takes the
// front: that program receives no pointer event after it. The place of the
// event is the corner outside the surface, with no button.
pointer_leaves_front :: proc "contextless" () {
	if order_count == 0 {
		return
	}
	client := &clients[order[order_count - 1]]
	if client.pointer_over {
		client.pointer_over = false
		send(client, .Pointer, {0 = ~u64(0), 1 = ~u64(0), 2 = 0})
	}
}

// draw draws again each damage rectangle, then copies it to the screen.
draw :: proc "contextless" (now: u64) {
	start := system.nanoseconds()
	screen_build(now, display.interface_font_of())
	draw_areas(damage[:damage_count])
	// The windows that this frame read a picture of.
	for &client in clients {
		if client.surface.pixels == nil || client.presents == 0 {
			continue
		}
		left, top := client.x + BORDER, client.y + TITLE_HEIGHT
		for area in damage[:damage_count] {
			if area.left < left + client.surface.width && left < area.right && area.top < top + client.surface.height && top < area.bottom {
				client.frames += 1
				break
			}
		}
	}
	damage_count = 0
	// The screen shows each change that the compositor received.
	desktop_change_waits = false
	for &client in clients {
		client.present_waits = false
	}
	spent := system.nanoseconds() - start
	if palette_is_open() {
		palette_frames += 1
		palette_time += spent
		palette_frame_drawn() // The screen shows the chosen entry: Enter runs it.
	}
	if dragging >= 0 {
		move_frames += 1
		move_time += spent
		move_longest = max(move_longest, spent)
	}
	pointer_frame_end()
	if full_measure {
		full_measure = false
		system.log_in("surfaces", .Info, "compositor: a full frame of ", u64(screen.width), "x", u64(screen.height), " with ", u64(order_count), " windows in ", spent / 1000, " us")
	}
}

// draw_areas draws all that is in the damage rectangles of the screen, then
// copies each to the screen. The steps go in phases over all the
// rectangles: the background, the draw table of the screen, the palette,
// then the pointer and the copy. One rectangle with all its steps after the
// other gives the same pixels, because no two damage rectangles touch
// (damage_rectangle_add) and each step writes only inside its rectangle:
// the phases let the drawing module take all the rectangles of a part in
// one call.
draw_areas :: proc "contextless" (areas: []Rectangle) {
	for area in areas {
		canvas := graphics.view(frame, area.left, area.top, area.right - area.left, area.bottom - area.top)
		graphics.copy(canvas, -area.left, -area.top, background)
	}

	// The windows, the bar and the menus: one draw table for the frame
	// (screen_build), each record cut to each area. The drawing module
	// draws in the coordinates of its canvas: the canvas is the whole
	// frame, so the records stay in the coordinates of the screen.
	screen_draw(areas)

	if palette_is_open() {
		rectangles: [DAMAGE_CAPACITY]interface.Rectangle
		count := rectangles_of_areas(areas, rectangles[:])
		screen_draw_part(&palette_now, 0, palette_now.record_count, nil, frame, rectangles[:count])
	}

	for area in areas {
		canvas := graphics.view(frame, area.left, area.top, area.right - area.left, area.bottom - area.top)
		pointer_draw(canvas, -area.left, -area.top) // pointer_picture.odin
	}
	screen_put(areas)
}

// screen_put puts the frame in memory on the screen. With one screen page,
// it copies the damage rectangles into the page that the display shows.
// With two, it copies the damage rectangles and the debt of the hidden page
// into that page, then flips: the display shows the frame whole, and the
// page that it showed owes the damage of this frame. A page that is not
// known (the start, a refused flip) is copied whole.
screen_put :: proc "contextless" (areas: []Rectangle) {
	if screen_page_count < bochs_display.PAGE_COUNT {
		for area in areas {
			screen_copy(screen_pages[0], area)
		}
		frames_on_the_shown_page += 1
		return
	}
	hidden := 1 - screen_page_shown
	changed, copied, owed_by_the_shown_page: interface.Damage
	for area in areas {
		interface.damage_add(&changed, {area.left, area.top, area.right, area.bottom})
	}
	interface.damage_of_picture(&screen_page_debts, hidden, &changed, {0, 0, screen.width, screen.height}, &copied, &owed_by_the_shown_page)
	for rectangle in copied.rectangles[:copied.count] {
		screen_copy(screen_pages[hidden], {rectangle.left, rectangle.top, rectangle.right, rectangle.bottom})
	}
	if !bochs_display.page_show(display_registers, hidden, screen.height) {
		// The device kept another offset: it shows no page that this
		// service knows. The page 0 then takes each frame, as with no
		// device, from this whole frame on.
		system.log("compositor: the display refused the page flip to the screen page ", u64(hidden), ": each later frame is written into the screen page 0, which the display shows")
		bochs_display.page_show(display_registers, 0, screen.height)
		screen_page_count, screen_page_shown = 1, 0
		screen_copy(screen_pages[0], {0, 0, screen.width, screen.height})
		frames_on_the_shown_page += 1
		return
	}
	page_flips += 1
	screen_page_shown = hidden
	interface.picture_debts_after(&screen_page_debts, hidden, &changed, true)
}

// screen_copy copies a rectangle of the frame in memory into a screen page,
// in the order of the bytes of the screen.
screen_copy :: proc "contextless" (page: graphics.Canvas, area: Rectangle) {
	width, height := area.right - area.left, area.bottom - area.top
	canvas := graphics.view(frame, area.left, area.top, width, height)
	target := graphics.view(page, area.left, area.top, width, height)
	if !red_first {
		graphics.copy(target, 0, 0, canvas)
		return
	}
	for y in 0 ..< height {
		for column in 0 ..< width {
			color := canvas.pixels[y * canvas.stride + column]
			target.pixels[y * target.stride + column] = color >> 16 & 0xFF | color & 0xFF00 | (color & 0xFF) << 16
		}
	}
}

// rectangles_of_areas gives the areas of the screen as rectangles of the
// interface package, at most as many as rectangles holds.
rectangles_of_areas :: proc "contextless" (areas: []Rectangle, rectangles: []interface.Rectangle) -> (count: int) {
	for area in areas {
		if count == len(rectangles) {
			break
		}
		rectangles[count] = {area.left, area.top, area.right, area.bottom}
		count += 1
	}
	return count
}

// frame_records appends the frame of a window as draw records of the
// interface package: the title bar with its gradient and its lighter top
// line, the borders, the title, the close button (docs/DESIGN.md, section
// 9). By hand the same frame of 800 x 600 took 8.5 us, as 9 records 8.9 us
// (one measure run, docs/INTERFACE.md, section 12).
frame_records :: proc "contextless" (table: ^interface.Draw_Table, client: ^Client, x, y: int, focus, pointer_over: bool) {
	outer_width := client.surface.width + 2 * BORDER
	outer_height := client.surface.height + TITLE_HEIGHT + BORDER
	start := graphics.Color(focus ? graphics.colors.title : graphics.colors.title_quiet)
	end := graphics.Color(focus ? graphics.colors.title_end : graphics.colors.title_quiet_end)
	interface.draw_horizontal_gradient(table, x, y, outer_width, 1, graphics.shade(start, 125), graphics.shade(end, 125))
	interface.draw_horizontal_gradient(table, x, y + 1, outer_width, TITLE_HEIGHT - 1, start, end)
	interface.draw_horizontal_gradient(table, x, y + outer_height - BORDER, outer_width, BORDER, start, end)
	interface.draw_rectangle(table, x, y + TITLE_HEIGHT, BORDER, outer_height - TITLE_HEIGHT - BORDER, start)
	interface.draw_rectangle(table, x + outer_width - BORDER, y + TITLE_HEIGHT, BORDER, outer_height - TITLE_HEIGHT - BORDER, end)
	// The title: a name, cut in its font to the room before the close button.
	title := interface.text_fit(table, interface.FONT_INTERFACE, system.name_of(client.title[:]), outer_width - CLOSE_SIZE - 16)
	interface.draw_text(table, x + 8, y + 4, title, focus ? graphics.COLOR_WHITE : graphics.colors.dim, interface.FONT_INTERFACE)
	base := graphics.Color(graphics.colors.stop_program_quiet)
	cross_color := graphics.Color(graphics.colors.stop_program_quiet_mark)
	if focus || pointer_over {
		base = pointer_over ? graphics.colors.stop_program_pointer_over : graphics.colors.stop_program
		cross_color = graphics.COLOR_WHITE
	}
	close_x := x + outer_width - BORDER - CLOSE_SIZE
	interface.draw_vertical_gradient(table, close_x, y, CLOSE_SIZE, TITLE_HEIGHT, graphics.shade(base, 118), graphics.shade(base, 82))
	interface.draw_rectangle(table, close_x, y, CLOSE_SIZE, 1, graphics.shade(base, 150))
	interface.draw_character(table, close_x + (CLOSE_SIZE - graphics.CELL_WIDTH) / 2, y + (TITLE_HEIGHT - graphics.CELL_HEIGHT) / 2, 'x', cross_color)
}

// title_measure measures three forms of the title bar of the widest window
// on the frame, before the first frame: one color, as before the gradient;
// the gradient with a mix for each pixel; the gradient as one row of colors
// that each line copies. The log has the time of each.
title_measure :: proc "contextless" () {
	ROUNDS :: 64
	width := min(screen.width, len(title_row))
	times: [3]u64
	for form in 0 ..< 3 {
		start := system.nanoseconds()
		for _ in 0 ..< ROUNDS {
			switch form {
			case 0:
				graphics.fill(frame, 0, 0, width, TITLE_HEIGHT, graphics.colors.title)
			case 1:
				for line in 0 ..< TITLE_HEIGHT {
					for column in 0 ..< width {
						frame.pixels[line * frame.stride + column] = graphics.mix(graphics.colors.title, graphics.colors.title_end, u32(column * 255 / (width - 1)))
					}
				}
			case 2:
				graphics.gradient(title_row[:width], graphics.colors.title, graphics.colors.title_end, width, 0)
				graphics.copy(frame, 0, 0, {pixels = raw_data(title_row[:]), width = width, height = TITLE_HEIGHT})
			}
		}
		times[form] = (system.nanoseconds() - start) / ROUNDS
	}
	system.log_in("surfaces", .Info, "compositor: a title bar of ", u64(width), " pixels: one color ", times[0] / 1000, ".", times[0] / 100 % 10, " us, a mix for each pixel ", times[1] / 1000, ".", times[1] / 100 % 10, " us, one row of colors then copies ", times[2] / 1000, ".", times[2] / 100 % 10, " us")
}

// close_button_under_pointer gives the client whose close button is under
// the pointer, or nil: the button of the window in front at that place.
close_button_under_pointer :: proc "contextless" () -> ^Client {
	for position := order_count - 1; position >= 0; position -= 1 {
		client := &clients[order[position]]
		outer_width := client.surface.width + 2 * BORDER
		if !inside(pointer_x, pointer_y, client.x, client.y, outer_width, client.surface.height + TITLE_HEIGHT + BORDER) {
			continue
		}
		if inside(pointer_x, pointer_y, client.x + outer_width - BORDER - CLOSE_SIZE, client.y, CLOSE_SIZE, TITLE_HEIGHT) {
			return client
		}
		return nil
	}
	return nil
}

// memory_measure measures copy_bytes_without_overlap and fill_bytes_with_value
// (src/runtime/memory.asm; the compiler calls them as memcpy and memset) on the two
// canvases of the screen, before the first frame, for the sizes where the
// forms change, aligned and 3 bytes after an alignment of 64; and a loop of
// 16 bytes written in Odin, the form that graphics.copy had before. The log
// has the time of one call in nanoseconds, and what the processor says of
// its string instructions (CPUID leaf 7: ERMS, FSRM).
memory_measure :: proc "contextless" () {
	SIZES :: [?]int{8, 64, 512, 4096, 65536, 3 << 20 - 128} // The last one: a frame, less the offsets of the measure.
	to := ([^]u8)(frame.pixels)
	from := ([^]u8)(background.pixels)
	limit := min(frame.width * frame.height, background.width * background.height) * size_of(graphics.Color)
	intrinsics.mem_zero(to, limit) // The first use of each page, before the measure.
	Form :: enum {
		Copy,
		Copy_Unaligned,
		Loop,
		Loop_Unaligned,
		Fill,
		Fill_Unaligned,
	}
	tenths: [Form][len(SIZES)]u64 // Tenths of a nanosecond for one call.
	for form in Form {
		for size, index in SIZES {
			offset := form == .Copy_Unaligned || form == .Loop_Unaligned || form == .Fill_Unaligned ? 3 : 0
			count := min(size, limit - 128)
			rounds := clamp(64 << 20 / max(count, 64), 8, 100_000)
			start := system.nanoseconds()
			for _ in 0 ..< rounds {
				switch form {
				case .Copy, .Copy_Unaligned:
					intrinsics.mem_copy_non_overlapping(&to[offset], &from[64 + offset], count)
				case .Loop, .Loop_Unaligned:
					loop_copy(&to[offset], &from[64 + offset], count)
				case .Fill, .Fill_Unaligned:
					intrinsics.mem_zero(&to[offset], count) // A call of memset with 0.
				}
			}
			tenths[form][index] = (system.nanoseconds() - start) * 10 / u64(rounds)
		}
	}
	names := [Form]string {
		.Copy           = "compositor: copy_bytes_without_overlap, ns for 8 64 512 4096 65536 3145600 bytes, aligned:",
		.Copy_Unaligned = "compositor: copy_bytes_without_overlap, not aligned:",
		.Loop           = "compositor: a loop of 16 bytes, aligned:",
		.Loop_Unaligned = "compositor: a loop of 16 bytes, not aligned:",
		.Fill           = "compositor: fill_bytes_with_value, aligned:",
		.Fill_Unaligned = "compositor: fill_bytes_with_value, not aligned:",
	}
	for form in Form {
		line: [256]u8
		count := copy(line[:], names[form])
		for value in tenths[form] {
			count += len(system.format(line[count:], " ", value / 10, ".", value % 10))
		}
		system.log_in("surfaces", .Info, string(line[:count]))
	}
	_, ebx, _, edx := intrinsics.x86_cpuid(7, 0)
	system.log_in("surfaces", .Info, "compositor: the processor: ERMS ", ebx >> 9 & 1 != 0 ? "yes" : "no", ", FSRM ", edx >> 4 & 1 != 0 ? "yes" : "no")
}

// loop_copy copies count bytes 16 at a time, with no call of memcpy: the
// form of graphics.copy before src/runtime/memory.asm, kept for the measure.
// The store is volatile, so that the compiler does not make the loop a
// call of memcpy.
loop_copy :: proc "contextless" (to, from: [^]u8, count: int) {
	Block :: #simd[16]u8
	index := 0
	for ; index + 16 <= count; index += 16 {
		intrinsics.volatile_store((^[16]u8)(&to[index]), transmute([16]u8)intrinsics.unaligned_load((^Block)(&from[index])))
	}
	for ; index < count; index += 1 {
		to[index] = from[index]
	}
}

// The draw table of the screen: for each window, from the back to the front,
// its frame and its surface (a Picture record), then the bar and the menus.
// The compositor builds it once for each frame and draws it in each damage
// area. The palette has its own table; the pointer is drawn after both.
screen_records: [512]interface.Draw_Record
screen_text: [8192]u8
screen_table := interface.Draw_Table{}

// A part of the screen table: the records of one window, or of the bar and
// its menus, and the one picture memory that their Picture record names as
// number 0. Each surface is a memory object of another program, mapped at
// its own address, and a call of the drawing module takes one picture
// memory: so the compositor draws each part with a call of its own.
Screen_Part :: struct {
	first, count:   int, // The records of the part in screen_table.
	picture_memory: []graphics.Color, // The surface of the window, the heron of the bar, or none.
	// The rectangle of the screen that holds each pixel of the part: the
	// outer rectangle of a window. A damage rectangle that it does not meet
	// needs no call. The part of the bar holds the menus, and has no bound.
	bounds:         Rectangle,
	bounded:        bool,
}

// The parts of the screen: one for each window, then one for the bar.
screen_parts: [CLIENT_CAPACITY + 1]Screen_Part
screen_part_count: int
// The list of one picture memory that the table has while it appends the
// Picture record of one part: the record then names memory 0.
screen_picture_memory: [1][]graphics.Color
// The drawing module refused a call of the compositor: the line of the log
// is written one time, as the cause is in the compositor and each frame has it.
screen_refusal_logged: bool

// The heron of the bar (docs/DESIGN.md, "The mark"). Its gradients are
// computed once, at the start, into this picture; each frame shows it with
// a Picture record, a copy of 24 rows. Its generation never changes, so the
// difference of two frames never finds it changed.
BAR_MARK_GENERATION :: 1
bar_mark_pixels: [bar.MARK_SIZE * bar.MARK_SIZE]graphics.Color
bar_mark_picture: graphics.Canvas

// bar_background_records appends the surface of the bar, with its corner
// at (x, y): its gradient and the line under it.
bar_background_records :: proc "contextless" (table: ^interface.Draw_Table, x, y, width: int) {
	interface.draw_vertical_gradient(table, x, y, width, BAR_HEIGHT - 1, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_rectangle(table, x, y + BAR_HEIGHT - 1, width, 1, graphics.colors.track)
}

// bar_mark_build draws the heron of the bar into its picture. A picture has
// no transparency, so the picture first gets the pixels of the bar under the
// heron, from the same records and the same code that draw the bar: an empty
// cell of the heron then shows exactly the bar around it. The drawing module
// draws in the coordinates of the canvas, so the records of the bar start at
// the corner of the screen as the picture sees it.
bar_mark_build :: proc "contextless" () {
	bar_mark_picture = {pixels = raw_data(bar_mark_pixels[:]), width = bar.MARK_SIZE, height = bar.MARK_SIZE, stride = bar.MARK_SIZE}
	records: [4]interface.Draw_Record
	table := interface.Draw_Table{records = records[:]}
	bar_background_records(&table, -bar.MARK_X, -bar.MARK_Y, bar.MARK_X + bar.MARK_SIZE)
	whole_picture := [1]interface.Rectangle{{0, 0, bar.MARK_SIZE, bar.MARK_SIZE}}
	screen_draw_part(&table, 0, table.record_count, nil, bar_mark_picture, whole_picture[:])
	// The mark of the bar is a small icon, one pixel for a cell: the cells
	// variant. On the light bar it has the colors of the light background,
	// as the mark of the bar of the light page of the site.
	mark.mark_draw(bar_mark_picture, 0, 0, bar.MARK_CELL_SIZE, .Cells, graphics.appearance == .Light)
}

// background_build draws the background of the rules into its canvas: one
// color, and a grid of points. The compositor draws it once at its start,
// and again at each change of the appearance.
background_build :: proc "contextless" () {
	background_appearance = graphics.appearance
	graphics.clear(background, graphics.colors.background)
	for y := graphics.POINT_STEP / 2; y < background.height; y += graphics.POINT_STEP {
		for x := graphics.POINT_STEP / 2; x < background.width; x += graphics.POINT_STEP {
			graphics.fill(background, x, y, graphics.POINT_SIZE, graphics.POINT_SIZE, graphics.colors.point)
		}
	}
}

// screen_draw_part draws the records first ..< first + count of a table
// that touch each rectangle of a canvas, over the pixels that the canvas
// has, with one call of the drawing module for all the rectangles. A
// refusal draws nothing, and writes one line on the log for the life of
// the compositor.
screen_draw_part :: proc "contextless" (table: ^interface.Draw_Table, first, count: int, picture_memory: []graphics.Color, canvas: graphics.Canvas, rectangles: []interface.Rectangle) {
	refused: errors.Error_Record
	if interface.draw_part_through_module(table, first, count, picture_memory, canvas, rectangles, false, 0, &refused) || screen_refusal_logged {
		return
	}
	screen_refusal_logged = true
	system.log_in("surfaces", .Warning, "compositor: the drawing module refused execute_draw_table_in_rectangles_10 (the error kind ", u64(max(refused.kind, 0)), ", the argument ", u64(max(refused.argument, 0)), "): the part of the screen is not drawn. The compositor writes this line one time")
}

// screen_draw draws the parts of the screen table into the frame, from the
// back to the front: one call of the drawing module for each part that
// meets an area, with the areas that it meets. The order of the calls is
// the order of the records, so the pixels are those of one draw of the
// whole table in each area.
screen_draw :: proc "contextless" (areas: []Rectangle) {
	for part in screen_parts[:screen_part_count] {
		rectangles: [DAMAGE_CAPACITY]interface.Rectangle
		count := 0
		for area in areas {
			if count == len(rectangles) {
				break
			}
			if part.bounded && (part.bounds.right <= area.left || area.right <= part.bounds.left || part.bounds.bottom <= area.top || area.bottom <= part.bounds.top) {
				continue
			}
			rectangles[count] = {area.left, area.top, area.right, area.bottom}
			count += 1
		}
		if count > 0 {
			screen_draw_part(&screen_table, part.first, part.count, part.picture_memory, frame, rectangles[:count])
		}
	}
}

// screen_part_end ends the part that started at the record first.
@(private = "file")
screen_part_end :: proc "contextless" (first: int, picture_memory: []graphics.Color, bounds: Rectangle, bounded: bool) {
	screen_parts[screen_part_count] = {first = first, count = screen_table.record_count - first, picture_memory = picture_memory, bounds = bounds, bounded = bounded}
	screen_part_count += 1
}

// screen_picture_append appends the Picture record of one part: the table
// has, for this record only, the list of its one picture memory.
@(private = "file")
screen_picture_append :: proc "contextless" (x, y: int, picture: graphics.Canvas, memory: []graphics.Color, generation: u32) {
	screen_picture_memory[0] = memory
	screen_table.picture_memories = screen_picture_memory[:]
	interface.draw_picture(&screen_table, x, y, picture, generation)
	screen_table.picture_memories = nil
	screen_picture_memory[0] = nil
}

// screen_build builds the draw table of the screen, in its parts.
// interface_font: the interface font of the names, or nil for the font of
// the cells (the measure of bar_measure compares the two).
screen_build :: proc "contextless" (now: u64, interface_font: ^display.Interface_Font) {
	// A memory of a window that closed is never named again: a new
	// mapping can have its address.
	screen_parts = {}
	screen_part_count = 0
	screen_table = {records = screen_records[:], text = screen_text[:], interface_font = interface_font}
	table := &screen_table
	pointer_close := close_button_under_pointer()
	for position in 0 ..< order_count {
		client := &clients[order[position]]
		focus := position == order_count - 1
		first := table.record_count
		frame_records(table, client, client.x, client.y, focus, client == pointer_close)
		// A window shows a picture that its program presented, or none:
		// before the first Present, the program draws in the memory of
		// the surface, and the window has the background color.
		memory: []graphics.Color
		if client.presents > 0 {
			memory = client.surface.pixels[:client.surface.stride * client.surface.height]
			screen_picture_append(client.x + BORDER, client.y + TITLE_HEIGHT, client.surface, memory, 0)
		} else {
			interface.draw_rectangle(table, client.x + BORDER, client.y + TITLE_HEIGHT, client.surface.width, client.surface.height, graphics.colors.background)
		}
		outer := Rectangle{client.x, client.y, client.x + client.surface.width + 2 * BORDER, client.y + client.surface.height + TITLE_HEIGHT + BORDER}
		screen_part_end(first, memory, outer, true)
	}

	// The bar: the mark of the system, the two buttons, the date and the time
	// of day (the time since boot when the system has no date).
	bar_first := table.record_count
	width := frame.width
	bar_background_records(table, 0, 0, width)
	screen_picture_append(bar.MARK_X, bar.MARK_Y, bar_mark_picture, bar_mark_pixels[:], BAR_MARK_GENERATION)
	bar_button_records :: proc "contextless" (table: ^interface.Draw_Table, x, y, width, height: int, label: string, open: bool) {
		interface.draw_rectangle(table, x, y, width, height, open ? graphics.colors.chosen : graphics.colors.track)
		interface.draw_text(table, x + bar.PADDING, y + (height - graphics.CELL_HEIGHT) / 2, label, open ? graphics.COLOR_WHITE : graphics.colors.text, interface.FONT_INTERFACE)
	}
	left, top, button_width, button_height := bar.button(bar_layout)
	bar_button_records(table, left, top, button_width, button_height, bar.LABEL, menu_open == .Programs)
	left, top, button_width, button_height = bar.windows_button(bar_layout)
	bar_button_records(table, left, top, button_width, button_height, bar.WINDOWS_LABEL, menu_open == .Windows)
	// The hint of the palette: a name, in the interface font, measured in
	// its two parts as they are drawn.
	hint_width := interface.text_measured_width(table, interface.FONT_INTERFACE, PALETTE_HINT_NAME) + interface.text_measured_width(table, interface.FONT_INTERFACE, PALETTE_HINT_KEY)
	hint_x := width - CLOCK_WIDTH - 32 - hint_width
	interface.draw_text(table, interface.draw_text(table, hint_x, 8, PALETTE_HINT_NAME, graphics.colors.dim, interface.FONT_INTERFACE), 8, PALETTE_HINT_KEY, graphics.colors.text, interface.FONT_INTERFACE)
	seconds := now / 1000
	x := width - CLOCK_WIDTH - 16
	if milliseconds, known := date.milliseconds_now(date_page, now); known {
		// The local time: the date of UTC and the time zone of the date
		// page (src/md/features/time_zone.md).
		zone := date.zone_offset_seconds_read(date_page)
		date_text: [24]u8
		shown := calendar.iso_text(date_text[:], milliseconds / 1000 + zone)
		interface.draw_text(table, x, 8, shown, graphics.colors.text)
		if zone != bar_zone_logged {
			bar_zone_logged = zone
			zone_buffer: [settings.ZONE_TEXT_SIZE]u8
			system.log("compositor: the bar shows the local time ", shown, " with the time zone ", settings.zone_text(zone_buffer[:], i32(zone / 60)), ", at ", milliseconds / 1000, " s since 1970")
		}
	} else {
		x += CLOCK_WIDTH - 8 * 8
		x = interface.draw_unsigned(table, x, 8, seconds / 3600, graphics.colors.text, 2)
		x = interface.draw_text(table, x, 8, ":", graphics.colors.dim)
		x = interface.draw_unsigned(table, x, 8, seconds / 60 % 60, graphics.colors.text, 2)
		x = interface.draw_text(table, x, 8, ":", graphics.colors.dim)
		interface.draw_unsigned(table, x, 8, seconds % 60, graphics.colors.text, 2)
	}

	// The menus of the bar, as cards of the package.
	card_frame := interface.Frame{table = table}
	count: interface.Text_Builder
	if menu_open == .Windows && order_count > 0 {
		menu_left, menu_top, menu_width, menu_height := bar.windows_menu(bar_layout, order_count)
		interface.card(&card_frame, {menu_left, menu_top, menu_width, menu_height}, "WINDOWS", "the client table", graphics.colors.kernel, interface.number_text(&count, u64(order_count)))
		for line in 0 ..< order_count {
			index := window_of_line(line)
			if index < 0 {
				break
			}
			line_x, line_y, line_width, line_height := bar.windows_line(bar_layout, line)
			focus := index == order[order_count - 1]
			if line == menu_line {
				interface.draw_rectangle(table, line_x, line_y, line_width, line_height, graphics.colors.chosen)
			}
			if focus {
				// The window that has the focus: a square, and its title in white.
				interface.draw_rectangle(table, line_x + 8, line_y + 8, 8, 8, line == menu_line ? graphics.COLOR_WHITE : graphics.colors.title)
			}
			// A disk program keeps the room of its hash prefix at the end of
			// the line: the nickname ends before it.
			room := line_width - bar.WINDOWS_TITLE_X - bar.PADDING
			if clients[index].from_disk {
				room -= bar.WINDOWS_HASH_GAP + interface.text_measured_width(table, {}, string(clients[index].hash_prefix[:]))
			}
			title := interface.text_fit(table, interface.FONT_INTERFACE, system.name_of(clients[index].title[:]), room)
			title_end := interface.draw_text(table, line_x + bar.WINDOWS_TITLE_X, line_y + 4, title, focus || line == menu_line ? graphics.COLOR_WHITE : graphics.colors.text, interface.FONT_INTERFACE)
			if clients[index].from_disk {
				// A value, in the font of the cells, faded: the name is the
				// nickname, and the prefix only tells two files apart.
				interface.draw_text(table, title_end + bar.WINDOWS_HASH_GAP, line_y + 4, string(clients[index].hash_prefix[:]), graphics.colors.dim)
			}
		}
	}
	if menu_open == .Programs {
		menu_left, menu_top, menu_width, menu_height := bar.menu(bar_layout)
		interface.card(&card_frame, {menu_left, menu_top, menu_width, menu_height}, "PROGRAMS", "bar.names", graphics.colors.kernel, interface.number_text(&count, len(bar.names)))
		for name, index in bar.names {
			line_x, line_y, line_width, line_height := bar.line(bar_layout, index)
			if index == menu_line {
				interface.draw_rectangle(table, line_x, line_y, line_width, line_height, graphics.colors.chosen)
			}
			interface.draw_text(table, line_x + bar.PADDING, line_y + 4, name, index == menu_line ? graphics.COLOR_WHITE : graphics.colors.text, interface.FONT_INTERFACE)
		}
	}
	screen_part_end(bar_first, bar_mark_pixels[:], {}, false)
	if table.full {
		system.log_in("surfaces", .Warning, "compositor: the draw table of the screen is full: records are missing")
	}
}

// window_frame_of gives the frame that the compositor draws around the
// surface of a client, for the places of src/library/private/compositor/bar.
window_frame_of :: proc "contextless" (client: ^Client) -> bar.Window_Frame {
	return {outer_width = client.surface.width + 2 * BORDER, border = BORDER, close_size = CLOSE_SIZE, title_height = TITLE_HEIGHT}
}

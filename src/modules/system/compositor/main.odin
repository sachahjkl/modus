// The compositor (docs/ARCHITECTURE.md, "U8. Graphics: the draw table and the compositor"): the service that owns the
// display. It combines the surfaces of processes into the framebuffer, and it
// sends input to the process that has focus. It is also the desktop shell of
// this first version: a bar with the start menu and the menu of
// the windows, and windows that the input moves. It follows the design
// rules (docs/DESIGN.md): rectangles only, the spacing tokens, the colors
// of src/library/modus/graphics.
//
// **What it is for.** No process writes to the screen. A process asks the
// compositor for a [surface](term:surface): memory that the process and the
// compositor share. The process draws into it and sends `Present`; the
// compositor copies the changed rectangle into its frame, then the frame to
// the screen page that the display does not show, and flips
// (src/md/infrastructure/whole_frame.md). The compositor is the only holder of the framebuffer and
// of the ring of the [input service](term:input-service), so no process
// reads the keys of another window or draws over it.
//
// **What a reader sees.** The whole screen: the background with its grid
// of points, the [bar](term:bar) at the top (the
// [start menu](term:start-menu), the
// [menu of the windows](term:menu-of-the-windows), the hint of the
// [palette](term:palette), the date and the time), the windows with their
// [title bar](term:title-bar) and their close button, and the
// [pointer](term:pointer). The input can:
//
// - press a line of the start menu: the compositor asks the root
//   service to start that module;
// - press the key super: the palette opens; typed letters narrow one list
//   of the modules and of the windows, and Enter starts the chosen
//   module or brings the chosen window to the front (palette.odin);
// - drag a title bar: the window moves; a press on a window brings it to the
//   front and gives it the [focus](term:focus);
// - drag an edge or a corner of a
//   [resizable window](term:resizable-window): its process draws it at
//   the new size (window_resize.odin);
// - press Control+C and Control+V: the [clipboard](term:clipboard) copies
//   from the window in front and pastes into it (clipboard.odin);
// - press the close button: the root service stops the process.
//
// The keys go to the window in front, unless the palette is open.
//
// **Its lines in the log**: `compositor: two screen pages: each frame
// reaches the screen whole, by a page flip` (or `one screen page` on a
// display with no page flip), `compositor: ok <width>x<height>` at the start,
// `compositor: first frame`, then one line for
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
// the other processes: the handles 0 to 2 are the framebuffer, the ring of
// the input service, and a control ring to the root service; on the
// standard VGA of the test machine, the handle 0 holds two
// [screen pages](term:screen-page) and the handle 3 is the memory of the
// registers of the VGA, for the [page flip](term:page-flip); the values 0
// to 3 are the width, the height, the pixels of a line and the pixel format
// of the screen. The root service also maps its own file (for its exports),
// two [pointer themes](term:pointer-theme), the
// [settings page](term:settings-page), the font outlines and the
// [date page](term:date-page). Its row of `start_grant_sets` has the grants
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
// imports as each process with a window does. A call of the module takes
// one picture memory, and each surface is a memory of its own, so the
// screen table is in parts: one for each window, with its surface, and one
// for the bar, with its heron. A damage rectangle is one call for each
// part that it meets (src/md/api/picture.md).
//
// The design of the desktop is in docs/DESIGN.md, "9. The desktop"; the
// pointer is in docs/POINTERS.md.
package compositor

import "modus:bochs_display"
import "modus:display"
import "modus:contract/errors"
import "modus:contract/settings"
import "modus:contract/scale_factor"
import "modus:contract/date"
import "modus:contract/desktop_shell"
import "modus:calendar"
import "modus:graphics"
import "modus:interface"
import "modus:text_rendering"
import "internal:compositor/bar"
import "modus:mark"
import "modus:screen_presence"
import "internal:compositor/palette"
import "internal:compositor/quality"
import clipboard_rules "internal:compositor/clipboard"
import "modus:contract/ring"
import "modus:key_path"
import "modus:system"
import "modus:contract/pointer_pictures"
import "modus:contract/virtio_input"
import process_page "modus:contract/disk_process_page"
import "modus:contract/value_kinds"
import "base:intrinsics"

// Its loop, and the thread that makes the lists of the palette. The
// working memory is the sum of these parts, at the reference screen of
// 1920 x 1080:
// - the frame and the background, each the size of the screen: 2 x 2025
//   pages, and 2 x 5 page tables (8.1 MB need 4 tables of 2 MiB, and one
//   more when the start is not on a 2 MiB edge);
// - the two screen pages: device memory, which costs no page, but 15.8
//   MiB of it need up to 9 page tables;
// - each of these three spans can cross a 1 GiB edge, and then needs a
//   second page directory: 3 pages;
// - the page of the display registers: a page table and a page directory,
//   2 pages;
// - its tables and the other mappings: 1647 pages;
// - the mapping of the surface of each window: the largest surface,
//   display.SURFACE_SCREEN_LIMIT, 4096 x 4096 pixels of the screen (2048
//   logical pixels at the largest scale, 2) of 8 bytes for two pictures,
//   is 128 MiB, whose mapping takes at most 65 page tables of 2 MiB (its
//   start need not be on a 2 MiB edge) and 2 page directories (it can
//   cross a 1 GiB edge): 67 pages. 32 clients: 32 x 67 = 2144 pages. These
//   two parts were the 2255 pages counted at the scale 1, with surfaces of
//   2048 x 2048 and 19 pages each: 2255 - 32 x 19 = 1647;
// - a resize maps the new surface of a window beside its old one until
//   its Present (src/md/features/window_resize.md): one more such mapping
//   for each client, 2144 pages. A rescale holds one surface at a time:
//   the window releases the old one first;
// - the glyph memory of its two copies of the text rendering, its own
//   (its bar, its menus, its titles) and the one of the drawing module:
//   each draws every glyph of its text into its own private glyph cache,
//   and reserves its memory at its first glyph: 2 x 354 pages
//   (display.TEXT_MEMORY_PAGES) = 708 pages.
// 4050 + 10 + 9 + 3 + 2 + 1647 + 2144 + 2144 + 708 = 10717. A screen whose
// frame and background the budget cannot pay is named on one line, and the
// compositor stops (entry).
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 10717, processes = 1, threads = 2}

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
// reads these numbers (tools/modustool/machine/machine.odin, WINDOW_*).
TITLE_HEIGHT :: 24
BORDER :: 2
// A press on the grip of the bottom right corner is a drag of that corner:
// the square of the corner holds the grip and the border beside it.
#assert(bar.CORNER_REACH >= bar.GRIP_SIZE + BORDER)
CLOSE_SIZE :: 24 // The close button: a square at the right end of the title bar.
TITLE_ICON_X :: 8 // The icon of the module in the title bar, from the corner of the frame.
TITLE_TEXT_X :: TITLE_ICON_X + bar.ICON_SIZE + 6 // The title, after the icon.
CLIENT_CAPACITY :: 32 // The root service starts 32 processes at most.
DAMAGE_CAPACITY :: 8
CLOCK_WIDTH :: bar.CLOCK_WIDTH // "2026-11-11 16:30:05", or the time since boot "00:00:00" when the system has no date.

Client :: struct {
	ring_memory: system.Handle, // 0: the slot is free.
	ring:        ring.Ring,
	// The window exists: the process created its surface. It keeps its
	// frame, its place and its line in the menu while a rescale released
	// its surface (src/md/features/window_resize.md, "The rescale").
	created:     bool,
	surface:     graphics.Canvas, // pixels is nil before Surface_Create, and while the surface is released.
	pictures:    [^]graphics.Color, // The memory of the surface: two pictures. surface is one of them. nil with surface.pixels.
	surface_serial: u64, // The surface serial of the surface shown, or of the one released.
	surface_scale: scale_factor.Scale, // The scale at which the process made the surface shown.
	released:    bool, // The process let its surface go: the compositor draws the frame with the background.
	// The window declined this scale with Surface_Declined: its budget does
	// not pay a surface at it. It counts among the windows that declined
	// the scale while that scale is in force and it is released.
	declined:       bool,
	declined_scale: scale_factor.Scale,
	// The fit at a new scale (window_resize.md, "The fit at a new scale"): scale_due holds the scale in force for this window until its
	// fit request ends; fit_due says that the fit to the newest work area is
	// not asked yet; scale_told is the scale of the last Settings_Changed.
	scale_due:  bool,
	fit_due:    bool,
	scale_told: scale_factor.Scale,
	// A fit that grows the window waits for its surface at the new scale
	// (bar.fit_order): window_fit_after_scale takes it.
	fit_after_scale: bool,
	answer_due:  bar.Answer_Slot, // A Surface_Answer that the full ring of the window did not take (window_events.odin).
	shown:       int, // The picture that surface is: the one that the last Present named.
	// The proof that the window shows whole frames: the frames that read a
	// picture of the window, and the Present records that named the
	// picture that the compositor already read. A process that draws in
	// the picture on the screen has no other complete picture to name.
	frames:      u64,
	pictures_drawn_again: u64,
	presents_refused: u64, // The Present records whose picture number names no picture of the surface.
	commands_refused: u64, // The records whose kind names no command, or None: the first one writes a line.
	x, y:        int, // The corner of the frame of the window, in logical pixels of the desktop.
	width, height: int, // The size of the window in logical pixels of the desktop: its surface is these pixels at the scale (scale.odin).
	title:       system.Name,
	icon:        bar.Icon, // The icon of the title: found once, when the window takes its title.
	// A disk process: the root service gave its nickname and the first
	// bytes of the hash of its file in Client_Add. The window has the
	// nickname as its title, and the menu of the windows shows the hash
	// prefix beside it.
	from_disk:   bool,
	nickname:    system.Name,
	hash_prefix: [process_page.HASH_PREFIX_DIGITS]u8,
	pointer_shape: pointer_pictures.Pointer_Shape, // The shape that the process asked for over its surface (pointer_picture.odin).
	pointer_over: bool, // The last pointer event of the process was over its surface, or with a button down: the process gets one event more when the pointer leaves.
	presents:    u64, // The Present records that the process sent since it created its surface.
	present_waits: bool, // A Present changed a part of the screen, and no frame drew it yet.
	picture_due:   bool, // The process said that a change waits for its next picture (display.Command.Picture_Due), and no Present came after.
	// The act names of the window, as the last checked record Act_Names
	// gave them: the palette offers to go there (palette.odin). They go with
	// the window: client_remove clears the slot.
	act_names:   palette.Act_Name_Set,
	act_name_sets_logged: int, // The sets that the log named: the first ACT_NAME_SETS_LOGGED only.
	// A resizable window (src/md/features/window_resize.md): the limits of
	// the last Resizable that the border took. With none, the window is
	// fixed and its edges give no resize.
	resizable:   bool,
	size_limits: display.Size_Limits,
	resizable_refusal_logged: bool, // The line of a refused Resizable is on the log: a window writes it one time.
	// The pending surface: the surface of a new size that the process gave
	// with Surface_Resize, or of a new scale with Surface_Rescale. nil until
	// then, and again from the first Present of its serial, when it becomes
	// the surface of the window. It keeps the logical size and the scale
	// that the compositor checked, so that Present computes nothing again.
	resize_pictures: [^]graphics.Color,
	resize_width, resize_height: int, // Pixels of the screen.
	resize_logical_width, resize_logical_height: int,
	resize_scale: scale_factor.Scale,
	resize_serial: u64,
	resize_pending_edges: bar.Resize_Edges, // The edges that the drag of resize_pictures held: the opposite ones stay in place when the window takes it.
	// The request of the last drag: the compositor sent Resized with this
	// size, and no answer came yet. The one Surface_Resize that it takes
	// is the answer of this size; Resize_Declined ends it too. While it
	// waits, the edges of the window take no new drag.
	resize_asked: bool,
	resize_asked_width, resize_asked_height: int,
	// The request is a clamp to the work area: the compositor cut the size
	// asked, or asked a fixed window, and the window scrolls its layout in
	// the smaller surface (src/md/features/window_scroll.md).
	resize_asked_clamp: bool,
	// The size of the request before the cut to the work area: the window
	// wants it once it takes the request.
	resize_asked_wanted_width, resize_asked_wanted_height: int,
	// The clamps that ended with no new surface, in a row: the compositor
	// asks a clamp again at most CLAMP_ASKS_MOST times (window_resize.odin).
	clamp_asks: int,
	resize_edges: bar.Resize_Edges, // The edges that the drag of the request held.
	// The size of the surface that the window opened with, or that the
	// principal asked last and the window took: the fit to the work area
	// starts from it, so a clamped window gets it back when the work area
	// grows.
	wanted_width, wanted_height: int,
	resizes_refused: u64, // The Surface_Resize and Resize_Declined records that the compositor refused.
	// The measures of the window (quality_measures.odin): the times of its
	// start, from Client_Started and from its first flip; its first picture
	// waits for the flip that shows it; and the newest key serial that it
	// got, past which a Present names no key of it.
	start:           quality.Window_Start,
	start_due:       bool,
	key_serial_sent: u64,
	clipboard: clipboard_rules.Window_State, // What waits for an answer of the process to a key of the clipboard (clipboard.odin).
	clipboard_refused: u64, // The Copy, Copy_Declined and Paste_Taken records that the compositor refused.
	// The process holds the start grant Screen_Capture, as its Client_Add
	// says: the compositor takes the commands of the capture face and of
	// the input face from it (capture.odin).
	capture_allowed: bool,
	minimized:       bool,
	maximized:       bool,
	// The place and the size of a maximized window before its maximize: the
	// second toggle gives them back.
	saved_x, saved_y: int,
	saved_width, saved_height: int,
	// A restore came while a request of the window waited for its answer:
	// the saved size is asked when that request ends.
	restore_size_due: bool,
	decoration:      desktop_shell.Window_Decoration,
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
frame_memory_handle: system.Handle
background: graphics.Canvas
background_appearance: graphics.Appearance // The appearance of the pixels of `background` and of the mark of the bar.
clients: [CLIENT_CAPACITY]Client
order: [CLIENT_CAPACITY]int // The clients that have a surface, from back to front. The last one has focus.
order_count: int
// The same clients in the order in which their windows opened: the plates
// of the bar keep it, so a change of the focus moves no plate.
opened: [CLIENT_CAPACITY]int
opened_count: int
input: ring.Ring
control: ring.Ring
pointer_x, pointer_y: int
buttons: u32
dragging := -1
// The press that started the drag of a title: a maximized window gives back
// its size of before only once the pointer leaves it.
drag_press_x, drag_press_y: int
// The last press on a title bar, the first of a double press.
title_double_press: bar.Double_Press
// A menu of the bar.
Menu :: enum {
	None,
	Start, // The start menu: a press on a line starts the module.
	Windows, // One line for each window, in the order of the client table: a press brings the window to the front.
}

menu_open: Menu // The menu that is on the screen.
menu_line := -1 // The line of the menu under the pointer.
menu_action: bar.Start_Action // The quick action of the start menu under the pointer.
// The button of the bar under the pointer at the last move: it is drawn
// lit, and a change draws the buttons again.
bar_button_hovered: bar.Bar_Button
drag_x, drag_y: int
// The drag of the edges of a window: the client, or -1. The compositor
// draws the outline of the new frame until the release, then sends the
// event Resized (src/md/features/window_resize.md).
resizing := -1
resize_start: bar.Resize_Start
resize_outline: Rectangle // The new frame, as the outline shows it.
RESIZE_OUTLINE_THICKNESS :: 2
damage: [DAMAGE_CAPACITY]Rectangle // The parts of the screen that the next frame draws again.
damage_count: int
frames: u64
presents: u64 // The Present records of all the processes since the start.
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
// layout, in logical pixels: each change but the Present of a process. The
// damage is kept in pixels of the screen (scale.odin).
damage_add :: proc "contextless" (x, y, width, height: int) {
	area := screen_rectangle_of(x, y, width, height)
	damage_screen_add(area.left, area.top, area.right - area.left, area.bottom - area.top)
}

// damage_screen_add records a change of the desktop in pixels of the
// screen: the pointer picture, and the whole screen.
damage_screen_add :: proc "contextless" (x, y, width, height: int) {
	if damage_rectangle_add(x, y, width, height) {
		desktop_change_waits = true
	}
}

// damage_whole_screen records the whole screen: also the pixels past the
// last logical pixel, which no record covers and the background does.
damage_whole_screen :: proc "contextless" () {
	damage_screen_add(0, 0, screen.width, screen.height)
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
	if client.created {
		damage_add(client.x, client.y, client.width + 2 * BORDER, client.height + TITLE_HEIGHT + BORDER)
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
	// The card with the demonstrations open holds the closed card: one
	// rectangle covers the menu before and after the action that opens or
	// closes them.
	x, y, width, height = bar.menu(bar.with_demonstrations(layout, true))
	damage_add(x, y, width, height)
	x, y, width, height = bar.windows_button(layout)
	damage_add(x, y, width, height)
	x, y, width, height = bar.windows_menu(layout, bar.WINDOWS_MENU_ROW_CAPACITY) // A window or a grant can leave while the menu is open.
	damage_add(x, y, width, height)
}

// The texts that the compositor draws itself follow the rule of the two
// fonts (docs/DESIGN.md, section 5): the names (the buttons of the bar, the
// lines of the menus, the titles of the windows, the names of the
// palette, a hint) in the interface font; the values (the clock, the date,
// the text that the input types, a count) in the font of the cells. The
// interface font is the one of src/library/modus/display (interface_font_load); with
// none, or with the setting Spleen 8x16, each text is in the font of the
// cells with the same layout rules.
bar_layout: bar.Layout
bar_layout_known: bool
bar_in_interface_font: bool

// bar_measure writes once in the log the time of one whole frame of the
// bar with the start menu open, built and drawn, in the font of
// the cells and in the interface font: the least of 20 rounds, so that a
// round that the host stops in its middle does not count. It runs after
// the first frame of a measure run only (start_measures_run), and the
// frame after it draws the whole screen.
bar_measure :: proc "contextless" () {
	ROUNDS :: 20
	font := display.interface_font_of()
	saved_layout, saved_menu := bar_layout, menu_open
	menu_open = .Start
	fonts := [2]^display.Interface_Font{nil, font}
	least := [2]u64{max(u64), max(u64)}
	measured := 0
	for measured_font in fonts {
		if measured == 1 && (font == nil || graphics.text_state.font != .Vector) {
			break
		}
		bar_layout = bar.layout_of(measured_font != nil ? text_rendering.Face.Interface : text_rendering.Face.None)
		_, menu_top, _, menu_height := bar.menu(bar_layout)
		areas := [1]Rectangle{{0, 0, frame.width, screen_pixel_of(max(BAR_HEIGHT, menu_top + menu_height))}}
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
		system.log_fact(.Info, Bar_Measured_Without_Interface_Font{cells_font_time = value_kinds.Nanoseconds_As_Microseconds(least[0])})
		return
	}
	system.log_fact(.Info, Bar_Measured{cells_font_time = value_kinds.Nanoseconds_As_Microseconds(least[0]), interface_font_time = value_kinds.Nanoseconds_As_Microseconds(least[1])})
}

// bar_layout_update measures the bar in the font that draws it now, and
// writes in the log which font it is when it changes: the modus tool reads
// that line to find the places of the bar. The places of the old and of
// the new layout are damaged.
bar_layout_update :: proc "contextless" () {
	font := display.interface_font_of()
	in_interface_font := font != nil && graphics.text_state.font == .Vector
	layout := bar.placed(bar.layout_of(in_interface_font ? text_rendering.Face.Interface : text_rendering.Face.None), bar_edge_of(desktop_bar_position), desktop_height)
	if bar_layout_known && layout == bar_layout && in_interface_font == bar_in_interface_font {
		return
	}
	// A move of the bar alone writes no line: the line says the font and the
	// widths that the modus tool measures, and a move changes neither.
	measured_again := !bar_layout_known || in_interface_font != bar_in_interface_font || bar.placed(layout, .Top, 0) != bar.placed(bar_layout, .Top, 0)
	if bar_layout_known {
		damage_menu_of(bar_layout)
		damage_bar()
	}
	bar_layout, bar_layout_known, bar_in_interface_font = layout, true, in_interface_font
	damage_bar()
	damage_menu_of(bar_layout)
	if !measured_again {
		return
	}
	if in_interface_font {
		system.log_fact(.Info, Bar_In_Interface_Font{name_width = u64(layout.longest_name_width)})
	} else {
		system.log_fact(.Info, Bar_In_Cell_Font{})
	}
}

// window_of_line gives the client of a line of the menu of the windows, or -1.
window_of_line :: proc "contextless" (line: int) -> int {
	count := 0
	for &client, index in clients {
		if !client.created {
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
// their order: one fact for each window, "compositor: windows: console,
// the window 1 of 3".
windows_log :: proc "contextless" () {
	windows: u64 = 0
	for &client in clients {
		if client.created {
			windows += 1
		}
	}
	place: u64 = 0
	for &client in clients {
		if !client.created {
			continue
		}
		place += 1
		system.log_fact(.Info, Window_Listed{place = place, windows = windows, window = window_field(client.title[:])})
	}
	// The line of a disk process shows the hash prefix that the root
	// service gave, faded beside its nickname.
	for &client in clients {
		if client.created && client.from_disk {
			system.log_fact(.Info, Disk_Process_In_Menu{hash_prefix = value_kinds.text_field(string(client.hash_prefix[:]), HASH_PREFIX_FIELD_BYTES), window = window_field(client.title[:])})
		}
	}
}

// The bar shows the local date and time of day (src/library/modus/contract/date):
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
	damage_add(bar.clock_x(desktop_width), desktop_bar_y() + bar.CLOCK_TEXT_Y, CLOCK_WIDTH, graphics.CELL_HEIGHT)
}

// damage_bar records each row of the bar, at its edge now.
damage_bar :: proc "contextless" () {
	damage_add(0, desktop_bar_y(), desktop_width, BAR_HEIGHT)
}

canvas_create_with_handle :: proc "contextless" (width, height: int) -> (canvas: graphics.Canvas, handle: system.Handle) {
	pages := (u64(width * height * 4) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	memory, status := system.memory_create(pages, 0, {.Contiguous})
	if status != .Ok {
		memory, status = system.memory_create(pages)
	}
	address: rawptr
	if status == .Ok {
		address, status = system.memory_map(memory)
	}
	if status != .Ok {
		system.log_fact(.Info, No_Memory{})
		system.stop(.Failed)
	}
	return {pixels = ([^]graphics.Color)(address), width = width, height = height, stride = width}, memory
}

canvas_create :: proc "contextless" (width, height: int) -> graphics.Canvas {
	memory, status := system.memory_create((u64(width * height * 4) + system.PAGE_SIZE - 1) / system.PAGE_SIZE)
	address: rawptr
	if status == .Ok {
		address, status = system.memory_map(memory)
	}
	if status != .Ok {
		system.log_fact(.Info, No_Memory{})
		system.stop(.Failed)
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
		system.log_fact(.Info, Two_Screen_Pages{})
	} else {
		display_registers = nil
		system.log_fact(.Info, One_Screen_Page{})
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
//    window, opens a menu or starts a process. Before the new records, the
//    records that wait for a window whose ring was full go to it, in order
//    (window_events.odin).
// 4. The ring of each window: `Surface_Create`, `Present` (the changed
//    rectangle becomes damage), `Pointer_Shape`, `Resizable` and
//    `Surface_Resize`.
// 5. The calls of `pointer`, `windows` and `screen`, after the input and
//    after the rings of the windows, so that they give the place of now
//    and count each `Present` that a process sent before the call.
// 6. A frame, at most one each 16 ms, when the screen has damage.
//
// **The stop.** With no framebuffer (modus:screen_presence), the
// compositor writes `compositor: no framebuffer` and stops with `Failed`;
// with no input ring or no control ring, it writes `compositor: no input
// ring or no control ring` and stops with `Failed`. When its budget
// cannot pay the frame and the background of the screen, it writes
// `compositor: a screen of <width>x<height> needs <n> pages, the budget
// holds <m>` and stops with `Failed`. Without the
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
	// The same test as the root service makes before it starts this
	// process: the two never disagree on a screen.
	if !screen_presence.screen_present(status, ctx.values[VALUE_WIDTH], ctx.values[VALUE_HEIGHT]) {
		system.log_fact(.Info, No_Framebuffer{})
		system.stop(.Failed)
	}
	if input_status != .Ok || control_status != .Ok {
		system.log_fact(.Info, No_Input_Or_Control_Ring{})
		system.stop(.Failed)
	}
	screen = {pixels = ([^]graphics.Color)(address), width = width, height = height, stride = int(ctx.values[VALUE_PIXELS_PER_LINE])}
	screen_pages_open(ctx)
	red_first = ctx.values[VALUE_FORMAT] == FORMAT_RED_FIRST
	// The frame and the background have the size of the screen, and the
	// budget is counted at the reference screen: a firmware that kept a
	// larger mode gives a screen that the budget cannot pay. The line names
	// both amounts, and the compositor stops with its code, so the root
	// service runs on with no desktop.
	canvas_pages := (u64(width) * u64(height) * size_of(graphics.Color) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	needed_pages: u64 = 2 * canvas_pages
	budget_left, budget_status := system.budget_read()
	if budget_status != .Ok || budget_left.pages < needed_pages {
		system.log_fact(.Info, Screen_Past_Budget{width = u64(width), height = u64(height), needed_pages = needed_pages, budget_pages = u64(budget_left.pages)})
		system.stop(.Failed)
	}
	frame, frame_memory_handle = canvas_create_with_handle(width, height)
	gpu_scanout_open(ctx, frame_memory_handle, width, height)
	background = canvas_create(width, height)
	// The layout at the default scale until the settings page is read
	// below: a page that the root service created holds it. The first take
	// sets up the features of the desktop at that logical screen.
	desktop_scale_take(settings.choice_default(), true)
	// The background, the mark of the bar and the measures draw in the dark
	// appearance: the settings are read below, and a change of the
	// appearance draws the background and the mark again.
	background_build()
	pointer_x, pointer_y = desktop_width / 2, desktop_height / 2
	bar_mark_build()
	pointer_theme_open(ctx) // pointer_picture.odin
	damage_whole_screen()
	full_measure = true
	system.log_fact(.Info, Compositor_Ready{width = u64(width), height = u64(height)})
	quality_profile_log() // quality_measures.odin
	service_start(ctx) // exports.odin
	// The text of the desktop: the settings of the principal and the font
	// outlines (modus:contract/settings); a change of the settings wakes
	// this loop.
	display.text_settings_open(ctx)
	display.interface_font_load(ctx)
	// What the fallback chains draw past the Latin-1 Supplement, script by
	// script, once at each boot: the log names what no font has.
	display.script_coverage_tell("compositor")
	palette_start() // palette.odin
	bar_layout_update()
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
		first_choice, first_ok := settings.read(display.settings_page)
		if desktop_scale_take(first_choice, first_ok) {
			background_build()
			bar_layout_update()
			damage_whole_screen()
			pointer_drawn_valid = false
			pointer_update(0)
		}
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
		desktop_features_tick(now) // desktop_features.odin
		quality_turn_start() // quality_measures.odin
		if display.settings_page != nil {
			// The root service changes the appearance in force alone, with
			// no new change count, and wakes this loop.
			// A refused page gives the defaults with its count: the windows
			// draw with them, as with a page that never stays stable.
			// The scale is the one setting that a refused page does not
			// set to its default: each window holds a surface of the scale
			// in force, and the desktop keeps it (desktop_scale_take).
			if choice, read_ok := settings.read(display.settings_page); choice.change_count != settings_seen || choice.appearance_in_force != settings_told.appearance_in_force {
				settings_seen = choice.change_count
				choice.scale = bar.scale_after_read(scale, choice.scale, read_ok)
				if !settings_told_once || settings.values_differ(choice, settings_told) {
					settings_told = choice
					settings_told_once = true
					settings_changed(choice)
				}
			}
		}
		for record in system.receive(&control.commands) {
			quality_record_read()
			kind, kind_ok := display.control_of_ring_word(record.kind)
			if !kind_ok {
				system.log_fact(.Info, Control_Word_Refused{word = u64(record.kind)})
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
			case .Client_Started:
				quality_window_started(system.Handle(record.values[0]), record.values[1])
			case .Settings_Raise:
				settings_raise(record.values[0], record.values[1]) // tray_widgets.odin
			case .None, .Start, .Stop, .Appearance_Next:
				// The border refused None above. Start, Stop and
				// Appearance_Next go from the compositor to the root service,
				// never to the compositor.
				system.log_fact(.Info, Control_Command_Not_Taken{word = u64(record.kind)})
			}
		}
		window_events_pass() // The records that wait go before the new ones.
		for record in system.receive(&input.commands) {
			quality_record_read()
			kind, kind_ok := display.input_of_ring_word(record.kind)
			if !kind_ok {
				system.log_fact(.Info, Input_Word_Refused{word = u64(record.kind)})
				continue
			}
			switch kind {
			case .None:
				// The border refused None above.
			case .Key:
				key_records += 1
				character := display.key_character_of(record.values[1])
				switch {
				case window_switcher_key(u32(record.values[0]), record.values[2] != 0, u32(record.values[3])):
					// Alt+Tab, and each key while its card is open: the card
					// holds the keys until the release of Alt, and does not
					// open over a dialog or a menu (window_switcher.odin).
				case powerbox_and_wide_grant_key(u32(record.values[0]), record.values[2] != 0, u32(record.values[3])):
					// Trusted powerbox modal or Ctrl+Shift+Escape wide-grant revocation took the key.
				case desktop_context_menu_key(u32(record.values[0]), character, record.values[2] != 0):
					// The context menu of the desktop took the key.
				case record.values[2] != 0 && u32(record.values[0]) == display.KEY_ESCAPE && capture_popover_escape():
					// Local Escape closed the bar viewer list popover.
				case record.values[2] != 0 && u32(record.values[0]) == display.KEY_ESCAPE && tray_widget_escape():
					// Escape closed the card of a tray widget (tray_widgets.odin).
				case record.values[2] != 0 && u32(record.values[0]) == display.KEY_ESCAPE && taskbar_preview_dismiss():
					// Escape closed the preview of a group of the bar (desktop_features.odin).
				case keyboard_desktop_key(u32(record.values[0]), character, record.values[2] != 0, u32(record.values[3])):
					// A move or a resize of the window in front by keys, or the bar with the keys (keyboard_desktop.odin).
				case palette_key(u32(record.values[0]), character, record.values[2] != 0, u32(record.values[3])):
					// The palette took the key.
				case clipboard_key(character, u32(record.values[3]), record.values[2] != 0):
					// A key of the clipboard goes to no process (clipboard.odin).
				case desktop_shortcut_key(u32(record.values[0]), character, record.values[2] != 0, u32(record.values[3])):
					// Workspace switch, window snap, or magnifier toggle (desktop_features.odin).
				case order_count > 0 && !clients[order[order_count - 1]].minimized:
					// A minimized window gets no key: with every window
					// minimized, a key goes to none.
					in_front := order[order_count - 1]
					send(&clients[in_front], .Key, quality_key_values(in_front, record.values))
				}
			case .Pointer:
				// The input service is a process: a count of notches far
				// past a hand is cut, as the window layer cuts it.
				wheel := int(clamp(i64(record.values[3]), -key_path.WHEEL_NOTCHES_LIMIT, key_path.WHEEL_NOTCHES_LIMIT))
				before_x, before_y := pointer_x, pointer_y
				pointer_moved(int(i64(record.values[0])), int(i64(record.values[1])), u32(record.values[2]), wheel)
				if pointer_x != before_x || pointer_y != before_y {
					capture_note_machine_pointer_move()
				}
				pointer_moves += 1
			case .Pointer_Absolute:
				x_word, y_word := record.values[0], record.values[1]
				width_word, height_word := record.values[4], record.values[5]
				if width_word == 0 || height_word == 0 || width_word > u64(max(i32)) || height_word > u64(max(i32)) || x_word >= width_word || y_word >= height_word {
					continue
				}
				target_x, target_y: u32
				if width_word > 1 {
					scaled_x, x_problem := virtio_input.scale_axis_coordinate(i32(x_word), {0, i32(width_word - 1)}, u32(desktop_width))
					if x_problem != .None {
						continue
					}
					target_x = scaled_x
				}
				if height_word > 1 {
					scaled_y, y_problem := virtio_input.scale_axis_coordinate(i32(y_word), {0, i32(height_word - 1)}, u32(desktop_height))
					if y_problem != .None {
						continue
					}
					target_y = scaled_y
				}
				wheel := int(clamp(i64(record.values[3]), -key_path.WHEEL_NOTCHES_LIMIT, key_path.WHEEL_NOTCHES_LIMIT))
				buttons_masked := u32(record.values[2] & u64(display.BUTTON_LEFT | display.BUTTON_RIGHT))
				before_x, before_y := pointer_x, pointer_y
				pointer_moved(int(target_x) - pointer_x, int(target_y) - pointer_y, buttons_masked, wheel)
				if pointer_x != before_x || pointer_y != before_y {
					capture_note_machine_pointer_move()
				}
				pointer_moves += 1
			}
		}
		for &client, index in clients {
			if client.ring.head == nil {
				continue
			}
			// One turn takes the records that the ring holds at its start,
			// and no more: a process that writes records as fast as this
			// loop reads them must not keep this loop from the frame, the
			// input and the other windows. The records that come during
			// the turn end the next wait at once.
			taken := false
			for _ in 0 ..< system.records_of_turn(&client.ring.commands) {
				record := system.receive(&client.ring.commands) or_break
				taken = true
				quality_record_read()
				// A process writes the word: a word of no command, and None,
				// are counted, and the first one of a window writes a line,
				// so a window that writes many cannot fill the log of the
				// compositor.
				command, command_ok := display.command_of_ring_word(record.kind)
				if !command_ok {
					if client.commands_refused == 0 {
						system.log_fact(.Info, Window_Word_Refused{word = u64(record.kind)})
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
					if client.created {
						// The process names the picture that is complete,
						// and the serial of its surface. From here on the
						// compositor reads only that picture, and the
						// process draws the other. A number that names no
						// picture, and a serial of no surface that the
						// compositor holds, are refused and counted: the
						// window keeps the last picture that was named,
						// and shows none before a first one.
						picture := record.values[0]
						serial := record.values[display.PRESENT_SURFACE_SERIAL]
						// The first Present of the serial of the pending
						// surface names a picture of it: the window takes
						// it now, and the old surface ends.
						resized := client.resize_pictures != nil && serial == client.resize_serial
						shown := client.surface.pixels != nil && serial == client.surface_serial
						if picture >= display.PICTURE_COUNT || !(resized || shown) {
							client.presents_refused += 1
							continue
						}
						if resized {
							resize_surface_take(&client)
						} else if client.presents > 0 && int(picture) == client.shown {
							client.pictures_drawn_again += 1
						}
						client.shown = int(picture)
						client.surface.pixels = client.pictures[client.shown * client.surface.width * client.surface.height:]
						// The process can name the rectangle that changed; the
						// numbers are its own: they are cut to the surface.
						left, top := int(min(record.values[1], u64(client.surface.width))), int(min(record.values[2], u64(client.surface.height)))
						// The first picture of the window: the screen shows
						// none of it yet, so each pixel of it changed.
						// From this picture on, the window is on the screen
						// and in the menu of the windows: a step that opens
						// that menu waits for this line, not for the line of
						// the surface, which comes before any picture.
						if client.presents == 0 {
							system.log_fact(.Info, Window_Shown{window = window_field(client.title[:])})
						}
						// The first picture of a new surface: each pixel
						// of it changed too.
						whole := client.presents == 0 || resized
						if whole {
							left, top = 0, 0
						}
						// Width 0: from (left, top) to the end of the surface.
						changed_width, changed_height := client.surface.width - left, client.surface.height - top
						if record.values[3] != 0 && !whole {
							changed_width = int(min(record.values[3], u64(client.surface.width - left)))
							changed_height = int(min(record.values[4], u64(client.surface.height - top)))
						}
						quality_present(index, &client, client.presents == 0, record.values[display.PRESENT_KEY_SERIAL])
						client.presents += 1
						presents += 1
						// The rectangle is in pixels of the surface: the
						// pixels of the screen from the corner of the
						// surface, inside the part that the surface covers.
						box := surface_screen_box(&client)
						changed := bar.Screen_Box{max(box.left + left, box.left), max(box.top + top, box.top), min(box.left + left + changed_width, box.right), min(box.top + top + changed_height, box.bottom)}
						if changed.left < changed.right && changed.top < changed.bottom && damage_rectangle_add(changed.left, changed.top, changed.right - changed.left, changed.bottom - changed.top) {
							client.present_waits = true
						}
					}
				case .Picture_Due:
					client.picture_due = record.values[0] != 0
				case .Pointer_Shape:
					pointer_shape_request(&client, record) // pointer_picture.odin
				case .Act_Names:
					palette_act_names_take(&client, record) // palette.odin
				case .Resizable:
					resizable_take(&client, record)
				case .Surface_Resize:
					surface_resize_take(&client, record)
				case .Surface_Rescale:
					surface_rescale_take(&client, record) // window_resize.odin
				case .Surface_Release:
					surface_release_take(index, record) // window_resize.odin
				case .Surface_Declined:
					surface_declined_take(&client, record) // window_resize.odin
				case .Resize_Declined:
					resize_declined_take(&client)
				case .Copy:
					clipboard_copy_take(index, record) // clipboard.odin
				case .Copy_Declined:
					clipboard_answer_take(index, .Copy_Declined, record)
				case .Paste_Taken:
					clipboard_answer_take(index, .Paste_Taken, record)
				case .Capture_Size_Ask, .Capture_Open, .Capture_Taken, .Capture_Close, .Capture_Viewers, .Remote_Key, .Remote_Pointer:
					capture_command(index, command, record) // capture.odin
				}
			}
			// The process can wait until this loop took its last picture
			// (display.canvas_wait): it draws the next one in the picture
			// that this loop read until now. No frame is drawn between
			// the record and this wake.
			if taken && client.ring.head != nil {
				system.wake_writer(&client.ring.commands)
			}
		}
		windows_at_scale_check() // After the records of the windows: the line of a change of the scale.
		palette_turn() // A list of the ranking thread, an answer of the palette provider.
		// The calls read the place of the pointer after the input records,
		// and the state of the screen after each Present that a process
		// sent before the call: a caller that reads "nothing waits" then
		// knows that the screen shows what the processes sent.
		system.service_run(&service)
		plan_difference_asker_check()
		pointer_update(now) // After each change of what is under the pointer.
		if second_of_bar(now) != shown_second {
			shown_second = second_of_bar(now)
			damage_clock()
			tray_widgets_second() // tray_widgets.odin: the foot of the calendar.
		}
		if damage_count > 0 && now >= next_frame {
			draw(now)
			next_frame = now + FRAME_INTERVAL
			frames += 1
			if frames == 1 {
				system.log_fact(.Info, First_Frame{})
				if system.measure_run() {
					start_measures_run()
				}
			}
		}
	}
}

// start_measures_run runs the measures of the copies, of a title bar, of
// the blend of the arrow and of the bar, once, after the first frame of a
// measure run (system.measure_run). They are never on the path to the first
// frame: on the software processor of a browser machine they took more
// than 100 s. Each one writes over the frame in memory, so the next frame
// draws the whole screen.
start_measures_run :: proc "contextless" () {
	memory_measure()
	title_measure()
	if pointer_theme != nil {
		pointer_blend_measure() // pointer_picture.odin
	}
	bar_measure()
	damage_whole_screen()
}

// settings_changed gives the new font to the text of the desktop, draws the
// whole screen again, and tells each window: its process draws again
// (src/library/modus/display gives it the new font before the event).
settings_changed :: proc "contextless" (choice: settings.Choice) {
	_ = display.text_settings_apply()
	// A new scale: the desktop has another logical size, and its grid of
	// points another place on the screen. The windows keep their logical
	// places; each rescales to the scale that the event below names
	// (src/md/features/window_resize.md, "The rescale"). The loop gives the
	// scale in force in the choice of a refused page.
	rescaled := desktop_scale_take(choice, true)
	settings_count_told = u64(choice.change_count)
	windows_declined_told = windows_declined_count() // scale.odin
	// A new appearance: the background and the mark of the bar are pixels
	// that the compositor keeps, so it draws them again; each record of the
	// screen reads the tokens at its next frame.
	if rescaled || graphics.appearance != background_appearance {
		background_build()
		bar_mark_build()
	}
	if rescaled {
		windows_at_scale_due = true // scale.odin
		// The pointer picture of the size of the new scale.
		pointer_drawn_valid = false
		pointer_update(0)
	}
	bar_layout_update()
	pointer_theme_choose(choice.pointer_theme) // pointer_picture.odin
	pointer_form_choose(pointer_form_in_force(choice))
	told := 0
	for &client in clients {
		if client.ring.head != nil {
			// The scale and the edge of the bar change the work area.
			if client.created {
				work_area_send(&client)
			}
			// A new scale: the window is fitted into the new work area
			// first, and gets the scale when its fit request ends (scale.odin).
			if rescaled && client.created {
				client.scale_due, client.fit_due = true, true
				client.clamp_asks = 0
			}
			if !window_scale_step(&client) {
				settings_changed_send(&client)
			}
			told += 1
		}
	}
	damage_whole_screen()
	palette_refresh() // An open panel is measured again in the new font.
	// The template names the seven settings in the order of settings.Setting.
	#assert(len(settings.Setting) == 7, "the template of Settings_Changed names the seven settings")
	zone_buffer: [settings.ZONE_TEXT_SIZE]u8
	system.log_fact(.Info, Settings_Changed{windows = u64(told), font = setting_value_field(choice, .Font), subpixel_order = setting_value_field(choice, .Subpixel_Order), pointer_theme = setting_value_field(choice, .Pointer_Theme), grid_fit = setting_value_field(choice, .Grid_Fit), keyboard_layout = setting_value_field(choice, .Keyboard_Layout), appearance = setting_value_field(choice, .Appearance), scale = setting_value_field(choice, .Scale), in_force = value_kinds.text_field(settings.appearance_in_force_names[choice.appearance_in_force], SETTING_VALUE_FIELD_BYTES), zone = value_kinds.text_field(settings.zone_text(zone_buffer[:], choice.zone_offset_minutes), ZONE_FIELD_BYTES)})
}

// The change count of the last choice that the windows were told: the
// first word of each Settings_Changed.
settings_count_told: u64

// work_area_send names the work area to a window, as the display contract
// asks of each holder: the desktop without the bar, in logical pixels.
work_area_send :: proc "contextless" (client: ^Client) {
	height := desktop_work_bottom() - desktop_work_top()
	send(client, .Work_Area, {0 = u64(max(desktop_width, 1)), 1 = u64(max(height, 1))})
}

// The bar fits the lines that the display contract lets a holder keep, so
// each window gets the least work area at each scale, the largest too.
#assert(BAR_HEIGHT <= scale_factor.HOLDER_LINES_MOST)

// send gives an event to a window. A full ring loses no key: the event
// waits for the window in the compositor (window_events.odin). The kind is
// a member: the compositor writes the word of the record here, and reads
// no word back to know the class of the event.
send :: proc "contextless" (client: ^Client, kind: display.Event_Kind, values: [7]u64) {
	window_event_send(client, kind, values)
}

// client_add takes the ring of a new process from the root service. For a
// disk process the record also holds its nickname and the first bytes of
// the hash of its file: the window takes that nickname, not the title that
// the process sends.
client_add :: proc "contextless" (record: ring.Record) {
	memory := system.Handle(record.values[0])
	for &client in clients {
		if client.ring_memory != 0 {
			continue
		}
		opened, status := system.ring_open(memory, receive_handles = true)
		if status != .Ok {
			break
		}
		client = {ring_memory = memory, ring = opened}
		client.capture_allowed = record.values[display.CLIENT_ADD_CAPTURE] == display.CLIENT_CAPTURE
		nickname := process_page.nickname_of({record.values[1], record.values[2], record.values[3]})
		if nickname.length > 0 {
			client.from_disk = true
			copy(client.nickname[:len(client.nickname) - 1], process_page.nickname_text(&nickname))
			process_page.hash_prefix_write(&client.hash_prefix, record.values[4])
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
		for position in 0 ..< opened_count {
			if opened[position] == index {
				copy(opened[position:opened_count - 1], opened[position + 1:opened_count])
				opened_count -= 1
				break
			}
		}
		// A new window can take this place of the table: a press on its
		// title is no second press of the window that left.
		if title_double_press.window == index {
			title_double_press = {}
		}
		if dragging == index {
			dragging = -1
		}
		if resizing == index {
			resize_outline_damage()
			resizing = -1
		}
		keyboard_window_gone(index) // keyboard_desktop.odin
		damage_window(&client)
		damage_focus()
		if client.pictures != nil {
			system.memory_unmap(client.pictures)
		}
		if client.resize_pictures != nil {
			system.memory_unmap(client.resize_pictures)
		}
		if client.commands_refused != 0 {
			system.log_fact(.Info, Window_Closed_After_Refused_Commands{window = window_field(client.title[:]), refused = client.commands_refused})
		}
		clipboard_client_remove(index) // clipboard.odin
		if capture.client == index {
			capture_end("its service stopped") // capture.odin
		}
		desktop_window_closed(index) // desktop_features.odin
		quality_window_gone(index) // quality_measures.odin
		window_queue_close(index) // window_events.odin
		system.ring_close(&client.ring)
		system.close(client.ring_memory)
		if client.created {
			window_grants_window_closed(system.name_of(client.title[:])) // powerbox_dialog.odin
		}
		client = {}
		windows_declined_tell() // scale.odin: a window that declined the scale left.
		palette_entries_refresh() // A window left.
		taskbar_preview_dismiss()
		windows_menu_rows_build() // start_menu.odin
		return
	}
}

surface_create :: proc "contextless" (index: int, record: ring.Record) {
	client := &clients[index]
	// The process wrote the number of the handle: it can name any handle of
	// the compositor, among them the surface or the ring of another client.
	// The kernel proves that this process gave the handle through its own
	// ring (src/library/modus/system, handle_state). A number with no proof is not a
	// gift of this process: the compositor neither uses it nor closes it.
	// The handle is in the low 32 bits of the first word; the word of the
	// scale of the surface is above them (display.SURFACE_CREATE_SCALE_SHIFT).
	memory := system.Handle(record.values[0] & 0xFFFF_FFFF)
	kind, rights, through := system.handle_state(memory, client.ring_memory)
	// No log line: a process could send this command without end.
	if !through {
		return
	}
	// The handle is a gift of this process: each return below closes it.
	defer system.close(memory)
	if client.created {
		return
	}
	// The process chose these numbers: check them against the memory
	// itself. The record names the logical size and the scale: the pixels of
	// the screen follow from the rule of each edge, so a logical size past
	// the limit, a word that names no scale, and a surface of pixels that
	// no logical size gives, are each refused (bar.surface_create_refusal).
	facts := bar.Surface_Create_Facts {
		is_memory  = kind == .Memory,
		readable   = .Read in rights,
		scale_word = record.values[0] >> display.SURFACE_CREATE_SCALE_SHIFT,
		width      = record.values[1],
		height     = record.values[2],
	}
	if facts.is_memory {
		if pages, size_status := system.memory_size(memory); size_status == .Ok {
			facts.memory_bytes = pages * system.PAGE_SIZE
		}
	}
	refusal, surface_scale, screen_width, screen_height := bar.surface_create_refusal(facts)
	if refusal != .None {
		return
	}
	address, status := system.memory_map(memory, {}) // Read only.
	if status != .Ok {
		return
	}
	client.created = true
	desktop_window_opened(index) // desktop_features.odin
	client.pictures = ([^]graphics.Color)(address)
	client.surface = {pixels = client.pictures, width = int(screen_width), height = int(screen_height), stride = int(screen_width)}
	client.surface_serial, client.surface_scale = 1, surface_scale
	client.width, client.height = int(facts.width), int(facts.height)
	client.wanted_width, client.wanted_height = client.width, client.height
	// The process read another scale than the scale in force: the
	// compositor names its own, and the window rescales to it. Until then
	// its surface is cut to its interior.
	client.scale_told = surface_scale
	if surface_scale != scale {
		settings_changed_send(client) // scale.odin
	}
	// A disk process could title its window as a process of the system: its
	// window has the nickname that the root service gave.
	client.title = client.from_disk ? client.nickname : system.name_unpack({record.values[3], record.values[4], record.values[5], record.values[6]})
	client.icon = bar.icon_of(system.name_of(client.title[:]))
	// A free place of the work area, or a cascade place that covers no title
	// (src/md/features/window_placement.md). A window larger than the work
	// area keeps its close button on the screen.
	frame := window_frame_of(client)
	if x, y, found := bar.new_window_free_place(desktop_work_box(), shown_window_boxes(index), frame.outer_width, client.height + frame.title_height + frame.border, frame.title_height); found {
		client.x, client.y = x, y
	} else {
		client.x, client.y = bar.new_window_place(bar.CASCADE_X, bar.CASCADE_Y, frame, client.height, desktop_width, desktop_height)
	}
	pointer_leaves_front()
	damage_focus()
	order[order_count] = index
	order_count += 1
	opened[opened_count] = index
	opened_count += 1
	damage_window(client)
	system.log_fact(.Info, Surface_Made{window = window_field(client.title[:]), width = u64(client.width), height = u64(client.height), x = u64(client.x), y = u64(client.y)})
	// The take of the window, by the display contract: the window writes
	// the fact of the contract when it reads it.
	work_area_send(client)
	// A window larger than the work area gets at most the work area from its
	// first surface, and scrolls its layout (src/md/features/window_scroll.md).
	// A window of another scale releases its surface at the Settings_Changed
	// above, and a window between two surfaces declines a request: its fit
	// waits for its surface of the scale in force (window_fit_after_scale).
	if surface_scale != scale {
		client.fit_after_scale = true
	} else {
		window_fit_now(client) // scale.odin
	}
	palette_entries_refresh() // A window appeared.
	taskbar_preview_dismiss()
	windows_menu_rows_build() // start_menu.odin
}

// lower moves a window to the back: a minimized window gives the focus to
// the window behind it.
lower :: proc "contextless" (position: int) {
	if position < 0 || position >= order_count {
		return
	}
	index := order[position]
	if position == order_count - 1 {
		// The window in front leaves it, also when it is the only one: a
		// minimized window then gets no pointer event and no key.
		pointer_leaves_front()
		damage_focus()
	}
	if position > 0 {
		copy(order[1:position + 1], order[0:position])
		order[0] = index
	}
	damage_focus()
	palette_entries_refresh() // Another window can be in front.
	taskbar_preview_dismiss()
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
	taskbar_preview_dismiss()
}

inside :: proc "contextless" (x, y, left, top, width, height: int) -> bool {
	return x >= left && y >= top && x < left + width && y < top + height
}

// pointer_moved takes one pointer record of the input service: a move, the
// buttons, and the notches of the wheel. The wheel goes where the pointer
// goes: to the palette while it is open, else to the process of the window
// in front when the pointer is over its surface. A window behind gets no
// notch: the input goes only to the process that has the focus, so no
// process reads input that the principal gave to another one.
pointer_moved :: proc "contextless" (motion_x, motion_y: int, new_buttons: u32, wheel: int) {
	close_before := close_button_under_pointer()
	// The pointer moves in logical pixels of the desktop: one unit of a move
	// of the mouse is one logical pixel, so a press acts at a place of the
	// layout and the pointer reaches each logical pixel.
	pointer_x = clamp(pointer_x + motion_x, 0, desktop_width - 1)
	pointer_y = clamp(pointer_y + motion_y, 0, desktop_height - 1)
	// The close button under the pointer is brighter: draw again the
	// button that the pointer leaves and the one that it reaches.
	if close_after := close_button_under_pointer(); close_after != close_before {
		for client in ([2]^Client{close_before, close_after}) {
			if client != nil {
				damage_add(client.x + client.width + BORDER - CLOSE_SIZE, client.y, CLOSE_SIZE, TITLE_HEIGHT)
			}
		}
	}
	pressed := new_buttons & display.BUTTON_LEFT != 0 && buttons & display.BUTTON_LEFT == 0
	released := new_buttons & display.BUTTON_LEFT == 0 && buttons & display.BUTTON_LEFT != 0
	held := buttons != 0 || new_buttons != 0
	right_pressed := new_buttons & display.BUTTON_RIGHT != 0 && buttons & display.BUTTON_RIGHT == 0
	buttons = new_buttons
	// The place of each press is a fact that only the compositor has: the
	// input service joins the moves that find its ring full, and the edges
	// of the screen cut the joined move where they would not cut each move
	// alone. A test that moves the pointer with no other way to read it
	// learns from this line where the press landed.
	if pressed {
		system.log_fact(.Info, Left_Button_Pressed{x = u64(pointer_x), y = u64(pointer_y)})
	}
	if pressed || right_pressed {
		taskbar_preview_press(pointer_x, pointer_y) // A press outside the preview of the bar closes it.
	}

	if plan_difference_pointer(pressed) { // powerbox_dialog.odin
		// The dialog of the trusted display takes the pointer.
		return
	}
	if palette_is_open() {
		// The panel takes the pointer: no menu and no window receives it.
		palette_pointer(motion_x != 0 || motion_y != 0, pressed, released, wheel)
		return
	}
	if dragging >= 0 {
		if buttons & display.BUTTON_LEFT != 0 {
			if clients[dragging].maximized {
				// A maximized window stays in place while the pointer is
				// still at the press: a hand that shakes between the two
				// presses of a double press does not move it.
				if bar.press_still(drag_press_x, drag_press_y, pointer_x, pointer_y) {
					return
				}
				desktop_restore_under_pointer(&clients[dragging]) // desktop_features.odin
			}
			damage_window(&clients[dragging])
			// The window follows the pointer to the pixel, and a part
			// of its title stays on the screen at each edge.
			clients[dragging].x, clients[dragging].y = bar.dragged_window_place(pointer_x, pointer_y, drag_x, drag_y, window_frame_of(&clients[dragging]), desktop_width, desktop_height)
			damage_window(&clients[dragging])
		} else {
			// The input put the window down: the log has its new place.
			client := &clients[dragging]
			system.log_fact(.Info, Window_Moved{x = u64(max(client.x, 0)), y = u64(client.y), window = window_field(client.title[:])})
			system.log_fact(.Info, Window_Move_Measured{frames = move_frames, time_per_frame = value_kinds.Time_In_Microseconds(move_time / max(move_frames, 1) / 1000), longest_frame = value_kinds.Time_In_Microseconds(move_longest / 1000), window = window_field(client.title[:])})
			move_frames, move_time, move_longest = 0, 0, 0
			dragging = -1
			damage_whole_screen()
			full_measure = true
		}
		return
	}
	if resizing >= 0 {
		resize_pointer_moved(buttons & display.BUTTON_LEFT != 0) // window_resize.odin
		return
	}
	// The start menu: its button opens it. A press on a line
	// starts the process. Any press closes the menu.
	// The menu of the windows: its button opens it, and a press on a line
	// brings the window to the front.
	desktop_magnifier_track(i32(pointer_x), i32(pointer_y))
	capture_popover_pointer_move(pointer_x, pointer_y)
	tray_widgets_pointer_move(pointer_x, pointer_y) // tray_widgets.odin
	desktop_taskbar_pointer_move(pointer_x, pointer_y)
	if hovered := bar.button_at(bar_layout, pointer_x, pointer_y); hovered != bar_button_hovered {
		bar_button_hovered = hovered
		damage_menu()
	}
	if right_pressed && menu_open == .None && !bar.inside_bar(bar_layout, pointer_y) {
		desktop_context_menu_open(pointer_x, pointer_y)
		return
	}
	// The right button on a plate: the menu of the acts on its window
	// (desktop_features.odin).
	if right_pressed && menu_open == .None && bar.inside_bar(bar_layout, pointer_y) && desktop_taskbar_menu_open(pointer_x, pointer_y) {
		return
	}
	// The context menu of the desktop takes the pointer while it is open: a
	// line under the pointer is chosen, a press on it acts, a press outside
	// closes the menu and goes on to what is under it.
	if desktop_context_menu_pointer(pointer_x, pointer_y, pressed) {
		return
	}
	if menu_open != .None {
		over, on_revoke := bar.line_at(bar_layout, pointer_x, pointer_y), false
		if menu_open == .Windows {
			over, on_revoke = bar.windows_menu_point(bar_layout, windows_menu_rows[:windows_menu_row_count], pointer_x, pointer_y)
		}
		action := menu_open == .Start ? bar.action_at(bar_layout, pointer_x, pointer_y) : bar.Start_Action.None
		if over != menu_line || action != menu_action || on_revoke != menu_on_revoke {
			menu_line, menu_action, menu_on_revoke = over, action, on_revoke
			damage_menu()
		}
	}
	if pressed {
		// Only two presses on a title bar make a double press: each other
		// press forgets the first one, and a press on a title takes it back.
		last_title_press := title_double_press
		title_double_press = {}
		keyboard_pointer_pressed() // keyboard_desktop.odin
		if capture_popover_press(pointer_x, pointer_y) {
			return
		}
		if tray_widgets_press(pointer_x, pointer_y) { // tray_widgets.odin
			return
		}
		was_open := menu_open
		if menu_open != .None && menu_choice_do(false) { // start_menu.odin
			return // A press on a grant row keeps the menu open, and reaches nothing under it.
		}
		under := bar.button_at(bar_layout, pointer_x, pointer_y)
		if under == .Start && was_open != .Start {
			menu_show(.Start)
		}
		if under == .Windows && was_open != .Windows {
			menu_show(.Windows)
		}
		if was_open == .None && bar.inside_bar(bar_layout, pointer_y) && desktop_taskbar_press(pointer_x, pointer_y) {
			return
		}
		if was_open != .None || bar.inside_bar(bar_layout, pointer_y) {
			return
		}
		// An edge of a resizable window, before the window under the
		// pointer: the band of an edge lies outside the frame.
		if index, edges := resize_edges_under_pointer(); edges != {} {
			resize_begin(index, edges) // window_resize.odin
			return
		}
		for position := order_count - 1; position >= 0; position -= 1 {
			client := &clients[order[position]]
			if client.minimized {
				continue
			}
			csd := client.decoration == .Client
			outer_width := csd ? client.width : client.width + 2 * BORDER
			outer_height := csd ? client.height : client.height + TITLE_HEIGHT + BORDER
			if !inside(pointer_x, pointer_y, client.x, client.y, outer_width, outer_height) {
				continue
			}
			client_index := order[position]
			raise(position)
			if !csd {
				close_x := client.x + outer_width - BORDER - CLOSE_SIZE
				max_x := close_x - 28
				min_x := max_x - 28
				if inside(pointer_x, pointer_y, close_x, client.y, CLOSE_SIZE, TITLE_HEIGHT) {
					system.send(&control.completions, ring.Record{kind = u32(display.Control.Stop), values = {0 = u64(client.ring_memory)}})
					return
				}
				if inside(pointer_x, pointer_y, max_x, client.y, 28, TITLE_HEIGHT) {
					_ = desktop_toggle_maximize(client)
					return
				}
				if inside(pointer_x, pointer_y, min_x, client.y, 28, TITLE_HEIGHT) {
					desktop_toggle_minimize(client)
					return
				}
				if pointer_y < client.y + TITLE_HEIGHT {
					title_double_press = last_title_press
					if bar.double_press_take(&title_double_press, system.time(), pointer_x, pointer_y, client_index) {
						_ = desktop_toggle_maximize(client)
						return
					}
					dragging = client_index
					drag_x, drag_y = pointer_x - client.x, pointer_y - client.y
					drag_press_x, drag_press_y = pointer_x, pointer_y
					return
				}
			}
			break
		}
	}
	// The process with focus receives the pointer when it is over its surface,
	// and while a button is down. A minimized window has no surface on the
	// screen: it receives none.
	if order_count > 0 && !clients[order[order_count - 1]].minimized {
		client := &clients[order[order_count - 1]]
		x := pointer_x - client.x - BORDER
		y := pointer_y - client.y - TITLE_HEIGHT
		// One event more when the pointer leaves the surface: the process
		// then draws at rest what the pointer was over (a scroll bar).
		on_surface := inside(x, y, 0, 0, client.width, client.height)
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

// pointer_leaves_front tells the process of the window in front that the
// pointer is no longer over its surface, before another window takes the
// front: that process receives no pointer event after it. The place of the
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
	quality_frame_start() // quality_measures.odin
	capture_before_frame() // capture.odin: before the frame takes its areas.
	screen_build(now, display.interface_font_of())
	draw_areas(damage[:damage_count])
	// The frame is on the screen: the copy and the page flip are done.
	quality_frame_flipped() // quality_measures.odin
	// The windows that this frame read a picture of.
	for &client in clients {
		if client.surface.pixels == nil || client.presents == 0 {
			continue
		}
		box := surface_screen_box(&client)
		for area in damage[:damage_count] {
			if area.left < box.right && box.left < area.right && area.top < box.bottom && box.top < area.bottom {
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
	pointer_motion_frame_end(system.nanoseconds()) // pointer_picture.odin
	if full_measure {
		full_measure = false
		system.log_fact(.Info, Full_Frame_Measured{width = u64(screen.width), height = u64(screen.height), windows = u64(order_count), elapsed = value_kinds.Time_In_Microseconds(spent / 1000)})
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
		// The panel is laid out in logical pixels of the desktop.
		palette_now.scale = scale
		screen_draw_part(&palette_now, 0, palette_now.record_count, nil, frame, rectangles[:count])
	}

	// The copy of the screen holds no pointer: it runs before the pointer.
	capture_after_draw(areas) // capture.odin

	for area in areas {
		canvas := graphics.view(frame, area.left, area.top, area.right - area.left, area.bottom - area.top)
		pointer_draw(canvas, -area.left, -area.top) // pointer_picture.odin
	}
	screen_put(areas)
	gpu_scanout_present(areas)
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
		system.log_fact(.Info, Page_Flip_Refused{screen_page = u64(hidden)})
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
	if desktop_magnifier.enabled {
		for y in 0 ..< height {
			for column in 0 ..< width {
				color := desktop_magnifier_sample(area.left + column, area.top + y)
				if red_first {
					color = color >> 16 & 0xFF | color & 0xFF00 | (color & 0xFF) << 16
				}
				target.pixels[y * target.stride + column] = color
			}
		}
		return
	}
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
	outer_width := client.width + 2 * BORDER
	start := graphics.Color(focus ? graphics.colors.title : graphics.colors.title_quiet)
	end := graphics.Color(focus ? graphics.colors.title_end : graphics.colors.title_quiet_end)
	// The title and the borders reach one logical pixel under the surface
	// (bar.frame_parts, whose host test checks the seam at each scale): the
	// surface is copied at the pixel of the screen of its own corner, which
	// rounds on its own, and is drawn over them, so no pixel of the
	// background shows between the frame and the surface.
	parts := bar.frame_parts(x, y, client.width, client.height, BORDER, TITLE_HEIGHT)
	title_part, bottom_part, left_part, right_part := parts[0], parts[1], parts[2], parts[3]
	interface.draw_horizontal_gradient(table, title_part.left, title_part.top, title_part.right - title_part.left, 1, graphics.shade(start, 125), graphics.shade(end, 125))
	interface.draw_horizontal_gradient(table, title_part.left, title_part.top + 1, title_part.right - title_part.left, title_part.bottom - title_part.top - 1, start, end)
	interface.draw_horizontal_gradient(table, bottom_part.left, bottom_part.top, bottom_part.right - bottom_part.left, bottom_part.bottom - bottom_part.top, start, end)
	interface.draw_rectangle(table, left_part.left, left_part.top, left_part.right - left_part.left, left_part.bottom - left_part.top, start)
	interface.draw_rectangle(table, right_part.left, right_part.top, right_part.right - right_part.left, right_part.bottom - right_part.top, end)
	// The icon of the module, then the title: a name, cut in its font to
	// the room before minimize/maximize/close.
	icon_color := focus ? graphics.COLOR_WHITE : graphics.colors.dim
	bar.icon_records(table, x + TITLE_ICON_X, y + (TITLE_HEIGHT - bar.ICON_SIZE) / 2, client.icon, icon_color, focus ? graphics.shade(graphics.colors.title, 170) : graphics.colors.dim)
	title_room := max(24, outer_width - CLOSE_SIZE - 2 * 28 - 20 - (TITLE_TEXT_X - 8))
	title := interface.text_fit(table, interface.FONT_INTERFACE, system.name_of(client.title[:]), title_room)
	interface.draw_text(table, x + TITLE_TEXT_X, y + 4, title, focus ? graphics.COLOR_WHITE : graphics.colors.dim, interface.FONT_INTERFACE)
	base := graphics.Color(graphics.colors.stop_process_quiet)
	cross_color := graphics.Color(graphics.colors.stop_process_quiet_mark)
	if focus || pointer_over {
		base = pointer_over ? graphics.colors.stop_process_pointer_over : graphics.colors.stop_process
		cross_color = graphics.COLOR_WHITE
	}
	close_x := x + outer_width - BORDER - CLOSE_SIZE
	CTRL_PITCH :: 28
	max_x := close_x - CTRL_PITCH
	min_x := max_x - CTRL_PITCH
	ctrl_mark := focus ? graphics.COLOR_WHITE : graphics.colors.dim
	// Minimize button: flush on the title gradient (Kernel theme), crisp 1px bar, subtle hover highlight.
	if min_x > x + 40 {
		if inside(pointer_x, pointer_y, min_x, y, CTRL_PITCH, TITLE_HEIGHT) {
			interface.draw_vertical_gradient(table, min_x, y + 1, CTRL_PITCH, TITLE_HEIGHT - 1, graphics.shade(end, 132), graphics.shade(end, 108))
		}
		interface.draw_rectangle(table, min_x + (CTRL_PITCH - 9) / 2, y + TITLE_HEIGHT - 9, 9, 1, ctrl_mark)
	}
	// Maximize / Restore button: flush on the title gradient, crisp 1px 8x8 frame with 2px top header bar.
	if max_x > x + 40 {
		if inside(pointer_x, pointer_y, max_x, y, CTRL_PITCH, TITLE_HEIGHT) {
			interface.draw_vertical_gradient(table, max_x, y + 1, CTRL_PITCH, TITLE_HEIGHT - 1, graphics.shade(end, 132), graphics.shade(end, 108))
		}
		mx := max_x + (CTRL_PITCH - 9) / 2
		my := y + (TITLE_HEIGHT - 8) / 2
		if client.maximized {
			// The restore: a second window behind the first, of which
			// only the edges that the first does not hide are drawn.
			interface.draw_rectangle(table, mx + 2, my, 7, 1, ctrl_mark)
			interface.draw_rectangle(table, mx + 8, my, 1, 6, ctrl_mark)
			interface.draw_rectangle(table, mx + 2, my, 1, 2, ctrl_mark)
			interface.draw_rectangle(table, mx + 7, my + 5, 2, 1, ctrl_mark)
			interface.draw_outline(table, mx, my + 2, 7, 6, 1, ctrl_mark)
			interface.draw_rectangle(table, mx + 1, my + 3, 5, 1, ctrl_mark)
		} else {
			interface.draw_outline(table, mx, my, 9, 8, 1, ctrl_mark)
			interface.draw_rectangle(table, mx + 1, my + 1, 7, 1, ctrl_mark)
		}
	}
	// Close (x) button (exact rightmost position preserved)
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
	system.log_fact(.Info, Title_Bar_Measured{width = u64(width), one_color_time = value_kinds.Nanoseconds_As_Microseconds(times[0]), mix_time = value_kinds.Nanoseconds_As_Microseconds(times[1]), row_copy_time = value_kinds.Nanoseconds_As_Microseconds(times[2])})
}

// close_button_under_pointer gives the client whose close button is under
// the pointer, or nil: the button of the window in front at that place.
close_button_under_pointer :: proc "contextless" () -> ^Client {
	for position := order_count - 1; position >= 0; position -= 1 {
		client := &clients[order[position]]
		outer_width := client.width + 2 * BORDER
		if !inside(pointer_x, pointer_y, client.x, client.y, outer_width, client.height + TITLE_HEIGHT + BORDER) {
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
	// The last one: 3 MiB less the offsets of the measure, past the caches of
	// the processor. It stays this size, smaller than a frame of the
	// reference screen, so that its line keeps one series over the releases.
	SIZES :: [?]int{8, 64, 512, 4096, 65536, 3 << 20 - 128}
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
	// One fact for each form: the times of the six sizes, in the order of
	// SIZES, which the template of each form names.
	#assert(len(SIZES) == 6, "the templates of the copy measures name the six sizes")
	for form in Form {
		times: [len(SIZES)]value_kinds.Tenths
		for value, index in tenths[form] {
			times[index] = value_kinds.Tenths(value)
		}
		switch form {
		case .Copy:
			system.log_fact(.Info, Copy_Aligned_Measured{time_8 = times[0], time_64 = times[1], time_512 = times[2], time_4096 = times[3], time_65536 = times[4], time_3145600 = times[5]})
		case .Copy_Unaligned:
			system.log_fact(.Info, Copy_Unaligned_Measured{time_8 = times[0], time_64 = times[1], time_512 = times[2], time_4096 = times[3], time_65536 = times[4], time_3145600 = times[5]})
		case .Loop:
			system.log_fact(.Info, Loop_Aligned_Measured{time_8 = times[0], time_64 = times[1], time_512 = times[2], time_4096 = times[3], time_65536 = times[4], time_3145600 = times[5]})
		case .Loop_Unaligned:
			system.log_fact(.Info, Loop_Unaligned_Measured{time_8 = times[0], time_64 = times[1], time_512 = times[2], time_4096 = times[3], time_65536 = times[4], time_3145600 = times[5]})
		case .Fill:
			system.log_fact(.Info, Fill_Aligned_Measured{time_8 = times[0], time_64 = times[1], time_512 = times[2], time_4096 = times[3], time_65536 = times[4], time_3145600 = times[5]})
		case .Fill_Unaligned:
			system.log_fact(.Info, Fill_Unaligned_Measured{time_8 = times[0], time_64 = times[1], time_512 = times[2], time_4096 = times[3], time_65536 = times[4], time_3145600 = times[5]})
		}
	}
	_, ebx, _, edx := intrinsics.x86_cpuid(7, 0)
	system.log_fact(.Info, Processor_Copy_Features{erms = value_kinds.text_field(ebx >> 9 & 1 != 0 ? "yes" : "no", YES_NO_FIELD_BYTES), fsrm = value_kinds.text_field(edx >> 4 & 1 != 0 ? "yes" : "no", YES_NO_FIELD_BYTES)})
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
// The start menu draws an icon of up to nine rectangles on each of its
// lines, and each window an icon in its title bar.
screen_records: [2048]interface.Draw_Record
screen_text: [16384]u8
screen_table := interface.Draw_Table{}

// A part of the screen table: the records of one window, or of the bar and
// its menus, and the one picture memory that their Picture record names as
// number 0. Each surface is a memory object of another process, mapped at
// its own address, and a call of the drawing module takes one picture
// memory: so the compositor draws each part with a call of its own.
Screen_Part :: struct {
	first, count:   int, // The records of the part in screen_table.
	picture_memory: []graphics.Color, // The surface of the window, the heron of the bar, or none.
	// The rectangle of the screen that holds each pixel of the part, in
	// pixels of the screen: the outer rectangle of a window. A damage
	// rectangle that it does not meet needs no call. The part of the bar
	// holds the menus, and has no bound.
	bounds:         Rectangle,
	bounded:        bool,
	// The records are logical pixels of the desktop, drawn at the scale:
	// the frames, the bar, the menus. The part of a surface is not: its one
	// Picture record is the pixels of the surface at their place on the
	// screen, copied as they are.
	scaled:         bool,
}

// The parts of the screen: up to three for each window (its frame, its
// surface, and its resize grip overlay), one for the outline of a resize,
// then one for the bar.
screen_parts: [3 * CLIENT_CAPACITY + 2]Screen_Part
screen_part_count: int
// The list of one picture memory that the table has while it appends the
// Picture record of one part: the record then names memory 0.
screen_picture_memory: [1][]graphics.Color
// The drawing module refused a call of the compositor: the line of the log
// is written one time, as the cause is in the compositor and each frame has it.
screen_refusal_logged: bool

// The heron of the heron button (docs/DESIGN.md, "The mark"). A picture
// has no transparency, so each look of the button has its own picture of
// the heron on the plate of that look. Their gradients are computed once,
// at the start, into these pictures; each frame shows one with a Picture
// record, a copy of 24 rows. Each look has its own generation, which never
// changes: the difference of two frames finds a change of the look, and
// nothing else.
BAR_MARK_GENERATION :: 1 // The generation of the look Rest; each next look adds one.
bar_mark_pixels: [Start_Button_Look][bar.MARK_SIZE * bar.MARK_SIZE]graphics.Color
bar_mark_pictures: [Start_Button_Look]graphics.Canvas

// bar_background_records appends the surface of the bar, with its corner
// at (x, y): its gradient and the line on the side of the windows. The
// gradient has the same rows at both edges, so the one picture of the mark,
// built at the top, shows the bar around the heron at the bottom too.
bar_background_records :: proc "contextless" (table: ^interface.Draw_Table, x, y, width: int, edge: bar.Edge) {
	interface.draw_vertical_gradient(table, x, y, width, BAR_HEIGHT - 1, graphics.colors.card_top, graphics.colors.card_bottom)
	switch edge {
	case .Top:
		interface.draw_rectangle(table, x, y + BAR_HEIGHT - 1, width, 1, graphics.colors.track)
	case .Bottom:
		// The line faces the windows over the bar, with the light of a
		// plate under it; the last row of the screen ends the gradient.
		interface.draw_rectangle(table, x, y, width, 1, graphics.colors.track)
		interface.draw_rectangle(table, x, y + 1, width, 1, graphics.shade(graphics.colors.card_top, 125))
		interface.draw_rectangle(table, x, y + BAR_HEIGHT - 1, width, 1, graphics.colors.card_bottom)
	}
}

// bar_mark_build draws the heron into the picture of each look of the
// heron button. Each picture first gets the pixels of the plate under the
// heron, from the same records and the same code that draw the plate: an
// empty cell of the heron then shows exactly the plate around it. The
// drawing module draws in the coordinates of the canvas, so the records of
// the plate start at the corner of the screen as the picture sees it.
bar_mark_build :: proc "contextless" () {
	for look in Start_Button_Look {
		picture := graphics.Canvas{pixels = raw_data(bar_mark_pixels[look][:]), width = bar.MARK_SIZE, height = bar.MARK_SIZE, stride = bar.MARK_SIZE}
		bar_mark_pictures[look] = picture
		records: [16]interface.Draw_Record
		table := interface.Draw_Table{records = records[:]}
		start_button_records(&table, bar.START_BUTTON_X - bar.MARK_X, bar.PLATE_Y - bar.MARK_Y, look)
		whole_picture := [1]interface.Rectangle{{0, 0, bar.MARK_SIZE, bar.MARK_SIZE}}
		screen_draw_part(&table, 0, table.record_count, nil, picture, whole_picture[:])
		// The mark of the button is a small icon, one pixel for a cell: the
		// cells variant. On the light plate it has the colors of the light
		// background, as the mark of the bar of the light page of the site.
		mark.mark_draw(picture, 0, 0, bar.MARK_CELL_SIZE, .Cells, graphics.appearance == .Light)
	}
}

// background_build draws the background of the rules into its canvas: one
// color, and a grid of points. The compositor draws it once at its start,
// and again at each change of the appearance.
background_build :: proc "contextless" () {
	background_appearance = graphics.appearance
	graphics.clear(background, graphics.colors.background)
	// The grid of points is in logical pixels of the desktop: each point
	// goes to the screen by the rule of each edge.
	for y := graphics.POINT_STEP / 2; y < desktop_height; y += graphics.POINT_STEP {
		for x := graphics.POINT_STEP / 2; x < desktop_width; x += graphics.POINT_STEP {
			point := screen_rectangle_of(x, y, graphics.POINT_SIZE, graphics.POINT_SIZE)
			graphics.fill(background, point.left, point.top, point.right - point.left, point.bottom - point.top, graphics.colors.point)
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
	system.log_fact(.Warning, Screen_Draw_Refused{error_kind = u64(max(refused.kind, 0)), error_argument = u64(max(refused.argument, 0))})
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
			screen_table.scale = nil
			if part.scaled {
				screen_table.scale = scale
			}
			screen_draw_part(&screen_table, part.first, part.count, part.picture_memory, frame, rectangles[:count])
		}
	}
}

// screen_part_end ends the part that started at the record first.
@(private = "file")
screen_part_end :: proc "contextless" (first: int, picture_memory: []graphics.Color, bounds: Rectangle, bounded: bool, scaled: bool) {
	screen_parts[screen_part_count] = {first = first, count = screen_table.record_count - first, picture_memory = picture_memory, bounds = bounds, bounded = bounded, scaled = scaled}
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
		if client.minimized {
			continue
		}
		focus := position == order_count - 1
		first := table.record_count
		// A window shows a picture that its process presented, or none:
		// before the first Present, and while a rescale released its
		// surface, the window has the background color, under the frame,
		// whose borders reach one logical pixel into the interior.
		outer := screen_rectangle_of(client.x, client.y, client.width + 2 * BORDER, client.height + TITLE_HEIGHT + BORDER)
		box := surface_screen_box(client)
		shows_surface := client.presents > 0 && client.surface.pixels != nil
		if !shows_surface {
			interface.draw_rectangle(table, client.x + BORDER, client.y + TITLE_HEIGHT, client.width, client.height, graphics.colors.background)
		}
		if client.decoration != .Client {
			frame_records(table, client, client.x, client.y, focus, client == pointer_close)
		}
		screen_part_end(first, nil, outer, true, true)
		if !shows_surface {
			continue
		}
		// The surface: its pixels of the screen, from the corner of the
		// interior on the screen, with no scale. The picture is the view of
		// the part inside the interior: its stride stays the stride of the
		// surface. A surface of an older scale is cut to the interior; one
		// that is smaller leaves strips, which the background fills, only
		// where the frame does not cover them, so no pixel is written twice
		// (bar.background_strips).
		surface_first := table.record_count
		memory := client.surface.pixels[:client.surface.stride * client.surface.height]
		strips := bar.background_strips(box, window_frame_inner(client))
		for strip in strips {
			if strip.right > strip.left {
				interface.draw_rectangle(table, strip.left, strip.top, strip.right - strip.left, strip.bottom - strip.top, graphics.colors.background)
			}
		}
		view := client.surface
		view.width, view.height = box.right - box.left, box.bottom - box.top
		screen_picture_append(box.left, box.top, view, memory, 0)
		screen_part_end(surface_first, memory, {box.left, box.top, box.right, box.bottom}, true, false)
		if client.resizable && client.decoration != .Client {
			grip_first := table.record_count
			outer_width := client.width + 2 * BORDER
			gx := client.x + outer_width - BORDER - bar.GRIP_SIZE
			gy := client.y + TITLE_HEIGHT + client.height - bar.GRIP_SIZE
			grip_col := focus ? graphics.colors.text : graphics.colors.dim
			interface.draw_rectangle(table, gx + 7, gy + 1, 2, 8, grip_col)
			interface.draw_rectangle(table, gx + 1, gy + 7, 8, 2, grip_col)
			interface.draw_rectangle(table, gx + 4, gy + 4, 3, 3, grip_col)
			screen_part_end(grip_first, nil, screen_rectangle_of(gx, gy, bar.GRIP_SIZE, bar.GRIP_SIZE), true, true)
		}
	}
	// The outline of the frame that a drag of the edges gives, over the
	// windows: the window keeps its picture until its process draws the
	// new size.
	if resizing >= 0 {
		first := table.record_count
		outline := resize_outline
		interface.draw_outline(table, outline.left, outline.top, outline.right - outline.left, outline.bottom - outline.top, RESIZE_OUTLINE_THICKNESS, graphics.colors.title)
		screen_part_end(first, nil, screen_rectangle_of(outline.left, outline.top, outline.right - outline.left, outline.bottom - outline.top), true, true)
	}
	keyboard_first := table.record_count
	if keyboard_box, keyboard_drawn := keyboard_window_records(table); keyboard_drawn { // keyboard_desktop.odin
		screen_part_end(keyboard_first, nil, keyboard_box, true, true)
	}

	// The bar: the heron button, the button of the windows, the plates of
	// the windows, the tray, then the date and the time of day (the time
	// since boot when the system has no date), at the right.
	bar_first := table.record_count
	width := desktop_width
	bar_top := desktop_bar_y()
	bar_background_records(table, 0, bar_top, width, bar_layout.edge)
	look := start_button_look()
	start_x, start_y, _, _ := bar.button(bar_layout)
	start_button_records(table, start_x, start_y, look) // start_menu.odin
	screen_picture_append(bar.MARK_X, bar.mark_y(bar_layout), bar_mark_pictures[look], bar_mark_pixels[look][:], BAR_MARK_GENERATION + u32(look))
	windows_button_records(table) // start_menu.odin
	seconds := now / 1000
	clock_x := bar.clock_x(width)
	x := clock_x
	clock_text, clock_separator := tray_clock_plate_records(table) // tray_widgets.odin: the clock opens the calendar.
	if milliseconds, known := date.milliseconds_now(date_page, now); known {
		// The local time: the date of UTC and the time zone of the date
		// page (src/md/features/time_zone.md).
		zone := date.zone_offset_seconds_read(date_page)
		date_text: [24]u8
		shown := calendar.iso_text(date_text[:], milliseconds / 1000 + zone)
		interface.draw_text(table, x, bar_top + bar.CLOCK_TEXT_Y, shown, clock_text)
		if zone != bar_zone_logged {
			bar_zone_logged = zone
			zone_buffer: [settings.ZONE_TEXT_SIZE]u8
			system.log_fact(.Info, Bar_Local_Time{date = value_kinds.Time_In_Seconds(milliseconds / 1000), local_time = value_kinds.text_field(shown, LOCAL_TIME_FIELD_BYTES), zone = value_kinds.text_field(settings.zone_text(zone_buffer[:], i32(zone / 60)), ZONE_FIELD_BYTES)})
		}
	} else {
		x += CLOCK_WIDTH - 8 * 8
		x = interface.draw_unsigned(table, x, bar_top + bar.CLOCK_TEXT_Y, seconds / 3600, clock_text, 2)
		x = interface.draw_text(table, x, bar_top + bar.CLOCK_TEXT_Y, ":", clock_separator)
		x = interface.draw_unsigned(table, x, bar_top + bar.CLOCK_TEXT_Y, seconds / 60 % 60, clock_text, 2)
		x = interface.draw_text(table, x, bar_top + bar.CLOCK_TEXT_Y, ":", clock_separator)
		interface.draw_unsigned(table, x, bar_top + bar.CLOCK_TEXT_Y, seconds % 60, clock_text, 2)
	}

	// The tray, from the clock to the left: the hairline of the clock, the
	// buttons of the notifications and of the control center, which keep
	// their places (tray_widgets.odin), the mark of a viewer of the remote
	// display (capture.odin), the mark of each assistive holder
	// (assistive.odin), which are never left out, then the pills of the
	// tray. The plates of the windows take the room that is left.
	interface.draw_rectangle(table, bar.tray_right(width) + bar.TRAY_CLOCK_GAP / 2, bar_top + 6, 1, BAR_HEIGHT - 12, graphics.colors.track)
	tray_buttons_records(table)
	tray_right := bar.tray_buttons_left(width) - TRAY_BADGE_GAP
	capture_mark_records(table, tray_right + 16)
	if capture_is_open() && capture_mark_drawn {
		tray_right = capture_mark_x - TRAY_BADGE_GAP
	}
	if assistive_left := assistive_marks_records(table, tray_right); assistive_left < tray_right {
		tray_right = assistive_left - TRAY_BADGE_GAP
	}
	desktop_taskbar_and_tray_records(table, tray_right) // desktop_features.odin
	bar_focus_records(table) // keyboard_desktop.odin: after each item of the bar, so none covers the outline.

	// The menus of the bar, as cards in the look of the start menu.
	card_frame := interface.Frame{table = table}
	if menu_open == .Windows && order_count > 0 {
		windows_menu_records(table) // start_menu.odin
	}
	if menu_open == .Start {
		start_menu_records(table) // start_menu.odin
	}
	capture_popover_records(&card_frame)
	desktop_notifications_records(table)
	tray_card_records(table) // tray_widgets.odin: over the banners, which it lists.
	powerbox_dialog_records(table)
	desktop_taskbar_preview_records(table) // desktop_features.odin
	desktop_context_menu_records(table)
	window_switcher_records(table) // window_switcher.odin: over each other card, as it holds the keys.
	screen_part_end(bar_first, bar_mark_pixels[look][:], {}, false, true)
	if table.full {
		system.log_fact(.Warning, Screen_Draw_Table_Full{})
	}
}

// window_frame_of gives the frame that the compositor draws around the
// surface of a client, for the places of src/library/internal/compositor/bar.
// desktop_work_box gives the work area: the desktop less the bar.
desktop_work_box :: proc "contextless" () -> bar.Box {
	top := desktop_work_top()
	return {0, top, desktop_width, desktop_work_bottom() - top}
}

// The outer boxes of the shown windows, for the place of a new window.
shown_boxes: [CLIENT_CAPACITY]bar.Box

// shown_window_boxes gives the outer box of each window that shows, but the
// window of a client index: a minimized window does not show.
shown_window_boxes :: proc "contextless" (except: int) -> []bar.Box {
	count := 0
	for position in 0 ..< opened_count {
		other := opened[position]
		client := &clients[other]
		if other == except || !client.created || client.minimized || count >= len(shown_boxes) {
			continue
		}
		frame := window_frame_of(client)
		shown_boxes[count] = {client.x, client.y, frame.outer_width, client.height + frame.title_height + frame.border}
		count += 1
	}
	return shown_boxes[:count]
}

window_frame_of :: proc "contextless" (client: ^Client) -> bar.Window_Frame {
	return {outer_width = client.width + 2 * BORDER, border = BORDER, close_size = CLOSE_SIZE, title_height = TITLE_HEIGHT}
}

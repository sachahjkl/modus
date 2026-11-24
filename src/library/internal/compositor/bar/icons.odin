package bar

import "modus:graphics"
import "modus:interface"

// The icons of the system: squares of ICON_SIZE pixels made of whole
// rectangles, so each edge falls on a pixel at scale 1 and the icon stays
// sharp at each scale. A module has the icon of its kind; the window of a
// module shows it in its title bar, on its plate of the bar and in the
// menus (src/md/features/desktop_shell_look.md, "The chosen form").
Icon :: enum u8 {
	Window, // A framed window: a module of no other kind.
	Console, // A screen with a prompt.
	Monitor, // A chart of three bars on a base line.
	Clock, // A dial with two hands.
	Settings, // Three sliders.
	Document, // A page with lines of text.
	Manual, // An open book.
	Network, // Three nodes and their links.
	Debugger, // A bug.
	Picture, // A framed landscape with a sun.
	Disk, // A stack of three platters.
	Grant, // A key: a right or a grant.
	Sound, // A speaker and two waves.
	Capture, // A screen that records.
	Magnifier, // A lens and its handle.
	Bar_Edge, // A screen with its bar.
	Windows_List, // Three lines of a list.
	Switches, // Two switches, one off and one on: the control center.
	Bell, // A bell: the notifications.
	Globe, // A globe with its equator and its meridian: a browser.
	Contrast, // A square half filled: the appearance.
}

// icon_of gives the icon of the window or the module of a name, or Window
// for a name of no known kind, as the nickname of a disk process. The
// compositor asks once for each window, when the window takes its title;
// the tool writes the icon of each line of the start menu from it
// (start_menu_names.odin).
icon_of :: proc "contextless" (name: string) -> Icon {
	switch name {
	case "console", "terminal", "kernel_events":
		return .Console
	case "boot", "monitor", "budget", "crowd", "limits", "processors", "scheduler", "tally", "threads", "workers":
		return .Monitor
	case "log", "edit", "agenda", "interface_font", "notes", "tables":
		return .Document
	case "manual", "hall_of_fame":
		return .Manual
	case "settings":
		return .Settings
	case "clock":
		return .Clock
	case "pages", "address_space", "disk", "imports":
		return .Disk
	case "remote", "remote_display", "network", "flow", "net", "quic_echo", "rings", "server":
		return .Network
	case "debugger", "debugger_window", "inspect", "errors", "extended_state", "fault", "fault_ring", "locks", "return_fault":
		return .Debugger
	case "cryptography_vectors", "grants", "origin", "rights":
		return .Grant
	case "frames", "heron", "life", "paint", "plasma", "vector_glyphs":
		return .Picture
	case "sound", "tone":
		return .Sound
	case "browser":
		return .Globe
	}
	return .Window
}

// icon_records appends an icon with its corner at (x, y): its lines in
// color, and the part that tells it apart in accent.
icon_records :: proc "contextless" (table: ^interface.Draw_Table, x, y: int, icon: Icon, color, accent: graphics.Color) {
	part :: proc "contextless" (table: ^interface.Draw_Table, x, y, left, top, width, height: int, color: graphics.Color) {
		interface.draw_rectangle(table, x + left, y + top, width, height, color)
	}
	switch icon {
	case .Window:
		interface.draw_outline(table, x + 1, y + 2, 14, 12, 1, color)
		part(table, x, y, 2, 3, 12, 2, accent)
	case .Console:
		interface.draw_outline(table, x + 1, y + 2, 14, 12, 1, color)
		part(table, x, y, 4, 5, 2, 2, accent)
		part(table, x, y, 6, 7, 2, 2, accent)
		part(table, x, y, 4, 9, 2, 2, accent)
		part(table, x, y, 9, 10, 4, 1, color)
	case .Monitor:
		part(table, x, y, 1, 14, 14, 1, color)
		part(table, x, y, 3, 9, 2, 5, accent)
		part(table, x, y, 7, 4, 2, 10, accent)
		part(table, x, y, 11, 7, 2, 7, accent)
	case .Clock:
		interface.draw_outline(table, x + 2, y + 2, 12, 12, 1, color)
		part(table, x, y, 7, 4, 2, 5, accent)
		part(table, x, y, 9, 7, 3, 2, accent)
	case .Settings:
		part(table, x, y, 1, 3, 14, 1, color)
		part(table, x, y, 1, 8, 14, 1, color)
		part(table, x, y, 1, 13, 14, 1, color)
		part(table, x, y, 4, 1, 3, 5, accent)
		part(table, x, y, 9, 6, 3, 5, accent)
		part(table, x, y, 5, 11, 3, 5, accent)
	case .Document:
		interface.draw_outline(table, x + 3, y + 1, 10, 14, 1, color)
		part(table, x, y, 5, 4, 6, 1, accent)
		part(table, x, y, 5, 7, 6, 1, accent)
		part(table, x, y, 5, 10, 4, 1, accent)
	case .Manual:
		part(table, x, y, 1, 3, 6, 11, color)
		part(table, x, y, 9, 3, 6, 11, color)
		part(table, x, y, 7, 2, 2, 13, accent)
	case .Network:
		part(table, x, y, 6, 1, 4, 4, accent)
		part(table, x, y, 7, 5, 2, 3, color)
		part(table, x, y, 3, 8, 10, 1, color)
		part(table, x, y, 3, 9, 1, 2, color)
		part(table, x, y, 12, 9, 1, 2, color)
		part(table, x, y, 1, 11, 4, 4, color)
		part(table, x, y, 11, 11, 4, 4, color)
	case .Debugger:
		part(table, x, y, 6, 2, 4, 3, accent)
		part(table, x, y, 5, 5, 6, 9, color)
		part(table, x, y, 2, 7, 3, 1, color)
		part(table, x, y, 11, 7, 3, 1, color)
		part(table, x, y, 2, 11, 3, 1, color)
		part(table, x, y, 11, 11, 3, 1, color)
	case .Picture:
		interface.draw_outline(table, x + 1, y + 2, 14, 12, 1, color)
		part(table, x, y, 10, 4, 2, 2, accent)
		part(table, x, y, 3, 10, 3, 3, color)
		part(table, x, y, 6, 7, 3, 6, color)
		part(table, x, y, 9, 10, 4, 3, color)
	case .Disk:
		part(table, x, y, 2, 2, 12, 3, color)
		part(table, x, y, 2, 7, 12, 3, color)
		part(table, x, y, 2, 12, 12, 3, color)
		part(table, x, y, 11, 3, 2, 1, accent)
		part(table, x, y, 11, 8, 2, 1, accent)
		part(table, x, y, 11, 13, 2, 1, accent)
	case .Grant:
		interface.draw_outline(table, x + 1, y + 5, 6, 6, 1, accent)
		part(table, x, y, 7, 7, 8, 2, color)
		part(table, x, y, 11, 9, 2, 3, color)
		part(table, x, y, 14, 9, 1, 2, color)
	case .Sound:
		part(table, x, y, 2, 6, 3, 4, color)
		part(table, x, y, 5, 4, 2, 8, color)
		part(table, x, y, 9, 6, 1, 4, accent)
		part(table, x, y, 12, 3, 1, 10, accent)
	case .Capture:
		interface.draw_outline(table, x + 1, y + 2, 14, 12, 1, color)
		part(table, x, y, 6, 6, 4, 4, accent)
	case .Magnifier:
		interface.draw_outline(table, x + 1, y + 1, 9, 9, 1, color)
		part(table, x, y, 4, 4, 3, 3, accent)
		part(table, x, y, 9, 9, 2, 2, color)
		part(table, x, y, 11, 11, 2, 2, color)
		part(table, x, y, 13, 13, 2, 2, color)
	case .Bar_Edge:
		interface.draw_outline(table, x + 1, y + 2, 14, 12, 1, color)
		part(table, x, y, 2, 10, 12, 3, accent)
	case .Windows_List:
		part(table, x, y, 2, 2, 3, 3, accent)
		part(table, x, y, 7, 3, 7, 1, color)
		part(table, x, y, 2, 7, 3, 3, accent)
		part(table, x, y, 7, 8, 7, 1, color)
		part(table, x, y, 2, 12, 3, 3, accent)
		part(table, x, y, 7, 13, 7, 1, color)
	case .Switches:
		interface.draw_outline(table, x + 1, y + 2, 14, 5, 1, color)
		part(table, x, y, 3, 3, 4, 3, color)
		interface.draw_outline(table, x + 1, y + 9, 14, 5, 1, color)
		part(table, x, y, 9, 10, 4, 3, accent)
	case .Bell:
		part(table, x, y, 7, 1, 2, 2, color)
		part(table, x, y, 5, 3, 6, 2, color)
		part(table, x, y, 4, 5, 8, 6, color)
		part(table, x, y, 2, 11, 12, 2, color)
		part(table, x, y, 7, 14, 2, 2, accent)
	case .Globe:
		interface.draw_outline(table, x + 2, y + 2, 12, 12, 1, color)
		part(table, x, y, 3, 7, 10, 2, accent)
		part(table, x, y, 7, 3, 2, 10, accent)
	case .Contrast:
		interface.draw_outline(table, x + 2, y + 2, 12, 12, 1, color)
		part(table, x, y, 3, 3, 5, 10, accent)
	}
}

package role_policy

// The renderer of the terminal of the console that a boot image gives,
// with the screen of the machine (src/md/features/console_renderers.md,
// "Which renderer a machine runs"). The signed boot image gives the default
// holder of each role: an image with the compositor runs the desktop, and
// an image with no compositor runs one of the three renderers that draw no
// window. A plan of principal 0 can still override each holder.

// The module of each renderer of the terminal that draws no window. The
// default holder table names modules by their names, as this one does.
SERIAL_TERMINAL_MODULE :: "serial_terminal"
GRID_TERMINAL_MODULE :: "grid_terminal"
DOM_TERMINAL_MODULE :: "dom_terminal"

// Which module draws the terminal of the console.
Console_Renderer :: enum u8 {
	Desktop_Terminal = 0, // The terminal draws a window that the compositor shows: the holders of the image as they are.
	Serial_Terminal  = 1, // serial_terminal writes ANSI text on the second serial port; no process draws on the screen.
	Grid_Terminal    = 2, // grid_terminal draws a grid of characters on the framebuffer, and reads the keys of the input service.
	Dom_Terminal     = 3, // dom_terminal writes JSON lines on the second serial port for a page that draws them; no process draws on the screen.
}

// What the boot image holds and what the machine has, for the choice.
Console_Parts :: struct {
	compositor:      bool, // The image holds the default holder of Display.
	serial_terminal: bool, // The image holds serial_terminal.
	grid_terminal:   bool, // The image holds grid_terminal.
	dom_terminal:    bool, // The image holds dom_terminal.
	screen:          bool, // The machine has a framebuffer at the start.
}

// console_renderer_choose gives the renderer of a boot image on a machine.
// The compositor wins: an image with the desktop keeps it, whatever else it
// holds. With no compositor, dom_terminal comes first: an image that
// holds it is made for a page, which draws the terminal itself. Then
// grid_terminal, which needs a screen; then serial_terminal, which needs
// none. An image with none of them keeps the holders as they are, so a
// machine of a test with no console starts as before.
console_renderer_choose :: proc "contextless" (parts: Console_Parts) -> Console_Renderer {
	if parts.compositor {
		return .Desktop_Terminal
	}
	if parts.dom_terminal {
		return .Dom_Terminal
	}
	if parts.grid_terminal && parts.screen {
		return .Grid_Terminal
	}
	if parts.serial_terminal {
		return .Serial_Terminal
	}
	return .Desktop_Terminal
}

// Why the root service refuses the start of a renderer of the terminal.
Console_Renderer_Refusal :: enum u8 {
	None                       = 0, // The renderer starts.
	Desktop_Terminal           = 1, // The image runs the desktop: a terminal is a window, never a renderer with a device.
	Holder_Is_Not_The_Renderer = 2, // The holder of Terminal is not the module of the renderer: a plan cannot give COM2 or the framebuffer to another module.
	Renderer_Running           = 3, // A renderer runs: one process at a time holds COM2, or the framebuffer and the input ring.
}

// console_renderer_module gives the module of a renderer that draws no
// window, or "" for the desktop.
console_renderer_module :: proc "contextless" (renderer: Console_Renderer) -> string {
	switch renderer {
	case .Desktop_Terminal:
		return ""
	case .Serial_Terminal:
		return SERIAL_TERMINAL_MODULE
	case .Grid_Terminal:
		return GRID_TERMINAL_MODULE
	case .Dom_Terminal:
		return DOM_TERMINAL_MODULE
	}
	return ""
}

// console_renderer_needs_screen says if a process with the grant Terminal
// needs a screen to start: the terminal of the desktop and grid_terminal
// draw on it; serial_terminal and dom_terminal write the second serial
// port.
console_renderer_needs_screen :: proc "contextless" (renderer: Console_Renderer) -> bool {
	switch renderer {
	case .Desktop_Terminal, .Grid_Terminal:
		return true
	case .Serial_Terminal, .Dom_Terminal:
		return false
	}
	return true
}

// console_renderer_start_check says if the root service starts a renderer
// with its device: the holder of Terminal must be the module of the
// renderer, and no renderer may run. The device of a renderer is a part of
// the machine that one process holds: two renderers would write one serial
// port, or one screen, and read one keyboard.
console_renderer_start_check :: proc "contextless" (renderer: Console_Renderer, terminal_holder: string, renderer_running: bool) -> Console_Renderer_Refusal {
	module_name := console_renderer_module(renderer)
	if module_name == "" {
		return .Desktop_Terminal
	}
	if terminal_holder != module_name {
		return .Holder_Is_Not_The_Renderer
	}
	if renderer_running {
		return .Renderer_Running
	}
	return .None
}

// console_renderer_holders_set writes the default holders of Display and
// Terminal for a renderer. Serial_Terminal and Dom_Terminal leave Display
// with no holder: no process draws on the screen, and a start of "display"
// is refused as a role with no holder. Grid_Terminal gives both roles to
// grid_terminal: it is the one process that writes the screen. Desktop_Terminal changes
// nothing. Overrides stay as they are: a plan still wins over the image.
console_renderer_holders_set :: proc "contextless" (names: ^Holder_Names, renderer: Console_Renderer) {
	switch renderer {
	case .Desktop_Terminal:
	case .Serial_Terminal:
		names.defaults[.Display] = ""
		names.defaults[.Terminal] = SERIAL_TERMINAL_MODULE
	case .Dom_Terminal:
		names.defaults[.Display] = ""
		names.defaults[.Terminal] = DOM_TERMINAL_MODULE
	case .Grid_Terminal:
		names.defaults[.Display] = GRID_TERMINAL_MODULE
		names.defaults[.Terminal] = GRID_TERMINAL_MODULE
	}
}

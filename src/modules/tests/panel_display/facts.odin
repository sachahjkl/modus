package panel_display

import "modus:contract/value_kinds"

// The log facts of the barless second Display role holder
// (src/md/features/roles_and_contracts.md).

// The holder opened its screen, rings, and service ring and waits for windows.
@(log_fact = "panel_display: ready {width}x{height}")
Panel_Ready :: struct {
	width:  u64,
	height: u64,
}

// A screen could not be opened from the context.
@(log_fact = "panel_display: no framebuffer")
No_Framebuffer :: struct {}

// The input ring or control ring could not be opened from the context.
@(log_fact = "panel_display: no input or control ring")
No_Input_Or_Control_Ring :: struct {}

// The holder made the first surface for a window.
@(log_fact = "panel_display: surface {window} {width}x{height}")
Surface_Made :: struct {
	width:  u64,
	height: u64,
	window: [40]u8,
}

// The holder blitted the first presented picture of a window.
@(log_fact = "panel_display: shown {window}")
Window_Shown :: struct {
	window: [40]u8,
}

// The root service removed a client window.
@(log_fact = "panel_display: removed {window}")
Window_Removed :: struct {
	window: [40]u8,
}

// A record on the control ring had an unknown kind word.
@(log_fact = "panel_display: refused control word {word}")
Control_Word_Refused :: struct {
	word: u64,
}

// A record on the input ring had an unknown kind word.
@(log_fact = "panel_display: refused input word {word}")
Input_Word_Refused :: struct {
	word: u64,
}

// A record on a window ring had an unknown command word.
@(log_fact = "panel_display: refused window word {word}")
Window_Word_Refused :: struct {
	word: u64,
}

// window_field packs a client title into the fixed text field of a log fact.
window_field :: proc "contextless" (title: []u8) -> [40]u8 {
	return value_kinds.text_field(system_name_slice(title), 40)
}

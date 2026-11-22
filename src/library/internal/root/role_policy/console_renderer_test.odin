#+build !freestanding
package role_policy

import "core:testing"
import "modus:contract/role_contract"

// The default holders of a desktop image, as the root service writes them.
@(private = "file")
desktop_holder_names :: proc() -> Holder_Names {
	names: Holder_Names
	names.defaults[.Display] = "compositor"
	names.defaults[.Input] = "input"
	names.defaults[.Console] = "console"
	names.defaults[.Terminal] = "terminal"
	names.defaults[.Storage] = "storage"
	return names
}

// Each of the 32 cases of the five parts: the compositor wins whatever else
// the image holds; with no compositor, dom_terminal with or without a
// screen, then grid_terminal only with a screen, then serial_terminal with
// or without one; an image with no renderer keeps the desktop holders.
@(test)
console_renderer_choose_takes_each_case_of_the_parts :: proc(t: ^testing.T) {
	for bits in 0 ..< 32 {
		parts := Console_Parts {
			compositor      = bits & 1 != 0,
			serial_terminal = bits & 2 != 0,
			grid_terminal   = bits & 4 != 0,
			screen          = bits & 8 != 0,
			dom_terminal    = bits & 16 != 0,
		}
		expected := Console_Renderer.Desktop_Terminal
		switch {
		case parts.compositor:
			expected = .Desktop_Terminal
		case parts.dom_terminal:
			expected = .Dom_Terminal
		case parts.grid_terminal && parts.screen:
			expected = .Grid_Terminal
		case parts.serial_terminal:
			expected = .Serial_Terminal
		}
		testing.expectf(t, console_renderer_choose(parts) == expected, "%v gives %v, not %v", parts, console_renderer_choose(parts), expected)
	}
	// The cases that a reader looks for by name.
	testing.expect_value(t, console_renderer_choose({compositor = true, serial_terminal = true, grid_terminal = true, dom_terminal = true, screen = true}), Console_Renderer.Desktop_Terminal)
	testing.expect_value(t, console_renderer_choose({dom_terminal = true}), Console_Renderer.Dom_Terminal)
	testing.expect_value(t, console_renderer_choose({dom_terminal = true, grid_terminal = true, serial_terminal = true, screen = true}), Console_Renderer.Dom_Terminal)
	testing.expect_value(t, console_renderer_choose({serial_terminal = true}), Console_Renderer.Serial_Terminal)
	testing.expect_value(t, console_renderer_choose({serial_terminal = true, screen = true}), Console_Renderer.Serial_Terminal)
	testing.expect_value(t, console_renderer_choose({grid_terminal = true}), Console_Renderer.Desktop_Terminal)
	testing.expect_value(t, console_renderer_choose({grid_terminal = true, screen = true}), Console_Renderer.Grid_Terminal)
	testing.expect_value(t, console_renderer_choose({}), Console_Renderer.Desktop_Terminal)
}

// The desktop keeps each holder of the image. A serial console gives the
// terminal to serial_terminal and Display to no module, so the role name
// "display" resolves to nothing and a start of it is refused. A grid
// console gives Terminal to grid_terminal and Display to no module too:
// grid_terminal does not implement the display contract. Each other role
// keeps its holder in each case.
@(test)
console_renderer_holders_set_gives_display_and_terminal :: proc(t: ^testing.T) {
	desktop := desktop_holder_names()
	console_renderer_holders_set(&desktop, .Desktop_Terminal)
	testing.expect(t, desktop == desktop_holder_names())
	testing.expect_value(t, holder_name(&desktop, .Terminal), "terminal")

	serial := desktop_holder_names()
	console_renderer_holders_set(&serial, .Serial_Terminal)
	testing.expect_value(t, holder_name(&serial, .Terminal), SERIAL_TERMINAL_MODULE)
	testing.expect_value(t, holder_name(&serial, .Display), "")
	_, display_ok := target_resolve(&serial, role_contract.role_properties(.Display).name)
	testing.expect(t, !display_ok)
	testing.expect(t, !is_holder(&serial, "compositor", .Display))
	testing.expect(t, !is_holder(&serial, "", .Display))
	testing.expect_value(t, role_of_module(&serial, SERIAL_TERMINAL_MODULE), role_contract.Role.Terminal)
	testing.expect_value(t, role_of_module(&serial, "terminal"), role_contract.Role.None)

	grid := desktop_holder_names()
	console_renderer_holders_set(&grid, .Grid_Terminal)
	testing.expect_value(t, holder_name(&grid, .Display), "")
	testing.expect_value(t, holder_name(&grid, .Terminal), GRID_TERMINAL_MODULE)
	_, grid_display_ok := target_resolve(&grid, role_contract.role_properties(.Display).name)
	testing.expect(t, !grid_display_ok)
	testing.expect(t, !is_holder(&grid, GRID_TERMINAL_MODULE, .Display))
	testing.expect(t, !is_holder(&grid, "", .Display))
	testing.expect(t, is_holder(&grid, GRID_TERMINAL_MODULE, .Terminal))
	testing.expect(t, !is_holder(&grid, "compositor", .Display))
	testing.expect_value(t, role_of_module(&grid, GRID_TERMINAL_MODULE), role_contract.Role.Terminal)

	dom := desktop_holder_names()
	console_renderer_holders_set(&dom, .Dom_Terminal)
	testing.expect_value(t, holder_name(&dom, .Terminal), DOM_TERMINAL_MODULE)
	testing.expect_value(t, holder_name(&dom, .Display), "")
	_, dom_display_ok := target_resolve(&dom, role_contract.role_properties(.Display).name)
	testing.expect(t, !dom_display_ok)
	testing.expect_value(t, role_of_module(&dom, DOM_TERMINAL_MODULE), role_contract.Role.Terminal)
	testing.expect_value(t, role_of_module(&dom, SERIAL_TERMINAL_MODULE), role_contract.Role.None)

	for names in ([?]Holder_Names{serial, grid, dom}) {
		names := names
		for role in ([?]role_contract.Role{.Input, .Console, .Storage}) {
			testing.expect_value(t, holder_name(&names, role), holder_name(&desktop, role))
		}
	}
}

// A plan that overrides the terminal keeps its holder over the image of a
// console: the image gives the defaults only.
@(test)
console_renderer_holders_set_keeps_the_override_of_a_plan :: proc(t: ^testing.T) {
	names := desktop_holder_names()
	names.overrides[.Terminal] = "other_terminal"
	console_renderer_holders_set(&names, .Serial_Terminal)
	testing.expect_value(t, holder_name(&names, .Terminal), "other_terminal")
	testing.expect_value(t, names.defaults[.Terminal], SERIAL_TERMINAL_MODULE)
}

// The start of a renderer is refused for the desktop, for a holder of
// Terminal that is not the module of the renderer (the other renderer, the
// terminal of the desktop, an empty name, a name that differs by one byte),
// and while a renderer runs, whichever check fails first; a renderer starts
// only as its own module with no renderer running.
@(test)
console_renderer_start_check_refuses_a_second_renderer_and_another_holder :: proc(t: ^testing.T) {
	testing.expect_value(t, console_renderer_start_check(.Desktop_Terminal, "terminal", false), Console_Renderer_Refusal.Desktop_Terminal)
	testing.expect_value(t, console_renderer_start_check(.Desktop_Terminal, SERIAL_TERMINAL_MODULE, false), Console_Renderer_Refusal.Desktop_Terminal)
	others := [?]string{GRID_TERMINAL_MODULE, "terminal", "", "serial_terminal2", "serial_termina", "evil"}
	for other in others {
		testing.expectf(t, console_renderer_start_check(.Serial_Terminal, other, false) == .Holder_Is_Not_The_Renderer, "%q holds the serial renderer", other)
		testing.expectf(t, console_renderer_start_check(.Serial_Terminal, other, true) == .Holder_Is_Not_The_Renderer, "%q holds the serial renderer", other)
	}
	testing.expect_value(t, console_renderer_start_check(.Grid_Terminal, SERIAL_TERMINAL_MODULE, false), Console_Renderer_Refusal.Holder_Is_Not_The_Renderer)
	for other in ([?]string{SERIAL_TERMINAL_MODULE, GRID_TERMINAL_MODULE, "terminal", "", "dom_terminal2", "dom_termina"}) {
		testing.expectf(t, console_renderer_start_check(.Dom_Terminal, other, false) == .Holder_Is_Not_The_Renderer, "%q holds the DOM renderer", other)
	}
	testing.expect_value(t, console_renderer_start_check(.Serial_Terminal, DOM_TERMINAL_MODULE, false), Console_Renderer_Refusal.Holder_Is_Not_The_Renderer)
	testing.expect_value(t, console_renderer_start_check(.Dom_Terminal, DOM_TERMINAL_MODULE, true), Console_Renderer_Refusal.Renderer_Running)
	testing.expect_value(t, console_renderer_start_check(.Serial_Terminal, SERIAL_TERMINAL_MODULE, true), Console_Renderer_Refusal.Renderer_Running)
	testing.expect_value(t, console_renderer_start_check(.Grid_Terminal, GRID_TERMINAL_MODULE, true), Console_Renderer_Refusal.Renderer_Running)
	// A plan that overrides the terminal of a serial image is refused.
	names: Holder_Names
	console_renderer_holders_set(&names, .Serial_Terminal)
	names.overrides[.Terminal] = "other_terminal"
	testing.expect_value(t, console_renderer_start_check(.Serial_Terminal, holder_name(&names, .Terminal), false), Console_Renderer_Refusal.Holder_Is_Not_The_Renderer)
	// Last: each renderer as its own module with none running.
	testing.expect_value(t, console_renderer_start_check(.Serial_Terminal, SERIAL_TERMINAL_MODULE, false), Console_Renderer_Refusal.None)
	testing.expect_value(t, console_renderer_start_check(.Grid_Terminal, GRID_TERMINAL_MODULE, false), Console_Renderer_Refusal.None)
	testing.expect_value(t, console_renderer_start_check(.Dom_Terminal, DOM_TERMINAL_MODULE, false), Console_Renderer_Refusal.None)
	testing.expect_value(t, console_renderer_module(.Desktop_Terminal), "")
	testing.expect(t, console_renderer_needs_screen(.Desktop_Terminal) && console_renderer_needs_screen(.Grid_Terminal))
	testing.expect(t, !console_renderer_needs_screen(.Serial_Terminal) && !console_renderer_needs_screen(.Dom_Terminal))
}

package site

import "core:strings"
import "core:testing"

@(test)
site_browser_machine_html_contains_wasm_bridge_and_blank_relay :: proc(t: ^testing.T) {
	html := site_browser_machine_html()
	testing.expect(t, len(html) > 0, "browser_machine.html must not be empty")
	testing.expect(t, strings.has_prefix(html, "<!doctype html>"), "must start with HTML5 doctype")

	// Must bind every required freestanding WebAssembly export symbol.
	required_exports := [?]string {
		"modus_vm_init",
		"modus_vm_load_bytes",
		"modus_vm_step_budget",
		"modus_vm_framebuffer_ptr",
		"modus_vm_framebuffer_bytes",
		"modus_vm_push_key",
		"modus_vm_push_pointer",
		"modus_vm_pop_serial",
		"modus_vm_state_word",
	}
	for symbol in required_exports {
		testing.expectf(t, strings.contains(html, symbol), "browser_machine.html must call %s", symbol)
	}

	// Must render framebuffer on canvas, forward keyboard/pointer events, and display serial output.
	testing.expect(t, strings.contains(html, `<canvas id="screen"`))
	testing.expect(t, strings.contains(html, "putImageData"))
	testing.expect(t, strings.contains(html, `"keydown"`))
	testing.expect(t, strings.contains(html, `"pointermove"`))
	testing.expect(t, strings.contains(html, `id="serial-output"`))

	// Must handle non-isolated single-processor fallback gracefully.
	testing.expect(t, strings.contains(html, "window.crossOriginIsolated"))

	// Bring-your-own link relay URL field MUST default to empty and run no site relay.
	testing.expect(t, strings.contains(html, `<input id="relay-url" type="url" value=""`))
	testing.expect(t, strings.contains(html, "site runs no relay"))
	testing.expect(t, !strings.contains(html, "relay.modus.froment.software"), "site must never hardcode a project-operated relay")
}

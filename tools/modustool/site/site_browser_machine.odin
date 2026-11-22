// Browser machine runner page emitted as a static asset of the site
// (src/md/features/browser_machine.md, "The devices of the page").
//
// Provides a minimal, self-contained HTML and JavaScript harness that loads
// the freestanding WebAssembly software machine runtime, blits its RGBA
// framebuffer onto a canvas, forwards keyboard and pointer events, drains the
// serial output ring, runs single-processor without cross-origin isolation,
// and leaves the optional bring-your-own link relay URL blank by default.
package site

SITE_BROWSER_MACHINE_FILE :: "browser_machine.html"

@(private = "file")
SITE_BROWSER_MACHINE_HTML :: #load("browser_machine.html", string)

// site_browser_machine_html returns the self-contained browser machine runner
// HTML document shipped as a static asset beside the generated site.
site_browser_machine_html :: proc() -> string {
	return SITE_BROWSER_MACHINE_HTML
}

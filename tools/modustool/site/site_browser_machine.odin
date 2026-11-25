// The Try section and the browser machine pages on the site
// (src/md/features/browser_machine.md, "The page and its host"): the Try
// landing page (`try/index.html`), the static files of both the desktop and
// console pages, and the built WebAssembly kernel and boot images copied
// beside them when present.
package site

import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:build"

// site_try_add adds the Try section page (`try/index.html`) presenting both
// live WebAssembly machines: the fast Web Console (`browser_machine_console.html`)
// and the full Web Desktop (`browser_machine.html`).
site_try_add :: proc(site: ^Site) {
	path := site_section_page(.Try)
	console_link := site_relative(path, build.BROWSER_MACHINE_CONSOLE_PAGE_FILE)
	desktop_link := site_relative(path, "browser_machine.html")
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<h1>Try modus in the browser</h1>\n")
	strings.write_string(&b, "<p>Run unmodified x86-64 modus modules on the WebAssembly kernel locally in a Web Worker. Nothing is installed and nothing runs on a server.</p>\n")
	strings.write_string(&b, "<div class=\"docs-parts\">\n")

	// Card 1: Web Console.
	strings.write_string(&b, "<section class=\"card accent-kernel\" aria-labelledby=\"try-console\">\n")
	strings.write_string(&b, "<h2 id=\"try-console\">Web Console</h2>\n")
	strings.write_string(&b, "<p>Boots the minimal console image (<code>console.image</code>, about 5 MiB) with <code>dom_terminal</code> directly in the document, with no desktop overhead.</p>\n")
	fmt.sbprintf(&b, "<ul class=\"doors\"><li><a href=\"%s\">Open Web Console</a></li></ul>\n", console_link)
	strings.write_string(&b, "<p>Starter commands:</p>\n")
	strings.write_string(&b, "<pre><code>help()\nprocesses()\ns = isolate(\"sample\")\ns.readings(4)</code></pre>\n")
	strings.write_string(&b, "</section>\n")

	// Card 2: Web Desktop.
	strings.write_string(&b, "<section class=\"card accent-process\" aria-labelledby=\"try-desktop\">\n")
	strings.write_string(&b, "<h2 id=\"try-desktop\">Web Desktop</h2>\n")
	strings.write_string(&b, "<p>Boots the full graphical desktop (<code>boot.image</code>) with the compositor, vector fonts, console, and applications on a 1280 x 800 canvas.</p>\n")
	fmt.sbprintf(&b, "<ul class=\"doors\"><li><a href=\"%s\">Open Web Desktop</a></li></ul>\n", desktop_link)
	strings.write_string(&b, "<p>Press <code>Start</code> on the desktop page to boot. Modules are hashed on first use; boot stages appear on the canvas and in the COM1 serial log.</p>\n")
	strings.write_string(&b, "</section>\n")

	strings.write_string(&b, "</div>\n")
	site_page_add(site, Site_Page {
		path        = path,
		is_index    = true,
		title       = "Try",
		description = "Run modus in the browser: fast Web Console (about 5 MiB) or full Web Desktop on the WebAssembly kernel with no install.",
		section     = .Try,
		crumbs      = site_crumbs(.Home),
		body        = strings.to_string(b),
		sources     = site_sources("tools/modustool/site/site_browser_machine.odin", "tools/modustool/build/browser_machine.odin"),
		layout      = .Presentation,
	})
}

// site_browser_machine_copy_image copies one boot image into the site root
// under target_name and writes its accompanying `.trust` hash file (copying
// `<source>.trust` when present, else computing it from the signed image).
@(private = "file")
site_browser_machine_copy_image :: proc(site: ^Site, source_path, target_name: string) -> bool {
	bytes, read_error := os.read_entire_file(source_path, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: site: cannot read %s: %v", source_path, read_error)
		return false
	}
	site_write_file(site, target_name, bytes) or_return
	trust_name := strings.concatenate({target_name, build.BROWSER_MACHINE_TRUST_SUFFIX}, context.temp_allocator)
	source_trust := strings.concatenate({source_path, build.BROWSER_MACHINE_TRUST_SUFFIX}, context.temp_allocator)
	if os.is_file(source_trust) {
		trust_bytes, trust_err := os.read_entire_file(source_trust, context.temp_allocator)
		if trust_err != nil {
			fmt.eprintfln("modustool: site: cannot read %s: %v", source_trust, trust_err)
			return false
		}
		site_write_file(site, trust_name, trust_bytes) or_return
	} else if hex, found := build.browser_machine_trust_hash_hex(bytes); found {
		text := strings.concatenate({hex, "\n"}, context.temp_allocator)
		site_write_file(site, trust_name, transmute([]u8)text) or_return
	}
	return true
}

// site_browser_machine_copy_artifacts copies the built WebAssembly kernel,
// console image, and desktop image (plus `.trust` files) into the site when
// present on disk. Desktop image selection prefers the filtered browser
// machine desktop image, then `boot_release.image` (no test modules), then
// `boot.image`. Missing files are skipped so sandboxed host tests without
// `build/` still succeed.
site_browser_machine_copy_artifacts :: proc(site: ^Site, browser_machine_folder, release_image_path, boot_image_path: string) -> (copied: int, ok: bool) {
	kernel_src := strings.concatenate({browser_machine_folder, "/", build.BROWSER_MACHINE_KERNEL_FILE}, context.temp_allocator)
	if os.is_file(kernel_src) {
		bytes, read_error := os.read_entire_file(kernel_src, context.temp_allocator)
		if read_error != nil {
			fmt.eprintfln("modustool: site: cannot read %s: %v", kernel_src, read_error)
			return copied, false
		}
		site_write_file(site, build.BROWSER_MACHINE_KERNEL_FILE, bytes) or_return
		copied += 1
	}

	console_src := strings.concatenate({browser_machine_folder, "/", build.BROWSER_MACHINE_CONSOLE_IMAGE_FILE}, context.temp_allocator)
	if os.is_file(console_src) {
		site_browser_machine_copy_image(site, console_src, build.BROWSER_MACHINE_CONSOLE_IMAGE_FILE) or_return
		copied += 1
	}

	bm_desktop_src := strings.concatenate({browser_machine_folder, "/", build.BROWSER_MACHINE_BOOT_IMAGE_FILE}, context.temp_allocator)
	desktop_src := ""
	switch {
	case os.is_file(bm_desktop_src):
		desktop_src = bm_desktop_src
	case os.is_file(release_image_path):
		desktop_src = release_image_path
	case os.is_file(boot_image_path):
		desktop_src = boot_image_path
	}
	if desktop_src != "" {
		site_browser_machine_copy_image(site, desktop_src, build.BROWSER_MACHINE_BOOT_IMAGE_FILE) or_return
		copied += 1
	}
	return copied, true
}

// site_browser_machine_write writes every static file of the desktop and
// console browser machine pages beside the pages of the site, and copies the
// built WebAssembly kernel and boot images when present.
site_browser_machine_write :: proc(site: ^Site) -> bool {
	files := build.BROWSER_MACHINE_PAGE_FILES
	for file in files {
		site_write_file(site, file.name, transmute([]u8)file.text) or_return
	}
	copied, ok := site_browser_machine_copy_artifacts(site, build.BROWSER_MACHINE_FOLDER, build.BOOT_IMAGE_RELEASE, build.BOOT_IMAGE)
	if !ok {
		return false
	}
	if copied > 0 {
		fmt.printfln("modustool: site: browser machine artifacts copied: %d (wasm %d bytes, console.image %d bytes, boot.image %d bytes)", copied, site.files[build.BROWSER_MACHINE_KERNEL_FILE], site.files[build.BROWSER_MACHINE_CONSOLE_IMAGE_FILE], site.files[build.BROWSER_MACHINE_BOOT_IMAGE_FILE])
	}
	return true
}

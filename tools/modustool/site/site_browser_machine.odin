// The page of a browser machine on the site
// (src/md/features/browser_machine.md, "The page and its host"): the files
// of the page, its worker and the host of the kernel, which the build
// package holds for its command browser-machine too.
package site

import "modustool:build"

// site_browser_machine_write writes each file of the page beside the pages
// of the site. The kernel and the boot image are not files of the site: the
// command browser-machine writes them beside the page.
site_browser_machine_write :: proc(site: ^Site) -> bool {
	files := build.BROWSER_MACHINE_PAGE_FILES
	for file in files {
		site_write_file(site, file.name, transmute([]u8)file.text) or_return
	}
	return true
}

package site

import "core:os"
import "core:strings"
import "core:testing"
import "modustool:build"
import "modustool:foundation"

// The Try page links cleanly to both the Web Console and Web Desktop static
// pages, keeps one h1, a description within SITE_DESCRIPTION_LIMIT, no inline
// style or script, and passes site_check_pages.
@(test)
site_try_page_structure_and_links :: proc(t: ^testing.T) {
	site := test_site()
	site.address = SITE_ADDRESS
	append(&site.pages, Site_Page{path = site_section_page(.Home), is_index = true, title = SITE_SYSTEM_NAME, description = "modus home.", section = .Home, body = "<h1>modus</h1>\n"})
	site_try_add(&site)
	testing.expect_value(t, len(site.pages), 2)
	page := site.pages[1]
	testing.expect_value(t, page.path, "try/index.html")
	testing.expect_value(t, page.section, Site_Section.Try)
	testing.expect(t, page.is_index)
	testing.expect(t, len(page.description) > 0 && len(page.description) <= SITE_DESCRIPTION_LIMIT)
	testing.expect(t, strings.contains(page.body, "../browser_machine_console.html"))
	testing.expect(t, strings.contains(page.body, "../browser_machine.html"))
	testing.expect(t, strings.contains(page.body, `class="c-`))
	testing.expect(t, strings.contains(page.body, `isolate`))
	testing.expect(t, strings.contains(page.body, `sample`))
	testing.expect(t, strings.contains(page.body, `readings`))

	files := build.BROWSER_MACHINE_PAGE_FILES
	for file in files {
		site.files[file.name] = len(file.text)
	}
	// Provide the files referenced in site_page_html head/bar/foot.
	for name in ([]string{
		SITE_STYLE_SHEET, SITE_SEARCH_SCRIPT, SITE_SEARCH_INDEX, SITE_RELEASES_FEED, SITE_MANIFEST,
		SITE_MARK_FONT, "favicon.ico", "mark_animation.js", "pictures/icon.svg", "pictures/icon_180.png",
		"pictures/mark_bar.png", "pictures/mark_bar_light.png", "pictures/froment_software.png",
	}) {
		site.files[name] = 1
	}
	append(&site.pages, Site_Page{path = site_section_page(.Releases), is_index = true, title = "Releases", description = "Releases.", section = .Releases, body = "<h1>Releases</h1>\n<section id=\"release-part\"></section>\n"})
	append(&site.pages, Site_Page{path = site_page_file(SITE_LICENSES_FOLDER), is_index = true, title = "Credits", description = "Credits.", section = .Reference, body = "<h1>Credits</h1>\n"})

	written := make(map[string]string, context.temp_allocator)
	for p in site.pages {
		written[p.path] = site_page_html(&site, p)
	}
	problems := site_check_pages(site.pages[:], written, site.files, true)
	testing.expect_value(t, len(problems), 0)
	for problem in problems {
		testing.expectf(t, false, "site_check_pages fault: %s", problem)
	}
}

// site_browser_machine_copy_artifacts copies present binaries + .trust files,
// prefers the browser-machine desktop image then boot_release.image then
// boot.image, and succeeds cleanly when no build artifacts exist (sandboxed
// host tests).
@(test)
site_browser_machine_copy_artifacts_precedence_and_absence :: proc(t: ^testing.T) {
	root, mk_err := os.make_directory_temp("", "modus_site_bm_*", context.temp_allocator)
	if !testing.expectf(t, mk_err == nil, "make temp dir: %v", mk_err) {
		return
	}
	defer _ = os.remove_all(root)

	bm_dir := strings.concatenate({root, "/bm"}, context.temp_allocator)
	release_img := strings.concatenate({root, "/boot_release.image"}, context.temp_allocator)
	boot_img := strings.concatenate({root, "/boot.image"}, context.temp_allocator)

	// 1. Nothing built yet: succeeds with 0 copied artifacts.
	orig_cwd, _ := os.get_working_directory(context.temp_allocator)
	site_work := strings.concatenate({root, "/work"}, context.temp_allocator)
	_ = os.make_directory_all(site_work)
	_ = os.set_working_directory(site_work)
	defer _ = os.set_working_directory(orig_cwd)

	_ = foundation.reset_folder(SITE_FOLDER)
	s0 := test_site()
	copied0, ok0 := site_browser_machine_copy_artifacts(&s0, bm_dir, release_img, boot_img)
	testing.expect(t, ok0 && copied0 == 0)
	testing.expect_value(t, s0.files[build.BROWSER_MACHINE_KERNEL_FILE], 0)

	// 2. Fallback to boot_release.image over boot.image when bm/boot.image is absent.
	_ = os.make_directory_all(bm_dir)
	_ = os.write_entire_file(strings.concatenate({bm_dir, "/", build.BROWSER_MACHINE_KERNEL_FILE}, context.temp_allocator), transmute([]u8)string("wasm-bytes"))
	_ = os.write_entire_file(strings.concatenate({bm_dir, "/", build.BROWSER_MACHINE_CONSOLE_IMAGE_FILE}, context.temp_allocator), transmute([]u8)string("console-img"))
	_ = os.write_entire_file(strings.concatenate({bm_dir, "/", build.BROWSER_MACHINE_CONSOLE_IMAGE_FILE, build.BROWSER_MACHINE_TRUST_SUFFIX}, context.temp_allocator), transmute([]u8)string("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"))
	_ = os.write_entire_file(release_img, transmute([]u8)string("release-img-bytes"))
	_ = os.write_entire_file(boot_img, transmute([]u8)string("full-boot"))

	_ = foundation.reset_folder(SITE_FOLDER)
	s1 := test_site()
	copied1, ok1 := site_browser_machine_copy_artifacts(&s1, bm_dir, release_img, boot_img)
	testing.expect(t, ok1 && copied1 == 3)
	testing.expect_value(t, s1.files[build.BROWSER_MACHINE_KERNEL_FILE], len("wasm-bytes"))
	testing.expect_value(t, s1.files[build.BROWSER_MACHINE_CONSOLE_IMAGE_FILE], len("console-img"))
	testing.expect_value(t, s1.files[build.BROWSER_MACHINE_CONSOLE_IMAGE_FILE + build.BROWSER_MACHINE_TRUST_SUFFIX], 65)
	testing.expect_value(t, s1.files[build.BROWSER_MACHINE_BOOT_IMAGE_FILE], len("release-img-bytes"))

	// 3. Dedicated bm/boot.image wins over boot_release.image when present.
	_ = os.write_entire_file(strings.concatenate({bm_dir, "/", build.BROWSER_MACHINE_BOOT_IMAGE_FILE}, context.temp_allocator), transmute([]u8)string("bm-desktop-clean-image"))
	_ = os.write_entire_file(strings.concatenate({bm_dir, "/", build.BROWSER_MACHINE_BOOT_IMAGE_FILE, build.BROWSER_MACHINE_TRUST_SUFFIX}, context.temp_allocator), transmute([]u8)string("fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210\n"))
	_ = foundation.reset_folder(SITE_FOLDER)
	s2 := test_site()
	copied2, ok2 := site_browser_machine_copy_artifacts(&s2, bm_dir, release_img, boot_img)
	testing.expect(t, ok2 && copied2 == 3)
	testing.expect_value(t, s2.files[build.BROWSER_MACHINE_BOOT_IMAGE_FILE], len("bm-desktop-clean-image"))
	testing.expect_value(t, s2.files[build.BROWSER_MACHINE_BOOT_IMAGE_FILE + build.BROWSER_MACHINE_TRUST_SUFFIX], 65)
}

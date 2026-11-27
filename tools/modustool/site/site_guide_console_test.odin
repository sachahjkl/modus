package site

import "core:strings"
import "core:testing"
import "modustool:build"

@(test)
site_guide_console_extracts_runnable_lines_and_refuses_non_commands :: proc(t: ^testing.T) {
	// Direct runnable Lex commands with comments stripped.
	direct := "help(\"where\") // lookup\n1 MiB + 512 KiB\nprocesses() |> sort(\"resident\")\n"
	lines := site_guide_console_lines(direct)
	testing.expect_value(t, len(lines), 3)
	if len(lines) == 3 {
		testing.expect_value(t, lines[0], "help(\"where\")")
		testing.expect_value(t, lines[1], "1 MiB + 512 KiB")
		testing.expect_value(t, lines[2], "processes() |> sort(\"resident\")")
	}

	// Console transcript extracts only "> " command lines and drops output/error lines.
	transcript := "> 6 * 7\n42\n> \"abc\" + \"def\"\nabcdef\n> settings.set(font = .comic)\nerror: settings.set: Font has no member .comic\n"
	tlines := site_guide_console_lines(transcript)
	testing.expect_value(t, len(tlines), 3)
	if len(tlines) == 3 {
		testing.expect_value(t, tlines[0], "6 * 7")
		testing.expect_value(t, tlines[1], "\"abc\" + \"def\"")
		testing.expect_value(t, tlines[2], "settings.set(font = .comic)")
	}

	// Refusal cases: empty, comments-only, multi-line declarative files,
	// unbalanced delimiters, placeholder <name> or ellipsis ... grammar snippets.
	refused := [?]string {
		"",
		"   \n// comment only\n",
		"project {\n  source = here(),\n}\n",
		"plan {\n  values = { font = .vector },\n}\n",
		"let\n  x = 1\nin x\n",
		"recipes.configure_publisher(<64-hex-seed>)\n",
		"start(name, ...)\n",
		"map([1, 2, 3], (x) => x * 2\n",
	}
	for sample in refused {
		got := site_guide_console_lines(sample)
		testing.expectf(t, len(got) == 0, "expected refusal for %q, got %v", sample, got)
	}

	// Line limit boundary: > SITE_GUIDE_CONSOLE_LINE_LIMIT direct lines refused.
	over := strings.repeat("1 + 1\n", SITE_GUIDE_CONSOLE_LINE_LIMIT + 1, context.temp_allocator)
	testing.expect_value(t, len(site_guide_console_lines(over)), 0)
	exact := strings.repeat("1 + 1\n", SITE_GUIDE_CONSOLE_LINE_LIMIT, context.temp_allocator)
	testing.expect_value(t, len(site_guide_console_lines(exact)), SITE_GUIDE_CONSOLE_LINE_LIMIT)
}

@(test)
site_guide_console_escapes_attributes_and_blocks_xss :: proc(t: ^testing.T) {
	site := test_site()
	site.address = SITE_ADDRESS
	renderer := site_renderer_make(&site, "docs/guides/COURSE/index.html", "docs/COURSE.md")

	// Payload containing quotes, angle brackets, ampersands, and script tags inside a Lex string.
	markdown := "# Course\n\n```lex\n\"<script>alert('x')&\\\"y\\\"</script>\"\n1 MiB + 512 KiB\n```\n"
	site_render_markdown(&renderer, markdown)
	html := strings.to_string(renderer.builder)

	testing.expect(t, renderer.has_guide_console)
	testing.expect(t, strings.contains(html, `<div class="guide-console" data-console-lines="`))
	testing.expect(t, strings.contains(html, `data-console-root="../../../"`))
	// Raw dangerous characters never appear unescaped inside HTML or attributes.
	testing.expect(t, !strings.contains(html, "<script>"))
	testing.expect(t, strings.contains(html, `&quot;&lt;script&gt;alert(&#39;x&#39;)&amp;\&quot;y\&quot;&lt;/script&gt;&quot;&#10;1 MiB + 512 KiB`))
	// Progressive fallback: static <pre><code> stays intact, button starts hidden, link points to Web Console.
	testing.expect(t, strings.contains(html, "<pre><code>"))
	testing.expect(t, strings.contains(html, `class="guide-console-run" aria-expanded="false" hidden>Run in browser console</button>`))
	testing.expect(t, strings.contains(html, `href="../../../console/">Open Web Console</a>`))
	testing.expect(t, strings.contains(html, `class="guide-console-panel" role="region" aria-label="Interactive modus console" hidden></div>`))
	// Strict CSP check: zero inline styles and zero inline scripts.
	testing.expect_value(t, site_inline_code_problem(html), "")
}

@(test)
site_guide_console_skips_non_guide_pages_and_passes_site_checks :: proc(t: ^testing.T) {
	site := test_site()
	site.address = SITE_ADDRESS

	// Source comment rendering must never emit an interactive guide console widget.
	comment_renderer := site_renderer_make(&site, "docs/reference/modules/console/index.html", "")
	comment_renderer.comment = true
	site_render_markdown(&comment_renderer, "```lex\nhelp()\n```\n")
	testing.expect(t, !comment_renderer.has_guide_console)
	testing.expect(t, !strings.contains(strings.to_string(comment_renderer.builder), "guide-console"))

	// Declarative non-runnable Lex block in a guide emits plain <pre><code> without console chrome.
	decl_renderer := site_renderer_make(&site, "docs/guides/DECL/index.html", "docs/DECL.md")
	site_render_markdown(&decl_renderer, "# Decl\n\n```lex\nproject {\n  source = here(),\n}\n```\n")
	testing.expect(t, !decl_renderer.has_guide_console)
	testing.expect(t, !strings.contains(strings.to_string(decl_renderer.builder), "guide-console"))

	// Guide script is listed in SITE_VERSIONED_FILES, uses zero innerHTML, and
	// reuses the existing browser_machine_worker.js + console.image bridge.
	versioned := SITE_VERSIONED_FILES
	listed := false
	for f in versioned {
		listed ||= f == SITE_GUIDE_CONSOLE_SCRIPT
	}
	testing.expect(t, listed)

	script := site_guide_console_script()
	testing.expect(t, !strings.contains(script, "innerHTML"))
	testing.expect(t, strings.contains(script, "browser_machine_worker.js"))
	testing.expect(t, strings.contains(script, "modulus_kernel.wasm"))
	testing.expect(t, strings.contains(script, "console.image"))
	testing.expect(t, strings.contains(script, `kind: "console_type"`))
	testing.expect(t, strings.contains(script, "Escape"))
	testing.expect(t, strings.contains(script, "ArrowUp"))

	// Full page assembly with guide_console.js passes site_check_pages.
	guide_renderer := site_renderer_make(&site, "docs/guides/COURSE/index.html", "docs/COURSE.md")
	site_render_markdown(&guide_renderer, "# Course\n\n```lex\nhelp()\n```\n")
	testing.expect(t, guide_renderer.has_guide_console)

	append(&site.pages, Site_Page{path = site_section_page(.Home), is_index = true, title = SITE_SYSTEM_NAME, description = "modus home.", section = .Home, body = "<h1>modus</h1>\n"})
	append(&site.pages, Site_Page{path = site_section_page(.Guides), is_index = true, title = "Guides", description = "Guides.", section = .Guides, body = "<h1>Guides</h1>\n", layout = .Documentation})
	append(&site.pages, Site_Page{path = site_section_page(.Docs), is_index = true, title = "Docs", description = "Docs.", section = .Docs, body = "<h1>Docs</h1>\n", layout = .Documentation})
	append(&site.pages, Site_Page{path = site_section_page(.Releases), is_index = true, title = "Releases", description = "Releases.", section = .Releases, body = "<h1>Releases</h1>\n<section id=\"release-part\"></section>\n"})
	append(&site.pages, Site_Page{path = site_page_file(SITE_LICENSES_FOLDER), is_index = true, title = "Credits", description = "Credits.", section = .Reference, body = "<h1>Credits</h1>\n"})
	append(&site.pages, Site_Page{
		path        = "docs/guides/COURSE/index.html",
		title       = "Course",
		description = "Hands-on course.",
		section     = .Guides,
		crumbs      = site_crumbs(.Guides),
		body        = strings.to_string(guide_renderer.builder),
		layout      = .Documentation,
		script      = SITE_GUIDE_CONSOLE_SCRIPT,
	})

	files := build.BROWSER_MACHINE_PAGE_FILES
	for file in files {
		site.files[file.name] = len(file.text)
	}
	for name in ([]string{
		SITE_STYLE_SHEET, SITE_SEARCH_SCRIPT, SITE_SEARCH_INDEX, SITE_RELEASES_FEED, SITE_MANIFEST,
		SITE_MARK_FONT, SITE_GUIDE_CONSOLE_SCRIPT, "favicon.ico", "mark_animation.js",
		"pictures/icon.svg", "pictures/icon_180.png", "pictures/mark_bar.png", "pictures/mark_bar_light.png", "pictures/froment_software.png",
	}) {
		site.files[name] = 1
	}

	written := make(map[string]string, context.temp_allocator)
	for p in site.pages {
		written[p.path] = site_page_html(&site, p)
	}
	testing.expect(t, strings.contains(written["docs/guides/COURSE/index.html"], SITE_GUIDE_CONSOLE_SCRIPT))
	problems := site_check_pages(site.pages[:], written, site.files, true)
	testing.expect_value(t, len(problems), 0)
	for problem in problems {
		testing.expectf(t, false, "site_check_pages fault: %s", problem)
	}
}

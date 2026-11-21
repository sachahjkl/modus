package site

import "core:strings"
import "core:testing"
import "modustool:checks"

// A site with one release and one news entry: the pages of the releases
// and of the news, as the command writes them.
@(private = "file")
subscribe_test_site :: proc() -> Site {
	site := test_site()
	site.release = "0.1.0"
	releases := make([]checks.Changelog_Release, 1, context.temp_allocator)
	entries := make([]checks.Changelog_Entry, 1, context.temp_allocator)
	lines := make([]string, 1, context.temp_allocator)
	lines[0] = "**A thing**: it works."
	entries[0] = checks.Changelog_Entry{type_index = 0, lines = lines}
	releases[0] = checks.Changelog_Release{number = checks.Release_Number{0, 1, 0}, date = "2026-11-12", entries = entries}
	site.changelog.releases = releases
	news := make([]Site_News, 1, context.temp_allocator)
	news[0] = Site_News{entry = checks.News_Entry{file_name = "2026-11-12-a.md", title = "A thing", date = "2026-11-12", release = checks.NEWS_NEXT_RELEASE, guide = checks.NEWS_NONE, kind = .Shown, text = "A thing works. More text."}, anchor = "news-2026-11-12-a"}
	site.news = news
	site_news_add(&site)
	site_releases_add(&site)
	return site
}

// subscribe_test_target gives the file of the site that a relative link of
// a page names: each "../" climbs one folder of the page.
@(private = "file")
subscribe_test_target :: proc(from_page, link: string) -> string {
	target := link
	for _ in 0 ..< strings.count(from_page, "/") {
		if !strings.has_prefix(target, "../") {
			return ""
		}
		target = target[3:]
	}
	return target
}

// The pages of the releases and of the news each have one subscribe menu,
// closed in the file, under the heading: the link to the feed of the page,
// which is a file that the command writes in the Atom format, and the link
// to the releases of the repository. No link names RSS or X.
@(test)
site_subscribe_menu_on_the_pages_of_the_changes :: proc(t: ^testing.T) {
	site := subscribe_test_site()
	Case :: struct {
		page: string,
		feed: string,
		text: string, // The file that the command writes under that name.
	}
	cases := [?]Case {
		{site_section_page(.Releases), SITE_RELEASES_FEED, site_releases_feed(&site)},
		{site_section_page(.News), SITE_NEWS_FEED, site_news_feed(&site)},
	}
	for test_case in cases {
		body := ""
		for page in site.pages {
			if page.path == test_case.page {
				body = page.body
			}
		}
		testing.expectf(t, body != "", "the page %s is not written", test_case.page)
		if body == "" {
			continue
		}
		testing.expect_value(t, strings.count(body, SITE_SUBSCRIBE_MENU_OPEN), 1)
		testing.expect_value(t, strings.count(body, "<details"), 1)
		testing.expectf(t, !strings.contains(body, "<details open"), "%s: the menu is open in the file", test_case.page)
		// The menu is the first part after the heading.
		heading_end := strings.index(body, "</h1>\n")
		testing.expectf(t, heading_end >= 0 && strings.index(body, SITE_SUBSCRIBE_MENU_OPEN) == heading_end + len("</h1>\n"), "%s: the menu does not follow the heading", test_case.page)
		start := strings.index(body, SITE_SUBSCRIBE_MENU_OPEN)
		menu := body[start:]
		menu = menu[:strings.index(menu, "</details>")]
		testing.expect_value(t, strings.count(menu, "<a "), 2)
		testing.expect_value(t, strings.count(menu, SITE_SUBSCRIBE_ARROW + "</a>"), 2)

		// The feed: the link of the menu names the file of the feed of
		// this page, and that file is an Atom feed that the command writes.
		feed_open := "<a href=\""
		feed_at := strings.index(menu, feed_open)
		testing.expect(t, feed_at >= 0)
		if feed_at < 0 {
			continue
		}
		rest := menu[feed_at + len(feed_open):]
		link := rest[:strings.index_byte(rest, '"')]
		testing.expect_value(t, subscribe_test_target(test_case.page, link), test_case.feed)
		testing.expect(t, strings.contains(menu, strings.concatenate({link, "\" type=\"application/atom+xml\">", SITE_SUBSCRIBE_FEED_LABEL, SITE_SUBSCRIBE_ARROW, "</a>"}, context.temp_allocator)))
		testing.expectf(t, strings.has_prefix(test_case.text, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<feed xmlns=\"http://www.w3.org/2005/Atom\">"), "%s: the feed is not Atom", test_case.feed)
		testing.expect(t, strings.contains(test_case.text, "<entry>"))

		// The releases of the repository.
		testing.expect(t, strings.contains(menu, "<a href=\"" + checks.REPOSITORY_ADDRESS + "/releases\">" + SITE_SUBSCRIBE_WATCH_LABEL + SITE_SUBSCRIBE_ARROW + "</a>"))

		lower := strings.to_lower(menu, context.temp_allocator)
		for refused in ([]string{"rss", "x.com", "twitter"}) {
			testing.expectf(t, !strings.contains(lower, refused), "%s: the menu names %q", test_case.page, refused)
		}
	}
}

// The rules of the menu: the panel lies over the page, its width is the
// width of its longest line, and it keeps inside a window of 360 pixels;
// the button and the lines have the states of a site control; the script
// only adds ways to close the menu.
@(test)
site_subscribe_menu_rules :: proc(t: ^testing.T) {
	style := site_style_sheet("")
	testing.expect(t, strings.contains(style, ".subscribe-panel { position: absolute; left: 0; top: calc(100% + 4px); z-index: 20; width: max-content; max-width: calc(100vw - 56px);"))
	// A line that is wider than the panel breaks; nothing cuts it.
	testing.expect(t, !strings.contains(SITE_SUBSCRIBE_MENU_RULES, "overflow: hidden") && !strings.contains(SITE_SUBSCRIBE_MENU_RULES, "text-overflow") && !strings.contains(SITE_SUBSCRIBE_MENU_RULES, "nowrap; text-decoration"))
	testing.expect(t, !strings.contains(SITE_SUBSCRIBE_MENU_RULES, "transition") && !strings.contains(SITE_SUBSCRIBE_MENU_RULES, "border-radius"))
	testing.expect(t, strings.contains(style, ".subscribe-menu[open] > .subscribe-button::after { vertical-align: 0; transform: rotate(-0.375turn); }"))
	// Each angle of the style sheet is in turns: no degree, radian or grad.
	for unit in ([]string{"deg)", "rad)"}) {
		testing.expectf(t, !strings.contains(style, unit), "the style sheet has an angle with the unit %q", unit)
	}
	rules := site_control_rules()
	testing.expect(t, strings.contains(rules, ".subscribe-button:hover, .subscribe-button:focus-visible {"))
	testing.expect(t, strings.contains(rules, ".subscribe-panel a:hover, .subscribe-panel a:focus-visible {"))

	// The panel on a window of 360 pixels with a scroll bar: it starts at
	// the padding of the page, and its longest line at 9 pixels a
	// character, with the arrow, the padding of a line, the padding and the
	// border of the panel, ends inside the window: the line holds on one
	// line there.
	WINDOW :: 360
	SCROLL_BAR :: 17
	PAGE_PADDING :: 16 // .page
	CHARACTER :: 9
	ARROW :: CHARACTER + 8 // The arrow and its margin.
	LINE_PADDING :: 16 // .subscribe-panel a, 8 at each side.
	PANEL_FRAME :: 8 + 2 // The padding and the border of the panel.
	longest := max(len(SITE_SUBSCRIBE_FEED_LABEL), len(SITE_SUBSCRIBE_WATCH_LABEL))
	panel := longest * CHARACTER + ARROW + LINE_PADDING + PANEL_FRAME
	testing.expectf(t, PAGE_PADDING + panel <= WINDOW - SCROLL_BAR, "the panel ends at %d pixels; the window has %d", PAGE_PADDING + panel, WINDOW - SCROLL_BAR)
	// The max-width keeps the panel inside the window: 48 is the padding
	// of the page at both sides and a scroll bar.
	testing.expect(t, 2 * PAGE_PADDING + SCROLL_BAR <= 56)

	script := site_search_script()
	testing.expect(t, strings.contains(script, "document.querySelector(\"details.subscribe-menu\")"))
	testing.expect(t, strings.contains(script, "subscribeButton.focus();"))
}

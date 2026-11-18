// The subscribe menu of the pages that show the changes: the releases and
// the news (docs/SITE.md, "The subscribe menu"). A reader who wants to
// follow the system finds the ways on the page that shows the changes, not
// only in the head of the page, which a browser hides. It is a details
// element, as the project menu of the bar, so it opens and closes with no
// script.
package site

import "core:strings"
import "modustool:checks"

// The word of the button of the menu.
SITE_SUBSCRIBE_MENU_NAME :: "Subscribe"

// The label of the link to the feed of the page. The feeds are Atom: a
// label that says RSS names a format that the site does not write.
SITE_SUBSCRIBE_FEED_LABEL :: "Atom feed"

// The label and the address of the link to the releases of the
// repository. Its page holds the button Watch of the repository, whose
// choice of the releases sends a notification at each release; the choice
// itself has no address of its own.
SITE_SUBSCRIBE_WATCH_LABEL :: "Watch releases on GitHub"
SITE_SUBSCRIBE_WATCH_ADDRESS :: checks.REPOSITORY_ADDRESS + "/releases"

// The sign after each link of the panel: the link leaves the page for a
// file or for another site. A screen reader does not read it: the label
// says where the link goes.
SITE_SUBSCRIBE_ARROW :: "<span class=\"subscribe-arrow\" aria-hidden=\"true\">↗</span>"

// The start of the menu: closed in the file, its summary is its button.
SITE_SUBSCRIBE_MENU_OPEN :: "<details class=\"subscribe-menu\">\n<summary class=\"subscribe-button\">" + SITE_SUBSCRIBE_MENU_NAME + "</summary>\n<div class=\"subscribe-panel\">\n"

// The rules of the menu. The panel lies over the page under its button,
// at the left edge of the text column, so it opens into the column. Its
// width is the width of its longest line in the font of the reader
// (max-content), so no line breaks while the window has room; on a narrow
// window the panel keeps inside it, and a line that is wider breaks onto a
// second line: it is never cut. The panel is under the bar, which is over
// the page. The chevron is two lines at an angle: it points down when the
// menu is closed and up when it is open, at once, with no transition. The
// states of the button and of the lines are in site_controls.odin.
SITE_SUBSCRIBE_MENU_RULES :: `
.subscribe-menu { position: relative; display: inline-block; margin: 0 0 16px; }
.subscribe-button { list-style: none; display: inline-block; padding: 0 8px; line-height: 24px; white-space: nowrap; background: var(--track); cursor: pointer; }
.subscribe-button::-webkit-details-marker { display: none; }
.subscribe-button::after { content: ""; display: inline-block; width: 6px; height: 6px; margin-left: 8px; border-right: 2px solid currentColor; border-bottom: 2px solid currentColor; vertical-align: 4px; transform: rotate(45deg); }
.subscribe-menu[open] > .subscribe-button { background: var(--control-active); color: var(--control-active-text); }
.subscribe-menu[open] > .subscribe-button::after { vertical-align: 0; transform: rotate(-135deg); }
.subscribe-panel { position: absolute; left: 0; top: calc(100% + 4px); z-index: 20; width: max-content; max-width: calc(100vw - 56px); padding: 4px; background: var(--card-bottom); border: 1px solid var(--line); }
.subscribe-panel a { display: block; padding: 4px 8px; line-height: 24px; text-decoration: none; overflow-wrap: anywhere; }
.subscribe-arrow { margin-left: 8px; }
`

// site_subscribe_menu_html writes the menu on one page: the link to the
// feed that the page shows, then the link to the releases of the
// repository. The feed is a file at the root of the site that the command
// writes; the link is relative to the page.
site_subscribe_menu_html :: proc(b: ^strings.Builder, from_page, feed: string) {
	strings.write_string(b, SITE_SUBSCRIBE_MENU_OPEN)
	strings.write_string(b, "<a href=\"")
	strings.write_string(b, site_relative(from_page, feed))
	strings.write_string(b, "\" type=\"application/atom+xml\">" + SITE_SUBSCRIBE_FEED_LABEL + SITE_SUBSCRIBE_ARROW + "</a>\n")
	strings.write_string(b, "<a href=\"" + SITE_SUBSCRIBE_WATCH_ADDRESS + "\">" + SITE_SUBSCRIBE_WATCH_LABEL + SITE_SUBSCRIBE_ARROW + "</a>\n")
	strings.write_string(b, "</div>\n</details>\n")
}

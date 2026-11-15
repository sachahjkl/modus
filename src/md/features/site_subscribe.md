# The subscribe menu of the site

## Purpose

A reader who wants to know when the system changes must find the way to follow it on the page that shows the changes. The site writes two feeds, `releases.xml` and `news.xml`, and each page names them in its head; a browser hides that link. The page Releases and the page News each show a button "Subscribe" that opens a small menu with the ways to follow the page.

What the menu looks like and how it behaves is in [`docs/SITE.md`](../../../docs/SITE.md), "The subscribe menu".

## Constraints

- **Each page is whole with no script.** The menu opens and closes with no script, with the pointer and with the keyboard.
- **No cut text, no text over a text.** The panel holds its longest line on every window, from 360 pixels.
- **The colors and the font of the site**, rectangular forms, the states of a site control from the one table.
- **A link names what it gives.** The feed is Atom; a link that says "RSS" names a format that the site does not write.

## The chosen form

**A `details` element, closed in the file, whose `summary` is the button.** With no script a click, Enter or Space opens and closes the panel. It is the mechanism of the project menu of the bar ([site_bar.md](site_bar.md)): one form of a menu on the whole site.

- The button is a rectangle of the track with the word "Subscribe" and a chevron. The chevron points down when the menu is closed and up when it is open. It is two lines at an angle: the one place of the menu where a form says more than a rectangle, because it says the direction of the panel.
- The panel is a card under the button, with a border of 1 pixel, one row for each link. It lies over the page and moves nothing.
- Two links, each followed by "↗", the sign of a link that leaves the page for a file or another site:
  - **"Atom feed"**: the feed of the page. The page Releases links `releases.xml`, the page News links `news.xml`.
  - **"Watch releases on GitHub"**: the page of the releases of the repository. Its header holds the button "Watch", whose choice "Custom" then "Releases" sends a notification at each release; the page itself lists the same releases. The address of the watch choice has no stable URL of its own.
- **The width of the panel comes from its longest line**: `width: max-content`, so the browser measures the line in the font of the reader. A line never breaks while the window has room. A `max-width` keeps the panel inside a narrow window; a line that is wider than that breaks onto a second line, it is never cut.
- **The menu stands under the heading of the page**, at the left edge of the text column, so its panel opens to the right into the column and cannot pass the right edge of the window.
- **The script only adds ways to close**, as for the project menu: Escape closes the menu and puts the focus on its button; a click outside closes it; a focus that leaves it closes it. It is a part of the one script of the site. With no script the button still closes the menu.
- The button and each line of the panel are site controls: they get their states from the one table of the controls.

## Refused forms

- **A menu built by a script.** A reader with no script would have no menu, and the site would have a second mechanism of a menu.
- **An RSS feed in addition to the Atom feed.** Every feed reader reads Atom; a second format is a second file to keep the same, for no reader.
- **A link to X.** The site points to the files that it writes and to the repository; a follow on an account of a social network is not a way to follow the releases of the system.
- **Two links on the page with no menu.** Many sites of software group the ways to follow behind one button, and a reader looks for that button. Two links also take a line of the text for each page.
- **A fixed width in pixels.** A fixed width is right for one font only. The project menu has short lines and room at twice their width; the line "Watch releases on GitHub" is three times longer, and room at twice its width wastes a third of a phone screen.
- **The menu in the bar.** The bar has no room ([site_bar.md](site_bar.md), "The measure that decided the form"), and the menu concerns two pages only.

## Subtle points

- **The feed link points to a file that the site writes.** `releases.xml` is written at each build; `news.xml` only when the news exist, and the page News exists only then. The checks of the links of the pages refuse a link to a file that the command did not write.
- **A `details` in the text column is not a menu of the bar.** Its rules do not depend on the width of the window: it is a menu at every width, unlike the project menu, which is a list under 720 pixels.
- **The chevron turns with a `transform`.** The rules of the states of a control refuse a `transform`; the turn is a rule of the open menu, not a state of a control, and it shows at once, with no transition.

## State

Built: the menu on the pages Releases and News, its rules, the part of the script, its lines in the table of the controls, the host test. Not yet seen in a browser.

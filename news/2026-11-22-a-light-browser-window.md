title: A light browser window
date: 2026-11-22
release: next
picture: none
kind: Shown
guide: none

`start("browser")` opens a window with back, forward, an address field and the document origin of the page. Its four pages, modus://welcome, modus://properties, modus://guide and modus://forms, are HTML and CSS. The contract package html_css parses each page into at most 512 nodes, applies its style rules, lays out block, inline and flex boxes, and paints them into the draw table of the window.

A press on a link loads its page, and back and forward keep the scroll of each page. The form sends its fields in the query of its action, and the answer shows them. The origin modus://forms keeps the last query; a page of modus://welcome asks for it and is refused.

The window has no grant but its window. An address of HTTP or HTTPS shows a page that says so: each origin will get its own process with its own network grant.

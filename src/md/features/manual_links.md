# The links of a page of the manual

The documentation text of a module is Markdown, and its links name terms of the glossary, headings of the guides, modules, exports and records ([`docs/SITE.md`](../../../docs/SITE.md), "The links of a comment"). The site opens each of them. The program `manual` opened only a link to a module or to an export: a link to a term or a guide was a colored word that did nothing. This file records how the manual opens each link, how a principal reaches a link with the keyboard, and how a principal goes back.

The guide is [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The links of a page of the manual".

## Constraints

- **The manual reads only the boot image.** It has the grant `Image` and no grant of storage or of the network. The glossary and the guides are not modules.
- **The hash of a module names its bytes.** A module must not change when a guide changes: a text of a guide inside a module file would change the hash of each documented module at each edit of a guide.
- **No text over another text, and no cut text.** A page of a term or of a heading is drawn by the same layout as the documentation of a module.
- **A test presses an element by its name** ([../infrastructure/test_pointer.md](../infrastructure/test_pointer.md)).

## The chosen form

**One resource holds the pages of the links: `manual_pages`.** At each build, the tool reads the documentation text of each module of the boot image and of each of its exports, and takes the target of each link. For each target `term:<term>`, it writes one link page: the name of the term as its title, then its short definition and its explanation. For each target `docs/<NAME>.md#<id>`, it writes one link page: the heading as its title, the text under the heading up to the next heading, then a list of links to the headings directly under it. The tool adds the pages of those headings too, so a principal walks down the tree of a section that a module names, and no further. For a target `docs/<NAME>.md`, the page is the text before the first heading of level 2, then a list of links to each heading of level 2, with their pages and the pages under them. The format is the contract `src/library/contract/manual_pages`: a header, one entry for each page in the order of the bytes of its target, then the text. The tool writes the file; the manual checks its hash against its entry of the image, validates it once, and then reads it in place.

**A guide becomes the Markdown of a comment.** The reader of the system knows the part of Markdown of a source comment only. The tool writes a heading inside a page as a bold paragraph, a row of a table as a list item whose cells are joined by `; `, with no row of dashes, and a quote as its text. A relative link of a guide (`STORAGE.md#4-7`) becomes `docs/STORAGE.md#4-7`: it opens when its page is in the resource.

**A link resolves in one place, in this order.** `manual_pages.link_target_kind` gives the kind of a target, for the tool and for the manual. An address (`https://`) is shown, not opened. A term and a guide open their link page, when the resource has it. A name opens a module, a module and its export, or a record: `information.Module` opens the record `Module` on the page of the module whose text holds the link when that module describes it, else on the page of the first module of the boot image that describes it.

**A link that opens has a line under it, and one that does not has none.** A link that opens is drawn in the color of a link with a line of that color under it. A link with no page is drawn in the color of a link with no line. An address is its label, then the address in the font of the cells, in the dim color, between parentheses: the manual has no browser, and the principal can read and copy it.

**The manual owns the focus of its links.** Tab moves the focus to the next link of the page that opens, and Shift+Tab to the one before; the order is the order of the text, and it goes round. With no focus, Tab takes the first link at or under the top of the view. A link that is out of the view scrolls into it. Enter opens the link that has the focus. The link with the focus has a band behind it and a white line of 2 pixels under it. A new page has no focus.

**Backspace goes back.** Each change of the page (a link, a module of the list, up and down, `show`, the table of all the modules) keeps the page that it leaves, with its first row, in a history of 64 places. Backspace shows the last kept place, and removes it. When the history is full, the oldest place is forgotten, and the count of the forgotten places is kept. The table of all the modules moved from Tab to the key `o`, because Tab moves the focus in each window of the system.

**Each link names itself.** Each link that opens and that the view shows is an element of the frame, named by the text of its first part: a test presses `the description tables`. A link that wraps over two rows takes a press on each part, and its name is the text of its first part.

The log lines: `manual: the focus is on the link <name> to <target>`, `manual: the link <name> opens <target>`, `manual: the page <target>: <title>, <n> rows`, `manual: back to the page before` and `manual: back: no page before`. A module page keeps its line `manual: <module>: ...`.

## Refused forms

- **The guides in the module file.** Each module would carry the same texts, and its hash would change at each edit of a guide.
- **The whole documentation in the resource.** `docs/` holds 2.4 MB of Markdown, and the glossary alone 538 KB. The resource holds the pages that the modules of the image name, and the sections under them.
- **A page for each declaration of the sources.** A link to a procedure of a support package (`system.word_wait`) names a declaration that no module describes: the build reads no source to make it a page. A record that a module describes opens, because the module file holds it. This part is planned work in `ROADMAP.md`.
- **The interface focus of the package for the links.** The package keeps the focus order of the elements of the last frame: Tab would reach only the links of the view, and never scroll. The text of a page is longer than its view.
- **An address that opens.** The system has no browser. A link that does nothing when a principal presses it is a fault; an address with no line under it says that it does not open.
- **Tab for the table of all the modules.** Tab moves the focus in each window that uses the interface package; one window with another meaning for Tab breaks that rule.

## Subtle points

- **A target is bytes of a module file or of the resource.** The manual keeps the target and the label of a link as slices of those bytes: they stay valid when the page changes, so the link that opens is read before the page is cleared.
- **A link has one record, its parts have its number.** A link that wraps, or that has a bold word inside it, is several parts of the page. The spans of one link have the same target range in the text: the manual counts one link when the target range changes.
- **The text of a page holds line feeds.** A Markdown text is not a text of a contract (a text holds no control character): the reader of the resource checks each line of a page as a text.
- **A label longer than an element name has no name.** An element name holds 32 bytes; such a link still takes a press and the focus.

## State

Built: the resource `manual_pages` and its contract; the link pages of the terms and of the headings of the guides; the record of a module as a destination; the focus, Enter and Backspace; the element names of the links; the machine test of a click, of Tab and Enter, and of Backspace.

Left: a page for a declaration that no module describes.

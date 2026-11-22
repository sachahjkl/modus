title: The browser reads tables and keeps each origin apart
date: 2026-11-22
release: next
picture: none
kind: Shown
guide: none

The browser window now parses a page after the insertion modes of the WHATWG. Misnested tags such as `<b><i>text</b>more</i>` give the tree that other browsers give, a table with no row group or a stray text is repaired, and a page of 2000 nested elements stops at its bounds of 512 nodes and 64 open elements.

The CSS of a page can now use descendant and child selectors, borders, text-align and tables, with the specificity of the standard.

An address of HTTP or HTTPS now shows the request that the worker of its origin writes, with the cookies of that origin only. The window still has no network grant. The storage, the cookies, the form values and the style sheet of each origin cross a border of messages, and a request for the state of another origin is refused with no byte of it.

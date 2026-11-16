title: The manual shows a declaration that no module describes
date: 2026-11-16
release: next
picture: docs/screenshots/manual_declaration.png
kind: Shown
guide: docs/MODULE_CONTRACT.md

The documentation of a module can link a procedure of a support package, such as `system.word_wait`. No module file describes such a procedure, and the program `manual` reads only the boot image. Now the build writes a page for each such link into the boot image, from the source: the file and the line, the one line of Odin, and the comment above the declaration. The link in the manual has a line under it and opens that page. A link to a module, an export or a record that a module describes still opens the page of the module. The picture shows the page of `system.word_wait`, which the machine test opens with Tab and Enter from the page of the module `manual`.

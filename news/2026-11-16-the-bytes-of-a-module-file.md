title: The bytes of a module file, drawn from the code
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

The guide of the module contract now draws each record of a module file byte by byte, as the header diagrams of the RFCs do. A row is 8 bytes. Each field is a rectangle over its bytes, with its name and its size; its type and its comment show under the pointer. The diagrams cover the header, the table directory and one record of each table: 12 layouts. The offsets and the sizes come from the compiler that builds the tool, so a diagram cannot differ from the code. The same layouts are in the Markdown of the guide as text, and the check of the repository fails when that text differs from the code.

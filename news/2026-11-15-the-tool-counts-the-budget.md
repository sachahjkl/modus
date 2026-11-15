title: The tool counts the budget of a module
date: 2026-11-15
release: next
picture: none
kind: Decided
guide: docs/MODULE_CONTRACT.md

The budget that a program asks for is now mostly counted, not guessed. Its source states only what no file shows: its working memory, its programs, its threads and the size of its window.

The build adds three parts that are facts: the pages of the module and of each module that it imports, a stack and a thread area for each thread, and the two pictures of the window. A window of 1000 x 704 is 1375 pages. When a module grows, its request grows with it, with no change of its source.

The page of each program on the site shows the parts of its budget, and each build prints the request of each module once.

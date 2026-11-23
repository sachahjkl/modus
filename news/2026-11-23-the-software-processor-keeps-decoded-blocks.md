title: The software processor of a page keeps decoded blocks
date: 2026-11-23
release: next
picture: none
kind: Measured
guide: none

A browser machine runs the x86-64 code of the processes on its software processor. It now keeps each run of instructions that it decoded as a decoded block, and runs it again with no fetch through the page tables and no decode of its prefixes. At each entry it compares the bytes of the block with the memory, so a block never runs code that a write changed.

In Node, with the same boot images, the processor time to the prompt of the console image fell from 4.6 s to 3.4 s, and to the first frame of the desktop image from 10.5 to 11.5 s to 8.6 s, over two runs each. The emulated vector forms are now about 40 % of the start of the console.

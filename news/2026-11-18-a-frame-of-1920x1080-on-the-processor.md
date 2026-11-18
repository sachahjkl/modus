title: A frame of 1920 × 1080 on the processor
date: 2026-11-18
release: next
picture: none
kind: Measured
guide: src/md/features/desktop_to_browser.md

modus is an operating system with a small kernel, in which each program draws its window into memory of its own, and the compositor shows it.

The standard of quality of its desktop is 120 Hz at 1920 × 1080: a frame in less than 8.3 ms. The program `processor_frame` now measures, on the test machine and with no GPU, what such a frame costs on one processor, with the code of the system: a clear and a present take 269 us, a full frame of the compositor with four windows 954 us, a frame in its damage 86 us, and a draw table of 339 records that fills the screen, with text in two fonts, pictures and alpha, 2043 us (the medians of 21 frames). The heaviest part takes a quarter of a frame at 120 Hz, so a machine with no GPU keeps the resolution and the rate of the standard, and leaves out only the blur, which no measure gives yet.

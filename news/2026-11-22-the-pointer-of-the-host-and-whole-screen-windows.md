title: The pointer of the host, and windows that fill the screen
date: 2026-11-22
release: next
picture: none
kind: Fixed
guide: docs/ARCHITECTURE.md

The machine of `modustool run` has a virtio tablet, and the root service now gives it to the input service: the pointer of the system is where the pointer of the host is, and the window of QEMU no longer holds the pointer of the host.

The maximize button, a double press on a title bar and Control+Shift+Up give a window the screen less the bar, and ask its process for that size. While a window is maximized, its button shows two windows, the restore: a second press, or a drag of its title, gives back its place and its size.

Each corner of a window resizes it on the diagonal, the grip at the bottom right too.

A terminal has at most 192 columns and 54 rows: a maximized terminal on a screen of 1920 x 1080 fills its window.

title: A desktop for a machine with no screen
date: 2026-11-23
release: next
picture: none
kind: Shown
guide: docs/QUIC.md

A machine with no display device, such as a server, now runs the desktop and the console in memory, at 1920 x 1080. A viewer of the remote display sees that desktop and drives it with its keys and its pointer.

A viewer with the input can ask the desktop for another size. The desktop takes the size at once, each window fits it again, and each viewer receives the new size and the whole screen. For a larger size, the memory of the desktop and of the remote display grows at the same step, within the share of a process, and returns when the size comes back. When the machine cannot pay a size, the viewer gets the cause and keeps its session.

On a machine with a screen, the size is the size of the screen, and an ask gets the cause that the screen is a device.

title: The machine of modustool run shows its screen through the virtual GPU
date: 2026-11-23
release: next
picture: none
kind: Measured
guide: docs/TOOLS.md

The machine of `modustool run` has a VirtIO-GPU with its VGA part. The firmware draws on the VGA part, then the compositor shows each frame through the scanout of the GPU. Each frame goes to the device as one batch of its damage rectangles, so the display of the host redraws only what changed, and the frame stays whole.

While the pointer moved at 125 moves each second (KVM, 1920 x 1080, the GTK display of QEMU in Xvfb), QEMU redrew about 1.07 million pixels each second. With the page flip of the standard VGA it redrew 67 to 89 million. The compositor drew 62 frames each second in both. At rest, QEMU redraws the clock of the bar only: 3800 pixels each second.

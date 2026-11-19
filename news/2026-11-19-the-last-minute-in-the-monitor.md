title: The last minute in the monitor
date: 2026-11-19
release: next
picture: docs/screenshots/monitor_light.png
kind: Shown
guide: docs/TOOLS.md

modus is an operating system with a small kernel, in which programs call each other's functions with typed values, and no text goes between processes.

The window of `monitor` now draws three graphs of the last minute: the memory in use, the processor time of all the processes, and the kernel entries in one second. Each graph is a curve of the last 120 samples, one each 500 ms, over the grid of points of the desktop. The monitor computes the points of a curve once for each sample, not in each frame. The bar of the memory and the bar of each process take the color of what they measure, the warning color from 60 %, and an orange from 85 %. The number beside each bar says the same value.

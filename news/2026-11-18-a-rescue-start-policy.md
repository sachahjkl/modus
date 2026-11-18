title: A rescue start policy takes over a failed console
date: 2026-11-18
release: next
picture: none
kind: Shown
guide: docs/ARCHITECTURE.md

The root service of modus no longer holds the order of the start. It starts one process, the start policy, which reads the start list of the boot image in its order and says when the machine is usable. When the console does not start, the start policy stops before that point, and the root service starts the rescue start policy: the input, the compositor, the console and `remote`. The machine then shows its console in place of a failure on the boot display. Hold the key R while the machine starts, or choose the entry "modus (rescue)" in the boot menu of the firmware, to start the rescue at that start. The boot program writes that entry at the end of the boot order when it is absent. Each list is a resource of the signed boot image, and the build refuses a list that names no module of its image.

title: A module replacement needs a signature
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

A replacement gives one module in place of another to every program that imports it. The drawing module is imported by the compositor, which holds every window and every key, and by the terminal. So a replacement now needs the consent of the key that signs the system.

The boot image holds a replacement list: each row names the two modules and the programs that it reaches, and the key signs the three together. The console still types `replace("calendar", "calendar_fixed")`, and the root service accepts it because a signed row names that pair.

Type `replace("calendar", "math")`: the console says "error: the root service refused the replacement of calendar by math: no signed row names it", and the log has the same reason. A row that another key signed is refused too. In both cases `calendar` stays in place, with its fault.

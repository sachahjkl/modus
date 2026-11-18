title: A stop of the boot program stays on the screen
date: 2026-11-18
release: next
picture: none
kind: Fixed
guide: docs/TRUSTED_BOOT.md

When the boot program cannot start the kernel, for memory, for the memory map of the firmware or for a kernel module that it cannot load, the boot display shows the reason in red and stays. Before, the boot program wrote one line on the console of the firmware and powered the machine off at once, so the line was gone before anyone read it. The boot program turns the watchdog of the firmware off, as for a failed check of trust, so the machine waits until it is stopped by hand.

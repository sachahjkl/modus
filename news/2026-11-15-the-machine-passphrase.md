title: The grants of the machine survive a restart under a machine passphrase
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/PRINCIPALS.md

The machine can now have a passphrase. In the console, `machine_passphrase()` opens the window of `unlock`, which asks for it two times. The passphrase is never a line of the console.

With a machine passphrase, the grants that the console gives to a disk program are kept on the disk, in a table signed by the machine key. At the next start, the window of `unlock` asks for the passphrase, and the grants come back. Until it is typed, the machine runs, and its disk programs start with no grant.

A table that another key signed is refused, with a line of the log, and gives no grant. So a reader of the disk who has no passphrase cannot give a program a store. With no machine passphrase, nothing is typed, and the grants last until the machine stops, as before.

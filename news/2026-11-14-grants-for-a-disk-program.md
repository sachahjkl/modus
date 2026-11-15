title: A disk program gets a store by its nickname
date: 2026-11-14
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

A program that comes from a disk can now get a grant. Its nickname is the name of its file in the store `programs`, and the principal chooses it. In the console, `allow("visitor", "store")` gives the program of that nickname a store of its own, `disk-visitor`, from its next start.

The grant names the file by its hash. A start of the nickname with another file is refused before a byte is read. `nickname_move` points the nickname to a new version of the file, and the store follows: the new version finds the data of the old one.

No command gives a disk program the ring of the root service, a right over the machine or a device, or the right to act for the principal. The grants of principal 0 last until the machine stops, because principal 0 has no passphrase to sign them; the data of the store stays on the disk.

title: A machine with no screen still takes calls
date: 2026-11-18
release: next
picture: none
kind: Fixed
guide: docs/ARCHITECTURE.md

modus is an operating system with a small kernel, in which a process gets only the handles of its role.

A machine with no screen used to end its start on a failure that the screen would have shown. Now the root service writes one line, starts no desktop and no console, and starts `remote`. A client key that a principal allowed earlier, and that the disk grant table of the principal keeps, calls the services as before.

The test seals the machine key with the TPM, allows the key of the client in a console, then starts the same disk on a machine with no display device: a call of the client through `remote` runs.

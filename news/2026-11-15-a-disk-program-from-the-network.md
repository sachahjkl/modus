title: A program comes over the network to a machine that runs
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

A module file can now reach a machine that runs, with no new disk. In the console, `connect("programs")` opens the module file service. `programs.receive("visitor", "/visitor")` fetches the file from a web server, stores it in the store of the programs, and gives the hash of its bytes. `start_from_disk("visitor", hash)` then starts it.

`programs.list()` shows each file of that store with the hash of its bytes, which the service reads again.

The service only carries the bytes. The root service checks them against the hash at each start, so a file with other bytes never runs under that hash. The service writes only the store of the programs, and only for a caller that acts for the principal.

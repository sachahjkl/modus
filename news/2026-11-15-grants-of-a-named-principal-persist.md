title: The disk grants of a named principal survive a restart
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/PRINCIPALS.md

A named principal now gives a grant to a program from a disk in its own session. A console that the desktop starts during the session of alice acts for alice: `allow("visitor", "store")` gives the nickname `visitor` a store of its own for alice.

The grant lasts across a restart of the machine. The table of alice is on the disk, in her store of module files, with a tag under a key that only her passphrase opens. When alice unlocks her session again, the root service reads the table, and `visitor` starts with its store and finds its data.

A table that another key signed gives no grant. A reader of the disk with no passphrase cannot add a grant to alice.

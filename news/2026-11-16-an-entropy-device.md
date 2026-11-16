title: The seed of the system takes bytes from an entropy device
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/RANDOMNESS.md

The random seed of modus no longer depends on the processor alone when the machine has the entropy device of virtio. At its start, the root service starts a device service for it, the program `entropy`, and asks it for two reads of 32 bytes. It does not wait for them: when they come, it mixes them into the generator that gives each program its seed. The bytes add to the bytes of the processor and never replace them, so a device that lies cannot weaken the seed. A read of zeros, of one value, with no byte, or equal to the read before adds nothing and counts as refused. The strength that the system claims does not change. The log says `root: the entropy device gave 64 bytes in 2 reads: 64 bytes mixed into the random generator of the system; refused reads: 0`, and the window of `randomness` shows the device. A machine with no such device starts as before, and its log says so.

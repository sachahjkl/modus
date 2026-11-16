type: Added

**An entropy device.** A machine with the entropy device of virtio (`virtio-rng-pci`) starts the entropy service, and the root service mixes 64 bytes of the device into the generator that seeds each program after it, beside the sources of the processor and never in their place. A read of zeros, of one value, with no byte, or equal to the read before adds nothing and counts as refused; the seed strength does not change. A machine with no such device starts as before and says so on the log, and the window of `randomness` shows the device.

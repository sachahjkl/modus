type: Fixed

**The flags of a device region are written under the lock of its frames.** A region of a device that a guest maps no longer has its cache flags written outside that lock, so a concurrent read of the flags sees either the old or the new value.

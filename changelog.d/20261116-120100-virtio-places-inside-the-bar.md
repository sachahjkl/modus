type: Fixed

**A virtio device service takes the places of the registers only inside its memory**: a capability whose registers are not inside the memory of its BAR, or a notify register of a queue outside the notify registers, is refused, and the block, frame and entropy services stop with a line that names it, in place of a fault on an address that is not mapped. The size of each queue is a power of two, so its counters stay in order when they wrap.

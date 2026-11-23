type: Changed

**A Linux shell that takes the size of its window.** The shell of the window `linux` runs on the virtio console `hvc0`, so a program of the guest gets `SIGWINCH` and the new size at each resize of the window. The log of the kernel stays on the serial port and goes to the log of the system only. The guest loads the virtio modules of the kernel of Nixpkgs from its initial archive.

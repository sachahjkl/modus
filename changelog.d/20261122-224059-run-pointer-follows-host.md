type: Fixed

**The pointer of `modustool run` follows the pointer of the host.** The machine of `modustool run` has a virtio tablet, and the root service now gives the tablet to the input service: the pointer moves to where the host pointer is, and the window of QEMU no longer grabs the pointer of the host.

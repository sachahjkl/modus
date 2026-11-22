type: Added

**The screen through the virtual GPU.** The compositor attaches its framebuffer read-only to `gpu_device` over the VirtIO-GPU 1.2 PCI control queue, binds the 1920 × 1080 2D scanout, and presents damaged rectangles to the host virtual GPU (`compositor.gpu_info()` reports live scanout and present counts).

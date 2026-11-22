type: Added

**Live VirtIO-GPU 1.2 PCI discovery and on-demand export serving for `plans`, `recipes`, `projects`, `collector`, and `powerbox`.** `root` now scans PCI bus 0 for VirtIO-GPU (`0x1AF4:0x1050`) and starts `gpu_device` automatically at boot, and starts `plans`, `recipes`, `projects`, `collector`, and `powerbox` on demand with live `system.service_open` export rings callable directly from `console` and `remote`.

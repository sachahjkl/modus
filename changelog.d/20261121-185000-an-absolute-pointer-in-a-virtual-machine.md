type: Added

**An absolute pointer in a virtual machine.** The input service drives `virtio-tablet-pci` alongside the PS/2 fallback, batches `ABS_X`, `ABS_Y`, button, and wheel updates until `SYN_REPORT` so the pointer never steps along one axis before the other, and scales axis ranges onto the screen with exact integer arithmetic clamped at the edges.

type: Added

**Resizable terminal grid core and headless memory screen contract.** Added the freestanding terminal grid resize package (`internal:terminal/grid_resize`) wired into the terminal service with `terminal.Input.Resized` notifications, and the freestanding headless virtual framebuffer contract (`modus:contract/memory_screen`) with strict geometry, stride, damage, and atomic viewer-resize validation.

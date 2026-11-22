type: Added

**Live VirtIO-GPU scanout bridge in `compositor` and one-step `compile_c` command in `console`.** `root` now hands the VirtIO-GPU client ring to `compositor` (`GRANT_GPU_RING`), which probes `Display_Info` and `Probe_Venus`, attaches its framebuffer, flushes `Present_Rect`, and exposes `compositor.gpu_info()`; `console` adds `compile_c(name, source)` chaining `c_compiler` (`chibicc`), `assemble`, and `isolate_memory` in one Lex call.

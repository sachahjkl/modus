type: Added

**VirtIO-GPU hardware cursor queue framing, sequenced Venus reply ring parser, coalesced grid draw-table emitter, and resizable monitor surface layout.** Extended `virtio_gpu` with 64x64 `UPDATE_CURSOR`/`MOVE_CURSOR` commands, `venus_vulkan` with sequenced host reply framing and in-flight tracking, `draw_record` with zero-allocation terminal grid draw-table emission, and `desktop_layout` with budget-checked resizable monitor layout calculation.

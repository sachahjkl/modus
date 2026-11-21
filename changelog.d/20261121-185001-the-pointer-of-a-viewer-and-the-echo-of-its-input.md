type: Added

**The pointer of a viewer and the echo of its input.** Remote display protocol version 2 adds `Pointer_Shape`, `Pointer_Picture`, and `Pointer_Warp` messages together with a monotonic 64-bit `input_echo_count` on every `Viewer_Frame_Start` and `Pointer_Warp`, so a viewer renders its own local cursor with zero wait and measures exact input-to-display latency.

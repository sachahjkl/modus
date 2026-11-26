type: Fixed

**Fix `settings` scrolling, enable Web Desktop mouse wheel, and speed up the browser software processor.** `settings` now moves the scroll position to follow keyboard focus only when focus actually changes instead of snapping back on every pointer or wheel scroll, Web Desktop enables PS/2 IntelliMouse wheel scrolling, and `software_machine` uses a larger O(1)-flushed TLB (2048 entries), a larger decoded block cache (4096 blocks of up to 32 instructions), and epoch-based code-frame verification to eliminate per-entry byte comparisons in hot loops.

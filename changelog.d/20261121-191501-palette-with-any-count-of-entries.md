type: Changed

**A palette with any count of entries.** The palette provider protocol (version 8) replaces the fixed 256-entry cap with a header carrying `entry_count` and `byte_length` over a memory object sized for the actual entries, growing on demand through `Outcome.Table_Replaced`. The palette ranks any count of entries off the main thread with SIMD fuzzy matching and frecency, and draws only the visible viewport window in O(visible rows) per frame.

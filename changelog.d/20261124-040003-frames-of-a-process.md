type: Added

**The frames of a process.** `Memory_Commit` accepts `Commit_Flag.Frames_Now` (refused with `Decommit`), `map_region` installs present 4 KiB, 2 MiB, and 1 GiB entries while skipping empty regions, and aligned prefault commits take 2 MiB hardware runs with no privilege under a per-budget run quota, zero-allocation demotion via parked page tables, counted fallbacks in `System_Report`, and per-size entry counts in `Process_Mapping` (with 1 GiB allocator, `pdpe1gb`, and `word_table` infrastructure ready for bounded resumable zeroing).

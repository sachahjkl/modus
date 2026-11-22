type: Changed

**A faster switch between threads.** Each processor now tracks the thread whose x87, SSE, and AVX registers it last saved via `modulus:extended_switch` and skips `xrstor`/`fxrstor` when switching back to the same unmodified thread on the same processor, while invalidating on guest runs, `Thread_Control` writes, teardown, and cross-processor migration.

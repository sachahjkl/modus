type: Fixed

**The console line that never ran under a loaded host.** Typed console lines now deliver and execute reliably under load: the compositor drains window key bursts and pending answers without sleeping on concurrent reads, counts every fixed wait word in its wait set, `system.wait_end` wakes waiting ring peers with full memory ordering even on its fast path, the console retires finished lines with Acquire ordering before taking the next key, and serial terminal renderers apply back pressure without dropping keys after Escape.

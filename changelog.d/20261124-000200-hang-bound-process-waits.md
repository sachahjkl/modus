type: Fixed

**Service, picker, disk-load, and role-update waits use the 60 s hang bound instead of short fixed timeouts.** Raised `remote.CALL_LIMIT`, `console.LINE_RECORD_ANSWER_LIMIT`, `root.PICKER_LISTING_BOUND_MILLISECONDS`, `powerbox.STORES_CALL_BOUND_MILLISECONDS`, `disk_process.LOAD_DEADLINE_MILLISECONDS`, and `plans.ROLES_BUSY_PAUSE_MILLISECONDS` to match `ANSWER_BOUND_MILLISECONDS` (60 s), and removed the 1000 ms polling waits in `remote`'s weak-seed loop.

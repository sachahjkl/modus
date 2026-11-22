type: Changed

**Live `module_gc` sweep and request-serial idempotency in `storage`, plus bar vertical positioning in `compositor`.** Wired `internal:storage/module_gc` reachability garbage collection and `supervision.Request_Serial_Log` duplicate-call protection directly into `storage`, updated taskbar pills and tray badges in `compositor` to follow `desktop_bar_y()`, and pruned 7 verified `Next` entries from `ROADMAP.md`.

type: Changed

**Single-writer settings page and delegated principals service.** Moved appearance day-edge scheduling and date-page wakeups out of the root service into `settings` so the shared settings page has one writer, and added the freestanding delegated `principals` service and pure `principals_core` state machine for principal sessions, disk grant tables, remote client keys, and principal 0 start policy choices.

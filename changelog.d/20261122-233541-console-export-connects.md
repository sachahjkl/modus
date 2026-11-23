type: Added

**A call of an export connects its service**: `monitor.processes()` before `connect("monitor")` connects the service first, with the same check and the same log line as `connect`, then calls the export.

type: Added

**Current and peak handle and mapping counts in `Process_Report`.** The kernel tracks current and peak handle and mapping counts per process and reports `handle_count`, `handles_peak`, `mapping_count`, and `mappings_peak` in `Inspect(.Process)` and `monitor.processes()`, allowing the root service to read its table counts in one inspection call.

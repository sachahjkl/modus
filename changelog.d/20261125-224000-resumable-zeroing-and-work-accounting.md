type: Added

**Bounded resumable 1 GiB frame-run zeroing state machine and work accounting contracts**: added the pure host-tested 2 MiB slice-by-slice resumable zeroing state machine (`frame_runs.Zero_Run_Progress`) in `modulus:frame_runs`, and extended `modus:contract/work_budget` with sibling-isolated processor-time budgets, per-client service page/time accounting, bounded lowest-step-debt scheduling, and `work(process)` report rows.

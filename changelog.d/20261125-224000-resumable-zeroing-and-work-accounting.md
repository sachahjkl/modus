type: Added

**Bounded resumable 1 GiB frame-run zeroing and work accounting contracts**: wired 2 MiB slice-by-slice resumable zeroing (`frame_runs.Zero_Run_Progress`) with inter-slice interrupt windows into the kernel 1 GiB prefault path, and extended `modus:contract/work_budget` with sibling-isolated processor-time budgets, per-client service page/time accounting, bounded lowest-step-debt scheduling, and `work(process)` report rows.

type: Added

**Console record-stream short forms (`keep`, `audit`, `merge`) and live root role connection accounting.** Added `keep(stream)`, `audit(service)`, and `merge(a, b)` wiring list short-form commands in `console`; `root` now resolves role names on `Connect`/`Disconnect` through `role_target_resolve` and tracks per-connection work budgets, supervision generations, and service time attribution via `connection_accounts.odin`.

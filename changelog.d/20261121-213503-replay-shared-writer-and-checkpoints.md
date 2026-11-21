type: Added

**Pure engines for replay shared-writer gating and debugger reverse checkpoints.** `replay_filter` adds the `Shared_Writer_Gate` state machine enforcing input-point gating, the one-stint wait bound, and immediate revocation override; `input_history` adds `Checkpoint_Ring`, `step_back_plan`, and `watch_back_plan` for reverse stepping and reverse data watchpoints.

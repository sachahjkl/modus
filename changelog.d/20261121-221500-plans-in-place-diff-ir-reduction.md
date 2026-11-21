type: Fixed

**In-place plan difference without IR blowup.** `plan_diff_compute`, `plans_core.compute_difference`, and `plans_core.apply_plan` write `Plan_Difference` into a caller-supplied pointer instead of returning the 11 KiB record by value, shrinking freestanding `plans` LLVM IR from 17.57 MB to 0.77 MB (31.95 MB to 3.14 MB with debug info) and compiling with `llc -O3` in 0.43 s.

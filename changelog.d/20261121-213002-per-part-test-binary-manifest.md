type: Added

**Per-part machine test binary dependency manifest.** `tools/modustool/machine` now defines `part_binary_plans`, `part_scenario_sources`, `part_binary_plan_problems`, and `part_binary_plans_json`, mapping all 33 machine test parts to their minimal scenario source files and claimed output log patterns. Host tests verify against the repository tree that every part is covered, every declared scenario file exists on disk, and no two parts claim a conflicting output.

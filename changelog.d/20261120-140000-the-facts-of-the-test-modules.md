type: Changed

**The test modules write log facts**: the lines with a value of `log_reader`, `arena`, `hierarchy`, `ranges`, `shortage`, `hostile_terminal`, `flood`, `iommu_device`, `debug_target`, `visitor`, `store_importer` and `disk_start_policy` are records of fields, whose sentences are those of before. In the console, `log.records(0) |> facts(ranges.Loop_Commits_Made)` gives the time of each fifty commits of range writes, and `log.records(0) |> facts(log_reader.Child_Records_Read) |> where(child = "log_reader child 2")` the check of the records of one child.

type: Changed

**The storage service and the block service write log facts**: a disk that does not answer, the read back of a commit and its root, a check of a commit that fails, the open of the disk with its damaged blocks, a share, a store at its limit, the erase of versions, the stop of the removal of a tree and the commit of range writes are records of fields, whose sentences are those of before. In the console, `log.records(0) |> facts(storage_service.Disk_Opened) |> where(wrong > 0)` gives each open of the disk that found blocks with a wrong check.

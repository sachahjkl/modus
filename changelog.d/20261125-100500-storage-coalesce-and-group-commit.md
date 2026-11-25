type: Added

**Storage extent coalescing and group commit.** The storage service sorts commit writes by disk block number, coalesces contiguous block runs into multi-block transfers up to the block service limit, and groups concurrent commits to distinct stores queued in the same service pass into one flushed and read-back root commit.

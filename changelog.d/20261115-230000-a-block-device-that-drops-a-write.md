type: Added

**A block device that drops a write, as a test.** `modustool test power` now runs the storage service on a disk that answers Ok to the write of one block of a commit and does not keep it. At the next start, the service refuses that commit with one line of the log and uses the commit before it, and the object reads its previous version.

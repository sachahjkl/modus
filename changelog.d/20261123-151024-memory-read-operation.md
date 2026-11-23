type: Added

**A kernel operation reads a memory object by its handle.** `Memory_Read` (36) copies up to 1 MiB of an object that the caller holds with Read into its own memory, and gives a status (`Bad_State` for a page that is not committed) where a read through a mapping would fault; `system.memory_read` copies a larger range in several calls. `Memory_Size` now also gives the flags of the creation that the object keeps (`Contiguous`, `Uncommitted`, `Large_Pages`), which `system.memory_size_and_flags` returns.

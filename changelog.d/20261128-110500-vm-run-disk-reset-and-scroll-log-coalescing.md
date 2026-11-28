type: Fixed

**Automatic reset of obsolete local data disks in `modustool run` and quieter element logging while scrolling.** `modustool run` and `modustool run --console` now replace `build/data_disk.img` with a fresh disk when its root blocks carry an older storage format, keeping current and blank disks untouched. Window element places now clip to the active draw clip (omitting off-screen widgets) and coalesce during active scroll-bar drags and rapid scrolling in `settings` until scrolling settles, avoiding COM1 log floods while keeping `Click_Element` accurate.

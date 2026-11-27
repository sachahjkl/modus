type: Added

**Second display holder and resumable 1 GiB `pdpe1gb` runs.** The kernel now commits aligned 1 GiB `Frames_Now` ranges across bounded 2 MiB zeroing slices that yield through the scheduler with locks released and reclaim unfinished tails on thread stop, verified by the 4 GiB `gigabyte_pages` test part; and `root` grants replacement `Role.Display` holders the Display role grant row, verified live by the barless second display holder `panel_display` in the `roles_display` test part.

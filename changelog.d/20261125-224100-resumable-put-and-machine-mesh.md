type: Added

**Resumable object cache uploads and machine identity seed helpers**: `modus:contract/object_cache` and `tools/modustool/cache_server` add Bao-verified resumable uploads that checkpoint verified 1 MiB frames and resume from the last contiguous frontier after interruption; `modus:contract/machine_mesh` adds TPM-rooted machine identity seed derivation, quote qualifying data binding, and monotonic revocation preparation helpers.

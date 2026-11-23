type: Added

**The catalog of the system written by its build.** Each build now writes `build/catalog.lex` for the boot image and `build/catalog_release.lex` for the release boot image without test modules, giving `catalog.release`, `catalog.modules.<name>`, and `catalog.c.module(path)` from the exact BLAKE3 hashes of the built modules so projects evaluate without hand-written hashes.

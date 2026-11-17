type: Changed

**The check of the imports covers the whole system**: `modustool` now reads each source of `src/`, refuses a package of `core:` in a source that is not a test, and refuses a test that imports one with no `#+build !freestanding` as its first build line, with the file and the line of each breach. The files that the manifest of the cryptography of Odin names keep the imports of their origin.

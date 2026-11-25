type: Added

**Console ergonomics: unified `start`, one-step `projects.install`, and `help(name)`.** `start(name)` now launches boot-image modules or pinned disk processes from `module_files` (with optional wiring `Table` or 64-digit hash `Text` as the second argument); `projects.install(name, [mode])` connects `recipes`, ingests, builds, verifies, and delivers a project module in one command returning a `Project_Install` record; and `help(name)` delegates directly to `describe(name)` including boot-image service exports and plain-English command guides.

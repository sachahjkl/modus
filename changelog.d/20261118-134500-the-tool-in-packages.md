type: Changed

**The tool in packages.** The tool `modustool` is one command over eight packages, one folder each under `tools/modustool`: `foundation`, `resources`, `build`, `checks`, `fuzz`, `similarity`, `machine` and `site`. A developer reads one concern in one folder, and `modustool check` runs the host tests of each package in its own process. The commands and their arguments do not change.

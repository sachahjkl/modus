type: Added

**Odin core target on modus for outside modules.** Outside modules can declare `target: modus` in `module.txt` to compile with `base:runtime` and the `core:` packages (`core:sys/modus`, `core:fmt`, `core:mem/virtual`, `core:time`, `core:sync`, `core:thread`, and `core:os`) while keeping zero ambient authority and freestanding system modules.

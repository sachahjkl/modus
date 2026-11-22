type: Added

**The services of the declarations count their work.** `plans` exports `diff_count`, `apply_generation` (the newest generation that an apply committed, which a rollback keeps) and `rollback_generation` (the generation that a rollback with no target selects, with no change), `recipes` exports `build_count` and `cache_hits`, and `projects` exports `pin_count`, the pins of the last `pins.lex` that it read whole.

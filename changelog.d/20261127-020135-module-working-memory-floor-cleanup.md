type: Changed

**The working memory leaves each module.** Every module whose start memory fits counted parts, `MODULE_START_OBJECTS`, `MODULE_START_BUDGETS`, or `wiring_pages` now states zero working memory and drops all `Measure pending` entries, leaving only eight modules with large post-ready allocations on `working_memory_pages`.

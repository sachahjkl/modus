type: Changed

**The floor of a module, counted whole, replaces the budget that it asked for.** The table `Floor` of each module with an entry holds what its process needs to reach its first state of work: its modules and their load (frame lists and page tables), its threads, its window, its start objects (`MODULE_START_OBJECTS`, `PACKAGE_START_OBJECTS`) and the floors of the children that the module table names, with the working memory that is left. A file with no table `Floor` no longer starts with a least budget: its start is refused with one line.

type: Fixed

**The cost of a memory object never wraps**: `operation.memory_list_pages` gave 1 list page for a count of pages near the top of its type, and `operation.memory_cost` wrapped to a small cost. The list pages are now exact for each count, and a cost past the type is the largest value, which no budget holds.

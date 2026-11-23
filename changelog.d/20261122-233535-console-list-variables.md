type: Added

**A console variable keeps a list**: `x = [1, 2, 3]` keeps the list, and `map(x, (n) => n * n)` on a later line gives `[1, 4, 9]`. A variable keeps 64 items at most, nested lists included, and 32 KiB of their texts and records; a list past a bound is refused with an error record `Over_Limit`, and the variable keeps its old value. A variable still keeps no function.

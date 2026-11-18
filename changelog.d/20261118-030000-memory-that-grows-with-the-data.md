type: Added

**Memory that grows with the data, paid by the budget.** A program holds data with no known bound in an arena of the support package `system`: `arena_create` reserves an uncommitted object, `arena_push` commits the next pages as the arena grows and gives back `No_Budget` with its error record when the budget cannot pay, `arena_reset` keeps the pages for the next frame, and `arena_end` gives every page back to the budget at once. The test program `arena` grows an arena until its budget refuses, and checks that it keeps running and that its budget comes back whole.

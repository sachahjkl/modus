type: Changed

**Undo in paint has no count of steps.** The history of `paint` keeps the box that each change touched, in memory of the budget that grows up to one copy of the picture, and drops its oldest steps past that, in place of 64 steps in 1 MiB: a fill on a photo of 6000 × 4000 undoes. A change larger than that memory is kept as the one step of the history, in the copy before the stroke, in place of a change that could not be undone.

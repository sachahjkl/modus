type: Added

**Host test seam for the `system.output_write` ring loop.** A host-only seam seeds full rings at and past their largest gap count so host tests run `system.output_write` itself: stalled rings close with a `Closed` completion, `rings_past_gap` increments, and sibling healthy rings still receive the exact record.

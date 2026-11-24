type: Added

**The collection of the objects of `recipes`.** `recipes` runs mark-and-sweep collection over its private store after local builds, before evicting live realisations when space runs low, and on demand through `recipes.collect_garbage`, removing unreferenced content-addressed objects while preserving live realisations, recipes, active or queued builds, pins, and recent puts.

type: Added

**Immutable trees with a domain-separated tree hash and mark-and-sweep collection of `module_files`.** The storage service freezes mutable subtrees bottom-up into canonical immutable tree objects named by a domain-separated BLAKE3 tree hash (`freeze_tree`, `tree_read`, `tree_entry`), and collects unreachable content-addressed objects in `module_files` (`collect_garbage`) while keeping every hash reachable from signed system modules, kept applied plans, disk grant modules and pinned trees, refusing corrupt or over-deep graphs with zero deletions.

type: Added

**Whole-store snapshot history and atomic rollback contract.** Added freestanding `modus:contract/store_history` providing a bounded immutable snapshot DAG with canonical `tree_hash` commits, historical object lookup, atomic whole-store rollback that preserves newer snapshots, and sorted snapshot diffs.

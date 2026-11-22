type: Added

**Canonical bootstrap and C-world recipe catalog with native x86-64 compilation proofs**: added typed reproducible `plans_recipes.Recipe_Spec` and `guest_builder.Guest_Build_Spec` catalog definitions for `chibicc_stage1`/`chibicc_stage2`, `sqlite`, `lua`, `zstd`, and the 6-stage `live_bootstrap_chain` (`hex0` to `odin`), verified alongside deterministic bit-for-bit BLAKE3 tests of the native x86-64 assembler and C + assembly `ET_REL` to `.modus` conversion.

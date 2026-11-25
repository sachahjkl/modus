type: Added

**Program trees and offline USB closure transfer**: `modus:contract/program_tree` validates canonical `MODTREE2` multi-file program trees (`module`, optional `modules/` helper subtree, and optional `assets/` read-only subtree), `modus:contract/object_cache` defines the deterministic self-verifying `MODCLOS1` offline closure stream format, and `tools/modustool/cache_server` adds `cache-export` and `cache-import` for air-gapped closure export and verified import.

type: Added

**Single-line `pins.lex` updater, paired build dispatch, and shared network library contract**: `projects_core` adds deterministic single-line `pins.lex` updates and `Project_Enter_Scope` validation refusing ambient paths and grant escalation; `recipes_core` adds `Paired_Builder_Table` and `recipe_graph_dispatch_step` for paired-machine DAG leaf builds with `MODTREE2` and Ed25519 verification and local sandbox failover; `modus:contract/network_library` adds the versioned boundary and workspace sizing contract for shared `tcp`, `quic`, and `cryptography` library modules.

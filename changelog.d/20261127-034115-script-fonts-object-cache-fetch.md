type: Added

**Live object-cache fetch wiring for script fonts in `root`.** When the local data disk lacks the script font set (or holds another hash, or no data disk is present) and principal 0 configured `root.script_fonts_cache_key`, the root service fetches the named set or `Script_Font_Pack_Manifest` (`MODSFP01`) over QUIC through `disk_processes`, verifies every Bao frame and the full BLAKE3 hash and `font_outlines` form on its own mapping, maps it read-only, and persists it to the local `script_fonts` store.

type: Changed

**One way to read an object through the storage service.** Migrated `font_outlines` and `script_fonts` delivery off `root`'s fixed address ranges onto `storage.map_object` under the read-only `"fonts"` tree grant (`Publish_Public_Object` for `script_fonts`, `GRANT_VALUE_STORAGE_FONTS_ONLY` short-lived font connections, and `drawing_fonts_set`/`process_fonts_places` for library modules), removing the retired `Pointer_Themes`, `Font_Outlines`, and `Script_Fonts` fixed-range slots (`SLOT_COUNT = 18`).

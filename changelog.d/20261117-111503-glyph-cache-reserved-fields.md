type: Changed

**A glyph cache with a reserved field that is not 0 is refused**: `glyph_cache.validate` refuses the last reserved field of the header and the reserved field of a size with `Bad_Count`, and the reserved field of a pair with `Bad_Pair`. The tool writes each of them as 0.

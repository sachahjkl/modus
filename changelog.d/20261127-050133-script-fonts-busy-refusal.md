type: Added

**A machine case of a start refused as busy during the read of the script fonts.** The local QUIC object cache holds a named object open until the `Release_Cache_Hold` step releases it. The `script_fonts` machine test proves that `start_from_disk` is refused as busy during the fetch and succeeds after the set maps and caches.

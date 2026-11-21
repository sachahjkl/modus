type: Added

**Zero-allocation LZ4 block codec, Binary Fuse8 filter, and commit-driven bigram store search index.** Three freestanding packages join `modus:contract`: `lz4` (up to 5.8 GiB/s compress and 12.2 GiB/s decompress on repetitive 64 KiB text), `xor_filter` (9.5 bits per key at 100 000 keys, 0% false negatives, 2.5–3.4 ns lookup), and `store_search` (103x–189x faster than brute-force search across 200 files, with O(1) subtree index reuse by `tree_hash`).

# Performance primitives: LZ4, Binary Fuse8 filters, and bigram store search

Three freestanding, zero-allocation contract packages provide fast compression, compact set-membership filtering, and commit-driven full-text prefiltering for system services and the host tool:

- `src/library/modus/contract/lz4`: standard LZ4 raw block compression and decompression.
- `src/library/modus/contract/xor_filter`: Binary Fuse 8-bit compact set filters over 64-bit keys with a strict binary wire border.
- `src/library/modus/contract/store_search`: bigram inverted index keyed by content-addressed `tree_hash` digests for commit-driven subtree reuse.

## Purpose

System services share three recurring performance needs across storage, remote display, log transport, object caching, module garbage collection, and project search:

1. **Fast block compression (`lz4`).** Remote display pixel updates, stored pages, and log streams benefit from compression that decompresses near memory-copy speed without dynamic allocation or a foreign C library.
2. **Compact membership filters (`xor_filter`).** The object cache protocol (`src/library/modus/contract/object_cache`) and module garbage collection (`src/library/internal/storage/module_gc`) test membership of 32-byte BLAKE3 hashes across large sets. A Binary Fuse 8-bit filter represents each key in roughly 9 to 10 bits with 0% false negatives and ~0.39% false positives, reducing cache round trips and mark-phase walks.
3. **Commit-driven search indexing (`store_search`).** A store in `modus` changes only by atomic commits over immutable content-addressed trees (`src/library/modus/contract/tree_hash`). A bigram inverted index keyed by `tree_hash` skips files that cannot match a query and reuses the index of every unchanged subtree in O(1) without a file watcher.

## Constraints

- **Freestanding, zero allocation, no kernel calls.** All three packages live under `src/library/modus/contract/` so every module and `tools/modustool` can import them without adding support-package ownership coupling ([../infrastructure/repository_layout.md](../infrastructure/repository_layout.md)). Every procedure is `"contextless"` and imports `base:` and `modus:contract/*` only.
- **Caller-supplied memory.** Scratch tables, filter fingerprint buffers, and subtree index caches are passed by the caller. No package calls an allocator.
- **Hostile-input safety.** Every decoder and wire border checks all lengths, magic bytes, reserved bytes, offsets, and bounds before touching output buffers. Invalid inputs return a closed `enum u8` refusal (`None = 0`) and never read or write out of bounds.
- **Reference and equivalence.** Each algorithm keeps a simple scalar or brute-force reference in the package or its tests, verified by deterministic fuzzing across edge lengths and hostile inputs.
- **Measured speed.** Each package provides an opt-in `-define:MEASURE=true` host benchmark printing real throughput or latency numbers without asserting hardware-dependent thresholds.

## The chosen form

### 1. LZ4 block codec (`src/library/modus/contract/lz4`)

- **Wire format.** Standard raw LZ4 block stream (token byte with 4-bit literal length and 4-bit match length minus 4, base-255 length extensions, literal bytes, 16-bit little-endian match offset, final literal-only sequence).
- **Compression (`compress_block`).** Uses a caller-supplied 4,096-entry `[4096]u16` hash table (8 KiB), cleared at entry for deterministic output. Storing truncated 16-bit positions and computing wrapping `u16` deltas allows the 8 KiB hash table to handle arbitrary block sizes beyond 64 KiB while verifying every 4-byte candidate strictly inside `[1, 65535]`. Match extensions compare 8 bytes at a time via `count_trailing_zeros`. Incompressible runs accelerate the probe step (`1 + (misses >> 6)`). The last 5 bytes of any block are emitted as literals (`LAST_LITERALS_MINIMUM :: 5`).
- **Decompression (`decompress_block` and `decompress_block_reference`).** `decompress_block_reference` performs straightforward byte-by-byte decoding as the specification oracle. `decompress_block` uses 8-byte copies for non-overlapping literals and matches (`offset >= 8`) and 8-byte pattern fills for small repeating offsets (`1, 2, 4`), while strictly enforcing identical bounds checks and error refusals for truncated tokens, zero offsets, offsets past current output, length overflow, destination overflow, and streams ending without a final literal-only sequence.

### 2. Binary Fuse8 compact filter (`src/library/modus/contract/xor_filter`)

- **Algorithm.** 3-wise Binary Fuse 8-bit filter (Graf & Lemire, 2022) mapping 64-bit keys (such as the first 64 bits of a BLAKE3 hash via `key_from_blake3_hash`) to three distinct power-of-two-aligned adjacent segments `(h0, h1, h2)` using 128-bit `mulhi` range reduction and Murmur64 `mix_split`.
- **Freestanding integer sizing.** Segment length (`4 ..= 262144`) and capacity overhead factor (`1.125x` at large sizes, wider at small sizes) are computed from deterministic integer tables with no floating-point `core:math` dependency.
- **Zero-allocation construction and duplicate handling (`filter_build`).** Peeling and reverse assignment run in caller-supplied scratch slices (`t2count`, `t2hash`, `alone`, `reverse_order`, `reverse_h`). If attempt 0 fails (cycle or duplicate keys), construction sorts a copy of the keys inside `reverse_order` with in-place heapsort and deduplicates before retrying with deterministic SplitMix64 seed progression.
- **Lookup (`contains`).** Evaluates `fingerprint(hash) == fp[h0] ^ fp[h1] ^ fp[h2]` in O(1) with 0% false negatives. Empty filters (`key_count == 0`) always return `false`.
- **Strict binary wire border (`filter_encode`, `filter_decode`).** 32-byte little-endian header (`"MODBF8V1"`, `seed`, `key_count`, `segment_length`, `segment_count`, zero `reserved`) followed by `(segment_count + 2) * segment_length` fingerprint bytes. `filter_decode` refuses corrupt magic, non-zero reserved bytes, zero or non-power-of-two segment lengths, zero or oversized segment counts, oversized fingerprint counts, truncation, and trailing bytes.

### 3. Commit-driven store search index (`src/library/modus/contract/store_search`)

- **Bigram inverted index (`Bigram_Index`).** Maps all 65,536 ASCII-lowered byte pairs through a 32-bit Fibonacci multiplicative mix into `BIGRAM_BUCKET_COUNT :: 4096` inverted bitset buckets (`[4]u64` per bucket, supporting up to 256 files per subtree). ASCII lowering covers arbitrary byte streams including UTF-8 and binary data without allocation.
- **Per-file signature (`index_build_for_file`).** Extracts a 4,096-bit `File_Bigram_Signature` in one linear pass over file bytes; `index_add_file_signature` transposes set bits into the subtree's inverted postings via `count_trailing_zeros`.
- **Two-stage content search (`index_search_content`).** Intersects all query bigram buckets across the 256-file bitset first (4 word-ANDs per query bigram, exiting early when empty), then runs exact ASCII case-insensitive verification only on surviving candidate files. Single-byte queries bypass bigram filtering and check every file, preserving 0% false negatives for all non-empty queries.
- **Content-addressed subtree reuse (`Subtree_Index_Cache`, `index_reuse_subtree`).** Keys cached `Bigram_Index` slots by canonical 32-byte `tree_hash` values with O(1) open-addressed lookup and clock-hand eviction. Across commits, unchanged subtrees hit the cache in O(1) and only subtrees whose `tree_hash` changed are reindexed.

## Refused forms

- **Porting upstream C libraries (`lz4.c`, `xor_singleheader`, `fff`).** Each C/Rust codebase carries host allocator assumptions, compatibility macros, or OS file-watcher machinery that conflict with freestanding caller-supplied memory and commit-driven trees.
- **32-bit hash table entries in `lz4` or unbounded dynamic tables.** A `[4096]u32` table doubles stack/scratch footprint to 16 KiB for no gain when wrapping `u16` deltas already cover the full 64 KiB LZ4 match window for arbitrary block lengths.
- **Classic Xor8 filters instead of Binary Fuse8.** Binary Fuse8 requires ~9.0–10.2 bits per key instead of ~9.84 bits per key and builds roughly twice as fast with the same O(1) lookup cost.
- **Bloom filters for static cache/GC hash sets.** A Bloom filter needs ~11.5 bits per key for a 0.39% false positive rate and ~8 probes per lookup versus 3 probes and ~9.0–10.2 bits per key for Binary Fuse8.
- **File-system watchers or trigram-only indices in `store_search`.** `modus` stores have no global file system and mutate only at commits; trigrams cannot prefilter 2-byte queries, whereas bigrams prefilter every query of 2 or more bytes with zero false negatives.
- **Floating-point `log` calls in `xor_filter` sizing.** Freestanding contract packages cannot import `core:math`; integer threshold tables give exact deterministic sizing on every target.

## Sources and licences

All three packages are clean Odin implementations of published formats and algorithms, with no copied upstream source files:

- **LZ4 block format** (Yann Collet; BSD-2-Clause): raw block encoding and decoding specification.
- **Binary Fuse Filters** (Thomas Mueller Graf and Daniel Lemire, ACM JEA 2022; Apache-2.0): 3-wise 8-bit Binary Fuse construction, peeling, and query algorithm.
- **Bigram store search index** (inspired by `fff` by Dmitriy Kovalenko; MIT): bigram prefiltering adapted to content-addressed immutable trees with `tree_hash` subtree reuse.

## Subtle points

- **LZ4 overlapping match copies.** When `match_offset < match_length`, the match repeats a periodic pattern of length `match_offset` (run-length encoding when `match_offset == 1`). Fast 8-byte copying is valid only when `match_offset >= 8` or after expanding offsets `1, 2, 4` into an 8-byte repeating word.
- **LZ4 trailing-sequence rule.** A non-empty LZ4 block must end after the literal run of its final sequence; stopping immediately after a match without a final literal-only sequence is malformed and refused as `.Truncated`.
- **Binary Fuse8 duplicate keys and small sets.** Duplicate keys cancel out in `t2hash` while leaving non-zero counts in `t2count`, preventing peeling. Sorting and deduplicating inside `reverse_order` on retry resolves duplicates without extra scratch memory or mutating caller input.
- **Binary Fuse8 empty set wire encoding.** An empty filter (`key_count == 0`) still carries a valid power-of-two `segment_length` (4) and `segment_count` (1) on the wire so `filter_decode` unconditionally refuses `segment_length == 0`, while `contains` short-circuits on `key_count == 0` to guarantee 0% false positives.
- **Bigram hash dispersion.** ASCII text bigrams cluster tightly in `0x6161..0x7A7A`; hashing the 16-bit lowered pair with a 32-bit Fibonacci multiplier spreads text bigrams evenly across all 4,096 inverted buckets.

## State

Built: `src/library/modus/contract/lz4`, `src/library/modus/contract/xor_filter`, and `src/library/modus/contract/store_search`, each with freestanding verification, adversarial host tests, fuzz/reference checks, and opt-in `-define:MEASURE=true` host benchmarks (numbers updated after measurement). Left: wiring `lz4` into remote display, storage pages, and log streams; wiring `xor_filter` into the object cache protocol and `module_gc`; and wiring `store_search` into the storage service and console.

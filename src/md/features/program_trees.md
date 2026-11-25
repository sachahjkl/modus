# Program trees and offline closure transfer

A program that needs helper modules or static read-only assets is a canonical `MODTREE2` tree, never a new archive format. An air-gapped machine receives that tree — or any recipe output closure — from a single deterministic `MODCLOS1` closure stream written to a USB drive and verified hash-by-hash on import.

## Canonical program tree layout

A program tree uses the existing `MODTREE2` tree format (`modus:contract/tree_hash`) with one closed top-level schema validated by `modus:contract/program_tree`:

- **`module`** (required, `Tree_Entry_Kind.Object`, non-zero BLAKE3 hash): the entry module binary launched by the starter.
- **`modules`** (optional, `Tree_Entry_Kind.Tree`, non-zero tree hash): a flat subtree mapping each helper module name to a `Tree_Entry_Kind.Object` module binary with a non-zero BLAKE3 hash.
- **`assets`** (optional, `Tree_Entry_Kind.Tree`, non-zero tree hash): a read-only immutable subtree of static files and nested folders (fonts, shaders, icons, lookup tables) addressed by relative `/`-separated paths up to 32 levels deep (`ASSET_PATH_MAX_DEPTH`) and 1024 bytes (`ASSET_PATH_MAX_BYTES`).

Any other top-level entry, a missing `module` entry, a non-Object `module`, a non-Tree `modules` or `assets`, a zero hash, a part node, or a malformed `MODTREE2` encoding is refused by `program_tree_validate`.

Helper lookup (`program_tree_lookup_helper`) validates the `modules` tree and accepts only `Tree_Entry_Kind.Object` entries with non-zero hashes. Asset lookup (`program_tree_lookup_asset`) validates every path segment with `tree_hash.tree_name_validate`, refuses empty, leading/trailing/double slashes, `.`, `..`, and paths deeper than 32 levels, and recomputes `tree_hash.tree_hash` on every intermediate subtree returned by the caller's read callback before walking into it.

## Deterministic offline closure stream (`MODCLOS1`)

An air-gapped machine cannot reach a QUIC object cache over the network. `modus:contract/object_cache` (`closure_stream.odin`) defines one self-verifying binary stream format for transferring a complete content-addressed closure (such as a program tree or a built recipe output) over removable media:

- **Stream header (`CLOSURE_STREAM_HEADER_SIZE` = 64 bytes, little-endian)**:
  - `[0..8]`: magic `"MODCLOS1"`
  - `[8..12]`: `version` (`u32`, must be `1`)
  - `[12..16]`: `flags` (`u32`, bit 0 = `has_realisation`, all other bits must be `0`)
  - `[16..48]`: `root_hash` (`[32]u8`, non-zero BLAKE3 or `MODTREE2` hash of the closure root)
  - `[48..56]`: `object_count` (`u64`, `1 ..= CLOSURE_STREAM_MAX_OBJECTS`)
  - `[56]`: `root_kind` (`Cache_Object_Kind`: `1` = Blob, `2` = Tree)
  - `[57..64]`: reserved (`[7]u8`, must be all zero)
- **Object records (`object_count` records in deterministic bottom-up order, root last)**:
  - Record header (`CLOSURE_RECORD_HEADER_SIZE` = 44 bytes): `[0]` `kind` (`Cache_Object_Kind`), `[1..4]` reserved zero, `[4..12]` `size` (`u64` LE, bounded by `payload_bound_for_kind`), `[12..44]` `hash` (`[32]u8`, non-zero).
  - Record payload: exact `size` bytes immediately following the header.
  - Because `MODTREE2` entries are strictly sorted in UTF-8 byte order and export walks post-order DFS deduplicating by `(hash, kind)`, two exports of the same closure produce byte-for-byte identical files.
- **Optional trailing realisation (`REALISATION_WIRE_SIZE` = 164 bytes when `has_realisation` is set)**:
  - Exact canonical `Realisation_Record` (`encode_realisation_record` / `decode_realisation_record`) whose `output_hash == header.root_hash` and `output_kind == header.root_kind`.
  - No trailing bytes are allowed after the last object record (or after the realisation when `has_realisation` is set).

### Verification and import rules

- Every `Blob` record is verified against `record.hash` with `blake3.hash` (streaming in 1 MiB chunks for blobs larger than one cache frame) before atomic rename into `objects/<64-hex>`.
- Every `Tree` record is verified with `tree_hash.tree_hash` and every child hash it names must already be verified in the stream or present in the destination store.
- The final record in the stream must match `header.root_hash` and `header.root_kind`.
- When `has_realisation` is set, the Ed25519 signature over `realisation_signing_bytes` is verified before writing `realisations/<64-hex>`. When `--signer <public_key_file>` is given, `signer_public_key` must match an explicitly trusted signer via `substitution_check`.
- Any truncation, bad magic, unsupported version, nonzero reserved byte, zero hash, tampered payload, malformed tree, missing child, bad signature, untrusted signer, or trailing byte refuses the import without committing the realisation or any unverified object.

### Host CLI commands

`tools/modustool/cache_server/closure_cli.odin` provides two host commands over on-disk cache stores:

- `modustool cache-export --dir <cache_dir> <root_hash> <out_file> [--realisation <recipe_hash>]`: walks `root_hash` bottom-up from `<cache_dir>`, verifies every object hash, and writes `<out_file>` atomically.
- `modustool cache-import --dir <cache_dir> <in_file> [--signer <public_key_file>]`: streams `<in_file>`, verifies every object hash and any trailing realisation signature, and commits verified objects (and realisation) atomically into `<cache_dir>`.

## Refused forms

- **A new zip, tar, or custom bundle container for multi-file programs.** A second container duplicates `MODTREE2`, invents a second hashing rule, and breaks deduplication across storage, recipes, and the object cache.
- **Top-down closure streams or importing realisations before objects.** Top-down streams allow a partial import to expose a tree or realisation pointing at absent objects.
- **Trusting an offline USB file without recomputing every hash.** Removable media is an untrusted transport; content-addressed hashes check every object, and Ed25519 checks every realisation.

## Subtle points and hazards

- **Intermediate asset subtrees must be re-hashed on every lookup step.** `program_tree_lookup_asset` never trusts the bytes returned by `read_subtree`; it checks `tree_hash.tree_hash` against the parent entry's hash before descending.
- **Blobs larger than 1 MiB stream on import.** `cache_closure_import` streams blobs above `FRAME_PAYLOAD_BYTES` into `tmp/` while updating a `blake3.Hasher` and only renames into `objects/<64-hex>` after the full digest matches.

## State

Built in `src/library/modus/contract/program_tree` (`program_tree.odin`, `program_tree_test.odin`), `src/library/modus/contract/object_cache` (`closure_stream.odin`, `closure_stream_test.odin`), and `tools/modustool/cache_server` (`closure_cli.odin`, `closure_cli_test.odin`).

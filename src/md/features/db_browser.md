# The SQLite module and the database browser

The system holds no SQLite in its boot image or its base libraries ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "12. Module metadata in flat tables, read through functions"). A process that needs SQL brings SQLite as an outside module of its own. This file records the typed, store-backed contract of `sqlite` (`src/outside/c_programs/sqlite/`) and the design of `db_browser` (`src/outside/projects/db_browser/`), an outside GUI application that browses and edits SQLite databases over the copy-on-write storage service.

## Purpose

- Replace raw pointer integers and `|`-delimited text rows in `sqlite` with typed records, tables, bytes, and structured error records ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes").
- Run untrusted C SQLite parsing and query execution in a zero-grant isolated child call host, separate from the window and store handles of `db_browser` ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default" and "15. Isolation inside a process").
- Persist only modified 4 KiB database pages atomically through `storage.write_range`, `storage.set_size`, and `storage.commit`, turning every SQL write into a copy-on-write storage version with no save action ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "9. A storage engine with one private store per process").
- Keep the interface thread responsive at all times: zero SQL, sorting, or storage calls run on the interface thread.

## Constraints

- **No ambient SQLite in the system.** `sqlite` stays in `src/outside/c_programs/sqlite/` and `db_browser` stays in `src/outside/projects/db_browser/`, outside `src/modules/` and outside the boot image.
- **Strict `.Read_Only_After_Load`.** `sqlite` stays `library: no` so its VFS function-pointer tables stay read-only after load.
- **Zero dangling `Bytes` pointers across calls.** A `Bytes` or `Table` parameter ends when its export returns ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "Tables and bytes as parameters"). No pointer into a caller-lent `Bytes` buffer can survive past return.
- **No RAM-to-storage divergence.** A multi-statement failure never leaves uncommitted dirty pages unsynced against the store, and `VACUUM` or shrink clamps dirty ranges to the new file size before `storage.set_size` and `storage.commit`.
- **Clear screen text.** Every status and error sentence in `db_browser` follows [`docs/WRITING.md`](../../../docs/WRITING.md): plain problem, cause, and action, with no raw SQLite numeric code as the message and each fact stated once.

## The chosen form

### 1. The typed `sqlite` module (`src/outside/c_programs/sqlite/`)

`sqlite` is a zero-import freestanding C module compiled from the pinned SQLite 3.54.1 amalgamation over the thin libc and the modus VFS (`sqlite.manifest`).

**Memory ownership without dangling pointers.**

- SQLite `memsys5` heap (`SQLITE_HEAP_CAPACITY = 4 MiB`, computed from measured 10,000-row transactions plus `VACUUM`) and VFS scratch slots (`SQLITE_SCRATCH_CAPACITY = 2 MiB`: rollback journal and temporary spill files, never persisted) live in `sqlite`'s own `.bss`, paid by the child call host's memory budget and occupying zero bytes in `sqlite.module`. `Open_Options.heap_bytes` bounds `memsys5` within `[64 KiB, 4 MiB]` (0 selects the full 4 MiB).
- The `main.db` bytes are supplied per call through `database: bytes(change)` on `session_open`, `session_execute`, and `session_close`. `sqlite` binds the VFS main slot pointer at entry and clears it to `NULL` before return. Over an isolated call host, `db_browser` lends a `Memory_Object` handle (`keep_memory_objects = true`), so zero bytes copy across the kernel; if `main.db` grows past the current buffer, the caller extends its arena and passes the larger buffer on the next call.
- A 1-bit-per-4 KiB-page dirty bitmap (`16 KiB` in `.bss`, tracking up to 512 MiB of database pages — computed bound) records every `file_write` and `file_truncate` on `main.db`.

**Contract types (`sqlite.manifest`).** Every record is flat, 8-byte aligned, at most 256 bytes, and valid when all zero:

- `enum Value_Kind u8`: `none = 0`, `null = 1`, `integer = 2`, `real_bits = 3` (raw IEEE-754 `u64` bits), `text = 4`, `blob = 5`.
- `record Error_Record size=56`: exact layout of `errors.Error_Record`.
- `record Open_Options size=32`: `fresh`, `read_only`, `page_size` (0 or 4096, format property matching storage blocks), `random_seed`, `database_bytes`, `heap_bytes`.
- `record Session_Info size=32`: `version_number`, `database_bytes`, `dirty_pages`, `page_size`, `open`, `read_only`.
- `record Column_Row size=72`: `column_index`, `declared_kind`, `name_length`, `name_truncated`, `name: text(64)` (inline display bound: names past 64 UTF-8 bytes truncate on a character boundary with `name_truncated = 1`).
- `record Cell_Row size=32`: `row_index`, `column_index`, `value_kind`, `truncated`, `integer_or_bits` (integer value, raw IEEE-754 bits, or full byte length of text/blob), `payload_offset`, `payload_length` (bytes written into `payload`).
- `record Query_Summary size=40`: `column_count`, `row_count`, `changes`, `dirty_pages`, `database_bytes`, `truncated_rows`, `has_rows`.
- `record Dirty_Range_Row size=16`: `byte_offset`, `byte_length`.

**Exports.** Every export that can fail returns `Modus_Answer` (`Call_Outcome`, `value`) and writes `Error_Record` (`found = sqlite_extended_errcode`, `value = sqlite3_error_offset`):

1. `session_open(options, database, info)`: opens `main.db` (`PRAGMA journal_mode = DELETE`), refuses double-open (`Wrong_State`), bad `page_size` or `heap_bytes`, and validates existing non-empty databases on open (`Data_Damaged` on corrupt bytes).
2. `session_execute(sql, database, columns, cells, payload, diagnostic, summary)`: runs statements with implicit savepoint rollback on autocommit multi-statement failures (excluding `VACUUM` and explicit transaction control), returns the result set of the last row-producing statement, and enforces atomic row emission (drops any unfinished row and sets `truncated_rows = 1` when `cells` fills, never emitting a partial row).
3. `session_dirty_ranges(ranges)`: emits coalesced dirty 4 KiB page runs clamped to `database_bytes` so `VACUUM` or shrink never emits ranges past the new file end.
4. `session_mark_synced()`: clears the dirty bitmap after storage commit.
5. `session_info(info)`: returns current session metadata (`open = 0` when closed).
6. `session_last_diagnostic(diagnostic)`: returns the last SQLite diagnostic text across isolated call boundaries (where failed calls drop non-error-details append tables).
7. `session_close(database)`: closes SQLite, shuts down `memsys5`, and clears session state.
8. `version_number()`: returns `sqlite3_libversion_number()`.

### 2. The `db_browser` GUI application (`src/outside/projects/db_browser/`)

`db_browser` is a Lex project (`project.lex`, `pins.lex`, `module.txt`) built as an outside Odin module importing `drawing` and `text_rendering`. Its pure state machine, grid formatter, off-thread sorter, SQL helpers, and layout checks live in the freestanding subpackage `core/` with full host tests.

**Two-thread architecture and budget.**

- `MODULE_BUDGET`: `working_memory_pages = 4096` (16 MiB: 10 MiB for the isolated `sqlite` child call host plus 6 MiB for UI snapshots, editor arenas, and database buffer), `processes = 2` (within `disk_process.LARGEST_BUDGET.processes = 2`), `threads = 3` (UI thread, worker thread, and 1 thread for the `sqlite_host` child, within `disk_process.LARGEST_BUDGET.threads = 4`), `window_width = 1280`, `window_height = 960`.
- **UI thread (`main.odin`)**: owns `display.Window`, `interface.Window_Memory`, `modus:layout` (`Box_Tree`, `Element_Tokens`, `Split_Pane`), `text_model` SQL editor with clipboard (`Ctrl+C/X/V`), and `interface.Action_Bar_State` (`Run` `Ctrl+Enter`, `Open store` `Ctrl+O`, `Versions` `Ctrl+H`, `Refresh` `Ctrl+R`). Registers `interface.element_name` for `"sql editor"` and each visible column header (`"column <name>"`). Renders only visible viewport rows from an immutable double-buffered `Result_Snapshot`.
- **Worker thread (`worker.odin`)**: owns `storage.Client`, runs `sqlite.module` inside a zero-grant child call host (`host`) loaded either from the boot image when `GRANT_IMAGE` is present or from `"host.module"` and `"sqlite.module"` in its private store `disk-db_browser` when running as a disk process with only `allow("db_browser", "store")`. Executes queries, sorts rows off-thread (emitting the `Query_Sorted` log fact), formats cells into the inactive `Result_Snapshot`, streams dirty 4 KiB page runs via `storage.write_range` + `storage.set_size` + `storage.commit`, lists/previews/restores CoW versions, asks the trusted display to open the store picker (`powerbox_pick_store`) on `Ctrl+O`, and wakes the UI thread through `system.Event` (`Word_Wake`).
- **Lex project (`project.lex`)**: declares `outputs.default = recipe(catalog.modules.host, { source = here(), target = "db_browser" })` so `recipes.build_project("db_browser", "prefer_cache")` resolves deterministically against signed remote object cache realisations.

**Layout and interaction.**

- Window sizes: default `1080 × 700`, least `720 × 440`, largest `1280 × 960`, checked with `#assert` minimum pane bounds (`SIDEBAR_MIN_WIDTH = 224`, `EDITOR_MIN_HEIGHT = 160`, `STATUS_HEIGHT = 24`). Dark and light `Element_Tokens`, HiDPI-scaled, zero text overlap.
- **Left sidebar**: `Tables` list (click runs `SELECT * FROM "<escaped>" LIMIT 500;` with `"` escaped as `""`; `500` is an inline preview capacity that the SQL editor can override) and `Columns` sub-list. `Ctrl+H` switches to `Versions` mode (`Up`/`Down` previews read-only snapshot, `Enter` restores as a new commit, `Esc` returns).
- **Right column**: SQL editor (`Ctrl+Enter` runs query, highlights error line/column from `error_offset`) over a virtualized sortable typed result grid (sticky clickable column headers with `^`/`v`, vertical and horizontal scrollbars, right-aligned integers and reals, left-aligned text, muted `NULL`, `<N B>` blobs).
- **Status band**: left shows a `docs/WRITING.md` error sentence or active store/database state; right shows `<rows> rows · <cols> cols · <size> KiB · v<gen>` with each fact stated once.
- **Revocation handling**: if the store connection ends (`!storage.connected`), the worker switches cleanly to read-only state and shows a clear notice without losing the current view.

## Refused forms

- **`library: yes` on `sqlite` with writable vtables.** Making `.data.rel.ro` writable inside `db_browser` weakens RELRO and exposes `db_browser`'s window and store handles to C memory bugs in `sqlite3.c`.
- **Retaining `Bytes` pointers across calls.** Violates the module contract and faults immediately across an isolated call host.
- **Pipe-delimited text rows.** Cannot distinguish `NULL` from empty text, corrupts values containing `|` or newlines, and forces text parsing between processes.
- **SQL, sorting, or storage on the interface thread.** Blocks rendering and input handling whenever a query or commit runs.
- **Showing raw SQLite numeric error codes in the UI.** Violates [`docs/WRITING.md`](../../../docs/WRITING.md).

## Subtle points and hazards

- **`VACUUM` cannot run inside a savepoint.** Multi-statement implicit savepoint wrapping must skip `VACUUM` and explicit `BEGIN`/`COMMIT`/`ROLLBACK` scripts while still syncing any dirty pages after error.
- **Failed isolated calls drop non-error-details append tables.** `session_last_diagnostic` ensures SQLite error text always crosses the call host boundary cleanly.
- **Dirty ranges after shrink.** `VACUUM` or `file_truncate` can leave dirty bits set beyond the new `database_bytes`; `session_dirty_ranges` clamps every emitted range strictly to `[0, database_bytes)` before `storage.set_size` and `storage.commit`.
- **Partial rows on `cells` cap.** `session_execute` checks remaining cell capacity for a full row before emitting any cell of that row, preventing torn rows.

## State

Built: the typed `sqlite` module (`src/outside/c_programs/sqlite/`), real SQLite 3.54.1 host tests covering edge and refusal cases, the `db_browser` outside Lex project (`src/outside/projects/db_browser/`) loading `"host.module"` and `"sqlite.module"` from `disk-db_browser` without `GRANT_IMAGE`, and the `modustool film tutorial` scenario with QUIC cache substitution. Left: receiving a granted `Store_Share` handle from the root service to switch and reload `main.db` after `Ctrl+O` opens the store picker.

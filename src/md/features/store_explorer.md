# The store and version explorer (`files`)

The system gives each process a private copy-on-write store with nested B+ trees and automatic commit versions ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "9. A storage engine with one private store per process"). `files` (`src/modules/applications/files/`, core model in `src/library/internal/files/files_core/`) is a built-in desktop application in the boot image and Start Menu that lets a principal browse accessible stores, navigate nested trees, inspect syntax-highlighted text or binary objects with their BLAKE3 content hash, filter entries, create or remove objects and subtrees, launch `edit` directly on a selected object with `Ctrl+E`, and preview, compare, or restore copy-on-write versions. An outside Lex project mirror also lives in `src/outside/projects/store_explorer/`.

## Purpose

- Give a principal direct visual inspection of stores, trees, objects, storage block quotas, and commit history without typing console commands.
- Keep the interface thread non-blocking at all times: all storage RPCs, root-ring `Start_Edit` launches, BLAKE3 hashing, syntax carry precomputation, hex formatting preparation, and substring entry filtering run on a dedicated worker thread.
- Let a principal jump straight from browsing a store object into `edit` (`Ctrl+E`) under a least-privilege grant (`start_grant.Grant.Open_Editor`) that cannot start arbitrary processes, stop processes, connect to services, or revoke grants.

## Constraints

- **Least-privilege grants.** `files` holds `{.Store, .Acts_For_Principal, .Open_Editor}` with a 4500-block private store limit.
  - `Store` and `Acts_For_Principal` let it list accessible stores of its own principal session through the storage service `stores` export and open selected stores with `storage.open_store`.
  - `Open_Editor` (`start_grant.Grant.Open_Editor = 36`, classified `.Never` in `disk_process.grant_by_command`) grants a root ring restricted by `root_ring.Root_Command_Sender.Root_Ring_Or_Open_Editor` solely to `Root_Command.Start_Edit` (plus universal `Disconnect` and `Budget_Grow`). The root service enforces principal isolation on `Start_Edit` before starting `edit`.
- **No blocking or O(N) work on the interface thread.** Storage reads, directory paging, entry filtering, BLAKE3 hashing, per-line syntax carry precomputation, version comparison, and `Start_Edit` RPCs run strictly on the worker thread and publish immutable double-buffered snapshots.
- **Bounded memory and clear error text.** Every buffer bound states its kind and reason. Every status and error sentence obeys [`docs/WRITING.md`](../../../docs/WRITING.md): plain problem, cause, and action, with no forbidden words, no raw status numbers, and each fact stated once.
- **Revocation safety.** If the storage connection ends (`!storage.connected`), the worker transitions cleanly to read-only state and reports the loss in the status band without discarding the visible view.

## The chosen form

### Two-thread architecture and budget

- `MODULE_BUDGET`: `working_memory_pages = 2048` (8 MiB working memory for two immutable snapshots, preview buffers, layout tree, glyph cache, and worker stack), `processes = 1`, `threads = 2` (interface thread and storage/root worker thread), `window_width = 1280`, `window_height = 960`, `window_least_width = 720`, `window_least_height = 440`.
- **Interface thread (`main.odin`)**: owns `display.Window`, `interface.Window_Memory`, `box_layout.Box_Tree`, dark and light `box_layout.Element_Tokens`, `interface.Action_Bar_State`, and pointer/keyboard handling. Renders only visible rows of the sidebar, entry list, and object inspector (syntax-highlighted UTF-8 text lines or 16-byte hex rows) from `snapshots[active_snapshot]`.
- **Worker thread (`worker.odin`)**: owns `storage.Client`, open subtree `storage.Place` stack, `GRANT_ROOT` ring handle, and worker scratch buffers. Communicates with the interface thread over bounded lock-protected ring queues (`QUEUE_CAPACITY = 16`), an explicit `has_snapshot` flag on `Worker_Result`, and four wake events (`req_event`, `res_event`, `res_space_event`, `snapshot_acked_event`) so snapshot handoff has zero data races and full result queues never deadlock.

### Layout, syntax highlighting, and interaction

- Window sizes: default `1080 × 700`, least `720 × 440`, largest `1280 × 960`, verified with compile-time `#assert` minimum pane bounds (`SIDEBAR_MIN_WIDTH = 224`, `RIGHT_MIN_WIDTH = 400`, `LIST_MIN_HEIGHT = 160`, `INSPECTOR_MIN_HEIGHT = 160`, `STATUS_HEIGHT = 24`, `ACTION_BAR_HEIGHT = 24`). Resizable horizontal and vertical split dividers use `box_layout.split_pane`.
- **Left sidebar**:
  - In `Browse` mode: shows accessible stores (`STORES`) at top and current tree path breadcrumbs (`PATH`) below. Clicking a store opens it; clicking a parent breadcrumb navigates up.
  - In `Versions` mode (`Ctrl+H`): lists copy-on-write versions of the selected object newest-first (`v<gen> · <date>` and `(current)` marker). `Up`/`Down` or click previews the historical version read-only and computes changed byte ranges (`storage.compare`) against the current state; `Enter` restores the selected older version (`storage.restore`); `Esc` returns to `Browse` mode.
- **Right column**:
  - Top pane (`ENTRIES`): shows current breadcrumb path, active filter text (`Ctrl+F`), and virtualized list of filtered entries (trees marked `[tree]`, objects showing byte size and generation) with a vertical scrollbar. Clicking a tree enters it (`storage.open_tree`); clicking an object inspects it; `Backspace` goes to the parent tree.
  - Bottom pane (`INSPECTOR`): header displays entry name, size, prefix BLAKE3 hash, and `Text` / `Hex` mode (`Ctrl+X` toggles); in `Versions` mode, shows the changed byte range summary from `storage.compare`. Body renders virtualized UTF-8 lines or 16-byte canonical hex rows (`offset  hex bytes  |ASCII|`) with a vertical scrollbar.
  - **Syntax-highlighted text preview**: when `index_preview_lines` indexes a UTF-8 preview on the worker thread, it detects `preview_language := text_model.syntax_language_of_path(object_name)` (`.c`, `.h`, `.lex`, `.recipe`, `.odin`) and precomputes `preview_line_carries[i]` for every line. During each frame, `draw_inspector` calls `text_model.syntax_highlight_row` only on the visible lines using their precomputed start carries and maps each `graphics.Code_Class` through `graphics.code_class_color(class, graphics.appearance)`, keeping frame work strictly O(visible cells) in both dark and light appearances.
  - **Content-addressed `MODAST1` AST preview**: when an object is a binary `MODAST1` AST codebase (`modus:ast_codebase`), the worker decodes it off-thread into static scratch memory, lists each definition with its 16-hex BLAKE3 digest, lowers the codebase to C via `ast_emit_c`, and indexes the preview with `.C` syntax highlighting. Corrupt or truncated `MODAST1` blobs fall back cleanly to 16-byte Hex mode.
- **Direct editor launch (`Ctrl+E`)**:
  - Selecting an object and pressing `Ctrl+E` (or clicking `Edit` in the action bar) dispatches `.Open_In_Editor` to the worker thread.
  - The worker resolves the canonical store name (`resolve_edit_store_name`, translating the `"private"` alias to `"files"` or `"files.principal.<N>"`), builds and validates the relative `/`-separated object path (`build_edit_object_path`), copies the path bytes into a 1-page read-only memory object lent through `GRANT_ROOT`, sends `Root_Command.Start_Edit`, closes its local memory handle, and surfaces `.Edit_Open_Refused` in the status band on refusal.
- **Create and remove entries**:
  - `Ctrl+N` prompts for a new empty object name; `Ctrl+T` prompts for a new subtree name (`storage.add`, validating names through `store.name_refusal`).
  - `Ctrl+D` asks for confirmation (`Delete "<name>"?` with `Enter` to delete and `Esc` to keep) before calling `storage.remove`.
- **Status band and action bar**:
  - Left status band shows active prompt, `docs/WRITING.md` problem sentence, or preview notice.
  - Right status band shows `<blocks>/<limit> blocks · <objects> objects · <versions> versions` (each fact stated once; adds `· read only` when store access ends).
  - Action bar (`interface.Action_Bar_State`): `Browse` mode offers `Edit` (`Ctrl+E`), `Versions` (`Ctrl+H`), `Filter` (`Ctrl+F`), `New object` (`Ctrl+N`), `New tree` (`Ctrl+T`), `Delete` (`Ctrl+D`), `Hex/Text` (`Ctrl+X`), `Refresh` (`Ctrl+R`); `Versions` mode offers `Older` (`Down`), `Newer` (`Up`), `Restore` (`Enter`), `Back` (`Esc`).

## Refused forms

- **Granting `Root_Ring` to `files`.** `Root_Ring` grants arbitrary process start, stop, connect, and principal control. `Open_Editor` restricts the root ring to `Start_Edit` alone.
- **Filtering, hashing, syntax carry scanning, `Start_Edit` RPCs, or storage reads on the interface thread.** Any O(N) scan or blocking RPC on the interface thread stalls rendering and input.
- **Unbounded object reads into RAM.** Objects up to `PREVIEW_MAX_BYTES` (64 KiB, inline capacity) load for preview and BLAKE3 hashing; larger objects stream in 32 KiB chunks for BLAKE3 hashing while showing the first 64 KiB with a clear truncation indicator, preventing budget exhaustion.
- **Raw error numbers or storage status codes in the UI.** Every refusal maps to a plain [`docs/WRITING.md`](../../../docs/WRITING.md) sentence.
- **Deleting without confirmation.** `Ctrl+D` always enters an explicit confirmation state naming the entry and requiring `Enter` to delete or `Esc` to keep.

## Subtle points and hazards

- **Open `storage.Place` lifetime.** Navigating into nested trees opens one `storage.Place` per path depth; navigating up or switching stores always closes popped places (`storage.close_tree`) so the connection never leaks places.
- **Upper-bound checks on `storage.read_range`.** Every chunked read loop guards `len(part) == 0 || u64(len(part)) > remaining` so a misbehaving or shortened object never overruns buffers or loops forever.
- **Binary vs UTF-8 inspection.** Preview bytes are checked with `is_preview_text_utf8` (allowing `\n`, `\r`, and `\t` while refusing NUL, other control bytes, and invalid UTF-8); valid printable UTF-8 opens in `Text` mode automatically and binary objects open in `Hex` mode, while `Ctrl+X` lets the principal toggle manually.
- **Private store alias resolution for `Start_Edit`.** Index `0` of the store sidebar displays `"private"` and uses `storage.ROOT`; when launching `edit`, `resolve_edit_store_name` maps index `0` to the process's real store name (`"files"` for principal 0, or `"files.principal.<N>"` for a named principal) so `Root_Command.Start_Edit` opens the exact store.

## State

Built: the `Open_Editor` least-privilege start grant and root-ring sender rule, `internal:files/files_core` with host tests, the built-in `files` desktop application (`src/modules/applications/files/`) in the boot image and Start Menu with syntax-highlighted text inspection and direct `Ctrl+E` editor launch. Left: machine test scenario driving `files` on a booted disk.

# The store and version explorer

The system gives each process a private copy-on-write store with nested B+ trees and automatic commit versions ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "9. A storage engine with one private store per process"). `store_explorer` (`src/outside/projects/store_explorer/`) is an outside graphical application that lets a principal browse accessible stores, navigate nested trees, inspect text or binary objects with their BLAKE3 content hash, filter entries, create or remove objects and subtrees, and preview, compare, or restore copy-on-write versions.

## Purpose

- Give a principal direct visual inspection of stores, trees, objects, storage block quotas, and commit history without typing console commands.
- Keep the interface thread non-blocking at all times: all storage RPCs, BLAKE3 hashing, hex formatting preparation, and substring entry filtering run on a dedicated worker thread.
- Demonstrate a production-grade outside Lex project built with `modustool module-build`, `modus:layout`, `modus:interface`, and `modus:storage`.

## Constraints

- **No ambient store access.** `store_explorer` reads only the store connection granted in its context. When its connection acts for the principal, it lists accessible stores through the storage service `stores` export and opens selected stores with `storage.open_store`; otherwise it explores its own private store cleanly without failing.
- **No blocking or O(N) work on the interface thread.** Storage reads, directory paging, entry filtering, BLAKE3 hashing, and version comparison run strictly on the worker thread and publish immutable double-buffered snapshots.
- **Bounded memory and clear error text.** Every buffer bound states its kind and reason. Every status and error sentence obeys [`docs/WRITING.md`](../../../docs/WRITING.md): plain problem, cause, and action, with no forbidden words, no raw status numbers, and each fact stated once.
- **Revocation safety.** If the storage connection ends (`!storage.connected`), the worker transitions cleanly to read-only state and reports the loss in the status band without discarding the visible view.

## The chosen form

### Two-thread architecture and budget

- `MODULE_BUDGET`: `working_memory_pages = 2048` (8 MiB working memory for two immutable snapshots, preview buffers, layout tree, and worker stack), `processes = 1`, `threads = 2` (interface thread and storage worker thread), `window_width = 1280`, `window_height = 960`.
- **Interface thread (`main.odin`)**: owns `display.Window`, `interface.Window_Memory`, `box_layout.Box_Tree`, dark and light `box_layout.Element_Tokens`, `interface.Action_Bar_State`, and pointer/keyboard handling. Renders only visible rows of the sidebar, entry list, and object inspector (UTF-8 text lines or 16-byte hex rows) from `snapshots[active_snapshot]`.
- **Worker thread (`worker.odin`)**: owns `storage.Client`, open subtree `storage.Place` stack, and `core.Worker_Scratch`. Communicates with the interface thread over bounded lock-protected ring queues (`QUEUE_CAPACITY = 16`), an explicit `has_snapshot` flag on `Worker_Result`, and three wake events (`req_event`, `res_event`, `res_space_event`, plus `snapshot_acked_event`) so snapshot handoff has zero data races and full result queues never deadlock.

### Layout and interaction

- Window sizes: default `1080 × 700`, least `720 × 440`, largest `1280 × 960`, verified with compile-time `#assert` minimum pane bounds (`SIDEBAR_MIN_WIDTH = 224`, `RIGHT_MIN_WIDTH = 400`, `LIST_MIN_HEIGHT = 160`, `INSPECTOR_MIN_HEIGHT = 160`, `STATUS_HEIGHT = 24`, `ACTION_BAR_HEIGHT = 24`). Resizable horizontal and vertical split dividers use `box_layout.split_pane`.
- **Left sidebar**:
  - In `Browse` mode: shows accessible stores (`STORES`) at top and current tree path breadcrumbs (`PATH`) below. Clicking a store opens it; clicking a parent breadcrumb navigates up.
  - In `Versions` mode (`Ctrl+H`): lists copy-on-write versions of the selected object newest-first (`v<gen> · <date>` and `(current)` marker). `Up`/`Down` or click previews the historical version read-only and computes changed byte ranges (`storage.compare`) against the current state; `Enter` restores the selected older version (`storage.restore`); `Esc` returns to `Browse` mode.
- **Right column**:
  - Top pane (`ENTRIES`): shows current breadcrumb path, active filter text (`Ctrl+F`), and virtualized list of filtered entries (trees marked `[tree]`, objects showing byte size and generation) with a vertical scrollbar. Clicking a tree enters it (`storage.open_tree`); clicking an object inspects it; `Backspace` goes to the parent tree.
  - Bottom pane (`INSPECTOR`): header displays entry name, size, full/prefix BLAKE3 hash, and `Text` / `Hex` mode (`Ctrl+X` toggles); in `Versions` mode, shows the changed byte range summary from `storage.compare`. Body renders virtualized UTF-8 lines or 16-byte canonical hex rows (`offset  hex bytes  |ASCII|`) with a vertical scrollbar.
- **Create and remove entries**:
  - `Ctrl+N` prompts for a new empty object name; `Ctrl+T` prompts for a new subtree name (`storage.add`, validating names through `store.name_refusal`).
  - `Ctrl+D` asks for confirmation (`Delete "<name>"?` with `Enter` to delete and `Esc` to keep) before calling `storage.remove`.
- **Status band and action bar**:
  - Left status band shows active prompt, `docs/WRITING.md` problem sentence, or preview notice.
  - Right status band shows `<blocks>/<limit> blocks · <objects> objects · <versions> versions` (each fact stated once; adds `· read only` when store access ends).
  - Action bar (`interface.Action_Bar_State`): `Browse` mode offers `Versions` (`Ctrl+H`), `Filter` (`Ctrl+F`), `New object` (`Ctrl+N`), `New tree` (`Ctrl+T`), `Delete` (`Ctrl+D`), `Hex/Text` (`Ctrl+X`), `Refresh` (`Ctrl+R`); `Versions` mode offers `Older` (`Down`), `Newer` (`Up`), `Restore` (`Enter`), `Back` (`Esc`).

## Refused forms

- **Filtering, hashing, or storage reads on the interface thread.** Any O(N) scan or storage RPC on the interface thread stalls rendering and input.
- **Unbounded object reads into RAM.** Objects up to `PREVIEW_MAX_BYTES` (64 KiB, inline capacity) load for preview and BLAKE3 hashing; larger objects stream in 32 KiB chunks for BLAKE3 hashing while showing the first 64 KiB with a clear truncation indicator, preventing budget exhaustion.
- **Raw error numbers or storage status codes in the UI.** Every refusal maps to a plain [`docs/WRITING.md`](../../../docs/WRITING.md) sentence.
- **Deleting without confirmation.** `Ctrl+D` always enters an explicit confirmation state naming the entry and requiring `Enter` to delete or `Esc` to keep.

## Subtle points and hazards

- **Open `storage.Place` lifetime.** Navigating into nested trees opens one `storage.Place` per path depth; navigating up or switching stores always closes popped places (`storage.close_tree`) so the connection never leaks places.
- **Upper-bound checks on `storage.read_range`.** Every chunked read loop guards `len(part) == 0 || u64(len(part)) > remaining` so a misbehaving or shortened object never overruns buffers or loops forever.
- **Binary vs UTF-8 inspection.** Preview bytes are checked with `text_encoding.text_valid` and for NUL/control bytes; valid printable UTF-8 opens in `Text` mode automatically and binary objects open in `Hex` mode, while `Ctrl+X` lets the principal toggle manually.

## State

Built: the `store_explorer` outside Lex project (`src/outside/projects/store_explorer/`), its pure freestanding `core/` package with host tests, and its validated freestanding modus module (`modustool module-build`). Left: machine test scenario driving `store_explorer` on a booted disk.

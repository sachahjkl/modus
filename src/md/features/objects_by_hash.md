# One way to read an object

Status: Decided.

## Purpose

A process reads an object that is not its own code: a font, a pointer theme, the link pages of the manual, or a list. Today the system has a second way to do this, named "resource", next to the storage service. It is an older form of storage that was never replaced.

This file records the one form: **an object is read through the storage service, from a tree that the process was granted, the same way whatever channel brought the object**. The boot image becomes one more source of objects that the storage service serves. It is not a second system.

## The fault in the current form

Today the word "resource" names three things with no common call:

- **A file of the boot image that the root service maps into one process.** The root service finds it by name, maps its pages read-only, and writes its address and its size into two numbered context values that the receiver knows by heart. Example: the compositor reads its pointer theme at context values 6 and 7 (`src/modules/system/compositor/pointer_picture.odin`, `src/modules/system/root/resources.odin`).
- **A file at a fixed address range in each process.** The font outlines and the script font set. The root service checks each one and maps it at a fixed range of the process, outside any call ([script_fonts.md](script_fonts.md), [glyphs_on_demand.md](glyphs_on_demand.md)).
- **A search of the whole image** by a process with the grant `Image` (`system.image_resource_find`).

Each new kind of data added a code path in the root service and a contract of context numbers in a module. That corrupts the model of a module in three ways:

- **A module does not call for its data.** It reads numbers that its starter wrote at places that only the two agree on. A module of another project cannot use the mechanism, because no table of the root service names it.
- **The source decides the code.** The same font read from the image and read from a disk takes two different paths. This contradicts [`docs/STORAGE.md`](../../../docs/STORAGE.md), "1. The model": "The boot image is a transport, not a concept."
- **The root service holds data policy.** It chooses, checks, and maps data for others. That is the work of the storage service.

## Constraints

- **Kernel interface bound.** Keep the 36 kernel operations unchanged ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface"). Do not add a sub-range memory-object operation to the kernel.
- **Content identity.** The identity of an object is its BLAKE3 hash ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system"). A name is for people and for the code that chooses.
- **No ambient access.** A hash alone is not a right ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close"). Hashes are public in plans, manuals, and logs.
- **One mechanism.** No second API exists next to storage. Each call that a module makes for data is a call of the storage contract.
- **Same code for each channel.** A module reads its object with the same call whether the bytes came in the boot image, from a local disk, from the object cache, or from a peer.
- **A process before the disk.** `unlock` and the compositor draw the passphrase screen before any disk is open or unlocked. They need fonts and a pointer theme at that time.
- **No hostile memory.** A receiver never maps a memory object that another client made ([window_resize.md](window_resize.md)).
- **No frame waits on storage.** No graphical window or compositor calls storage during a draw frame; live setting changes load objects on a worker thread ([background_work.md](background_work.md)).

## The chosen form

### 1. No resource concept and canonical image tree

The boot image carries objects as a transport. The build tool packs a canonical read-only **image tree** manifest (`modus:contract/image_tree`, resource `image_tree`) inside the boot image beside the data files. The manifest maps nested, strictly sorted UTF-8 entry names to boot-image resource entries (`image_entry_index`, `size`, and BLAKE3 `hash`).

The image tree excludes root-only boot and trust records: `system_description`, `system_description_signature`, `start_list`, `rescue_list`, `replacement_list`, `test_plan_values`, and `measure_run`. Both the manifest validator and the boot-image cross-check refuse any entry that names or points to one of these records. The terms "resource" and "resource of the boot image" leave the glossary and the guides.

### 2. Storage starts first and decouples image tree from disk

The root service starts `storage` through a dedicated `storage_start` path immediately after `machine_parts_page_create` and before `start_policy` ([start_policy.md](start_policy.md)). That start path gives `storage` no `Display` ring and calls no `text_settings_give`, which breaks the cycle between `storage`, `compositor`, and `unlock`.

The build tool includes `storage` in `start_list_floor_names` whenever `storage` is in the boot image. Minimal boot images that omit `storage` keep running without it.

Inside `storage`, readiness splits into two independent state tracks:

- **`image_tree_ready` (boolean):** `storage` validates the boot image manifest on entry and serves image-tree reads immediately, with zero disk dependency and no encryption key.
- **`disk_state` (closed enum):** `Absent`, `Opening`, `Opened`, `Silent`, or `Unusable`.

A missing data disk, a silent block device, an older disk format, or a damaged root never stops `storage` with `system.stop(.Failed)`. Instead, `storage` logs the fact, records the `disk_state`, refuses only disk-store calls (`Callee_Unavailable` with error kind `Device`), and keeps serving image-tree reads for the desktop, `unlock`, and rescue ([missing_hardware.md](missing_hardware.md)).

Role replacement ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "23. A role is a contract; its implementation is replaceable"): the boot-image `storage` serves early boot and the image tree before `plans` loads. A plan that replaces the `.Storage` role takes effect on the next boot, or on an explicit handoff once handoff exists.

### 3. Boot-image trust verification

The root service passes the boot trust `File_Check` mode (`modus:contract/boot_info`) to `storage`:

- When `File_Check == .Boot_Program`: the boot program and the root service already verified each entry against the signed system description. `storage` trusts the verified hashes in the boot image and does not hash entries again.
- When `File_Check == .Root_Service_At_Load` (for example in the browser machine, [browser_machine.md](browser_machine.md)): nothing hashed every file before boot. `storage` hashes each image-tree entry against its signed `Image_Entry.hash` once on first demand, caches the verified mark, and refuses any mismatch with `Data_Damaged` (`errors.Kind.Damaged`).

### 4. One call for a read-only object and strict path grammar

A process maps a read-only object through the storage client by exact `/` path in its granted trees. Object reads accept no search pattern.

Strict path grammar (`modus:contract/store`, `object_path_validate`):

- Split on `/`.
- Refuse an empty path, a leading `/`, a trailing `/`, or an empty segment (`//`).
- Refuse `.` and `..` segments.
- Refuse NUL bytes, control characters, and invalid UTF-8 bytes (`modus:contract/text_encoding`).
- Enforce format bounds: at most 255 bytes per segment (`ENTRY_NAME_CAPACITY`), at most 32 segments deep (`OBJECT_PATH_DEPTH_LIMIT`), and at most 4096 bytes total (`OBJECT_PATH_LIMIT`).

The answer returns a read-only memory object handle (`{.Read}` only), its exact byte size, its 32-byte BLAKE3 hash, and a `Call_Outcome`. The receiver checks the object format with the reader of that format. `storage` verifies identity, never format.

### 5. Exact resolution, hash pin mismatch, and ambiguity records

`storage` resolves the path across the trees granted on the caller's connection:

- **Zero matches:** return `Nothing_Has_That_Name` (`errors.Kind.Absent`). Naming a subtree instead of an object also returns `Nothing_Has_That_Name` with unit `Objects`.
- **More than one match:** refuse with `Argument_Refused` and never choose on the caller's behalf. Write the matching tree root names and object metadata into a caller-supplied bounded ambiguity table in the call region, and record the total match count in `Error_Record.found`. Never pack variable-length match names into the 56-byte `Error_Record`.
- **One match with an expected hash that differs:** if the caller supplied an expected hash to pin exact bytes and the entry at that path now holds another intact object, return `Another_Change_Came_First` with a distinct error kind (`Hash_Mismatch`, distinct from `Damaged`). Do not return `Data_Damaged`: the stored bytes match their own hash, and another change updated the name.

### 6. Shared read-only memory objects without new kernel operations

Never hand the boot-image memory handle (`image_memory`) directly to clients. That handle covers the entire boot image, including modules and root-only boot records.

Instead, keeping the 36 kernel operations unchanged:

1. On first demand for an image-tree object, `storage` creates a `Memory_Create` object sized to the object pages from a dedicated **machine-object budget** (accounted for in `start_lists.odin` floor checks), copies the verified bytes once, and zeroes trailing page padding.
2. `storage` strips `.Write` and `.Execute` from its own retained handle by calling `Handle_Give(0, h, {.Give, .Read})` followed by `Handle_Close(h)`.
3. For each reader, `storage` grants `{.Read}` only (no `.Write`, no `.Execute`, and no `.Give` on private objects). Every reader maps the same shared read-only memory object.

### 7. Memory ownership, isolation, and non-crashing eviction

`storage` splits cached read-only memory objects into two isolated pools:

- **Public system objects** (image tree and machine-wide public system trees): paid from the dedicated machine-object budget. Unprivileged callers cannot evict public system objects.
- **Per-principal private disk objects:** keyed by `(store_index, hash)` and never deduplicated across principals or unrelated stores ([store_encryption.md](store_encryption.md)). Each principal and connection is bounded by a per-principal quota and a machine ceiling from the plan of principal 0.

**Non-crashing eviction:** under cache pressure, `storage` evicts only entries whose `Handle_State.holdings == 1` (only `storage` holds a handle, and no client holds or maps the object). `storage` never calls `Handle_Revoke` to reclaim memory from an active mapping, because revoking an active mapping faults the reader.

**Security revocation:** on `Principal_Locked` and `Principal_Reclaim`, `storage` volatile-zeroes, revokes (`Handle_Revoke`), unmaps, and evicts every cached memory object belonging to that principal. Explicit share or grant revocation also revokes the granted handles.

### 8. Pinning lifecycle

Pinning has two distinct, explicit forms:

- **Ephemeral pin:** active automatically while any client holds or maps the shared memory object (`Handle_State.holdings > 1`). It ends when the last client closes its handle and unmaps.
- **Durable pin:** requested explicitly by a caller or a plan by hash. `storage` counts durable pins per principal, charges them against a per-principal pin quota, exposes the pin counts for inspection, and blocks `collect_garbage` and `erase_versions` from reclaiming a durably pinned object until it is unpinned or `Principal_Reclaim` removes the principal.

### 9. Connection scaling, tree grants, and context slots

Root-granted read-only trees (such as `pointer_themes` or `fonts`) are connection-level tree grants carried on a storage connection, never separate `SHARE_CAPACITY` (16) share rings.

Graphical processes avoid pinning long-lived storage connections solely for startup assets: a client connects to `storage`, maps its read-only objects, and disconnects while keeping its read-only memory mappings. Where concurrent long-lived connections grow, `storage` scales wait sets with client-paid connection pages.

Context-slot assignments (`GRANT_STORAGE_RING`, `GRANT_VALUE_STORAGE_FILE_SIZE`, and any read-only tree grant descriptors) must have zero slot collisions, checked statically by `start_grant_set_slot_taken_twice`.

### 10. Pointer theme live setting and compiled-in data

The plan selects the default pointer theme object by name or hash in the granted `pointer_themes` tree. When the principal changes the `pointer_theme` setting live, the compositor requests and maps the new read-only theme object off the draw frame via `interface.Background_Work` ([background_work.md](background_work.md)) and swaps the active pointer table once the worker completes.

Compiled-in data via Odin `#load` stays for bytes that change with the code and form part of the module's identity. Data that changes independently is an object of a tree.

## Frequent tasks

Plain expressions for frequent tasks ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task"):

- **Map a granted read-only object by name:**
  ```odin
  view, outcome := storage.map_object(&client, "pointer_themes/posy")
  ```
- **Map an object pinned to a known hash:**
  ```odin
  view, outcome := storage.map_object_pinned(&client, "fonts/noto_sans_hebrew", expected_hash)
  ```
- **Handle an ambiguous path explicitly:**
  ```odin
  matches: [8]image_tree.Ambiguity_Match
  view, match_count, outcome := storage.map_object_with_matches(&client, "default", matches[:])
  ```
- **Durably pin and inspect objects in the console:**
  ```
  storage.pin(place, "fonts/noto_sans_hebrew")
  storage.pins()
  storage.unpin(hash)
  ```

## What the form replaces

- The numbered context values of each resource (for example the pointer theme values).
- `resource_mapping` and `pointer_theme_choice` in the root service (`src/modules/system/root/resources.odin`).
- The fixed address ranges as a delivery mechanism for font outlines and the script font set. A process can still map an object at a chosen address; that address is its own choice, not a contract of the root service.
- The grant `Image` and `system.image_resources`, `system.image_resource_find` for data. The loader of the storage chain keeps direct reads of modules.
- The read of the script font set by the root service through `disk_processes`: the set is an object of a tree, read through storage like every other object.

## The refused forms

- **A new kernel sub-range memory-object operation.** Adding a 37th kernel operation breaks the counted kernel interface bound when a single copy on first demand into a shared `Memory_Create` object solves the isolation boundary in user space.
- **Handing `image_memory` directly to clients.** That exposes every module and root-only boot record in the boot image to any client that reads one font.
- **Cross-principal deduplication of cached private disk objects.** Sharing cached memory objects across principals creates a cross-principal side channel and leaks presence of plaintext data.
- **Evicting active mappings with `Handle_Revoke` under cache pressure.** Revoking an active mapping crashes the reader with a page fault.
- **Stopping `storage` on a missing or damaged disk.** That prevents `unlock`, the compositor, and rescue from reading fonts and pointer themes from the image tree.
- **A resource API next to storage.** That keeps two systems doing the same work.
- **Search patterns on object reads.** An exact `/` path removes hidden multi-match surprises; callers that list a tree use `list`.
- **Packing ambiguity match names into `Error_Record`.** `Error_Record` holds 56 bytes of integers only; variable-length match records belong in a bounded caller-supplied call-region table.
- **Returning `Data_Damaged` for a name-vs-hash mismatch.** The bytes at the name are intact; `Another_Change_Came_First` distinguishes a concurrent update from disk corruption.
- **A choice among several matches.** An order of trees or a newest-wins rule reads data that the reader did not expect.
- **A hash as a capability.** Hashes are public. A process that names a hash gets nothing without a grant of a tree that holds it.
- **One delivery path per source.** The source is a fact of `storage`, never of the reader.
- **A copy of the object in each process.** One shared read-only memory object serves all readers of a public object.
- **Data served by the root service before storage.** Starting `storage` first with `image_tree_ready` removes the second server.

## Subtle points and hazards

- **Start order and budget floor.** `storage` starts before `start_policy`, with no `Display` ring and no `text_settings_give`. Its machine-object budget is part of the start-list floor whenever `storage` is in the boot image.
- **No encryption of the image tree.** The image tree holds public system objects only. A principal's data is never placed in it.
- **Shared public objects across principals.** Mapping one read-only memory object for a public image-tree asset tells neither principal anything that the boot image does not already contain. Private objects stay isolated per `(store_index, hash)`.
- **Browser-machine verification.** When `File_Check == .Root_Service_At_Load`, `storage` hashes each image-tree entry on first demand before copying it into its shared read-only memory object.
- **Trailing page bytes.** When `storage` copies an object whose size is not a multiple of 4096 bytes into a `Memory_Create` object, kernel pages start zeroed and trailing bytes stay zero.

## Decisions

- **Keep the 36 kernel operations unchanged:** `storage` copies each image-tree object once on first demand into a shared read-only `Memory_Create` object paid from a dedicated machine-object budget, strips `.Write` and `.Execute` from its retained handle, and gives readers `{.Read}` only.
- **The storage service starts first,** before `start_policy`, the compositor, and `unlock`, and serves the image tree with no disk dependency.
- **Two isolated cache pools with non-crashing eviction:** public system objects use a dedicated machine-object budget and cannot be evicted by unprivileged callers; private disk objects are keyed by `(store_index, hash)` under per-principal quotas and evict only when `Handle_State.holdings == 1`.
- **Pinning is explicit:** ephemeral pins track active mappings (`holdings > 1`), while durable pins are requested by hash, counted per principal, and block garbage collection and version erasure until unpinned or reclaimed.
- **A name is a strict `/` path in the granted trees of the reader:** walked segment by segment from granted tree roots, with no global path and no search pattern.

## State

In progress.

Built:

- Strict object path parser and validator in `modus:contract/store` (`object_path.odin`, with host tests).
- Canonical read-only image-tree binary format, encoder, validator, subtree grant lookup, ambiguity collector, and hash-pin check in `modus:contract/image_tree` (with host tests).
- Decoupled `Disk_State` (`Absent`, `Opening`, `Opened`, `Silent`, `Unusable`) and `Service_Readiness` state-transition foundation in `internal:storage/service_state` (with host tests), wired into `storage`.

Left:

- Packing the `image_tree` manifest in `modustool` and including `storage` in `start_list_floor_names`.
- Dedicated `storage_start` path in `root`, connection-level read-only tree grants, and removing `resources.odin`, fixed-range delivery, and `Image` data lookups (`docs/ARCHITECTURE.md`, "U2b. Resources of the boot image"; [script_fonts.md](script_fonts.md); [glyphs_on_demand.md](glyphs_on_demand.md)).
- `storage` read-only object mapping export, machine-object budget pool, per-principal private pool, durable pin exports, and `Principal_Locked`/`Principal_Reclaim` cache scrubbing.
- Updating `compositor`, `unlock`, `manual`, and graphical clients to read objects through `storage`.

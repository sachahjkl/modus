# Odin core target on modus

An outside module written in Odin can compile against `base:runtime` and `core:` on `modus` (`-target:modus_amd64`, `ODIN_OS == .Modus`). This enables ported programs such as `gui_toolkit` and `wren` without weakening the freestanding rules of the system itself. This file records the architecture of that target, the compiler fork contract, and the build tool boundary.

The outside-module build path is in [third_party_module.md](third_party_module.md). The SDK layout is in [sdk.md](sdk.md). The long-term plan for rich modules is in [../features/desktop_to_browser.md](../features/desktop_to_browser.md), "The toolkit of rich modules".

## The boundary

- **System code stays freestanding.** The kernel, the boot program, the public library, the internal parts, and every module under `src/` compile with `-target:freestanding_amd64_sysv`, `-no-entry-point`, and `-default-to-nil-allocator`. They never import `core:` (except the audited cryptography copy). `library_imports_check` enforces this rule before every build ([repository_layout.md](repository_layout.md)).
- **Outside modules choose their target.** A developer selects the target in `module.txt` with `target: freestanding` (the default when omitted) or `target: modus`.
- **One module format and one build path.** Both targets pass through LLVM IR generation, `llc` with `--frame-pointer=all`, `ld.lld`, `convert`, and `module.validate`. No second module format or dynamic loader exists ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "10. One code module").
- **No new kernel operation.** The target builds on the existing kernel operations in `src/library/modus/contract/operation/operation.odin` ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface").
- **No ambient authority.** The target exposes only what the process receives in its start `Context`: its log handle, its budget handle, its private store handle, and any granted service handle ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close").

## The compiler fork (`sachahjkl/Odin`)

The Odin compiler fork adds `TargetOs_Modus` (`-target:modus_amd64`, `ODIN_OS == .Modus`) with these rules:

- **No host C runtime and no static constructors.** The build passes `-no-crt`. The compiler emits no `.init_array`, `.fini_array`, `.preinit_array`, `PT_INTERP`, or ELF TLS (`PT_TLS` / `SHF_TLS` / `__tls_get_addr`). `convert` refuses any module that carries them.
- **System assembly memory routines stay authoritative.** For `ODIN_OS == .Modus`, `base:runtime/procs.odin` excludes its byte-loop `memcpy`, `memmove`, and `memset` symbols. `src/runtime/memory.asm` supplies those symbols in the link, matching freestanding builds with zero symbol collision under `-no-crt`.
- **Fixed per-thread tables replace `@(thread_local)`.** Every `@(thread_local)` variable in `base:runtime` and `core:os` becomes a fixed `[256]T` table indexed by `thread_record().number`. The bound 256 is a format property matching `op.THREAD_CAPACITY` in `src/library/modus/contract/operation/operation.odin` ([../data/table_sizes.md](../data/table_sizes.md)).
- **Default temporary allocator.** Each thread slot holds a 64 KiB temporary allocator (a plan value sized for common string formatting and path assembly without early spill). Allocations past the inline block grow into page-backed chunks under the process budget.
- **Default heap allocator (`base:runtime/heap_allocator_modus.odin`).** A slab and free-list allocator satisfies `context.allocator` from pages created with `Memory_Create` and mapped with `Memory_Map` under the process budget.
- **Runtime entry (`base:runtime/entry_modus.odin`).** For non-library modules, `base:runtime` exports `@(export, link_name = "entry")`. That procedure captures the start `Context` pointer, initializes the runtime state and default allocators, runs `main()`, and stops the process with `Process_Stop` (`.Done` on normal return).
- **OS hooks (`base:runtime/os_specific_modus.odin`).** Runtime panic, assertion failure, and abort write diagnostic text through `Operation.Log` on the process log handle and terminate via `Process_Stop` (`.Failed`) or trap.

## The vertical slice of `core:` on `modus`

The initial target implements six `core:` packages over `modus` primitives:

| Package | Implementation on `modus` |
|---|---|
| `core:sys/modus` | Thin kernel entry (`syscall` and per-thread kernel ring), start `Context` capture, and handle bridge for log, budget, private store, and display handles |
| `core:mem/virtual` | 512-page (2 MiB) chunked `Memory_Create` and `Memory_Map` allocation paired with a reservation registry that tracks reserved, committed, and released page spans under the process budget |
| `core:time` | Zero-syscall monotonic reads from `op.TIME_ADDRESS` (`op.Time_Record`) and wall-clock date reads from the mapped `Date_Page` |
| `core:sync` | Futex waiting through `Operation.Word_Wait` and `Operation.Word_Wake`, using `tid = thread_record().number + 1` so thread 0 has a non-zero owner identifier |
| `core:thread` | Thread lifecycle over `Operation.Thread_Create` and `Operation.Thread_Stop`, giving each thread its own stack and its slot in the `[256]T` runtime tables |
| `core:os` | Zero ambient paths, empty arguments, and empty environment; `os.stdout` and `os.stderr` write lines through `Operation.Log`; file calls reach the process private store through a mutex-serialized storage client |

`core:net` is deferred out of the first vertical slice. Outside modules can call `modus:tcp` and `modus:quic` directly until a later layer binds `core:net` onto the network service grant.

## Integration in `modustool`

The build tool keeps one unified path for repository checkouts (`modustool module-build`) and verified SDK builds (`sdk_build_outside_module`):

- **Closed target enum.** `foundation.Module_Target` is a closed enum (`Freestanding`, `Modus`) parsed at one border from `target:` in `module.txt`. Unknown, empty, or duplicate `target:` lines stop the build.
- **Single flag builder.** `odin_module_compile_command` in `tools/modustool/build/modules.odin` builds compiler flags for both checkout builds and SDK builds. `.Freestanding` passes `-target:freestanding_amd64_sysv`, `-no-entry-point`, and `-default-to-nil-allocator`. `.Modus` passes `-target:modus_amd64` and `-no-crt`, omits `-default-to-nil-allocator`, and passes `-no-entry-point` only when `library: yes`.
- **Runtime `entry` export synthesis.** A non-library `target: modus` module defines `main :: proc()` while `base:runtime/entry_modus.odin` exports `entry`. `describe_package_for_target` verifies that `main` exists, refuses a duplicate manual `@(export) entry`, and appends a synthesized `entry` export description. The linker version script, `convert`, and the `Floor` table then preserve `entry` with no special-case ELF path.
- **Compiler-owned source filtering.** `compiler_source_library_of_path` classifies `base/` and `core/` files under `odin_root()` (or `/share/base/` and `/share/core/` when `odin root` is absent). `outside_module_source_has_a_place` accepts those compiler trees and refuses `vendor/` and paths outside the module folder and public library. `source_of_the_repository`, `facts_of_sources`, and `sdk_build_outside_odin` skip compiler-owned files so AST metadata extraction inspects only module and `modus:` sources.

## The forms that were refused

- **A POSIX shim layer.** A compatibility layer with file descriptors, `errno`, signals, and global paths recreates the ambient authority and text interfaces that `modus` removes ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "3. No \"everything is a file\"" and "16. Removed concepts").
- **Ambient filesystem paths, `argv`, or environment variables.** Inherited text settings and global paths break explicit capability passing. Any future opt-in wrapper for ported programs stays separate and undecided (`ROADMAP.md`, "Maybe").
- **ELF TLS segments (`PT_TLS` / `SHF_TLS`).** Supporting dynamic TLS relocations adds loader complexity and breaks the fixed module contract. Fixed `[256]T` tables match `op.THREAD_CAPACITY` with constant-time indexing and zero dynamic relocations.
- **Allowing `src/` kernel or system modules to import `core:`.** System services and the kernel must remain freestanding, deterministic, and free of hidden heap allocation.

## Subtle points and hazards

- **Thread 0 identity.** `thread_record().number` is `0` for the initial thread. `core:sync` locks treat `0` as unowned, so thread identifiers must add `1` (`tid = number + 1`).
- **No `-no-thread-local` on `.Modus`.** Passing `-no-thread-local` silently lowers a stray `@(thread_local)` into a shared racy global. Omitting that flag on `.Modus` ensures `convert` catches any unported `@(thread_local)` as a refused `PT_TLS` or `SHF_TLS` error.
- **No `@(init)` constructors.** `convert` refuses non-empty `.init_array`. All runtime and `core:os` initialization must execute explicitly inside `entry_modus.odin` before calling `main()`.
- **Library modules under `target: modus`.** A library module has no `entry` and must have no `Read_Only_After_Load` segment. `target: modus` with `library: yes` passes `-no-entry-point` and performs no `entry` synthesis.
- **Day-one test.** Two outside modules, `core_probe` and `core_probe_panic`, declare `target: modus`, build through both `modustool module-build` and `sdk_build_outside_module`, load onto a module disk, and run through `start_from_disk` on QEMU. `core_probe` exercises heap allocation, temporary allocation, `core:mem/virtual`, `core:time`, `core:sync`, `core:thread`, `core:os` log output, and private store I/O before exiting cleanly (`.Done`). `core_probe_panic` triggers a runtime panic and verifies log reporting and clean `.Failed` stop behavior.

## State

Built: this design, `foundation.Module_Target` and `target:` parsing in `module.txt`, unified Odin compiler flag construction in `tools/modustool/build/modules.odin` and `tools/modustool/build/sdk.odin`, runtime `entry` export synthesis in `tools/modustool/build/describe.odin`, compiler-library filtering in `tools/modustool/build/outside_module.odin`, `tools/modustool/build/facts.odin`, and `tools/modustool/build/import_declarations.odin`, and host unit tests.

Left: `TargetOs_Modus` (`modus_amd64`), `base:runtime` modus support, and the `core:` vertical slice in `sachahjkl/Odin`; pinning the updated compiler fork in `flake.nix`; and building and running `core_probe` and `core_probe_panic` via `start_from_disk` on QEMU.

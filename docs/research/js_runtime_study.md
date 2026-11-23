# JavaScript and Bun runtime feasibility study for modus

This study evaluates how `modus` can run JavaScript and Bun workloads without violating [`docs/PROPERTIES.md`](../PROPERTIES.md) or creating architectural dead ends.

## Executive recommendations

1. **Refuse a native Bun port.** Porting Bun to native `modus` requires reintroducing POSIX file systems, signals, `fork`, sockets, and a C++/Zig JIT runtime, directly violating Objective Rule 3 and Properties 3, 8, 16, and 25.
2. **Use QuickJS-NG as an outside C11 module (`src/outside/c_programs/`) for embedded application and web-browser JavaScript only.** QuickJS-NG is ~60K lines of MIT-licensed C11 with no JIT, supports caller-supplied memory arenas (`JS_NewRuntime2`), and runs inside a zero-grant isolated call host. Never use JavaScript as a system or agent scripting language; `lex` remains the single scripting language of `modus` (Properties 19 and 22).
3. **Run Bun, Node, and npm developer workloads inside the `linux` guest (`src/modules/system/linux/`).** The guest boundary enforces all 25 properties while giving Bun full Linux compatibility. Five concrete gaps in `linux` block Bun today and define a clean staged engineering plan.

---

## Constraints from the system architecture

Every JavaScript runtime option is tested against the fixed rules of `modus`:

- **Objective Rule 3 (No foreign interface in the system).** `modus` implements no POSIX, Win32, or Linux system call interface. Foreign systems run whole inside a guest (`src/md/features/foreign_systems.md`).
- **Property 2 (Sandbox by default) and Property 15 (Isolation inside a process).** Untrusted scripts and large C/C++ language runtimes run in zero-grant child processes or WebAssembly sandboxes, never with ambient handles.
- **Property 3 (No "everything is a file"), Property 8 (No global mutable file system), and Property 16 (Removed concepts).** No global `/`, `PATH`, signals, pipes, `fork`, or BSD sockets exist in native `modus`.
- **Property 11 (Reproducible system).** Modules are deterministic BLAKE3-addressed files. Process-confined runtime code generation is permitted only if no page is simultaneously writable and executable (W^X). Cross-mapping W^X enforcement in the kernel is still planned work (`docs/PROPERTIES.md`, "11. Reproducible system").
- **Property 14 (Memory is supplied by the caller).** Native modules allocate inside caller-supplied or process-budgeted arenas; no hidden global heap exists.
- **Property 19 (A command is a function) and Property 22 (General mechanisms).** System automation, console pipelines, and agent loops use typed `lex` calls (`src/md/features/agent_code_mode.md`), never JavaScript.
- **Property 25 (Take the gold, leave the debt).** Reject large multi-language dependency graphs that pull legacy operating system assumptions into `modus`.

---

## Option comparison

| Criterion | Option A: Native Bun port | Option B: QuickJS-NG outside module | Option C: Bun in `linux` guest |
|---|---|---|---|
| **Codebase and languages** | >1M LOC (Zig + C++ WebKit JSC + BoringSSL + libdeflate + uSockets) | ~60K LOC pure C11 (MIT, zero external deps) | Unmodified Linux x86-64 Bun binary in guest store |
| **POSIX / Linux dependency** | Deep (`io_uring`/`epoll`, signals, `fork`/`exec`, `/proc`, global FS, symlinks) | None when compiled with `CONFIG_BIGNUM` off and OS module omitted | Confined strictly inside the Linux guest |
| **W^X and JIT** | Multi-tier JSC JIT (LLInt, Baseline, DFG, FTL) relies heavily on RWX/W^X toggling | Interpreter-only; zero runtime code generation | Guest nested page tables enforce page-by-page W^X; `JSC_useJIT=0` avoids fault storms initially |
| **Memory model (Property 14)** | Global mimalloc/bmalloc heaps + virtual memory reservations | Custom allocator (`JS_NewRuntime2`) over `memsys5`/arena inside call-host budget | Single process-budgeted guest RAM object (`linux` reserves memory from budget) |
| **npm / Node ecosystem** | Partial even after years of POSIX emulation | None (ES2023 language core only; host provides explicit typed bindings) | Full Linux npm, Bun, Node, TypeScript, and native addon compatibility |
| **Property compliance** | **Contradicts Rule 3, P3, P8, P16, P25** | **Compliant** (when strictly scoped to app/browser JS, isolated in call host) | **Compliant** (all 25 properties hold at the guest boundary) |
| **Verdict** | **Refuse** | **Adopt for browser/app JS** | **Adopt for Bun/npm workloads** |

---

## Option A: Native Bun port — Refused

A native port of Bun to `modus` is a design dead end.

1. **Foreign OS surface.** Bun is built directly on Linux `io_uring`, `epoll`, `signalfd`, POSIX threads, `fork`/`exec`, `mmap` with `MAP_FIXED`, file descriptors, and a mutable hierarchical file system (`node_modules/`). Providing those interfaces natively requires building a POSIX compatibility layer in `modus`, which Objective Rule 3 and Properties 3, 8, and 16 explicitly forbid.
2. **Toolchain and C++ runtime debt.** Bun combines a large Zig codebase with WebKit's C++ JavaScriptCore engine, C++ standard library, exception/unwind tables, and BoringSSL. The `modus` freestanding module build supports Odin and freestanding C11 (`thin_libc`), with no C++ runtime, no unwinder, and deterministic builds verified by double-build byte equality (Property 11).
3. **JIT security surface.** JavaScriptCore's 4-tier JIT assumes rapid code patching and large executable code cages. Exposing that surface in a native process before cross-mapping W^X enforcement lands expands the trusted attack surface without solving npm compatibility.

**Conclusion:** Do not port Bun or JavaScriptCore to native `modus`.

---

## Option B: Native QuickJS-NG outside module — Recommended for browser and app JS

When a native `modus` application or lightweight web browser (`ROADMAP.md`, "A light web browser, one process for each origin") needs embedded JavaScript execution without booting a Linux guest, QuickJS-NG fits the existing `src/outside/c_programs/` architecture alongside `sqlite`, `lua`, and `zstd`.

### Why QuickJS-NG fits `modus`

- **Small, auditable C11.** QuickJS-NG (~60K LOC, MIT license) implements ES2023+ in standard C11 with no C++, no assembly required, and no third-party libraries. It compiles with the same freestanding clang flags and `thin_libc` adapter already used for `sqlite` (3.54.1) and `lua` (5.4.7).
- **Zero JIT / strict W^X.** QuickJS-NG is a bytecode interpreter. Every code page stays `.Read_Only_After_Load` (`library: no`), matching the isolation model of `sqlite.module`.
- **Strict memory and CPU bounding (Properties 2, 14, 15).** `JS_NewRuntime2` accepts a custom `JSMallocFunctions` allocator backed by a fixed `.bss` arena paid by a zero-grant child call host's budget. `JS_SetMemoryLimit`, `JS_SetMaxStackSize`, and `JS_SetInterruptHandler` bound RAM, stack depth, and execution steps deterministically without OS signals.
- **Typed border (Property 19).** Scripts receive only explicit typed values and return typed values or structured `Error_Record`s over `call_isolated`. No ambient file system, network, or clock exists inside the call host.

### Strict scope boundary

- QuickJS-NG lives strictly in `src/outside/c_programs/` as an outside module, never in the boot image or base libraries.
- QuickJS-NG must never become a shell, configuration, plan, or agent scripting language. `lex` owns all system declarations, console commands, and agent loops (`src/md/features/agent_code_mode.md`).
- If a workload needs WebAssembly rather than JavaScript, follow Property 15's WebAssembly direction (`src/md/features/desktop_to_browser.md`).

---

## Option C: Bun inside the `linux` guest — Recommended for Bun and npm workloads

Running unmodified Linux x86-64 Bun inside `src/modules/system/linux/` aligns with `src/md/features/foreign_systems.md`: POSIX, `node_modules/`, package managers, and glibc/musl stay confined inside one guest instance, while `modus` enforces grants, quotas, and isolation at the guest boundary.

### Current state of `src/modules/system/linux/`

`linux` already boots a real 64-bit Nixpkgs Linux kernel (`bzImage`) from its private store (`kernel` and `initial_archive`) using `Guest_Run` (AMD SVM), runs a busybox shell on `hvc0` (`virtio_console`), logs kernel output on COM1, sleeps cleanly when idle, handles terminal resizes (`SIGWINCH`), and switches guest memory page-by-page between `Write` and `Execute` (`src/md/features/linux_shell.md`).

### Exact five blockers preventing Bun in `linux` today

1. **No guest network device (`virtio-net`).** `linux` and `modus:contract/guest_os` expose `virtio_console` and `virtio_blk` only (`src/md/features/foreign_systems.md`, "The chosen form"). `bun install` and HTTP servers require a `virtio-net` MMIO device translated inside `linux` to the process's explicit `modus` TCP/UDP network grants (never a raw frame grant).
2. **No writable persistent `virtio-blk` disk in `linux`.** Only `guest_builder` wires read-only and writable `virtio-blk` disks (`MODGBD1`) today; `linux` runs exclusively from its in-RAM `initial_archive`. Bun needs a persistent writable block image backed by an object in `linux`'s private store (so `storage` commits changed 4 KiB blocks copy-on-write).
3. **Single guest processor (no local APIC / SMP).** `linux_machine` exposes legacy 8259 PICs and sets `nolapic`, capping the guest at 1 vCPU even though the kernel supports 32 guest processors (`src/md/features/guest.md`, `src/md/features/linux_shell.md`). Bun's multi-threaded bundler, HTTP server, and GC worker pool benefit directly from a local APIC and SMP threads paid by `linux`'s thread budget.
4. **Store quota too small for Bun + rootfs.** `start_grant_sets.odin` currently grants `linux` `store_blocks = 8192` (32 MiB) and a default `MODULE_BUDGET` floor of 128 MiB guest RAM (`src/modules/system/linux/main.odin`). A statically linked Linux Bun binary alone is ~90–100 MiB, plus a rootfs and `node_modules/`. Raising `linux`'s store quota and guest RAM ceiling must flow through the principal's plan (`store_blocks` and memory policy, not hardcoded constants).
5. **Guest W^X page-switching overhead on JIT code.** The kernel enforces page-by-page `Write` xor `Execute` in nested page tables (`src/md/features/guest.md`, "The switch of a page"), and instructions writing their own page trigger `Writes_Own_Page` exits (`src/md/features/linux_shell.md`). Booting Linux alone switches ~10,000 pages; JSC's JIT continuously toggles and patches code pages, risking severe fault overhead or unsupported self-modifying instructions.
   - **Immediate mitigation:** Run Bun inside the guest with `JSC_useJIT=0` (JavaScriptCore's LLInt interpreter mode), which executes Bun's Zig native APIs at full native speed while eliminating JIT W^X churn.
   - **Longer-term optimization:** Measure `JSC_useJIT=0` vs JIT once writable `virtio-blk` and `virtio-net` land; only add batched W^X protection transitions if measured workloads justify it, without ever allowing RWX nested page table entries (Property 11).

---

## Staged implementation roadmap (pending owner approval)

| Stage | Deliverable | Unlocks |
|---|---|---|
| **Stage 1 (Guest storage & quota)** | Wire writable store-backed `virtio-blk` into `src/modules/system/linux/` and raise `linux` store/RAM limits via plan values. | Persistent rootfs + offline `bun run` / `bun test` with `JSC_useJIT=0`. |
| **Stage 2 (Guest network)** | Add `virtio-net` MMIO in `guest_os` translated to `linux`'s explicit `modus:tcp`/`udp` network grants (scoped by destination grants). | `bun install`, `bunx`, and sandboxed dev servers inside the guest. |
| **Stage 3 (Guest SMP)** | Implement local APIC + multi-vCPU startup in `guest_os` / `linux` (1 thread per vCPU from budget). | Full multi-core Bun bundling, test parallelism, and Linux developer workloads. |
| **Stage 4 (Optional native embedded JS)** | Package QuickJS-NG (`src/outside/c_programs/recipes/quickjs.recipe`) as a `library: no`, zero-grant call-host module with typed `eval` exports. | Lightweight sandboxed JS for native `modus` web browser or app plugins without booting Linux. |

## Decision points for the owner

1. Confirm refusal of a native Bun port (Option A) and approval of the dual path: **Linux guest for Bun/npm** (Option C) plus **QuickJS-NG outside module only when embedded browser/app JS is needed** (Option B).
2. Confirm prioritizing Stages 1 and 2 (`linux` writable `virtio-blk` + grant-translated `virtio-net`) before Stage 4 (QuickJS-NG), because writable disks and network in `linux` also unlock Wine, compilers, and all other Linux developer tools.

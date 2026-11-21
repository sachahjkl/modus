# Credits and licences

This document is the single checked source of truth for every work of others that `modus` ships, reimplements, or draws ideas from. It records who produced the code, algorithms, and ideas, under which licence, and how to fund or repay upstream authors.

`modustool check` verifies all three tables (`TOOLS.md`, "The reuse list"): every reused work in the repository must have a row with its recorded SPDX licence and licence file, every path in Reused code and Reimplemented algorithms must exist in the repository, no required cell may be empty, and no duplicate entry is allowed. Where no funding link is known, the Funding column holds `—`.

The tools of the host that build and test the system (the compiler, LLVM, QEMU, OVMF, swtpm, OpenSSL) are listed on the site page "Credits and licences" (`SITE.md`, "The pages").

## Reused code

Each work of others that the system ships in a module or in the boot image, or that the repository holds as a copy. The licence is the SPDX identifier of what was read at the source of the work; `NONE` is a work with no licence.

| Work | Place | Upstream | Authors | License | License file | Funding |
|---|---|---|---|---|---|---|
| Paper Mono, as the subset "Paper Mono ASCII" | `resources/fonts/paper_mono.ttf` | Paper Mono | Paper Mono authors | OFL-1.1 | `resources/fonts/OFL.txt` | — |
| Paper Mono SemiBold, as the subset "Paper Mono ASCII SemiBold" | `resources/fonts/paper_mono_semibold.ttf` | Paper Mono | Paper Mono authors | OFL-1.1 | `resources/fonts/OFL.txt` | — |
| DejaVu Sans Mono, as the subset "DejaVu Sans Mono ASCII" | `resources/fonts/dejavu_sans_mono.ttf` | DejaVu Fonts | DejaVu Fonts contributors, Bitstream Inc. | Bitstream-Vera | `resources/fonts/BITSTREAM_VERA_LICENSE.txt` | — |
| JetBrains Mono, as the subset "JetBrains Mono ASCII" | `resources/fonts/jetbrains_mono.ttf` | JetBrains Mono | JetBrains s.r.o. | OFL-1.1 | `resources/fonts/OFL.txt` | — |
| IBM Plex Mono, as the subset "IBM Plex Mono ASCII" | `resources/fonts/ibm_mono.ttf` | IBM Plex | IBM Corp. | OFL-1.1 | `resources/fonts/OFL.txt` | — |
| Fira Mono, as the subset "Fira Mono ASCII" | `resources/fonts/fira_mono.ttf` | Fira | Carrois Corporate & Edenspiekermann AG, Mozilla | OFL-1.1 | `resources/fonts/OFL.txt` | — |
| Commit Mono, as the subset "CommitMono ASCII" | `resources/fonts/commit_mono.ttf` | Commit Mono | Eigil Nikolajsen | OFL-1.1 | `resources/fonts/OFL.txt` | https://github.com/sponsors/eigilnikolajsen |
| Iosevka, as the subset "Iosevka ASCII" | `resources/fonts/iosevka.ttf` | Iosevka | Belleve Invis | OFL-1.1 | `resources/fonts/OFL.txt` | https://github.com/sponsors/be5invis |
| B612, as the subset "B612 ASCII" | `resources/fonts/b612.ttf` | B612 | Airbus, Intactile DESIGN, PolarSys | OFL-1.1 | `resources/fonts/OFL.txt` | — |
| B612 Bold, as the subset "B612 ASCII Bold" | `resources/fonts/b612_bold.ttf` | B612 | Airbus, Intactile DESIGN, PolarSys | OFL-1.1 | `resources/fonts/OFL.txt` | — |
| Spleen 8x16, the fallback font | `src/library/modus/graphics/font.odin` | Spleen | Frederic Cambus | BSD-2-Clause | `src/library/modus/graphics/FONT_LICENSE` | https://github.com/sponsors/fcambus |
| Spleen 12x24, 16x32 and 32x64, the text of the boot display at 12, 16 and 32 eighths | `src/library/modus/bootscreen/spleen_sizes.odin` | Spleen | Frederic Cambus | BSD-2-Clause | `src/library/modus/graphics/FONT_LICENSE` | https://github.com/sponsors/fcambus |
| The pointer theme "Posy's Cursor", in the boot image of a development build that has it, never in a release image | `resources/pointers/posy.manifest` | Posy's Cursor | Michiel de Boer (Posy) | CC-BY-NC-4.0 | `resources/pointers/posy.manifest` | — |
| The cryptography of Odin's `core:crypto`, the files of `origin.manifest` | `src/library/modus/cryptography` | Odin core library | Ginger Bill, Yawning Angel, Odin contributors | Zlib | `src/library/modus/cryptography/LICENSE.odin.txt` | https://github.com/sponsors/gingerBill |
| The field arithmetic of fiat-crypto, in Odin's port | `src/library/modus/cryptography/_fiat` | fiat-crypto | MIT PLV (Andres Erbsen, Jade Philipoom, Jason Gross, Robert Sloan, Adam Chlipala) | BSD-1-Clause | `src/library/modus/cryptography/LICENSE.fiat-crypto.txt` | — |
| The runtime of the Odin compiler, in each module and in the boot program | `base:runtime` | Odin | Ginger Bill and Odin contributors | Zlib | `src/library/modus/cryptography/LICENSE.odin.txt` | https://github.com/sponsors/gingerBill |
| The package `reflect` of the core library of Odin, in the module `cryptography` | `core:reflect` | Odin | Ginger Bill and Odin contributors | Zlib | `src/library/modus/cryptography/LICENSE.odin.txt` | https://github.com/sponsors/gingerBill |
| The C compiler `chibicc`, at a pinned commit with four patches, in the module `c_compiler` | `src/outside/chibicc` | chibicc | Rui Ueyama | MIT | `src/outside/chibicc/LICENSE` | https://github.com/sponsors/rui314 |
| The portrait of Jonathan Blow: a credited frame of a video | `resources/hall_of_fame/jonathan_blow.png` | Hall of fame portrait | Credited video frame (see `CREDITS.md`) | NONE | `resources/hall_of_fame/CREDITS.md` | — |
| The portrait of Andreas Kling | `resources/hall_of_fame/andreas_kling.png` | Hall of fame portrait | See `resources/hall_of_fame/CREDITS.md` | CC-BY-3.0 | `resources/hall_of_fame/CREDITS.md` | — |
| The portrait of Michael Paulson | `resources/hall_of_fame/theprimeagen.png` | Hall of fame portrait | See `resources/hall_of_fame/CREDITS.md` | CC-BY-4.0 | `resources/hall_of_fame/CREDITS.md` | — |
| The portrait of Linus Torvalds | `resources/hall_of_fame/linus_torvalds.png` | Hall of fame portrait | See `resources/hall_of_fame/CREDITS.md` | CC-BY-SA-4.0 | `resources/hall_of_fame/CREDITS.md` | — |
| The portrait of John Carmack | `resources/hall_of_fame/john_carmack.png` | Hall of fame portrait | See `resources/hall_of_fame/CREDITS.md` | CC0-1.0 | `resources/hall_of_fame/CREDITS.md` | — |

## Reimplemented algorithms

Algorithms and specifications implemented from scratch in `src/` without copying upstream code. Every path in Place must exist in the repository.

| Algorithm | Authors | Upstream | Reference license | Place | Funding |
|---|---|---|---|---|---|
| EEVDF (Earliest Eligible Virtual Deadline First) scheduling | Ion Stoica, Hussein Abdel-Wahab; Peter Zijlstra (Linux EEVDF) | EEVDF paper (1995), Linux scheduler | Paper / GPL-2.0 | `src/modulus/schedule.odin` | https://www.linuxfoundation.org/about/donate |
| Exact-area analytic glyph rasterizer | Raph Levien, Sean Barrett | font-rs, stb_truetype 2 | Apache-2.0 / MIT | `src/library/modus/vector_font/raster.odin` | https://github.com/sponsors/raphlinus |
| Exact-area analytic path and text rasterizer | Raph Levien, Sean Barrett | font-rs, stb_truetype 2 | Apache-2.0 / MIT | `src/library/modus/text_rendering/raster.odin` | https://github.com/sponsors/raphlinus |
| Copy-on-write B-tree object store | Kent Overstreet, Fuchsia Fxfs authors | bcachefs, Fuchsia Fxfs | GPL-2.0 / BSD-3-Clause | `src/library/internal/storage/storage_tree/storage_tree.odin` | https://www.patreon.com/bcachefs |
| QUIC transport and TLS 1.3 key schedule | IETF QUIC and TLS Working Groups | RFC 9000, RFC 9001, RFC 9002 | IETF Standard | `src/library/modus/quic` | https://www.ietf.org/support/ |
| Turns-based polynomial trigonometry | Casey Muratori (turns convention) | Turns angle convention | Public domain | `src/library/modus/trigonometry/trigonometry.odin` | — |
| Vector UTF-8 validation (16 bytes at a time) | John Keiser, Daniel Lemire | simdutf (Keiser & Lemire 2021) | Apache-2.0 / MIT | `src/library/modus/contract/text_encoding/text_valid_sixteen_bytes_at_a_time.odin` | https://github.com/sponsors/lemire |
| Swiss tables (16-tag SIMD open addressing) | Matt Kulukundis (Google Abseil), Facebook Folly F14 authors | Abseil SwissTable, Folly F14 | Apache-2.0 | `src/library/modus/hash_table/hash_table.odin` | — |
| rapidhash V3 fast short-key hash | Nicolas De Carli, Wang Yi (wyhash) | rapidhash | MIT | `src/library/modus/fast_hash/fast_hash.odin` | — |
| Vector fuzzy matching and frecency | Dmitriy Kovalenko (fff / frizbee), Junegunn Choi (fzf), Mozilla Places authors | fff, frizbee, fzf | MIT | `src/library/modus/line_editor/fuzzy_match_vectors.odin` | https://github.com/sponsors/junegunn |

## Inspirations

Systems, papers, and ideas that shaped the 25 properties and the design of `modus`, covering every **Reuse** field of `PROPERTIES.md`.

| System or idea | Authors | Took and left | Link | Funding |
|---|---|---|---|---|
| seL4 | seL4 Foundation, Data61 / NICTA | Took: small capability-based microkernel, caller-supplied memory for kernel objects, cache-conscious fast paths. Left: formal Isabelle proof infrastructure, CSpace tree layout. | https://sel4.systems/ | https://sel4.systems/Foundation/Donate/ |
| Zircon | Google Fuchsia team | Took: uniform handle table with per-handle rights, typed kernel objects, capability routing. Left: channels with in-kernel message copying, VMO pager complexity. | https://fuchsia.dev/fuchsia-src/concepts/kernel | — |
| Windows NT | Dave Cutler and Microsoft NT team | Took: one uniform handle table with typed kernel objects and per-type operations. Left: Win32 subsystem, registry, kernel drivers. | https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/ | — |
| Capsicum | Robert N. M. Watson, Jonathan Anderson, Ben Laurie, Kris Kennaway | Took: capability-mode sandboxing and explicit handle delegation. Left: POSIX file descriptor model. | https://www.cl.cam.ac.uk/research/security/capsicum/ | https://freebsdfoundation.org/donate/ |
| io_uring | Jens Axboe | Took: shared-memory submission and completion rings for batched, non-blocking operations. Left: POSIX syscall surface and file descriptors. | https://kernel.dk/io_uring.pdf | — |
| Virtio | OASIS Virtio Technical Committee, Rusty Russell | Took: standard shared-memory queue protocol for block, network, input, console, entropy, and GPU devices. Left: legacy PCI transport variants. | https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html | — |
| FlexSC | Livio Soares, Michael Stumm | Took: batched kernel entry to avoid cache pollution on the normal path. Left: kernel thread pool for legacy syscalls. | https://www.usenix.org/conference/osdi10/flexsc-flexible-system-call-scheduling-exception-less-system-calls | — |
| Arrakis and IX | Simon Peter, Adam Belay, et al. | Took: kernel as control plane only, off the data path for network and storage I/O. Left: POSIX compatibility shim. | https://www.usenix.org/conference/osdi14/technical-sessions/presentation/peter | — |
| DPDK and SPDK | Linux Foundation DPDK / SPDK communities | Took: user-space direct queue access for network and block devices with IOMMU isolation. Left: hugepage polling loops in every process. | https://www.dpdk.org/ | https://www.linuxfoundation.org/about/donate |
| L4 | Jochen Liedtke and L4 family authors | Took: minimal IPC fast path and cache-line discipline. Left: synchronous register-only IPC. | https://os.inf.tu-dresden.de/L4/ | — |
| UEFI and TPM 2.0 | UEFI Forum, Trusted Computing Group | Took: firmware boot services, Secure Boot verification, measured boot, and TPM-sealed keys. Left: multi-stage legacy bootloaders and free-text kernel command lines. | https://uefi.org/specifications | — |
| bcachefs | Kent Overstreet | Took: copy-on-write B-tree ideas, cache-line-aware node search, checksummed pointers. Left: Linux kernel integration and GPL-2.0 codebase. | https://bcachefs.org/ | https://www.patreon.com/bcachefs |
| Fuchsia Fxfs | Google Fuchsia team | Took: user-space transactional object store with object identifiers and optional directories. Left: Rust codebase and Fuchsia-specific FIDL bindings. | https://fuchsia.dev/fuchsia-src/reference/fidl/fuchsia.fxfs | — |
| Nix | Eelco Dolstra and NixOS contributors | Took: content-addressed immutable store, reproducible closures, atomic upgrades and rollbacks. Left: fixed `/nix/store` absolute paths and POSIX wrapper scripts. | https://nixos.org/ | https://opencollective.com/nixos |
| Zero is initialization (ZII) and turns | Casey Muratori | Took: zero-initialized valid structs across every contract and angles measured in turns (1.0 = full circle). Left: C++ conventions. | https://www.computerenhance.com/ | — |
| Arena allocators | Ginger Bill (Odin), Andrew Kelley (Zig), Jonathan Blow (Jai) | Took: caller-supplied memory and explicit reserve/commit arenas with no global heap. Left: hidden implicit allocations. | https://odin-lang.org/ | https://github.com/sponsors/gingerBill |
| font-rs and stb_truetype | Raph Levien, Sean Barrett | Took: exact-area analytic rasterization for 2D paths and glyphs. Left: C single-header API and floating-point-only pipelines. | https://github.com/raphlinus/font-rs | https://github.com/sponsors/raphlinus |
| WebGPU, WGSL, SPIR-V, and Venus | W3C GPU for the Web, Khronos Group, Mesa Venus | Took: GPU command serialization model, SPIR-V precompiled shaders, and virtio-gpu Venus path. Left: software WebGPU fallback and runtime shader compilation. | https://www.w3.org/TR/webgpu/ | — |
| PowerShell and Nushell | Jeffrey Snover, Jonathan Turner, Sophia Turner, Nushell contributors | Took: typed records and tables in pipelines with no text parsing between commands. Left: .NET runtime and POSIX external command glue. | https://www.nushell.sh/ | https://opencollective.com/nushell |
| Oberon and Lisp machines | Niklaus Wirth, Jürg Gutknecht, MIT AI Lab | Took: commands as exported procedures called directly from the interface. Left: single-address-space trust model. | https://www.projectoberon.net/ | — |
| Wayland | Kristian Høgsberg and Wayland contributors | Took: versioned typed display contracts and compositor-owned surfaces. Left: Unix domain sockets and `libwayland` C protocol XML. | https://wayland.freedesktop.org/ | https://www.x.org/wiki/XorgFoundation/ |
| Fuchsia FIDL | Google Fuchsia team | Took: typed role contracts named by interface and routed by parent. Left: wire format separate from module metadata. | https://fuchsia.dev/fuchsia-src/concepts/fidl/overview | — |
| Object-capability membranes | Mark S. Miller | Took: interposed role holders (filters, auditors, remote views) transparent to clients. Left: dynamic JavaScript-style proxies. | http://www.erights.org/talks/thesis/ | — |
| xdg-desktop-portal | Flatpak and freedesktop.org contributors | Took: powerbox-style user-mediated grants filled by a desktop role holder. Left: D-Bus message broker and global service names. | https://flatpak.github.io/xdg-desktop-portal/ | https://opencollective.com/flatpak |
| rr | Robert O'Callahan, Kyle Huey, Mozilla | Took: single-threaded recording at input points, `rdtsc` and `cpuid` trapping, deterministic replay. Left: Linux ptrace/seccomp machinery. | https://rr-project.org/ | — |
| QEMU record and replay | QEMU contributors | Took: whole-machine recording at device boundaries as a reference model. Left: full-system emulation overhead for single-process debugging. | https://www.qemu.org/ | https://www.qemu.org/donate/ |
| FoundationDB and TigerBeetle | FoundationDB team, Joran Dirk Greef and TigerBeetle team | Took: routing every nondeterministic input through one explicit interface for deterministic simulation. Left: library-only interception that untrusted code could bypass. | https://tigerbeetle.com/ | — |
| Erlang / BEAM | Joe Armstrong, Robert Virding, Mike Williams | Took: isolated processes, supervision restarts, and explicit failure boundaries. Left: dynamically typed message passing and VM garbage collection. | https://www.erlang.org/ | https://erlef.org/sponsors/ |
| Plan 9 | Rob Pike, Ken Thompson, Dave Presotto, Phil Winterbottom | Took: per-process private namespaces and clean user-space services. Left: "everything is a file" text protocol (9P). | https://9p.io/plan9/ | — |

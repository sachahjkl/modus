type: Added

**Live QEMU `chibicc` self-hosting and C library execution.** The `bootstrap` machine test executes the full 14-unit `chibicc` Stage 0 → Stage 1 → Stage 2 self-hosting chain live on modus via `c_compiler.compile_unit`, `assemble.assemble_program`, and `system.module_space_load`, reproducing the exact host `modustool c-self-host` BLAKE3 hash, and loads and validates freestanding `sqlite` (3.54.1), `lua` (5.4.7), and `zstd` (1.5.7) modules live on modus against host module and compressed-frame BLAKE3 hashes.

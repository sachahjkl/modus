type: Added

**Self-hosted `chibicc` builds of Lua, zstd, and SQLite, plus Tier 2 `hex0` and `catm` seed bootstrap.** `modustool c-self-host --libraries` now compiles upstream Lua 5.4.7, zstd 1.5.7, and SQLite 3.54.1 using Stage 1 `chibicc` and the native modus assembler into validated `.modus` modules (`zstd` matches host clang's compressed-frame BLAKE3 hash and `sqlite` passes `PRAGMA integrity_check`), `c_builder` supports multi-unit C recipes, and `guest_builder` executes the real executable 262-byte x86-64 `hex0` self-host (`blake3(seed) == blake3(stage1)`) and `catm` stages.

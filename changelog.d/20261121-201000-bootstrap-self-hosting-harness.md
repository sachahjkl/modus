type: Added

**Self-hosting verification command and bootstrap recipe chain harness.** `modustool self-host` compiles `tools/modustool` in two isolated staging directories where Stage 1 compiles Stage 2 with identical deterministic flags, proving exact BLAKE3 fixed-point equality or reporting the first diverging byte offset, and `bootstrap_chain_verify` validates the stage-by-stage `chibicc` self-host, `hex0`-to-`odin` guest bootstrap, and SQLite, Lua, and zstd C-world recipe DAGs.

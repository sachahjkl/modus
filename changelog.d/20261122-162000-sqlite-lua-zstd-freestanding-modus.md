type: Added

**SQLite 3.54.1, Lua 5.4.7, and zstd 1.5.7 built as freestanding modus modules.** The three upstream C programs compile against `src/outside/c_programs/thin_libc/` (including freestanding IEEE-754 elementary math) with zero imports and zero host instructions, and pass live SQL, Lua, and zstd compression tests.

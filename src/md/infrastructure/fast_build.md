# Fast iteration build mode

A fast iteration build compiles user modules without full optimization and builds only the requested boot volumes, while keeping full optimization for the kernel, the boot program, checks, measures and releases.

## Purpose

While iterating on a bug or a machine test, compiling all 179 modules with `-o:speed` and `llc -O3` and building all 27 boot volumes takes minutes. A developer who works on one part of the system needs a faster loop that keeps the same module contract, the same safety checks and sound incremental caching.

## Constraints

- Every shipping build (`build`, `test`, `check`, `screenshots`, `measure`, `release`, `ship`, and `nix flake check`) must continue to use `-o:speed` and `llc -O3` with all required boot volumes.
- Switching between fast iteration mode and default speed mode must never mix outputs of one mode with outputs of the other.
- Every module of a fast iteration build must still obey the module contract: no thread-local storage, no undeclared external symbols, valid log fact tables and valid library segments.
- The kernel must keep fixed-size stack frames that pass `kernel_stack_check` and `kernel_has_no_vector_instruction`, and stay within the 16-page kernel stack and 2-page interrupt stacks ([kernel_stack_depth.md](kernel_stack_depth.md)).
- The boot program must link cleanly with `lld-link /nodefaultlib` without undefined symbols.

## The chosen form

- **Closed optimization mode enum (`Optimization_Mode`).** `tools/modustool/build/modules.odin` defines `Optimization_Mode :: enum { Speed, None }` with explicit border conversions (`"speed"`, `"none"`). No boolean or integer flag carries optimization state. The mode passes explicitly on the command line of every `module` and `volume` child process, and every command that checks, repeats, measures or ships forces `.Speed`.
- **User modules in `.None` mode (`--fast`).** A non-kernel module compiles with `odin build -o:none -use-single-module -no-thread-local`, runs `opt -O1 -S` on the single LLVM IR file before `facts_reached`, and runs `llc -O0` to emit the object.
  - `-use-single-module` keeps one LLVM IR file per module: Odin defaults to `-use-separate-modules` under `-o:none`.
  - `-no-thread-local` prevents `base:runtime`'s uncalled `default_random_generator_proc` from emitting `@thread_local` (`__tls_get_addr`) in unoptimized IR; modus modules never use thread-local storage.
  - `opt -O1 -S` performs light interprocedural constant propagation and dead-code elimination so dead calls into `text_rendering` foreign imports (from `bootscreen` in modules such as `root` that do not import `text_rendering`) and unreached support-package `log_fact` immediates are removed before `facts_reached` and `ld.lld`.
  - Measured on `console`: 21.2 s (`-o:none` + `opt -O1` + `llc -O0`) against 54.3 s (`-o:speed` + `llc -O3`). Measured on `root`: 14.8 s against 45.4 s.
- **The kernel and library modules always compile with `.Speed`.** `module_effective_optimization` returns `.Speed` for any row with `build.kernel == true` or `build.library == true`. Measured on `src/modulus`: under `-o:none` and `llc -O0`, LLVM emits dynamic stack alignment (`andq $-0x40, %rsp`) and frame-pointer restores (`movq %rbp, %rsp`) that `kernel_stack_check` refuses, and unoptimized frames risk exceeding the fixed 16-page kernel stack and 2-page interrupt stacks. Measured on `text_rendering` and `drawing`: under `-o:none`, Odin retains read-only relocation tables (relro rebases) that library modules cannot carry because each importer maps the shared library at a different address. Only three modules are kernels and three are library modules, and incremental builds keep them unchanged whenever their sources do not change.
- **The boot program always compiles with `.Speed`.** `src/boot` compiles directly with `odin build -target:freestanding_amd64_win64 -build-mode:obj` and links with `lld-link /nodefaultlib`, with no separate `opt` pass. Measured on `src/boot`: under both `-o:none` and `-o:minimal`, uneliminated dead branches in `bootscreen` -> `text_rendering` leave undefined references (`line_shape`, `line_widths`, `line_fit`, `glyph_find`) that fail `lld-link`. Compiling `src/boot` with `-o:speed` takes about 2.5 s once for a single volume; skipping the other 26 boot volumes saves over a minute.
- **Explicit optimization mode in every build record.** `Build_Record` (`build record, form 2`) stores an `optimization <speed|none>` line alongside `key`, `output`, `source` and `load`, and the optimization mode and exact `odin`, `opt` and `llc` commands are also hashed in `Build_Key_Inputs`. A record whose `optimization` line is absent, malformed or different from the requested mode is refused (`"the optimization mode changed"`), forcing a clean rebuild.
- **Single-volume and single-part commands.**
  - `modustool build [whole] [--fast] [volume_name] [host_processes]` builds all boot volumes when no volume name is given, or only the named boot volume (for example `modustool build --fast main`), skipping the other 26 volumes. Unknown volume names and unknown flags are refused before any build starts.
  - `modustool test --fast <part> [steps ...]` sets `Optimization_Mode.None`, builds only the boot volumes declared for `<part>`, and runs `<part>`. `test --fast` requires a part name and refuses `from <folder>` (which runs no build).

## The refused forms

- **Plain `-o:none` and `llc -O0` on all modules without `opt -O1` or `-no-thread-local`.** Refused by measurement: `root` retained `__tls_get_addr` (violating the no-TLS module rule) and undefined `text_rendering` symbols (`glyph_find`, `line_fit`, `line_shape`, `line_widths`), and `kernel` emitted `andq $-0x40, %rsp` and `movq %rbp, %rsp` that `kernel_stack_check` refuses.
- **`-o:none` or `-o:minimal` on `src/boot`.** Refused by measurement: `lld-link /nodefaultlib` fails with undefined `text_rendering` symbols (`line_shape`, `line_widths`, `line_fit`, `glyph_find`).
- **Separate build folders (`build/fast/`) for fast builds.** A second folder duplicates every module, boot image and 64 MiB boot volume on disk and complicates commands that read `build/`. Recording `optimization` in the build record keeps one build folder and guarantees clean invalidation when switching modes.
- **A boolean flag `fast_build := false` instead of `Optimization_Mode`.** A boolean hides a closed choice and does not scale cleanly at the CLI and record borders.
- **Allowing `modustool test --fast` with no part or with `from <folder>`.** Running all 33 parts in unoptimized mode is not an iteration loop, and `from <folder>` runs no build.

## Subtle points

- Kernel modules record their effective mode (`.Speed`) in their build records, so switching between `--fast` and default mode rebuilds all user modules and boot volumes without needlessly recompiling unchanged kernels.
- Boot volumes record the requested `Optimization_Mode` (`.Speed` or `.None`) even though `src/boot` compiles at `-o:speed`, so volume records also invalidate explicitly across mode switches alongside their boot image hashes.
- `modustool check`, `modustool repeat`, `modustool release image`, `modustool screenshots` and `nix flake check` always force `Optimization_Mode.Speed`.

## State

Built: `Optimization_Mode` enum and border parser, fast user-module IR pipeline (`-o:none -use-single-module -no-thread-local`, `opt -O1`, `llc -O0`) with `.Speed` preserved for kernel modules and `src/boot`, `build record, form 2` with explicit `optimization` invalidation, `modustool build --fast [volume_name]`, `modustool test --fast <part>`, and host tests for mode parsing, record invalidation, single-volume filtering and refusals. The guide is [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The incremental build".

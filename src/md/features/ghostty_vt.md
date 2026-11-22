# Freestanding `libghostty-vt` terminal emulation

`libghostty-vt` (Mitchell Hashimoto / Ghostty, MIT) provides a freestanding C-ABI VT100, xterm, SGR, alternate-screen, scrollback, Kitty keyboard, and Unicode grapheme/East-Asian-width terminal state machine with a caller-supplied allocator. Under Property 25 (Take the gold, leave the debt), `modus` reuses `libghostty-vt` instead of maintaining a sprawling custom xterm emulator for rich terminal and SSH workloads.

## Constraints and bootstrap split

- **Minimal bootstrap seed stays Zig-free.** `libghostty-vt` is written in Zig. Compiling it from source adds Zig to `flake.nix` and sits outside the `hex0 -> chibicc -> Odin` bootstrap seed ([bootstrap.md](bootstrap.md)). The small Odin `terminal` module therefore stays in the minimal bootstrap and rescue images.
- **Role separation.** `libghostty-vt` ships as a library module (`ghostty_vt`) and as the VT engine behind rich `Role.Terminal` holders and `ssh_client` sessions ([roles_and_contracts.md](roles_and_contracts.md)).
- **Bounded memory.** `libghostty-vt` receives an explicit `Ghostty_Allocator` backed by a caller-supplied fixed arena paid from the process's `MODULE_BUDGET`, with zero host `libc` heap and strict out-of-memory refusal.
- **Language-neutral module build.** Zig compiles `libghostty-vt` targeting `x86_64-freestanding-none` into a System V AMD64 `ET_REL` object, linked and converted through the existing `modustool sdk-convert` pipeline ([../infrastructure/outside_source.md](../infrastructure/outside_source.md)).

## Refused forms

- **Replacing the bootstrap terminal with a Zig dependency.** That would pull Zig into the minimal seed.
- **Global heap allocator behind `libghostty-vt`.** Every allocation must come from the caller's fixed arena so memory peaks stay bounded and deterministic.

## State

Built: the freestanding contract package `src/library/modus/contract/ghostty_vt/` defining the C-ABI `Ghostty_Allocator` vtable, bounded `Fixed_Arena` allocator adapter (alignment-safe bump/free/resize/remap with OOM bounds and live/peak counters), validated `Terminal_Options`, and adversarial host tests. Left: pinning the upstream Ghostty commit in `flake.nix` under `src/outside/ghostty/`, adding the Zig `x86_64-freestanding-none` build step, and wiring `ghostty_vt` into `ssh_client` and a `Role.Terminal` holder.

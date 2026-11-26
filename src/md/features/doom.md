# Native Doom (`doomgeneric`) on modus

Run native Doom (`doomgeneric`) directly on `modus` as a confined window module, with no POSIX layer and no guest machine. The module combines an Odin shell with freestanding C engine sources (`c_source`) in one position-independent module binary.

The vector form follows [`docs/SIMD.md`](../../../docs/SIMD.md), "1. The rule of the same bytes". Optional sound and missing hardware follow [timed_stream.md](timed_stream.md) and [missing_hardware.md](missing_hardware.md). Browser execution follows [browser_machine.md](browser_machine.md).

## The constraints

- **No foreign interface.** The engine compiles against a freestanding C runtime shim with no POSIX headers, no file paths, and no global file system.
- **No host imports.** The Odin shell imports `base:` and `modus:` packages only.
- **Byte-for-byte identical SIMD.** The SSE2 palette-to-BGRA32 blit keeps a scalar twin that produces the same bytes for every input.
- **No unbreakable input capture.** Opt-in pointer lock hides the desktop cursor and routes relative motion, while `Super` always releases lock and the bar shows the active lock indicator.
- **Deterministic timing and silent fallback.** Frame pacing runs on `system.nanoseconds()` at 35 Hz (`28_571_428 ns` per tic), and the module runs silent when no sound device is present.
- **Bounded memory and storage reads.** WAD data streams through `storage.read_range` in 56 KiB chunks inside the storage call region limit, with no hidden copies.

## The chosen form

### Module structure and build

The Doom module pairs a small Odin shell with freestanding C `doomgeneric` sources compiled into the same module. The Odin shell owns the window lifecycle, event loop, timing, storage reads, palette conversion, and optional sound output. The C engine calls a small set of `cdecl` bridge procedures implemented in Odin (`DG_Init`, `DG_DrawFrame`, `DG_SleepMs`, `DG_GetTicksMs`, `DG_GetKey`, and WAD read hooks).

### Direct 640 x 400 surface and SSE2 palette blit

The shell opens a fixed 640 x 400 window directly through `display.open` and writes 32-bit BGRA pixels into `window.canvas`. Each 8-bit indexed Doom pixel maps through the active 256-entry 32-bit BGRA palette table.

On `amd64`, the blit converts pixels in groups of four using `#simd[4]u32` stores from `base:intrinsics`, with a scalar twin for tail pixels, non-`amd64` targets, and host reference tests. Host tests compare both forms across widths 0 to 67, unaligned offsets, and guard words.

### Explicit 35 Hz frame pacing

Doom runs its game simulation at 35 tics per second (`28_571_428 ns` per frame). The shell computes the next frame deadline from `system.nanoseconds()` and waits on the display ring with that deadline, draining all pending key and pointer events before each tic.

### Chunked 56 KiB WAD reads

The storage service transfers object bytes inside a 64 KiB call region. The shell reads WAD data from its granted store with `storage.read_range` in 56 KiB chunks (`57_344` bytes, leaving headroom for call framing metadata) into a caller-supplied arena buffer. No global path or POSIX `fopen` exists.

### Right-click delivery and opt-in pointer lock

Right-clicking over a window surface delivers `display.BUTTON_RIGHT` to that window. Right-clicking on empty desktop background still opens the desktop context menu. Right-clicking on a window title bar raises the window without sending out-of-surface coordinates.

First-person turning needs relative motion without cursor clamping at window or screen edges. The display contract adds `Command.Pointer_Lock` with closed `Pointer_Lock_Mode` (`Release = 0`, `Acquire = 1`). It also adds `Event_Kind.Pointer_Delta` with signed `(dx, dy)` relative motion. Lock transitions report `Event_Kind.Pointer_Lock_Changed` with closed `Pointer_Lock_Reason` (`Window_Request`, `Super_Key`, `Focus_Lost`, `Refused`).

- Only the focused window can acquire pointer lock. Acquisition fails while any desktop modal, menu, palette, popover, or keyboard mode is open.
- While locked, the compositor hides the desktop cursor and shows `Pointer locked (Super)` in the bar.
- When a window ring is full, the compositor coalesces relative deltas by summing `(dx, dy)`.
- Non-system keys (`Escape`, `Alt+Tab`, `Ctrl+C`, `Ctrl+Shift+Arrow`) go directly to the locked window.
- `Super` and `Ctrl+Shift+Escape` always release pointer lock and restore the cursor. Trusted modals always take priority and release pointer lock.
- Focus changes, workspace switches, minimize, window close, and session reset release pointer lock automatically.
- The browser machine page provides a `Lock pointer` button using the browser Pointer Lock API. While locked, it forwards raw `movementX` and `movementY` deltas without breaking 1:1 desktop cursor mode.

### Optional sound on soundless machines

Some machines lack a virtio sound device, such as the browser machine or default QEMU without `virtio-sound-pci`. On those machines, the root service logs one line and starts a `Sound_Device` process without sound handles instead of refusing launch. A second concurrent holder on a machine with a sound device is still refused with `Callee_Busy`. The Doom shell checks `ctx.handles[timed_stream.GRANT_RING]` and runs silent when the handle is 0.

### Machine verification

QEMU machine tests use `qmp_key_state_command` in `tools/modustool/machine/qmp.odin` to hold movement and fire keys down across multiple 35 Hz tics, verifying live rendering, input response, and pointer-lock release via `Super`. Browser machine verification boots the same module in WebAssembly with `Lock pointer` relative motion.

## The refused forms

| Form | Why refused |
|---|---|
| Running Doom inside a Linux guest | A guest hides native display, input, storage, and timing costs behind a foreign kernel. |
| A POSIX `stdio` / filesystem shim | Contradicts no global file system and no foreign interface. |
| Unconditional cursor capture or `Escape` to unlock | Unbreakable capture violates no ambient control, and Doom uses `Escape` for its in-game menu. |
| Replacing pending `Pointer_Delta` records on ring full | Replacing relative deltas drops turning motion; coalesced deltas must sum `(dx, dy)`. |
| Simulating a fake sound device when hardware is absent | Contradicts the rule that absent capabilities are never simulated; omitting the handle makes absence explicit. |

## Subtle points

- **Game key combinations conflict with desktop shortcuts.** Doom uses `Ctrl` to fire, `Shift` to run, `Alt` to strafe, `Tab` for the automap, and arrows to move. Passing non-`Super` combinations straight to a pointer-locked window prevents accidental window snapping, workspace switches, or task switching during play.
- **Matching `Super` release must be swallowed.** When `Super` press exits pointer lock, its matching key-up event must not leak into the newly unlocked window.
- **Stale `Pointer_Delta` on lock exit.** Any pending coalesced delta in the compositor's window queue is cleared when lock ends so unlocked windows do not receive late relative deltas.

## State

Built:
- Window right-click routing with empty-desktop, bar, overlay, and window-frame guards.
- Opt-in `Command.Pointer_Lock`, summing `Event_Kind.Pointer_Delta` coalescing, and `Event_Kind.Pointer_Lock_Changed`.
- Compositor pointer-lock state machine, `Pointer locked (Super)` bar mark, `Super` and `Ctrl+Shift+Escape` release, and game shortcut bypass.
- Browser machine optional pointer lock, optional `.Sound_Device` silent launch on soundless machines, and `qmp_key_state_command` for held keys.
- Native `doom` application module (`src/modules/applications/doom/` + `src/outside/doomgeneric/`): pinned `doomgeneric` C engine with limit-removing patch, freestanding thin libc, zero-copy memory-mapped WAD loaded at startup via 56 KiB `storage.read_range` chunks, SSE2 `#simd[4]u32` palette-to-BGRA32 blitter with byte-identical scalar twin, 35 Hz frame pacing, WASD/arrow/mouse pointer-lock input, optional 48 kHz stereo DMX SFX mixing over `timed_stream`, and `doom` QEMU machine test scenario.

Left:
- Live QEMU and browser machine execution verification of the Doom module.

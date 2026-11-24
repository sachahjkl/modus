# The grants window

The desktop window `grants` (`src/modules/applications/grants`) lets the principal inspect and revoke every grant held in the current session without opening the console: active recorded grants of running processes, an active wide grant, and remembered disk grants.

## The purpose

Property 2 ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default") states that every process starts with no access and that every grant can be revoked. Previously only the console (`grants`, `revoke`, `disallow`, `agent_disallow`) let the principal inspect or revoke grants; no desktop window showed them. This window closes that open desktop question while enforcing strict least privilege and non-blocking interface rules.

## The constraints

- **Strict least privilege.** The window must not receive `Root_Ring` (which grants `Start`, `Stop`, `Principal_Create`, `Principal_Lock`, `Replace`, `Start_From_Disk`, `Wide_Grant_Ask`, and `Disk_Grant(.Allow)`) and must not receive `Acts_For_Principal` (which unlocks every other service on behalf of the principal).
- **Monotone authority reduction.** From this window the principal can inspect and revoke existing grants of the current session only; the window can never mint, extend, or allow a grant, and can never read or modify grants of another principal.
- **Non-blocking interface thread.** Every root-ring query and revocation runs on a worker thread (`interface.Background_Work`), never on the window thread. Frame drawing performs zero per-frame O(N) filtering or sorting over system state.
- **Sober layout and writing rules.** Every element takes its rectangle from `modus:layout` (`modus:interface`), uses color tokens from `modus:graphics` in both dark and light appearances, follows [`docs/DESIGN.md`](../../../docs/DESIGN.md), and obeys [`docs/WRITING.md`](../../../docs/WRITING.md) (each fact appears once across titles, badges, sentences, and buttons; confirmation controls name the action on their buttons).

## The chosen form

**Least-privilege start grant (`start_grant.Grant.Grants_Manage`).** A dedicated start grant gives the window a root ring (`root_ring.ROOT_RING_GRANTS`) and nothing else: no `Inspect`, no `Image`, no `Store`, no `Serve`, no `Acts_For_Principal`. `disk_process.grant_by_command` classifies `Grants_Manage` as `Never`, so no disk process can ever receive it. The sender rule `root_ring.Root_Command_Sender.Root_Ring_Or_Grants_Manage` permits `Grants_Manage` solely on:

- `Root_Command.Grants_Read`: a read-only indexed query with a closed enum `Grants_Read_Kind` (`Process`, `Wide_Grant`, `Disk_Grant`), returning only records belonging to `caller.principal`.
- `Root_Command.Grants` and `Root_Command.Revoke`: scoped strictly to `other.principal == caller.principal` when the caller lacks `Root_Ring`.
- `Root_Command.Wide_Grant_End`: scoped strictly to `wide_grant_flow_state.principal == caller.principal`.
- `Root_Command.Disk_Grant`: restricted strictly to `Disk_Grant_Action.Disallow` when the caller lacks `Root_Ring`; `Disk_Grant_Action.Allow` is refused with `Grant_Or_Right_Missing` (`No_Grant`).

**Single-record wire encoding.** Every `Grants_Read` response fits within the seven `u64` words of a `ring.Record` completion, requiring no extra shared memory page:

- `Process`: packed process name (`values[0..3]`), held `Root_Grant` bitset (`values[4]`), revoked `Root_Grant` bitset (`values[5]`), and total matching process count (`values[6]`).
- `Wide_Grant`: client public key (`values[0..3]`), active `Wide_Authorities` word (`values[4]`), expiry timestamp `ends_at_ms` (`values[5]`), and grant serial (`values[6]`, zero when no wide grant is active for `caller.principal`).
- `Disk_Grant`: packed nickname (`values[0..2]`), 8-byte hash prefix (`values[3]`), `Disk_Grants` bitset (`values[4]`), packed persistence and table-lasting enum bytes (`values[5]`), and total disk grant row count (`values[6]`).

**Pure model and off-thread worker.** All snapshot parsing, validation, row indexing, confirmation state, and formatting live in the pure internal package `internal:grants/grants_model`, tested on the host across empty, populated, boundary, overflow, and refusal inputs. The window module `src/modules/applications/grants` runs root-ring snapshot refreshes and revocations inside `interface.Background_Work` using `system.ANSWER_BOUND_MILLISECONDS` as its hang bound, wakes the window thread when done, and draws from the immutable snapshot using `modus:layout`.

**Start menu and palette integration.** `grants` is declared as an application in `tools/modustool/foundation/module_table.odin` with icon `bar.Icon.Grant`, so `start_menu_names.odin` and the compositor palette expose it automatically.

## The refused forms

- **Giving `grants` the start grant `Root_Ring` or `Acts_For_Principal`.** Refused: a bug in the window would allow starting arbitrary processes, changing replacements, allowing disk grants, or reading private stores of every service.
- **Querying the root ring on the window thread.** Refused: blocks window redraws and input while waiting for the root service.
- **Allowing `Disk_Grant_Action.Allow` from the window.** Refused: granting access belongs to the trusted powerbox and explicit principal commands, never to a review-and-revoke window.
- **Showing a separate modal dialog box for revocation.** Refused: an inline confirmation pair (`Confirm revoke` / `Cancel`, or `Confirm disallow` / `Cancel`) on the targeted row keeps the rest of the grant table visible while naming the exact action on its buttons.
- **Repeating the same fact across heading, pill, sentence, and button.** Refused: each section heading names its category once, empty states appear only when no row exists, and action buttons name only the action.

## Subtle points

- **Principal isolation.** The root service enforces `caller.principal` on every `Grants_Read`, `Grants`, `Revoke`, `Wide_Grant_End`, and `Disk_Grant` command sent by a `Grants_Manage` holder. A caller cannot pass another principal number; the protocol carries no principal argument.
- **Start policy disk row.** A disk grant row holding `Disk_Grant.Start_Policy` cannot be changed by `Disk_Grant(.Disallow)` (the root service refuses it as `Reserved`); the window shows it read-only with no disallow action.
- **Snapshot refresh consistency.** Indexed `Grants_Read` reads can observe a process starting or stopping between indices; out-of-range indices return an empty name with the current total, and the model skips empty rows cleanly and refreshes after every revocation.
- **Bounded tables.** `grants_model` holds up to `PROCESS_ROW_CAPACITY` (64, inline capacity sized above the desktop process count of a session, recording any excess in `processes_truncated`) and `DISK_ROW_CAPACITY` (`disk_process.ROW_CAPACITY`, format property).

## State

Built: `start_grant.Grant.Grants_Manage`, `root_ring.Root_Command.Grants_Read`, `Root_Command_Sender.Root_Ring_Or_Grants_Manage`, root service handlers and scoping checks, `internal:grants/grants_model` with host tests, `src/modules/applications/grants` window with `modus:layout`, `interface.Background_Work`, dark and light color tokens, start menu/palette wiring, and start grant set row.

# The host agent bridge

An external agent drives a running modus machine through one typed bridge on the host, over a client key that a principal allowed ([remote_client_keys.md](remote_client_keys.md)). The bridge replaces terminal scraping and ad-hoc shell scripts with four explicit, typed capabilities: Lex evaluation, screen snapshots, window-scoped input injection, and structured log fact queries. Every act that widens authority or requires principal proof stops with `Awaiting_Principal_Approval` and never self-approves through the bridge.

## Purpose

- Give an agent structured Lex results (typed values and typed tables) from `remote` without scraping terminal pixels or formatted text.
- Give an agent lossless screen snapshots through the `remote_display` client key.
- Gate every synthetic key and pointer event by an active wide grant ([wide_grants.md](wide_grants.md)) covering the target window, and record each act in the append-only BLAKE3 hash chain of the collector before delivery.
- Give an agent structured log fact queries filtered by module, fact name, and sequence range ([log_facts.md](log_facts.md)).
- Keep the principal as the one source of new grants: each Lex call outside a short list of read-only exports, `plans.apply` and `plans.rollback` among them, stops at the bridge border with `Awaiting_Principal_Approval`. The bridge decides this from the line alone, never from a flag of the request.

## Constraints

- **A principal is the one source of new grants** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users"). No command that crosses the bridge can approve a grant dialog, answer a wide grant screen, or apply a grant-adding plan.
- **No ambient access** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close"). Each capability is an explicit bit in `Bridge_Permissions` and must also agree with the client key uses in `remote` (`Calls`, `View`, `Input`).
- **No unrecorded input act** ([wide_grants.md](wide_grants.md), "The record of each act"). A synthetic key or pointer event is written and hash-chained before it reaches the transport; if the collector log is full or unavailable, the bridge refuses the input fail-closed.
- **Freestanding contract border.** The wire format, closed enums, and authorization rules live in `src/library/modus/contract/agent_bridge`, importing `base:` and `modus:contract/*` only, with no allocator and no kernel call.
- **One border for each transport word.** Every enum word and permission mask is validated once at the border; unknown bits, zero unset values, truncated frames, trailing bytes, and out-of-range coordinates or scan codes are refused.

## The chosen form

### Four explicit capabilities

| Command | Required permission | Required remote key uses | Safety gate |
|---|---|---|---|
| `Eval_Lex` | `Eval_Lex` | `Calls` | UTF-8 text validation; exactly one call with literal arguments, else refused; a call outside `READ_ONLY_EXPORTS` stops with `Awaiting_Principal_Approval` |
| `Read_Screen` | `Read_Screen` | `View` | Screen dimensions within `remote_display` bounds; returns typed frame metadata and PNG or raw BGRX pixels; writes a host file only in the folder of `--snapshot-dir`, under a name of the bridge |
| `Send_Key` | `Send_Input` | `View`, `Input` | Active, non-expired `wide_grants.Wide_Grant_Terms` bound to the client key and covering `target_window_id`; scan code, code point, and modifiers within `remote_display` limits; fail-closed act record in the BLAKE3 hash chain before send |
| `Send_Pointer` | `Send_Input` | `View`, `Input` | Active, non-expired `wide_grants.Wide_Grant_Terms` bound to the client key and covering `target_window_id`; coordinates, buttons, and wheel within `remote_display` limits; fail-closed act record in the BLAKE3 hash chain before send |
| `Read_Log_Facts` | `Read_Log_Facts` | `Calls` | Bounded record limit and valid sequence range (`sequence_end == 0` or `sequence_end >= sequence_start`); optional identifier filters for module and fact name |

### Binary wire framing (`"MODAB1"`)

The contract package `modus:contract/agent_bridge` defines canonical little-endian binary frames starting with the 6-byte magic `"MODAB1"` and 2-byte version `1`:

- **Command frame** (`COMMAND_HEADER_SIZE` = 84 bytes + bounded payload): magic, version, `Bridge_Command_Kind`, non-zero `request_id`, `principal_id`, `grant_serial`, `target_window_id`, 32-byte `client_key_hash`, `payload_length`, zero `reserved` field, followed by the exact command payload bytes.
- **Response frame** (`RESPONSE_HEADER_SIZE` = 72 bytes + bounded payload): magic, version, `Bridge_Status`, `Bridge_Refusal`, non-zero `request_id`, `act_sequence_number`, 32-byte `act_record_hash`, `payload_length`, zero `reserved` field, followed by the exact response payload bytes.

Each decoder checks the magic, version, reserved word, exact byte length (refusing both truncation and trailing bytes), closed enum membership, and payload bounds before returning a decoded record.

### Authorization and the principal approval invariant

`bridge_authorize_command` evaluates every command as a pure, contextless decision before any transport call runs:

1. **Client identity and permissions.** Refuses an all-zero client public key, unknown or empty `Bridge_Permissions` bits, unknown `remote.Client_Uses` bits, and any command whose required permission or remote use is absent.
2. **The read-only list of `Eval_Lex`.** `lex_line_classify` parses the line as exactly one call, `service.export` or `service.export(arguments)`. An argument is a literal (an integer, `true`, `false`, a text, a hash `blake3:<hex>`, a member `.name`), or a name, a comparison and a literal. Every other line is `Malformed` and refused with `Invalid_Text`: a line end or another control byte, a comment (`//`, and `#` and `--`, which Lex does not have), a pipe `|>`, a `;`, a nested call, a bare name (it can name a command such as `lock`), a list, a record, a function or a `let`. A call of an export on `READ_ONLY_EXPORTS` runs; a call of any other export stops with `Bridge_Status.Awaiting_Principal_Approval` and `Bridge_Refusal.Principal_Approval_Required`. The request carries no flag of sensitivity and no `Plan_Difference`: the bridge reads none, so an agent cannot say that its own call is safe.
3. **Wide grant and window scope gate for input.** For `Send_Key` and `Send_Pointer`, verifies that a wide grant is present, active, within its monotonic `[created_ms, expires_ms)` window, has valid `Wide_Grant_Terms` whose `principal_id` matches the policy and whose `grantee_identity_hash` equals `blake3.hash(client_key_public)`, holds both `.View_Screen` and `.Send_Input`, includes the non-zero `target_window_id` in `target_window_ids`, and has an available collector audit chain.

### The read-only list

`READ_ONLY_EXPORTS` names each export that reads and changes nothing and gives no secret of the principal. It is a list of the exports that exist:

| Service | Exports |
|---|---|
| `log` | `records`, `process_records`, `value_runs`, `process_value_runs`, `fact_records` |
| `plans` | `status`, `current_generation`, `diff_count`, `difference`, `generations` |
| `recipes` | `status`, `build_count`, `cache_hits`, `builds`, `realisations` |
| `projects` | `status`, `active_console_count`, `pin_count`, `pins` |
| `monitor` | `processes`, `counts`, `count`, `counts_named`, `served` |
| `compositor` | `pointer`, `windows`, `screen`, `gpu_info` |
| `manual` | `modules`, `exports`, `signature` |

What is not on it, and why:

- `plans.apply`, `plans.apply_poll` and `plans.rollback`: they change the plan, so the grants. `apply_poll` commits an accepted plan.
- Each export of `storage` and `settings`: they write.
- Each export of `debugger`, the reads too: `memory`, `registers` and `locals` give the state of another process.
- `compositor.wide_grant_indicator`, `notify`, `powerbox_ask`, `revoke_grant`, `plan_diff_ask` and the other exports of the compositor that change the screen or answer a dialog.
- Each export of `collector`: the act records of a wide grant are the audit of its holder, which the holder never reads.
- `manual.show`, `manual.overview`, `manual.running` and `manual.edges`: the first two change the manual window, and the last two inspect running processes.

A new entry must read only. The host test `test_lex_line_classification_is_a_strict_read_only_allowlist` refuses an entry whose name says that it writes.

**This path is not lasting.** The read-only agent console ([agent_code_mode.md](agent_code_mode.md)) takes the place of the single calls of `Eval_Lex`: the read-only list becomes the reach of that console, checked on the machine at each call, and `lex_line_classify` and the single-call path go in the same layer. One mechanism runs the lines of an agent, and nothing stays for compatibility before 1.0.

### Host stdio JSON-RPC adapter (`modustool agent-bridge`)

On the host, `tools/modustool/agent_bridge` provides a line-delimited JSON-RPC 2.0 adapter (`modustool agent-bridge`) that:

- parses each JSON request line strictly and rejects malformed JSON, unknown methods, missing required fields, or invalid binary frames;
- runs `bridge_authorize_command` and validates every payload against the contract borders before touching any transport;
- records an append-only `"modus act record v1"` BLAKE3 hash-chained `wide_grants.Act_Record` for every input act before invoking the transport, refusing the act if the audit chain is full;
- delegates execution to a pluggable `Machine_Transport`, with a real `remote` QUIC call client adapter (`tools/modustool/machine`) for live machines ([`docs/QUIC.md`](../../../docs/QUIC.md), "7. `remote` over QUIC (built)") and an in-memory fake transport for deterministic host tests;
- returns structured JSON responses containing typed Lex values/tables (a table or a record gives its columns, the kind of each column, `column_kinds`, one of `Lex_Column_Kind`: `text`, `integer`, `size`, `time`, `hexadecimal`, its unit word, `column_units`, the text of each cell, `rows`, and the value of each cell of a number column, `row_integers`, so a reader aligns and formats a number as the console does and never reads it back from its text), base64-encoded screen snapshots with their BLAKE3 hash, structured log fact arrays, or explicit `Awaiting_Principal_Approval` / `Refused` error objects;
- writes a snapshot to a host file only when the operator started it with `--snapshot-dir <folder>`: the file is `snapshot_<sequence>.png` or `snapshot_<sequence>.bgrx` in that folder, created new. A request names no path: the field `output_path` of an agent is not read.

**The snapshot folder.** At the start, the folder must exist and must not be a symbolic link; at each write, it is checked again, and the file is opened with create-new, so a link or a file planted at the next name is refused, never followed or overwritten. Without `--snapshot-dir`, the bridge writes no file.

## Refused forms

- **Terminal scraping or PTY forwarding.** Agents would parse rendered text instead of typed records and tables, breaking the rule that no process parses the text of another.
- **Self-approving `plans.apply` or grant dialogs through the bridge.** Even when an agent holds `Eval_Lex` and `Send_Input`, widening authority belongs exclusively to the principal on the trusted display or through a separate principal signing key.
- **Unscoped input injection.** Allowing `Send_Key` or `Send_Pointer` without an active `wide_grants.Wide_Grant_Terms` window list would let an agent type into any console or palette without explicit principal bounds.
- **Best-effort or post-hoc audit logging.** Recording an input act after delivery, or dropping records when the collector is full, would let an agent act without trace.
- **Untyped string commands or open integer status codes.** Every command kind, status, permission, refusal, and sensitive action is a closed explicit-value enum checked at one border.
- **A flag of the agent that says a call is safe.** The first form read `sensitive_action` and `plan_diff.any_grant_added` from the request: an agent that set them to `false` applied a plan with no principal. A caller never classifies its own call.
- **A denylist of dangerous names.** The first form scanned the line for names such as `plans.apply` and stopped at `#` or `--`. Lex has no such comment, so `# x` then a line end hid the call. A list of what may run fails closed for each export that is new or forgotten.
- **A path of the agent for the snapshot.** The first form wrote the snapshot to `output_path` of the request: an agent wrote any file that the host user can write.

## Subtle points

- **Host-side enforcement is defense in depth, not a replacement for machine enforcement.** On a running machine, `remote`, `remote_display`, the root service, and the collector independently enforce client keys, wide grants, trusted display isolation, and principal proof ([wide_grants.md](wide_grants.md), [declarations.md](declarations.md)). The host bridge enforces the same contract locally so a prompt-injected agent is stopped before sending unauthorized or self-approving calls.
- **A text of Lex has no escape.** It ends at the next quote. The parser of the bridge reads it the same way, so `"a\" plans.apply(1)` is a text, then a second call, and is refused. A parser that took `\"` as an escape would see one text and let the call through.
- **A bare name is no literal.** In Lex a name can be a command with no arguments; `monitor.count(lock)` would run `lock`. So an argument is a literal or a member `.name`, never a bare name.
- **Single-use window scope.** Window identifier `0` is always refused for input injection, even if other fields are valid.
- **Time monotonicity.** A clock value earlier than `wide_grant_created_ms` or at or past `wide_grant_expires_ms` refuses input, closing clock-skew and boundary expiry bugs.

## State

Built: the freestanding contract package `src/library/modus/contract/agent_bridge` (`"MODAB1"` binary framing, closed enums, `bridge_authorize_command`, the read-only list of `Eval_Lex`, and adversarial host tests), the host JSON-RPC stdio adapter `tools/modustool/agent_bridge` (pluggable `Machine_Transport`, real `remote` QUIC call transport adapter, append-only BLAKE3 act collector verification, and comprehensive host tests), and the CLI command `modustool agent-bridge`. Live `remote_display` frame/input streaming over the peer relay and end-to-end machine tests remain. The single-call path of `Eval_Lex` and its classifier are removed when the read-only agent console runs the lines of an agent.

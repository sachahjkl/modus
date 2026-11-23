# The assistant

A principal asks an agent for help from the desktop. The application `assistant` is a window where the principal types a request and reads the conversation: the replies of the agent, each act that the agent proposes, and its result. The agent itself, the agent runner, runs on the host: it reads each request through `remote`, asks a language model, and runs each proposed act only through the host agent bridge ([agent_bridge.md](agent_bridge.md)). The bridge stops each act that changes a grant or that is not on its read-only list, and the principal decides such an act on the trusted display only.

The terms Assistant, Agent runner, Model reply and Act dialog are in [`docs/glossary/access.md`](../../../docs/glossary/access.md). The guide is [`docs/ASSISTANT.md`](../../../docs/ASSISTANT.md).

## Purpose

- Give a principal an agent from the desktop, with no terminal and no second program on the host to watch.
- Show the principal each act that the agent proposes before its result, and the result after it, in one conversation.
- Keep each guarantee of the bridge: an act of the agent runs only through a capability of the bridge, a grant-adding or sensitive act stops with `Awaiting_Principal_Approval`, and the agent never answers a trusted surface.
- Keep the model, its endpoint and its key outside the system.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes". The window never parses a text of another process. The request, the reply and the result text are words for a person; they cross as Text fields that the window shows. Each fact that the window acts on is a typed value: a serial, an act number, an act state, the words of an error record.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close". The window draws no false system dialog: the act dialog is drawn by the trusted display, and shows names that the trusted display checks, never a word of the model.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users". The principal is the one source of a new grant. No act of the agent, no reply of the model and no call of the runner answers the act dialog.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default". The assistant holds a window, its exports, and a connection to the trusted display with the right to ask an act: no store, no network, no machine, and no grant to act for the principal.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "24. Every input of a process passes through a channel that can be recorded". A request comes from the keys of the window; a reply and an act come through calls of `remote`, each a record of its connection.
- The tool uses the Odin standard library only, and no secret is in the repository, in the system, or in a log.

## The chosen form

### Four parties

1. **The window**, the module `assistant` of the group `applications`, category `Application`. It is a window and a service in one process with one thread, as `paint`: its exports run between two events.
2. **The agent runner**, `modustool assistant` on the host. It calls the exports of the window through `remote` with a client key that the principal allowed ([remote_client_keys.md](remote_client_keys.md)).
3. **The model**: a language model behind an HTTP endpoint of the host, or the fake model of the tests, a script of replies.
4. **The bridge**: the host agent bridge, which runs each act of a model reply, with its authorization, its read-only list and its act records.

### The flow of one request

1. The principal types a request and presses Enter. The window keeps it with a serial, from 1.
2. The runner calls `assistant.request_serial()`: the serial of the oldest request that no runner took, or 0. Then `assistant.request_text(serial)`, which marks the request taken.
3. The runner gives the conversation to the model and reads its reply at the border of the model reply ("The model reply"). A refused reply goes to the window with `assistant.reply_refused(serial, …)`: the words of its error record. It ends the turn: no act of it comes.
4. A reply that passes: its text goes to the window with `assistant.reply(serial, text, acts)`, where `acts` is the count of its acts, 0 to 4. Each of its acts: `assistant.act(serial, kind, line, service, export)` gives the act number; the runner then gives the act to the bridge, and gives the outcome to the window with `assistant.act_result(act, state, text)`. The turn ends with the last act that the reply counted: the window refuses each later act of that request with `State`.
5. An act that the bridge stops with `Awaiting_Principal_Approval` has the state `Awaiting_Principal`. The window then asks the trusted display for the act dialog, and shows the decision of the principal when the trusted display gives it. If the trusted display refuses the dialog for a cause other than `Busy`, or the window has no connection to it, the act takes the final state `Not_Shown` and nothing runs: the window never asks again for an act that the trusted display cannot show.

### The exports of the window

Each export refuses a caller that does not act for the principal with `No_Grant`. The serials, the act numbers and the states are checked at the border of the export: a serial that no request has, an act number that no act has, a state word that names no member of `assistant.Act_State`, a text past its bound, a text that is not UTF-8 with no control byte, and a name that is not an identifier are refused with their error record, and change nothing.

| Export | What it does |
|---|---|
| `request_serial() -> Integer` | The serial of the oldest request not taken, or 0 |
| `request_text(serial) -> Text` | The text of the request, and marks it taken; a result too small for the text is refused and takes nothing |
| `reply(serial, text, acts) -> Integer` | The text of the reply to a taken request, and the count of its acts; once for each request |
| `reply_refused(serial, kind, unit, argument, value, limit) -> Integer` | A refused model reply: the words of its error record; it ends the turn |
| `act(serial, kind, line, service, export) -> Integer` | A proposed act of the reply, with its `Act_Kind` and the names of its one call; gives the act number |
| `act_result(act, state, text) -> Integer` | The outcome of the bridge for the act: `Done` with its result text, `Refused` with the refusal of the bridge, or `Awaiting_Principal` |
| `act_state(act) -> Integer` | The state of an act, which the runner reads after the decision of the principal |

The records, the enums and the bounds are the contract package `modus:contract/assistant`: a request of 240 bytes at most, a reply and a result of 1024 bytes at most, an act line of 200 bytes at most (the line of the bridge), 4 acts of one reply, 64 entries in the conversation of one run of the window.

**The names of an act are typed values of the runner.** The act dialog names the act as `service.export`. The runner takes the two names from the line with `lex_line_single_call` of the bridge contract, the parser that the bridge itself uses, and sends them as two Text arguments of `act`. The window checks that each is an identifier and never cuts the line itself (property 19). A line that is no single call, or whose names are no identifiers of the system (more than 31 bytes, an upper case letter, a leading `_`), has no names: the runner sends two empty texts. The bridge can still stop such a line for the principal, but the act dialog cannot show it: the runner then writes `Refused` with "the act names no export that the trusted display can show", and `act_result` refuses the state `Awaiting_Principal` for an act with no names.

### The model reply

The runner asks the model for one JSON object and reads it at one border, `model_reply_decode` of the tool, before any act runs:

```
{"text": "There are 12 processes.", "acts": [{"kind": "eval_lex", "line": "monitor.processes()"}]}
```

- `text` is a string of 1 to 1024 bytes, UTF-8 with no control byte but the line end, which the runner writes as a space: a Text that crosses to the window has no control byte.
- `acts` is an optional array of 0 to 4 acts. An act has `kind`, one of the names of `Act_Kind` (`eval_lex` today), and `line`, a string of 1 to 200 bytes.
- An unknown field, a missing field, a field of another type, a duplicated field, text after the object, or a reply that is not JSON is refused whole: no act of it runs and no text of it shows. The error record names the field: `Bad_Value`, `Too_Long`, `Empty` or `Absent`, with the unit `Bytes` or `Records`.
- The line of an act then passes the border of the bridge: `lex_line_classify` and `bridge_authorize_command`.

### The act dialog: a face of the trusted display for one act

An act that the bridge stops needs a decision of the principal on the trusted display. The trusted display has two dialogs today, and neither says what the principal decides here: the grant dialog of `powerbox_ask` gives Enter to Allow and gives no decision to the asker; the plan difference dialog names a plan and says "Accept plan". A dialog of the trusted path that names another thing than the decision misleads the principal, so the act dialog is a third face of the same dialog state:

- `compositor.act_ask(act)` shows "TRUSTED ACT", the asker, and the act. The asker is the name of the calling process, which the compositor reads from the caller of the connection: a process cannot name another asker. The act is `service.export`, two identifiers that the compositor checks: never the arguments, never a word of the model. It is drawn in the font of the cells, Paper Mono, as each text that a reader compares character by character ([`docs/FONTS.md`](../../../docs/FONTS.md), section 12.6).
- `compositor.act_poll(serial)` gives the decision: pending, allowed, refused or unknown, the members of `Plan_Display_Decision`. The decision goes to its asker only: the connection that asked, while it lasts. Another caller, a serial of a plan dialog, and the serial of a dialog that a later one replaced read unknown.
- `compositor.act_cancel(serial)` closes the act dialog of its asker with a refusal: the window calls it when the entry of the act leaves its ring, so the principal never decides an act that the window no longer shows.
- The trusted display closes an act dialog with a refusal when the connection of its asker ends, as when its process exits, or when its grant no longer names an asker of acts (`Act_Asker_Lost`).
- The act starts as the act of the plan difference dialog: the focus starts on Refuse, Enter acts on the button that has it, and Escape refuses at once. The act face is stricter on the focus. A key that moves the focus (Tab, an arrow) counts only after the arm time of 500 ms, and each move of the focus starts the arm time again: Tab then Enter at once never allows, as no key typed for a window allows. A press on the button that has no focus moves the focus only, under the same rule; a press on the button that has it acts after the arm time. One dialog of the trusted display shows at a time; the others refuse with `Busy`.

### The right to ask an act

The act dialog serves a caller with the right to ask an act, and a caller that acts for its principal. The assistant has no grant to act for the principal: with it, its connection to the trusted display would open each export that serves such a caller, `plan_diff_ask` with free text on the face of a plan, `revoke_grant`, `powerbox_ask`, the screen and the notifications. The right is the term `asks_acts` of the start grant set of the assistant. The root service writes it as the amount `plans_recipes.DISPLAY_AMOUNT_ACT_ASKER` of the grant of each connection of such a process to the holder of Display (`role_policy.display_caller_amount`), as it writes `DISPLAY_AMOUNT_PLANS_HOLDER` for the holder of Plans ([declarations.md](declarations.md), "The trusted display of a plan"). The display reads it with `plans_recipes.act_display_caller_allowed`. The amount opens `act_ask`, `act_poll` and `act_cancel` only: `plan_display_caller_allowed` reads the amount of the holder of Plans, a value that differs.

**An allowed act does not run yet.** The bridge never takes an approval from its caller ([agent_bridge.md](agent_bridge.md), "Refused forms"), and the runner is its caller. An allowed act runs only when the approval is bound to that one act and checked by a party that the agent cannot drive: an act record of a wide grant with the proof of the principal ([wide_grants.md](wide_grants.md)), run in an agent console. Until then the window shows "allowed; the act runs when the agent console of a wide grant runs it", and nothing runs. A refused act shows "refused by the principal", and nothing runs.

### The host configuration of the model

The runner reads two environment variables at its start, and nothing else:

- `MODUS_ASSISTANT_ENDPOINT`: `http://host:port/path` of a chat endpoint in the form of the OpenAI chat completions request. Plain HTTP only: the standard library of Odin has no TLS, so an endpoint on another machine is reached through a local proxy that the operator runs. A URL with `https`, with a user part, or with no port is refused at the start. The host must be a loopback address (`127.0.0.0/8`, `localhost`, `[::1]`): plain HTTP to another host sends the key in clear on the network. The option `--key-in-clear-off-host` names that risk and lifts the rule. A host with a byte that is not a letter, a digit, `.`, `-`, or the brackets and colons of an address of IPv6 is refused.
- `MODUS_ASSISTANT_KEY`, or the variable that `--key-variable NAME` names: the bearer key. A secret of the keyring of the host reaches the runner under its name as such a variable. The runner never prints it, never writes it to a file, and never sends it to the machine. A refusal names the variable, never its value. A key with a space or a control byte, a line end too, is refused: it would add a line to the head of the request.

One answer of the endpoint has one deadline of 120 seconds for the send and the receive together, and each send and each receive has the time that is left as its timeout. An endpoint that stalls is a `Model_Failed` turn: the window shows `No_Answer`. The connection to a loopback address is immediate; the connection to another host has the bound of the operating system, as the standard library gives no other.

### The conversation of the model

The runner keeps the conversation that the model reads: the last 16 requests with their replies and the outcomes of their acts; the oldest request leaves with all its turns. A request is a turn of the role `user`. A reply is a turn of the role `assistant` that holds its acts as `tool_calls`. The outcome of an act is a turn of the role `tool` with the identifier of its call: a result of the machine never speaks as the principal.

`--fake <file>` takes the replies from a script of the tests in place of the endpoint, and reads no variable.

## Refused forms

- **The model in the system.** The system has no TLS client and keeps no secret of a host, and a model would hold the key in a store of the principal. The runner keeps the model outside, as the bridge keeps the agent outside.
- **The window parses the model reply.** The window would read a text of another party and act on it (property 19). The runner decodes the reply on the host and sends typed values.
- **The runner sends its own calls through the bridge.** The calls of the runner to the window are fixed code of the tool, the same for each reply; the bridge stands between the model and the machine. A model reply never names an export of the window: an act line that names `assistant` is not on the read-only list, so the bridge stops it.
- **The grant dialog of `powerbox_ask` or the plan difference dialog for an act.** The first gives Enter to Allow and no decision to its asker; the second names a plan. A dialog that names another thing than the decision misleads the principal.
- **The grant `Acts_For_Principal` for the assistant.** One line, and the window would open each export of the trusted display that serves the principal, a grant much wider than one dialog.
- **The window cuts `service.export` from the line.** The window would read a text of another party and act on it (property 19). The runner sends the two names, taken by the parser of the bridge.
- **An act that asks the trusted display again after a refusal that is not `Busy`.** The refusal stays: the act would ask ten times a second forever, and hold back each act after it.
- **The act line or the text of the model on the trusted display.** Such words are a claim of the agent; the trusted display shows the asker and two identifiers that it checks.
- **An allowed act that the runner runs.** It is the self-approval that the bridge refuses: the runner would carry the approval as a claim.
- **The key in a file of the repository, in the command line, or in the log.** A command line is visible to each process of the host; an environment variable of one process is not.
- **HTTPS through a TLS library of C.** The tool uses the Odin standard library only.

## Subtle points

- **The serial of a request is taken once.** Two runners do not answer one request: `request_text` marks it taken, and `request_serial` gives only a request not taken.
- **Code in the font of the cells.** The window draws the line of an act and the result of an act that ran in Paper Mono, and the words that explain in B612: in B612 a parenthesis at 14 px reads as a bracket ([`docs/FONTS.md`](../../../docs/FONTS.md), section 12.6).
- **The window keeps 64 entries.** A request, a reply, a refusal and an act each take one; past 64 the oldest entry leaves the window, and a request whose entries left gets no new act: `act` refuses its serial with `Absent`. An act whose dialog shows when its entry leaves cancels that dialog with `act_cancel`.
- **The window bounds the acts of a turn.** `reply` counts the acts, at most `MODEL_ACT_CAPACITY`; `act` refuses an act past that count, an act before the reply, and an act after a refused reply, each with `State`. A second `reply` or `reply_refused` for one request is refused with `State`.
- **The text of a result is the text of the tool.** The runner writes the typed result of the bridge as words for the principal, at most 1024 bytes, with the cut mark of the system, "... and N bytes more", past them.
- **One act dialog at a time.** A second act that waits for the principal shows its dialog after the first one is decided; until then it shows "waiting for the trusted display". Only `Busy` makes it wait: each other refusal is final.
- **A machine test refuses only.** The step `Key_Again_Until` presses a key until a fact shows. It takes only `ret` and `esc`, which act on the first focus of a dialog, Refuse, and never move it; it fails at once on its fact `fails_on`. A test never allows an act or accepts a plan with repeated keys.

## State

Built: this design, the contract package `src/library/modus/contract/assistant` with host tests, the module `src/modules/applications/assistant`, the act dialog of the compositor (`act_ask` and `act_poll`, with the state in `src/library/internal/compositor/bar`), the command `modustool assistant` in `tools/modustool/agent_runner` with its border of the model reply, its HTTP client and its fake model, with host tests, and the machine test part `assistant`.

Left: an allowed act that runs in an agent console of a wide grant (`ROADMAP.md`); a tool of the model other than `eval_lex`: `read_log_facts`, `read_screen`, `send_key`; the conversation kept in a store of the principal.

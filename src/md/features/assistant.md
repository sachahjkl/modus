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
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default". The assistant holds a window, its exports, and a connection to the trusted display: no store, no network, no machine.
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
3. The runner gives the conversation to the model and reads its reply at the border of the model reply ("The model reply"). A refused reply goes to the window with `assistant.reply_refused(serial, …)`: the words of its error record.
4. A reply that passes: its text goes to the window with `assistant.reply(serial, text)`. Each of its acts: `assistant.act(serial, kind, line)` gives the act number; the runner then gives the act to the bridge, and gives the outcome to the window with `assistant.act_result(act, state, text)`.
5. An act that the bridge stops with `Awaiting_Principal_Approval` has the state `Awaiting_Principal`. The window then asks the trusted display for the act dialog, and shows the decision of the principal when the trusted display gives it.

### The exports of the window

Each export refuses a caller that does not act for the principal with `No_Grant`. The serials, the act numbers and the states are checked at the border of the export: a serial that no request has, an act number that no act has, a state word that names no member of `assistant.Act_State`, a text past its bound, and a text that is not UTF-8 with no control byte are refused with their error record, and change nothing.

| Export | What it does |
|---|---|
| `request_serial() -> Integer` | The serial of the oldest request not taken, or 0 |
| `request_text(serial) -> Text` | The text of the request, and marks it taken |
| `reply(serial, text) -> Integer` | The text of the reply to a taken request |
| `reply_refused(serial, kind, unit, argument, value, limit) -> Integer` | A refused model reply: the words of its error record |
| `act(serial, kind, line) -> Integer` | A proposed act of the reply, with its `Act_Kind`; gives the act number |
| `act_result(act, state, text) -> Integer` | The outcome of the bridge for the act: `Done` with its result text, `Refused` with the refusal of the bridge, or `Awaiting_Principal` |
| `act_state(act) -> Integer` | The state of an act, which the runner reads after the decision of the principal |

The records, the enums and the bounds are the contract package `modus:contract/assistant`: a request of 240 bytes at most, a reply and a result of 1024 bytes at most, an act line of 200 bytes at most (the line of the bridge), 64 entries in the conversation of one run of the window.

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

- `compositor.act_ask(act)` shows "TRUSTED ACT", the asker, and the act. The asker is the name of the calling process, which the compositor reads from the caller of the connection: a process cannot name another asker. The act is `service.export`, two identifiers that the compositor checks: never the arguments, never a word of the model.
- `compositor.act_poll(serial)` gives the decision: pending, allowed, refused or unknown, the members of `Plan_Display_Decision`.
- The act is the act of the plan difference dialog: the focus starts on Refuse, an act counts 500 ms after the dialog showed, Tab and the arrows move the focus, Enter acts on the button that has it, a press on a button acts on that button, and Escape refuses. One dialog of the trusted display shows at a time; the others refuse with `Busy`.

**An allowed act does not run yet.** The bridge never takes an approval from its caller ([agent_bridge.md](agent_bridge.md), "Refused forms"), and the runner is its caller. An allowed act runs only when the approval is bound to that one act and checked by a party that the agent cannot drive: an act record of a wide grant with the proof of the principal ([wide_grants.md](wide_grants.md)), run in an agent console. Until then the window shows "allowed; the act runs when the agent console of a wide grant runs it", and nothing runs. A refused act shows "refused by the principal", and nothing runs.

### The host configuration of the model

The runner reads two environment variables at its start, and nothing else:

- `MODUS_ASSISTANT_ENDPOINT`: `http://host:port/path` of a chat endpoint in the form of the OpenAI chat completions request. Plain HTTP only: the standard library of Odin has no TLS, so an endpoint on another machine is reached through a local proxy that the operator runs. A URL with `https`, with a user part, or with no port is refused at the start.
- `MODUS_ASSISTANT_KEY`, or the variable that `--key-variable NAME` names: the bearer key. A secret of the keyring of the host reaches the runner under its name as such a variable. The runner never prints it, never writes it to a file, and never sends it to the machine. A refusal names the variable, never its value.

`--fake <file>` takes the replies from a script of the tests in place of the endpoint, and reads no variable.

## Refused forms

- **The model in the system.** The system has no TLS client and keeps no secret of a host, and a model would hold the key in a store of the principal. The runner keeps the model outside, as the bridge keeps the agent outside.
- **The window parses the model reply.** The window would read a text of another party and act on it (property 19). The runner decodes the reply on the host and sends typed values.
- **The runner sends its own calls through the bridge.** The calls of the runner to the window are fixed code of the tool, the same for each reply; the bridge stands between the model and the machine. A model reply never names an export of the window: an act line that names `assistant` is not on the read-only list, so the bridge stops it.
- **The grant dialog of `powerbox_ask` or the plan difference dialog for an act.** The first gives Enter to Allow and no decision to its asker; the second names a plan. A dialog that names another thing than the decision misleads the principal.
- **The act line or the text of the model on the trusted display.** Such words are a claim of the agent; the trusted display shows the asker and two identifiers that it checks.
- **An allowed act that the runner runs.** It is the self-approval that the bridge refuses: the runner would carry the approval as a claim.
- **The key in a file of the repository, in the command line, or in the log.** A command line is visible to each process of the host; an environment variable of one process is not.
- **HTTPS through a TLS library of C.** The tool uses the Odin standard library only.

## Subtle points

- **The serial of a request is taken once.** Two runners do not answer one request: `request_text` marks it taken, and `request_serial` gives only a request not taken.
- **The window keeps 64 entries.** A request, a reply, a refusal and an act each take one; past 64 the oldest entry leaves the window, and a request whose entries left gets no new act: `act` refuses its serial with `Absent`.
- **The text of a result is the text of the tool.** The runner writes the typed result of the bridge as words for the principal, at most 1024 bytes, with the cut mark of the system, "... and N bytes more", past them.
- **One act dialog at a time.** A second act that waits for the principal shows its dialog after the first one is decided; until then it shows "waiting for the trusted display".

## State

Built: this design, the contract package `src/library/modus/contract/assistant` with host tests, the module `src/modules/applications/assistant`, the act dialog of the compositor (`act_ask` and `act_poll`, with the state in `src/library/internal/compositor/bar`), the command `modustool assistant` in `tools/modustool/agent_runner` with its border of the model reply, its HTTP client and its fake model, with host tests, and the machine test part `assistant`.

Left: an allowed act that runs in an agent console of a wide grant (`ROADMAP.md`); a tool of the model other than `eval_lex`: `read_log_facts`, `read_screen`, `send_key`; the conversation kept in a store of the principal.

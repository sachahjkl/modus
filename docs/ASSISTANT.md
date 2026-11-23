# The assistant: an agent from the desktop

The assistant is a window where a principal asks an agent for help. The agent runs on the host, reads each request, asks a language model, and proposes acts. Each act runs only through the host agent bridge, and an act that changes what may happen waits for the principal on the trusted display.

## About this guide

**The idea in plain words.** You type a request in the window `assistant`. A program on the host, the agent runner, reads it, asks a model, and sends back a reply and the acts that the model proposes. The window shows each act before its result. An act that only reads runs at once. An act that would change a grant or that is not on the read-only list of the bridge stops, and the trusted display asks you; the agent never answers for you.

**For whom.** A principal who wants help from an agent, an operator who runs the agent runner on the host, and a developer who works on `src/modules/applications/assistant` or `tools/modustool/agent_runner`.

**Read before.** `docs/PROPERTIES.md`, "21. Principals: who acts, without users". The terms Assistant, Agent runner, Model reply, Act dialog and Wide grant are in `docs/glossary/access.md`. The design is `src/md/features/assistant.md`, and the bridge is `src/md/features/agent_bridge.md`.

## 1. Start it

1. Allow the key of the client of the runner in the console: `remote_allow("<client key>")` (`docs/PRINCIPALS.md`, "The client keys of remote").
2. Start the window from the start menu, or with `start("assistant")` in the console.
3. On the host, start the agent runner (section 3).
4. Type a request in the field at the foot of the window, and press Enter.

## 2. What the window shows

Each entry has a label and words:

| Label | Words |
|---|---|
| `you, request N` | The request that you typed |
| `assistant` | The reply of the model |
| `act N, proposed` | A line of Lex that the model proposes; the bridge has not answered yet |
| `act N, done` | The line, and its result. A table shows as the console shows it: a line of heads, aligned columns with each number at the right and the unit of a size or a time in its head, the rows that fit the window (8 at most), then how many rows are not shown and how many rows the table has. A row is one line: the columns that the width holds show in their order, and one line names the others, "8 columns more: handles_peak, mappings, ...". A record shows one line for each field, its name and its value. A row holds 256 bytes: past them the widest cells end with "... and N bytes more", or the last columns are not shown, and a line says how many |
| `act N, refused by the bridge` | The line, and why the bridge refused it |
| `act N, waiting for the principal` | The line; the act dialog of the trusted display asks you |
| `act N, refused by the principal` | You refused it: nothing ran |
| `act N, allowed by the principal` | You allowed it once. It does not run yet: an allowed act runs only in the agent console of a wide grant |
| `act N, not shown by the trusted display` | The trusted display refused its act dialog, or the window has no connection to it: nothing ran, and the window does not ask again |
| `the reply to request N was refused at the border` | The words of the error record of the reply; no act of it runs |

The window keeps 64 entries; past them the oldest leaves. The conversation ends with the window.

## 3. The agent runner on the host

```
MODUS_ASSISTANT_ENDPOINT=http://127.0.0.1:8080/v1/chat/completions \
MODUS_ASSISTANT_KEY=... \
modustool assistant --remote-key <key of remote> --client-key <key of the client>
```

- **The endpoint** is plain HTTP of the chat completions form, in `MODUS_ASSISTANT_ENDPOINT`. The tool has no TLS: a model behind HTTPS is reached through a local proxy. `MODUS_ASSISTANT_MODEL` names the model; the default is `default`.
- **The endpoint is this machine**: `127.0.0.0/8`, `localhost` or `[::1]`. Plain HTTP to another host carries the key in clear on the network; `--key-in-clear-off-host` accepts that risk.
- **The key** is in `MODUS_ASSISTANT_KEY`, or in the variable that `--key-variable NAME` names: a secret of the keyring of the host comes in a variable of its name. The runner never prints it, never writes it, and never sends it to the machine. A key with a space, a line end or another control byte is refused at the start.
- **One answer of the model has 120 seconds**, the send and the receive together. An endpoint that stalls fails the request: the window shows `No_Answer`.
- **The model reads the last 16 requests**, with their replies and the outcome of each act. An outcome has the role `tool`: a result of the machine never speaks as you.
- **`--fake <script>`** takes the replies from a file, one reply on each line, and reads no variable: the tests run so.
- **`--once`** answers one request, or none, then stops.
- The runner prints one line for each request: `request N answered, K acts`, then one line for each act with its state.

## 4. The model reply

The model replies with one JSON object:

```
{"text": "There are 12 processes.", "acts": [{"kind": "eval_lex", "line": "monitor.processes()"}]}
```

- `text`: 1 to 1024 bytes; a line end becomes a space.
- `acts`: 0 to 4 acts. `kind` is `eval_lex`; `line` is one call of Lex, `service.export(arguments)` with literal arguments, 1 to 200 bytes.

Any other form is refused whole, and the window shows its error record:

| Argument | Field |
|---|---|
| 0 | The reply as a whole: no JSON, an unknown field, text after the object |
| 1 | `text` |
| 2 | `acts`, or an act as a whole |
| 3 | `kind` |
| 4 | `line` |

The kind is `Bad_Value`, `Too_Long`, `Empty` or `Absent`; `found` is the number of the act, from 1. A model that gives no reply shows `No_Answer`.

## 5. The act dialog

An act that the bridge stops shows "TRUSTED ACT" on the trusted display: the asker, `assistant`, and the act, `service.export`, never its arguments and never a word of the model. The runner takes the two names with the parser of the bridge. While the dialog shows, no window gets a key or a press.

- The focus starts on Refuse. Enter acts on the button that has the focus, 500 ms after the dialog showed. Escape refuses at any time.
- Tab moves the focus to "Allow once" only 500 ms after the dialog showed, and each move starts the 500 ms again. Tab then Enter typed at once never allows.
- A press on the button that has no focus moves the focus only; a second press, 500 ms later, acts.
- The dialog closes with a refusal when the window that asked exits, or when its entry leaves the window.

The exports `compositor.act_ask(act)`, `compositor.act_poll(serial)` and `compositor.act_cancel(serial)` show the dialog, give its decision to the connection that asked, and close it. They serve a process with the right to ask an act, as the assistant, and a process that acts for the principal (`docs/CONSOLE.md`, "The built-in commands and the services"). The assistant has the right to ask an act and no grant to act for the principal.

## 6. The exports of the window

The runner calls them through `remote`; each refuses a caller that does not act for the principal.

| Export | What it does |
|---|---|
| `assistant.request_serial()` | The serial of the oldest request that no runner took, or 0 |
| `assistant.request_text(serial)` | Its text; the request is then taken. A result too small for the text is refused, and the request is not taken |
| `assistant.reply(serial, text, acts)` | The reply of the model and the count of its acts, 0 to 4; once for each request |
| `assistant.reply_refused(serial, kind, unit, argument, value, limit)` | A reply refused at the border of the runner; no act of it comes |
| `assistant.act(serial, kind, line, service, export)` | A proposed act, with the names of its one call, or two empty texts for a line that is no single call; gives its number. An act past the count of the reply is refused with `State` |
| `assistant.act_result(act, state, text)` | The answer of the bridge: 2 done, 3 refused, 4 waiting for the principal |
| `assistant.act_table(act, shape, name, total_rows, columns, cells)` | The typed result of a done act: its columns, and its first 8 rows, cell after cell. A table that is not whole is refused, and the act keeps its words |
| `assistant.act_state(act)` | The state of an act: 5 allowed or 6 refused by the principal once you decided, 7 not shown by the trusted display |

The runner cannot write the states 5, 6 and 7: `act_result` refuses them with `Bad_Value`.

## 7. The tests

The machine test part `assistant` (`docs/TOOLS.md`, "The parts of the machine test") runs the runner with a fake model: a reply with an act that reads, a grant-adding act that you refuse in the act dialog, and a malformed reply. The step that decides the act dialog presses only Enter or Escape, which refuse; a test never allows an act with repeated keys. The host tests of `tools/modustool/agent_runner`, `src/library/modus/contract/assistant`, `src/library/internal/assistant/conversation` and `src/library/internal/compositor/bar` give each refused form.

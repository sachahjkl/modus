# The agent loop: lines of Lex that an agent composes, step by step

An agent that does real work for the principal does not answer with one call. It finds what the system can do, reads the state, acts, reads the state again, and goes on until the task is done. This file decides the form of that work: each agent step is a list of console lines of Lex that the agent writes; an agent console runs them in the session of the principal and gives their typed results back; the agent then writes the next step, until it gives its final answer. The agent loop is the series of these steps for one request of the principal.

The terms Agent step and Agent loop are in [`docs/glossary/access.md`](../../../docs/glossary/access.md). The agent console and the wide grant are designed in [wide_grants.md](wide_grants.md); the host bridge in [agent_bridge.md](agent_bridge.md).

## Purpose

- An agent does a task of several acts: it reads the log, stops a process, changes a store, builds a project and runs its tests, and checks each result before the next act.
- An agent composes calls in one step: it binds a result to a name, filters a table, and passes a value to the next call, with no round trip to the model for each call.
- An agent finds the services and the exports of the system from their descriptions, so a new module is a new capability of the agent with no change of its instructions.
- The principal reads, during the work and after it, each line that ran, its result, and each act that waited for an answer.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes". No process parses a text that another process produced. A result is a typed value.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task". The console and Lex are the general mechanism of composition. A second language beside them is a second mechanism.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "12. Module metadata in flat tables, read through functions". What the agent can call comes from the descriptions of the modules, read through functions.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default", and "20. No ambient access: the other holes to close". The agent reaches only the handles of its agent console.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users". The principal is the one source of a new grant. No line, no result and no answer of the model answers a trusted surface.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "24. Every input of a process passes through a channel that can be recorded". The lines reach the agent console through a ring.
- No act without its record ([wide_grants.md](wide_grants.md), "The record of each act").

## The chosen form

### The language of a step: Lex, run by an agent console

An agent step is an ordered list of 1 to `AGENT_STEP_LINE_CAPACITY` (16) console lines. Each line is a line of the console as the principal types it ([`docs/LEX.md`](../../../docs/LEX.md), "1. What Lex is: one language, two evaluation modes"): one expression, or `name = expression`, at most 200 bytes, evaluated in mode `console`. A name that a line binds is a variable of the agent console: later lines of the step and later steps of the same request read it. A new request clears the variables.

```
failed = log.records(0) |> facts(storage.Bad_Block)
failed |> rows
failed |> columns(time, block) |> first(5)
```

The parser and the evaluator are the ones of the console, `modus:lex_parser` and `modus:lex_evaluator`: no second parser, no second evaluator, no second command table.

**Why lines and not one long expression.** A line is the unit that the console already runs, records and draws. Each line gets its own result, its own error record and its own act record, so the principal reads which line did what, and the model reads which line failed. `let ... in` stays available inside one line.

**How the text reaches the one evaluator.** The lines are text, and Lex text has one kind of reader in the system: a console. The console of the principal reads the text that the principal typed, which the terminal carries as characters and never reads. An agent console reads the text that the agent wrote, which `remote` carries and never reads:

1. The runner of the agent on the host sends the lines of a step to `remote` over the connection of its client key, as one typed record: the request serial, the step serial, and a table of line records, each a Text field.
2. `remote` checks each Text at the text border (UTF-8 with no control character, at most 200 bytes) and the count of lines, and writes the records into the line ring of the agent console of that key. It reads no Lex.
3. The agent console takes the lines in order, parses and runs each one, and writes for each line a typed result record on its result ring: the kind of the value, a table or a record with its record description and its rows, or the error record of the failure.
4. `remote` gives the result records to the runner as typed values. The runner reads each table with its description, as the console draws it.

So property 19 holds: the author of the lines is the agent, outside every process of the system, as the principal is the author of its lines; no process of the system writes Lex for another process to parse. Only `remote` can write the line ring of an agent console, and only for the connection of its key. The agent console has no export that evaluates a text, and Lex has no command that evaluates a text: a result never becomes a line.

**The rule "no export evaluates a line for another process".** Lines reach a console only through a ring that one carrier writes and never reads: the terminal for the keys of the principal, `remote` for the lines of an agent. A console reads that ring as its own input; it serves no export that takes a text to evaluate. This is the reading of the rule wherever the rule is stated, the entry "Console lines kept and run again, as scripts" of `ROADMAP.md` too.

### Where a step runs, and what it reaches

A step runs in the agent console of the client key of the agent, a process in the session of the principal. The model and the runner stay on the host: they send lines and read typed results, and hold no handle of the machine.

The agent console has two reaches, each its start grant set:

| Reach | When | What its start grant set holds |
|---|---|---|
| Read-only | A client key with the use `Calls` and no wide grant | Connections to the services of the read-only list of the bridge ([agent_bridge.md](agent_bridge.md), "The read-only list"). Its call border refuses each export that is not on the list, and each built-in command that changes a state (`start`, `stop`, `load`, `isolate`, `revoke`) |
| Wide | A wide grant with the scope `Console_Lines` | The union of the wide scopes that the principal kept ([wide_grants.md](wide_grants.md), "The wide scopes") |

**The read-only reach needs no proof of the principal.** It widens nothing: a key with `Calls` already reaches the read-only list through the bridge. The reach moves from a classifier on the host to a check on the machine at each call, which is stricter: the host can no longer be the only party that decides.

At a wide grant, the root service stops the read-only agent console of the key and starts the wide one; at the end of the grant it stops the wide one. A change of reach is a new process with a new start grant set, never a change of a running one, so each variable of the old reach ends with it.

The read-only list moves from the host to the machine: the call border of the agent console checks it, on each call that a line makes, `map` and nested calls too. The classifier of single lines on the host (`lex_line_classify`) then has no use and goes: the host never decides what a line reaches.

**A call outside the reach.** A call that no handle of the agent console serves fails at once with the error record `No_Grant`, which names the missing wide scope. The trusted display shows nothing for it. The reason: the principal left that scope out when it gave the grant; a question for each call outside it would make the agent a source of grant requests, and train the principal to accept them. The agent console makes no grant request of the powerbox.

**A call that asks.** Two kinds of call wait for the principal, inside the reach:

- a call of a scope that the principal set to "asks each time" waits for the grant dialog of that one act ([wide_grants.md](wide_grants.md), "Acts that still ask");
- an `Apply` whose difference adds a grant waits for the proof of the principal on the screen of the difference.

The step waits at that call; it does not end. If the principal allows, the call runs and the line goes on. If the principal refuses, or the dialog ends with no answer, the call fails with its error record, and the step ends there. The reason the step waits: a step that ended at the call would make the model send it again, and the lines before the call would run twice, with their effects twice. The wait counts in no bound of the step but its own: the time of the dialog.

**The bounds of one step.** Each bound ends the step with its own error record, on the line where it was reached, and the lines after it do not run:

| Bound | Value | What it stops |
|---|---|---|
| Lines | `AGENT_STEP_LINE_CAPACITY`, 16 | A step of more lines is refused whole at the border of `remote`, before any line runs |
| Bytes of a line | 200, the bound of a console line | Refused whole at the border of `remote` |
| Evaluation steps | The evaluation budget of a console line, for each line | A recursion with no base case |
| Calls of exports | `AGENT_STEP_CALL_CAPACITY`, 64, for the whole step | A `map` over a long list of calls |
| Time | `AGENT_STEP_TIME_BOUND`, 60 seconds on the clock of the system, without the waits for the principal | A call that does not answer; checked at each call and at each check of the evaluation budget |
| Memory | The stated budget of the agent console; the pools of the evaluator are fixed | `Pool_Exhausted`, never a growth |
| Result | 64 rows and 24 columns for each line, 16 KiB for the step; `total_rows` counts the rest | The size that the model reads |

The values are starting values, to measure on real tasks ("State"). A test of a bound checks the refusal: the host test of the step state drives its clock and its counts, and never measures a speed. A time in a machine test of a step only ends a hang (the hang bound).

**One step at a time.** The agent console runs one step at a time. A step that arrives while one runs is refused with `Busy` at the border of `remote`.

### Discovery: the capabilities of the agent are the descriptions of the modules

The agent does not get a list of capabilities written for it. It gets one, the step, and finds the rest with lines:

- `help()`: the table of the commands that the agent console can call, each with one line of help, from the descriptions of the modules of its reach and the built-in commands of the console. A service out of the reach is not in it.
- `describe(name)`: the signature and the whole help of one command, or a short guide of a word of Lex.
- The exports of `manual` that read module metadata, `manual.modules()`, `manual.exports(name)` and `manual.signature(name, n)` (the export numbered `n` from 1), which are on the read-only list. Before the agent console, in the first layer, they are the whole of discovery: the instructions of the runner tell the model to call them, and name no service.

A new module with a described export is a new command of the agent at its first start, with no change of the instructions of the runner. The instructions of the runner hold the form of a step, the grammar of Lex, and the rule to call `help()` first; they name no service.

**The size that the model reads is bounded.** `help()` gives one row of 2 fields for each command; the result bound of a step cuts it with a count of the rows not shown, and `help() |> where(...)` narrows it. The whole text of one command comes only from `describe(name)`.

### The loop

One request of the principal becomes an agent loop:

1. The runner gives the model the request, the instructions, and the steps of the request so far.
2. The model answers with a step (a call of its one function, `run`, with the list of lines) or with a final answer (a text and no call). The runner reads the answer at the border of the model reply on the host. A step goes to the agent console; a final answer ends the loop.
3. The typed results of the step go back to the model in the role `tool`, and the loop goes on at 1.

The loop ends at the first of these:

- a final answer of the model;
- `AGENT_LOOP_STEP_CAPACITY`, 16 steps for one request: the runner tells the window, and the model gets no step more;
- a stop of the principal in the window, which the runner reads before each step;
- a step whose lines and results are equal to those of the step before: the agent repeats itself, and the loop ends with that cause;
- the end of the wide grant, a revocation, or a failure of the model.

Each end has its cause, a member of `Agent_Loop_End`, that the window shows once.

The states of a step are a closed set: `Sent`, `Running`, `Waiting_For_Principal`, then one end, `Done`, `Failed` (a line failed), or `Stopped` (a bound, the principal, the revocation). `Waiting_For_Principal` goes back to `Running` only on an answer of the trusted display.

### What the window shows

The window of the agent shows each step once, as a block in the conversation, under the request:

- the lines in the font of the cells, each colored as the console colors code;
- under each line, its result, drawn by the drawers of the console: a table with its heads and aligned columns, a record, a value, or the error record of the failure;
- on the line of a call that waited, its state and the decision of the principal: never a second list of the acts.

The step number and its end cause are in the head of the block, once. The block of a step that is not the last one shows its lines and folds its results; a press opens them. The final answer comes last, as text.

### The capabilities beyond the calls

Each capability is a typed command that a line calls, reached through a handle that one wide scope gives. None is a second path beside the lines.

| Capability | Scope | The command, and how it crosses |
|---|---|---|
| The screen | `Screen_View` | `screen.view()` asks the trusted display for one frame for the key and gives a typed record: the frame serial, the size, the BLAKE3 hash. The pixels cross through the use `View` of the key ([remote_display.md](remote_display.md)), never as a Lex value. The runner takes the frame of that serial, checks its hash, scales it to the bound of the model, and gives it with the result of the step: one picture for each step at most |
| The windows | `Screen_View` | `compositor.windows()`, a table of the windows with their process and their place |
| Keys and the pointer | `Input` | `input.type_text(window, text)`, `input.press(window, key)`, `input.point(window, x, y, buttons)`, served by the input face of the trusted display, which drops each record for a window outside the place bound. `compositor.presented(window, after)` waits for the next frame of the window, so a line waits for a state and never for a fixed delay |
| The log | `Log_Read` | `log.records`, `facts`, `where` ([log_facts.md](log_facts.md)) |
| Processes | `Processes` | `processes()`, `start`, `stop` for the processes picked |
| Stores | `Stores` | The exports of the storage service over the shares picked, each read-only unless `Change` was kept |
| Plans | none more | `plans.difference(p)` reads; `plans.apply(p)` waits for the proof when it adds a grant |
| Edit, build, run | `Stores` with `Change` on the store of the project, and `Processes` | The commands of the projects and of the recipes: read a source, replace one exact text in a source, `recipes.build(kernel.tools)`, start the built output, read its log and its stop report |

**The frequent tasks of the agent** (property 22), each one line:

| Task | Line |
|---|---|
| What can I call | `help()` |
| How do I call it | `describe("log.records")` |
| The bad blocks of the disk | `log.records(0) \|> facts(storage.Bad_Block)` |
| The largest processes | `processes() \|> sort("resident") \|> columns(name, resident)` |
| See the screen | `screen.view()` |
| Type into a window, then wait for it | `input.type_text(notes, "done")`, then `compositor.presented(notes, after = frame)` |
| What a plan changes | `plans.difference(system)` |
| Build the tools of a project | `recipes.build(kernel.tools)` |

The names of `screen`, `input` and the source commands of a project are proposals: the intent file of the layer of the screen and the input, and the layer of edit, build, run, fix them.

### The records

Each step and each call is an act record of the agent console ([wide_grants.md](wide_grants.md), "The record of each act"), written before it runs:

- **The step**: the request serial, the step serial, the count of lines, and the BLAKE3 hash of the lines. The text of the lines goes whole to the collector in the body region of the record output, so `acts(key)` shows the lines that ran, as the agent wrote them.
- **Each line**: its number, before it runs; then the kind of its result or its error record, when it ends.
- **Each call of an export**: the service, the export and the hash of the arguments. A line with `map` makes many calls, and the line alone does not say which ran.
- **Each wait**: the act that waited, and the answer of the principal.

A full ring refuses the step or the call with `Busy`, as each writer of act records does. The read-only agent console writes the same records: what an agent read is a fact that the principal reads afterwards too.

## Refused forms

- **JavaScript, Python or another language of the host as the language of a step.** A second language with a second evaluator beside Lex is a second mechanism of composition (property 22). Its interpreter would run on the machine as a large process with its own types, or on the host, where it would see the calls only as text. Lex already composes typed calls, binds names, filters tables, and reaches each export from its description.
- **A JSON list of calls as the step.** Each call would need its own round trip to the model, no result could feed a call except through the model, and the list would grow names, conditions and loops until it is a second language written in JSON.
- **The evaluation on the host.** The runner would run the evaluator and send single typed calls. The reach would then be a list that the host enforces, the variables would live outside the session, and the act records would not see a line. The agent console on the machine enforces the reach with its handles.
- **An export of the agent console that evaluates a line, or a Lex command `eval`.** A process of the system could then make another process parse its text, and a result could become a line. Only the line ring carries lines, and only `remote` writes it, for one key.
- **A grant dialog for a call outside the reach.** It makes the agent a source of grant requests. A wider reach is a new wide grant, shown whole, with the proof.
- **The step ends at a call that asks.** The model would send the step again, and the lines before the call would run twice.
- **The pixels of the screen as a Lex value.** A `Bytes` value is never stored in a variable, the result bound would cut it, and the window would draw it as numbers. The record names the frame; the pixels cross through `View`.
- **A pause of fixed length in a step.** A step waits for a fact: a frame presented, a fact of the log, the end of a process.

## Subtle points

- **Data never speaks as the principal.** A text in a store, a line of the log or a window on the screen can hold instructions for the model. The result of a step goes to the model in the role `tool`, as data, and the request of the principal is the only text in the role `user`. The system cannot stop a model from following an instruction in data; it bounds what a turned agent can do: the reach, "asks each time", the proof for a grant, the step bound, the time bound of the grant, the mark, and the act records.
- **A line cannot answer the trusted display.** The agent console holds no connection to a face that answers a dialog, and the input face never reaches a trusted surface. `input.press(window, .Enter)` on a dialog is dropped and counted.
- **The model asks for no wider grant from the loop.** A line refused with `No_Grant` names the missing scope; the model then ends the loop with a final answer that says what it needs. The runner proposes no wide grant during a loop: the principal opens the screen with `agent_allow` if it wants. So a turned loop cannot fill the screen with grant requests, and the limits of the wide grant screen ([wide_grants.md](wide_grants.md), "Security") stay the second line.
- **A runaway loop.** The step bound, the repeat check and the time bound of each step end it, and the stop of the principal ends it at the next step. The step that runs ends at its own time bound.
- **The variables end with the reach.** A wide grant, its end and a new request each start the agent console again or clear its variables, so a name never carries a handle across a change of reach.
- **The result is a table, not a sentence.** The model reads a table as its description and rows, and the window draws the same rows with the drawers of the console: the model and the principal read one fact in two forms of the same value.
- **Code in the font of the cells.** The window draws the lines and the results in Paper Mono ([`docs/FONTS.md`](../../../docs/FONTS.md), section 12.6).

## Prior art

- **Code Mode of Cloudflare, and the agents that write code to call their functions**: the model writes a short text of code that composes typed calls in a sandbox, in place of one call for each round trip. Taken: the composition in one step, the typed results, the discovery from the interfaces. Refused: TypeScript as the language and a separate sandbox; here the console and Lex already are both.
- **CodeAct**: acts as code, in a loop of observe and act. Taken: the loop with a step bound. Refused: Python with a whole interpreter.
- **PowerShell and Nushell**: typed tables between commands, which the model reads as rows and not as text.

## The order of the work

1. **The loop and discovery, single calls.** The runner sends several steps for one request; each line of a step is one call of the read-only list through the bridge, as today; `manual.modules`, `manual.exports` and `manual.signature` join the read-only list; the window shows each step.
2. **Lines with names, read only, in an agent console.** The read-only agent console, the line ring and the result ring through `remote`, the read-only list checked at its call border, the act records of a step, the bounds of a step. The classifier of the bridge goes, and so does the path of `Eval_Lex` for single calls: a key with `Calls` and no wide grant sends its lines to its read-only agent console, as every agent does. One mechanism runs the lines of an agent (property 22), and nothing stays for compatibility before 1.0.
3. **The wide reach.** The agent console of a wide grant runs the steps with real effects, with the waits of "asks each time" and of the proof. This is the work of [wide_grants.md](wide_grants.md), "The order of the work", items 2 to 4, with the lines of a step as its input.
4. **The screen, the keys and the pointer, and the log**, as commands of the lines. This layer gets its own intent file, which fixes the names of the commands of the screen and of the input, and decides whether an agent reads the semantic tree of a window ([accessibility.md](accessibility.md)) and under which scope.
5. **Edit, build, run**: the source commands of a project, and the build and the run of its outputs, driven by the agent.

Why this order: each layer gives a working loop; the reach grows only after the bounds and the records that hold it.

## State

The first layer is built: the runner runs up to 16 steps of up to 16 single calls of the read-only list for one request, through the bridge; `manual.modules`, `manual.exports` and `manual.signature` are on the read-only list, and the instructions of the runner name no service; the window shows each step once, folds the results of the older steps, and stops the loop with Stop or Escape through the export `stop_requested`; each end of the loop is a member of `Agent_Loop_End`, which the window shows with `loop_end`. The design of the first layer as built is in [assistant.md](assistant.md), "The agent loop". Left: the layers 2 to 5.

In the first layer a step is the acts of one model reply, not lines of an agent console: the repeat check compares the acts of two steps, not their results, because a single call has no name to bind, and the results of one step can differ for the same acts.

Open:

- the values of the bounds of a step and of the loop: starting values, to measure on real tasks;
- the names of the commands of the screen, of the input and of the sources of a project, and whether an agent reads the semantic tree of a window: decided in the intent file of the fourth layer, and of the fifth for the sources.

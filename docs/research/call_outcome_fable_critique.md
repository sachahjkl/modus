# The outcome of a call: a critique of the proposed intent

This file reads [`call_outcome_study.md`](call_outcome_study.md) and the proposed intent [`src/md/api/call_outcome.md`](../../src/md/api/call_outcome.md) against the independent study [`call_outcome_fable.md`](call_outcome_fable.md). It names the faults that it finds, then the points of agreement, the points of disagreement, and one joint recommendation.

The two studies agree on the placement: the outcome first, in `rax` or `x0`, then the value. Both measured it with the compilers of the flake. The disagreement is about what the closed word means and how it grows.

## 1. Which axis the closed word carries

Two axes exist.

- **The effect**: what the caller knows about the state after the call. The independent study froze five members on this axis.
- **The action**: what the caller does next. The intent takes twelve members on this axis, after gRPC.

The intent is right on one point that the independent study missed. The kernel decides a refusal where the operation fails, and explains it later, under other locks. The explanation can degrade to `Refused`. If the word carries the effect only, a degraded record loses "a budget is short" against "an argument is wrong". The class must therefore be decided with the failure, and it belongs in the word. The frequent tasks also read better: `if outcome == .Absent` is one comparison, with no read of the record.

The intent is wrong to treat the two axes as one. Its word carries both: nine members promise "nothing changed", and three do not. The effect is the axis that generic code needs (a relay, a retry, a replay, a test), and the intent gives it no name. A reader gets it only from a sentence: "each member except `In_Doubt` and `Bad_Answer` is a refusal".

The two axes also differ in kind. The members of the effect axis exclude each other, and a test can check them ("nothing changed"). The members of the action axis overlap, and no test can check them. gRPC documents this overlap itself, with a litmus test for `FAILED_PRECONDITION`, `ABORTED` and `UNAVAILABLE`.

**Conclusion: both, in one word.** The word is the action class. The effect is a total function of the word, with a name and a frozen set of its own.

## 2. Five faults of the twelve members

### 2.1 No member for a failure that the callee knows and that changed something

The intent gives three ways out for a callee whose work stops half way: a success with a status for each row, a refusal, or `In_Doubt`. None fits these cases.

- **A change that is not a batch.** An export applies four of seven steps, and the fifth meets a full disk. It has no row to hold a status. A refusal breaks the promise. `In_Doubt` says "the caller cannot know", and the callee knows exactly.
- **A table in a lent memory object.** [`docs/MODULE_CONTRACT.md`](../MODULE_CONTRACT.md), "Tables and bytes as parameters", states that such a table "keeps what the callee wrote before it failed". So a refusal of today already changes bytes that the caller sees.
- **A stream.** A reader received 900 records, then a block fails its check. No refusal member is honest: the caller saw records.

A success that hides a failure in its value is the `S_FALSE` of HRESULT, which both studies refuse. So the set needs one more member: the work started, it did not finish, and the description of the export states what holds.

### 2.2 `or_return` breaks the promise

The intent lists this frequent task: "Give the failure to my own caller: `size := storage.size(name, &error) or_return`". It is sound only when the outer export changed nothing before the inner call.

An export writes its own state, then calls a service that answers `Exhausted`. The service changed nothing. The export passes `Exhausted` on. Its caller now reads "nothing changed", and that is false. The most natural line of Odin gives the fault, and no check of the tool sees it.

The rule that is missing: **a border or an export can weaken an outcome, and never strengthen it.** An export passes a refusal on only when it changed nothing itself. Else it gives the member of 2.1, and the record of its callee goes in the table of error details.

### 2.3 `Invalid` is defined by a test that the kernel fails

`Invalid` means "the same call fails again in each state". The intent puts `Bad_Address` and `Handle_Ended` under it. In a system of handles, most arguments name state: an address is valid after a map, and a handle number names an object after a gift. The kernel statuses `Bad_Handle` and `Bad_Address` are the most frequent refusals of the system, and they do not pass the test of their member.

The same blur is between `Unavailable` and `In_Doubt` for a device. `Unavailable` promises that the call did not run. A device that fails during a write ran a part of it. The storage service already has the kind `Device` with the unit `Dropped_Writes` for that case.

The members need ordered tests, as gRPC gives them, and the definition of `Invalid` must lose "in each state".

### 2.4 Twelve members cannot be called frozen today

gRPC kept 17 codes for about ten years. Three facts make the comparison weaker than it looks.

- gRPC has `UNKNOWN` and `INTERNAL` as its escape. The intent refuses both, rightly, so its set has no slack.
- The intent itself asks, in its open questions, whether to split `Exhausted` and `In_Doubt`. A set with open splits is not frozen.
- Candidates for a member 13 already exist in the repository. A change that lost a race (the unit `Pending`, "another change came first") is the `ABORTED` of gRPC: the action is "read again and do the sequence again". The intent folds it into `Bad_State`, whose action is "change the state first". The agent bridge has "waits for the approval of the principal", whose action is "ask, then call again". A holder of a role that moved to another machine is a third.

The action axis is the axis that grows. The effect axis is not.

### 2.5 What an older caller does with a member 13

The intent gives `Bad_Answer`: "the answer breaks its contract; trust nothing". It is safe, and it is wrong twice.

- **It blames the callee.** The callee kept its contract; the caller is old. The sentence on the log names a fault that does not exist.
- **It loses the promise.** A new refusal member reaches the old caller as "treat the call as in doubt". The old caller then reads the state again for a call that changed nothing.

No encoding repairs this at the reader: a word that the reader does not know can also come from a broken callee, so the reader cannot trust it as a refusal. The repair is at the writer and in the rule of growth:

- The effect groups are frozen. A new member joins the group "nothing changed" only, and names the older member that it refines.
- A border that knows that its reader is older gives the older member. A relay between two paired machines knows the generation of its peer.
- Generic code switches on the effect, never on the twelve members. A member 13 then changes no generic code.

## 3. "A failed call gives the value 0"

The rule has two reasons, and only one holds.

- **Sound: at a border.** A receiver or a relay that writes 0 gives the caller the same bytes at each run, and passes no word of the callee by accident. `system.call` does this today.
- **Not sound: as a protection of a caller that forgets the outcome.** 0 is an answer of many exports. [`export_error_records.md`](../../src/md/api/export_error_records.md) records this exact defect: `math.next_prime` gave 0, "which a caller can take as a prime", and several exports gave an empty text. The rule makes a forgotten outcome quiet. The protection is that the caller must read the outcome (`@(require_results)`, `warn_unused_result`, `#[must_use]`).

In a direct call nobody enforces the 0. The intent adds a check of the literal form of a `return`. That is the same kind of check by syntax that this whole work removes.

The joint form: a border writes 0; the value of a direct call that did not succeed is not read; the compiler forces the read of the outcome.

## 4. The kernel in the same design

The design must cover the kernel: "how did this call end" is one concept. The step must be separate, and last. Three reasons.

- **The map is not one to one.** `No_Memory` and `No_Slot` both become `Exhausted`. `Bad_Handle` and `Bad_Address` meet the fault of 2.3. The intent states that the kernel loses the status that `Refused` held in `found`.
- **The kernel contract is the most costly to change twice.** Its table "each status has its kinds", `diagnose`, property 14 and each machine test name the nine statuses.
- **The set is not proven yet.** The exports, the isolated call and `remote` have the defect of the sign today. They are the first users. Two services that ran on the twelve members show the splits that are needed, before the kernel fixes them.

## 5. Other points that break

- **The table from kinds to outcomes rewrites a record.** "A record whose kind does not explain the outcome is read as `Refused`." The table is a third set that has a version. An older reader with an older table then erases a correct record of a newer callee. The kernel can keep this rule for its own records, where one build writes both. A reader of another process keeps the record as it came.
- **Who refused, in an isolated call.** The receiver gives `Invalid` for a call record outside the call region, and the export gives `Invalid` for its second parameter. On the action axis the caller does the same thing in both cases, so one member is acceptable. The record must then tell them apart with no guess: the unit `Region` and `Lent_Handles` do it today, and the intent must state it as a rule.
- **The two outcome words of `remote`** are right, and better than the member `Not_Delivered` of the independent study. They stay inside the header of `remote`. A chain of two relays must not grow a third word: each relay gives its client one outcome, weakened by the rule of 2.2.
- **A stream.** The intent has no word on the end of a stream. With the member of 2.1, the end record carries an outcome and the count of the records that are sound.
- **A handle in a result.** "A handle reaches the caller only with `Succeeded`" is right. With `In_Doubt` the handle can have arrived when the completion did not. The path needs a rule to find and end it. Neither study designs it.
- **AArch64 and WebAssembly.** Nothing breaks. The intent measured AArch64, which the independent study did not. The adapter of a WebAssembly instance is one fixed form.

## 6. The points where this critique now agrees

1. The word carries the action class, because the callee decides the class before it can explain it.
2. One enum of the whole system replaces the status sets of the rings, the isolated call, the caller library and the requests between machines.
3. The outcome first, then the value; an export that cannot fail returns its value alone; an export with a Record result can fail.
4. The kind stays in the record, and never in a register.
5. A bug stops its own process; a bad argument is an outcome, never a fault of the caller.
6. A Text or a Table that did not fit is a success. No member is "internal error" or "unknown".
7. The relay has its own outcome word in the header of `remote`. The member `Not_Delivered` is withdrawn.
8. The record of an isolated call travels in the completion, not in the call region.

## 7. The points where it still disagrees

1. **"Frozen."** The twelve members are a closed set with a version. Only the effect groups can be frozen. Reason: section 2.4.
2. **No member for a known failure that changed something.** Reason: sections 2.1 and 2.2. Without it, `or_return` gives false promises.
3. **`Bad_Answer` for a member that the reader does not know**, with no rule of growth. Reason: section 2.5.
4. **The value 0 as a protection.** Reason: section 3.
5. **The kernel in the first step.** Reason: section 4.
6. **The test of `Invalid`.** Reason: section 2.3.
7. **A reader that rewrites a record to `Refused`.** Reason: section 5.

## 8. A joint recommendation

1. **The form of the intent stays**: one word `Call_Outcome`, the outcome first, the record with its kind, the completion with the outcome in its `kind`.
2. **Thirteen members**: the twelve of the intent, and `Failed`: the work started and did not finish, and the description of the export states what holds.
3. **A named effect, frozen for ever**, as a total function of the member: `Done` (`Succeeded`), `Nothing_Changed` (the nine refusals), `Stated` (`Failed`), `Not_Known` (`In_Doubt`, `Bad_Answer`).
4. **Generic code switches on the effect.** Code that knows the export compares a member.
5. **The rule of growth**: a new member joins `Nothing_Changed` only, names the member that it refines, and comes with a new version of the contract. A border that knows an older reader gives the refined member.
6. **The rule of weakening**: a border, a relay or an export never gives a stronger effect than the one it received or caused. An export that changed something before its callee refused gives `Failed`.
7. **A word that names no member** is `Bad_Answer`, with the word in the record. This stays the answer for a word that no contract names.
8. **The value**: a border writes 0. A caller of a direct call does not read the value unless the outcome is `Succeeded`. The compiler forces the read of the outcome. No check reads the literal form of a `return`.
9. **Ordered tests for the members**, written in the intent, and `Invalid` without "in each state".
10. **The order of the work**: the exports, the isolated call and `remote`; then each ring; then the kernel, in its own step, after two services ran on the set. The set can change until the kernel step.

The questions that stay with the owner: the member `Failed` and its name, the splits of `Exhausted` and `In_Doubt`, a member for a change that lost a race, and the moment of the kernel step.

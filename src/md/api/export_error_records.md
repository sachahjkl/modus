# The error record of each export that can fail

Each export that can fail gives its call outcome and, on each path where it fails, an error record. This file records the rule of the record, the record of a kernel refusal in the words of an export, and the exports whose failure gave an empty answer. The form of the end of a call (the outcome, its effect group, the order of the pair) is in [call_outcome.md](call_outcome.md).

The guide is [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "8. Errors that diagnose". The check of the bindings is in [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The rules that a check holds".

## The purpose

A caller reads how a call ended from the call outcome, and why from one form: the error record. Before the call outcome, an export said that it failed with the sign of its integer result, and some exports gave -1 or a negated status of the kernel with no record: a caller read a number and had to guess its meaning.

## The constraints

- The record of an export is a value of the call, in memory of the caller ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The rules"). Its `argument` is a parameter of the export, from 1, or 0 for the call as a whole. Its `operation` is set by the reader, not by the export.
- A value is a value only: `math.number("-5")` gives -5 and `Succeeded`, and `sample.area` of a negative width gives a negative area.

## The chosen form

**The rule.** An export that has a path where it fails takes the last parameter `error: ^errors.Error_Record`, gives the call outcome first (`-> (outcome: call_outcome.Call_Outcome, value: i64)`), and writes the record on that path, usually with `call_outcome.fail`. An export with no failing path has one result, and no record.

**The check is the compiler.** The description of the build refuses an export with an error record that does not give the outcome first, and an export that gives an outcome with no record: such a module does not build. The binding of an import that can fail forces the read of its outcome (`@(require_results)`), and `outcome_binding_check` refuses a binding without it. No check reads the form of a `return`.

**A kernel refusal inside an export.** The modules `sample` and `hostile_exports` map a lent handle. When the kernel refuses the map, the export gives the outcome of the refusal (`system.outcome_of_status`) and the record of the kernel with two changes: `argument` is the parameter of the export that holds the handle when the kernel names its handle argument, else 0; `operation` is 0. The kind, the unit and the values stay. So the caller reads "the argument memory, handle 0x30004, has the rights Read; the call needs Read Write", in the words of its own call.

**A failure that gave an empty answer.** A name or a number that names nothing is a failure. These exports gave an empty text, 0 or a text that says no, and give an outcome and a record:

- `manual.about`, `manual.problem`: `Nothing_Has_That_Name` with `Absent` of the unit `Modules` for a name that names no module. An empty text stays the answer of a module with no documentation, and of a module that keeps each rule.
- `manual.signature`: `Nothing_Has_That_Name` for the name; `Argument_Refused` with `Bad_Value` of argument 2 for a number that names no export, with the count of the described exports as `limit`.
- `settings.set` gives `Argument_Refused` for a call that gives no setting; the getters of the enum parameters cannot fail ([../features/enum_parameters.md](../features/enum_parameters.md)).
- `storage.stores`: `Grant_Or_Right_Missing` with `No_Grant` of the unit `Acts_For_Principal` for a caller that does not act for a principal.
- `math.next_prime`: `Argument_Refused` with `Bad_Value` above 2^40. It gave 0, which a caller can take as a prime; the 0 of a failure is still no protection, and the caller reads the outcome first.

## The refused forms

- **The sign of the result, and a check of the form of a `return`.** A negative result is also an answer, so the check read forms of the syntax only, and missed a `return` of a variable and a helper of another package. The signature now says that an export can fail, and the compiler checks it ([call_outcome.md](call_outcome.md), "The refused forms").
- **A list of exports that a check skips.** The module `hostile_exports` is wrong on purpose only in the ways that the call path must refuse; its failures give outcomes and records as each module does.
- **The record of the kernel passed through with no change.** Its `argument` names a parameter of `Memory_Map`, and its `operation` a kernel operation: the console then writes the sentence of an operation that the caller did not call.

## The subtle points

- **A failure that gives 0 or an empty text** still compiles: an export with one result cannot fail, so an author who answers a failure with 0 gives the export one result. Review holds it.
- **A module of tests that is wrong on purpose.** `probe.lie` gives a false count of bytes, so that the console proves that it never reads past its buffer. It is not a failure of the export, and it keeps no record.
- **The draw exports of `interface_module`** name the table that is too large (argument 1 or 2) with `Too_Long`, an element larger than the element frame with `Full` and the argument 0, and a text table that passes 2^32 bytes with `Out_Of_Range` of the text table, each with `Argument_Refused`.

## What is built and what is left

Built: the rule, the refusals of the description and `outcome_binding_check` with its host tests, the outcome and the record of each export that can fail, and the machine test of the console for `manual.show`, `manual.about`, `manual.signature`, `math.next_prime` and `hostile_exports.look`, and from the host for `settings.set` and `storage.stores`.

Left: nothing of the rule. A new export that answers a failure with 0 is found by review only.

# The error record of each export that fails

Each export that can fail gives an error record on each path where it fails. A negative result with no record is refused by the tool. This file records the rule, how the check finds an export that breaks it, and the forms that were refused.

The guide is [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "8. Errors that diagnose". The check is in [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The rules that a check holds".

## The purpose

A caller reads why a call failed, in every service and every module, from one form: the error record. Before this rule, the kernel, the rings, the storage service, `manual` and `monitor` gave a record, and some other exports gave -1 or a negated status of the kernel. A caller of such an export read a number and had to guess its meaning: the console printed `-1`, and a test compared a number.

## The constraints

- The record of an export is a value of the call, in memory of the caller ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The rules"). Its `argument` is a parameter of the export, from 1, or 0 for the call as a whole. Its `operation` is set by the reader, not by the export.
- A negative result is not always a failure. `math.number("-5")` gives -5 and `sample.area` of a negative width gives a negative area: these are answers. So a check cannot refuse a negative result; it must find a failing path.
- The tool reads the sources with the parser of the compiler library. It has no type checker: it does not know the value of a variable.

## The chosen form

**The rule.** An export with an Integer result (`-> i64`) that has a path where it fails takes the last parameter `error: ^errors.Error_Record`, and writes the record on that path, usually with `errors.fail`. An export with no failing path needs no record.

**The check** (`export_error_record_check`, `tools/modustool/export_error_record_check.odin`). It reads each source file of `src/programs` and of `src/modules` that is not a test, one package (one folder) at a time. For each export with an `i64` result, no parameter `error` and a name other than `entry`, it reads each `return` of the body. A `return` gives a failing result when its one value is one of these:

- a minus before a literal, a call or a conversion (`-1`, `-i64(status)`), or before a constant of the package;
- a constant of the package whose value is a minus before a literal (`ERROR :: -1`);
- a `?:` or an `if else` expression with such a value on one side;
- such a value in parentheses, or in a conversion to an integer type (`i64(...)`);
- a call of a procedure of the same package that has such a `return` itself.

The check names the file, the line of the `return` and the export. It reads a procedure literal inside a body as a separate procedure: its `return` is not a `return` of the export.

**A kernel refusal inside an export.** The modules `sample` and `hostile_exports` map a lent handle. When the kernel refuses the map, the export gives the record of the kernel with two changes: `argument` is the parameter of the export that holds the handle when the kernel names its handle argument, else 0; `operation` is 0. The kind, the unit and the values stay. So the caller reads "the argument memory, handle 0x30004, has the rights Read; the call needs Read Write", in the words of its own call.

**The exports that changed:** `manual.show`; `sample.fill`, `sample.total`, `sample.span_total`; `hostile_exports.keep`, `hostile_exports.hold`, `hostile_exports.look`; the six draw exports of `interface_module` (`draw_background`, `draw_card`, `draw_cell_text`, `draw_label_value_line`, `draw_table_band`, `draw_bar`).

**A failure that gave an empty answer.** A name or a number that names nothing is a failure, as a negative result is. These exports gave an empty text, 0 or a text that says no, and now give a record:

- `manual.about`, `manual.problem`: `Absent` with the unit `Modules` for a name that names no module. An empty text stays the answer of a module with no documentation, and of a module that keeps each rule.
- `manual.signature`: `Absent` for the name; `Bad_Value` of argument 2 for a number that names no export, with the count of the described exports as `limit`.
- `settings.get`: `Absent` for a name that names no setting, `Too_Long` for a name of more than 32 bytes, with the codes of `settings.set`.
- `storage.stores`: `No_Grant` with the unit `Acts_For_Principal` for a caller that does not act for a principal. It gave the text "no grant to see the stores": a text that says no is a failure that a program cannot read.
- `math.next_prime`: `Bad_Value` above 2^40. It gave 0, which a caller can take as a prime.

**How they were found.** The check does not find them (see "The refused forms"). A scan of the sources listed each export with no record that gives a literal 0, an empty text or a text that says no. Each one was read: it is a failure, or an answer that stays.

## The refused forms

- **A list of exports that the check skips.** The module `hostile_exports` is wrong on purpose, but only in the ways that the call path must refuse: a table past its capacity, a handle kept after its call. Its failures are not part of that test, so it gives records as each module does. A list of exceptions grows in silence.
- **A check of the results when a program runs.** The console can refuse a negative result with a zero record. But a negative result can be an answer, and the fault is then found only on the path that a test runs.
- **A check of the description in the module file.** The description says if an export has an error record. It does not say if the export can fail.
- **A check that follows the values of variables.** It needs a type checker and a flow analysis in the tool. The forms above are the forms that the sources use; a `return` of a variable that holds -1 is not seen, and review holds it.
- **A check of a `return 0` or of an empty text.** A 0 and an empty text are answers of many exports: `tally.last()` before the first add, `roman(0)`, `manual.problem` of a module that keeps each rule. The source does not say which 0 is a failure, so the check needs a list of exceptions, which is refused above.
- **The record of the kernel passed through with no change.** Its `argument` names a parameter of `Memory_Map`, and its `operation` a kernel operation: the console then writes the sentence of an operation that the caller did not call.
- **A negated status as the result, with a record.** The record already holds the status (`Refused` with `found`): one negative result, -1, is enough.

## The subtle points

- **A failure with no negative result.** An export that answers a failure with 0 or an empty text is not seen by the check, because its result is not negative. Review holds it.
- **A module of tests that is wrong on purpose.** `probe.lie` gives a false count of bytes, so that the console proves that it never reads past its buffer. It is not a failure of the export, and it keeps no record.
- **No host test for `math`.** The core library of the compiler has a package `math`, which the test runner imports, and two packages of one build cannot have the same name. The console test holds `math.next_prime`.
- **A helper of another package** is not read: `errors.fail` and the procedures of a support package are not followed. A helper of the same package is followed at any depth; a cycle of calls counts as no failure.
- **The draw exports of `interface_module`** name the table that is too large (argument 1 or 2) with `Too_Long`, an element larger than the element frame with `Full` and the argument 0, and a text table that passes 2^32 bytes with `Out_Of_Range` of the text table.

## What is built and what is left

Built: the rule, the check in `modustool check` and `modustool rule-checks` with its host tests, the conversion of each export that the check found and of each export whose failure gave an empty answer, the host tests of their sentences, and the machine test of the console for `manual.show`, `manual.about`, `manual.signature`, `math.next_prime` and `hostile_exports.look`, and from the host for `settings.get` and `storage.stores`.

Left: nothing of the rule. A new export that answers a failure with 0 is found by review only.

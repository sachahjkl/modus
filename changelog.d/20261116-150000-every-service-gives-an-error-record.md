type: Changed

**Every service gives an error record.** Each export that fails now gives an error record, not a bare negative number: `manual.show`, `fill`, `total` and `span_total` of `sample`, `keep`, `hold` and `look` of `hostile_exports`, and the six draw exports of `interface_module`. The console prints why the call failed, as `error: manual.show: the argument name names none of the modules (-1)`. A refusal of the kernel inside an export names the argument of the export. `modustool check` refuses an export that gives -1, a negated status or a negative constant with no error record.

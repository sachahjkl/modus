# The arguments of an export

An export takes up to 12 arguments in the call form. The first six go in the integer registers of the machine, the others on the stack, as the C convention of the machine passes them. This file records why the bound was six, why it is no longer, and why a bound stays.

The guide is [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "4. The call form".

## The constraints

- The description of a module describes each export completely: the name, the type, the detail and the direction of each parameter. This holds at each count of parameters.
- The call form is the convention of the machine (System V AMD64 on x86-64), in a subset that every compiler gives: `proc "c"` in Odin, `extern "C"` in C, Rust and Zig. No contract depends on one language.
- A caller in another program sends the same values as an argument record. The record is derived from the description, so no second encoding exists.
- One routine, `export_call`, calls each export from an array of values. No code is made for each description.
- A description is a flat record of a fixed size, and a receiver copies an argument record with no allocation. So each count has a bound.

## The chosen form

- **The bound is 12 arguments** (`module.PARAMETER_CAPACITY`). It counts each argument of the call form: the parameters, the buffer of a Text or Table result, the place of a Record result and the address of the error record. `module.call_argument_count` gives the count of one export.
- **Arguments 1 to 6 are in `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9`. Arguments 7 to 12 are on the stack**: one word of 8 bytes each, argument 7 at the stack pointer of the call, argument 8 at 8 bytes above it, and so on. This is the rule of System V for a value of the integer class, so a callee compiled by any language reads them with no change.
- **`export_call` always writes six words of stack.** A callee reads the words that it has and ignores the others. The stack stays on a multiple of 16 bytes at the call. The routine needs no count, so it still needs no description.
- **Why 12.** The bound sizes fixed arrays: 11 bytes of the `Function` record for each parameter, a copy of up to 256 bytes in the private memory of a receiver for each Record parameter, and 32 bytes of the argument record for each Table. The largest export that is planned, the draw of a frame with its rectangles and its picture places, takes eight. 12 is twice the registers and leaves four. 16 grows the private memory of each receiver by 1 KiB more for no export that needs it.
- **The format version is 2.** The `Function` record has a new layout of 168 bytes: each array has 12 places, and the directions are beside the other arrays of one byte. A loader refuses a file of version 1. Each module is built again with the system.

## The refused forms

- **Six arguments, and a record for more.** The bound came from the six integer registers of the convention, with the rule "no parameter on the stack". It bent the borders of modules. The drawing module draws one damage rectangle in each call, because the table of the rectangles had no place among the parameters ([picture.md](picture.md)). The cells of a text grid are copied into the text table of the frame, because the damage of a grid needs two more tables and no parameter was left for them ([text_grid.md](text_grid.md)). The compositor draws one part of its table for each call, one picture memory each; that form does not come from the count, but from the kind of the parameter: a table of picture memories holds addresses ([picture.md](picture.md), "The compositor: one call for each part"). A work parameter of the drawing module was refused because it took one of the six ([library_modules.md](library_modules.md)). The reason "a seventh parameter is a sign that the border is in the wrong place" was false: the border of the drawing module was right, and the count of its tables was the fault of the bound.
- **A record that holds the arguments past six.** A record holds values only, with no address. The arguments past six are mostly tables, which are addresses of table places, so they cannot go in a record.
- **No bound.** A description is a flat table of records of one size, and a receiver of an isolated call copies the argument record into private memory of a fixed size. A count with no bound needs an allocation in each receiver, and a second table for the parameters.
- **A bound of 16 or more.** It costs memory in each receiver and in each `Function` record, for no export that needs it. The bound is one constant: it grows when an export needs it.
- **A count of stack words in `export_call`.** The routine would then need the description, or one more argument. Six words more on each call cost six stores and no branch.

## The subtle points

- **A float parameter is not in the description.** The eight float registers of the call form are loaded as before, and a float type is still a new member of `module.Type` with no change of the call. The stack words are for integer arguments only: a float past the eighth is not part of the call form.
- **The isolated call has no stack.** A receiver decodes the argument record into one array of 12 values and calls `export_call`, which puts each value in its register or on its stack word. The argument record and the call ring do not change their form.
- **A palette entry still has six parameters.** The form of the palette panel has six fields, and its table is a contract of its own. The console lists in the palette no command with more parameters than the form has; the console line calls each one.
- **A receiver copies more.** The private memory of an isolated call grows with the bound: about 3 KiB for the copies of the Record parameters. A service keeps one such record for each call that runs.

## What is built and what is left

Built: the bound of 12, the stack words of `export_call`, the description of version 2, the checks of the tool, the console, the isolated call and the call from the host. The export `weigh` of the module `sample` takes nine parameters and an error record, with a weight for each place, so the machine test of the console proves the order of the stack words in a direct and an isolated call.

Left: the drawing exports take the rectangles of a frame in one call (`ROADMAP.md`). The palette form with more than six fields.

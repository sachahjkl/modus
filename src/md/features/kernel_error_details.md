# Error details of a kernel command

A kernel command that the kernel refuses gives one error record in its completion: the first argument that is wrong. A process that names a table of error details in its command receives one error detail for each argument that the kernel finds wrong, not only the first. The guide is [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "Kernel operations".

## Purpose

A process that builds a command from values of a principal (the console, a test, a tool) corrects one argument, sends again, and learns of the next wrong argument only then. The exports already give each wrong argument in a table of error details. A kernel command now does the same, with the same record and the same Append rule.

## Constraints

- **The accepted path of a command does not change.** The kernel entry runs each command of every process. A cost of one instruction on each command was the reason the work waited: it is paid by each command, and used only by a refused command whose process asks for more. The chosen form adds no instruction to the dispatch of a command that names no table.
- **The completion record keeps its size.** Its seven values are the error record. A table does not fit there: it is memory of the process.
- **No fact of another process.** A detail names an argument of the caller and what the caller can see.
- **No value outside the call.** The table belongs to one command, as the error record does.

## The chosen form

- **A bit of the kind of the command.** Bit 31 of `kind` (`op.COMMAND_NAMES_ERROR_DETAILS`) says that the last value of the command, `values[6]`, is the address of a table place of error records (`op.Error_Details_Place`, the layout of `system.Error_Details`). In a process: `system.call_with_error_details(&error, &details, operation, values...)`.
- **The dispatch is not changed.** A kind with bit 31 is no operation, so the `switch` of `execute` takes it to its default branch, which already refused an unknown operation. Only that branch looks at the bit: it removes the bit and runs the operation once more, with the same lock held. In the source, a command with no table runs the same lines as before ("The measure" says what this claim covers). A command with a table that succeeds pays one branch that the processor did not predict and one more call of `execute`.
- **The details are computed after the refusal.** The kernel entry already calls the diagnosis only when the status is not Ok. `diagnose_command` reads the bit there. It finds the error record as before, then checks every argument again, each one alone, and writes the details. The operations do not change.
- **What a detail is.** The first detail is the error record of the completion: a reader with no table and a reader with a table read the same first answer. Then one detail for each other argument, in the order of the arguments, at most one for each argument, that a check of its form finds wrong now:
  - a handle: absent, ended, of the wrong kind, or without the rights that the operation needs (the same checks as the record, with the rights that depend on another argument, such as the flags of `Memory_Map`);
  - a count above the limit of its form (`Too_Long`);
  - a set of flags with a flag outside the flags of its form (`Bad_Flags`);
  - a choice above its largest value, or 0 where the enumeration names nothing with 0 (`Bad_Value`).
  The checks of counts, flags and choices are a pure procedure of the contract (`op.argument_value_problem`), with host tests.
- **The bound.** A command has seven values, so at most seven details: the record and one for each of the six other arguments. The kernel keeps them on its stack before it writes them.
- **The Append rule.** The kernel copies the table place once from memory of the process. It writes the details that fit after `count`, each record with the checked copy of a write under the process lock, and writes back the count of the full answer, which stops at the largest number. A detail past the capacity is counted and not written. A table place that the process cannot read stops everything: the error record in the completion stays the answer. A record inside the capacity that the process cannot receive (a page that it cannot write, an address past the end of the addresses) ends the answer there: the count then names the records written only, so that a reader never takes old bytes for a detail.
- **Which operations.** Each operation whose seventh value is not a parameter, except `Guest_Run`. `Log` uses its seventh value (the value runs): a command of `Log` with the bit is refused with `Bad_Operation` and the record `Unsupported`. `Guest_Run` runs outside the process lock, before the dispatch; giving it the bit would add a test to that path, and its exits are already its completion records.
- **A batch.** Each command of a batch has its own table, or none.

## The measure

The claim "no added instruction" is a claim about the source: no line on the path of a command with no table changed, except the event point of an operation, which removes the bit from the kind it records, and runs only when a rule of the kernel events observes operations. The machine code of `execute` can still change: its default branch now calls `execute`, so the compiler can save other registers in its prologue or give it another frame. The evidence is the measure line of the process `errors`, printed and never compared: a command that succeeds with no table and with a table, and a command that is refused with no table and with a table. The time of a command with a table that succeeds shows the cost of the second call of `execute`, which only a process that asks for details pays.

**The second frame of `execute`.** A command with a table runs its operation under two frames of `execute` on the kernel stack (16 pages). `execute` is large, and its frame holds the locals of each branch that the compiler inlined. The build measures it: the frame of `execute` comes from `llc`, its table of recursions allows two levels of `execute` on one chain, and each build prints the deepest chain of the kernel stack with the bytes that stay free. The build fails when less than 4 of the 16 pages stay free ([infrastructure/kernel_stack_depth.md](../infrastructure/kernel_stack_depth.md)).

## Refused forms

- **An `and` of the kind before the dispatch.** One instruction on each command of each process, for a refused command that asks for more. The default branch of the dispatch gives the same result for free.
- **A new operation that diagnoses a refused command again** (the process sends the command and its status back). It adds an operation to the counted set, and it takes the status from the process: a process could then name a status that the kernel never gave, and learn a fact of the machine from a record whose kind is chosen by that status (a full table of the machine is named only when it is the one cause of the real status).
- **A table place in the thread record.** It is a value outside the call: the defect of `errno`.
- **Every family of cause in the details.** A budget that cannot pay, a full table, the state of another process are not wrong arguments: they are states, and the record names them only when they explain the real status. A detail for each would read machine facts with no status to bound them. They stay in the error record, as before.
- **A check of each address argument.** The size of the memory that an address names depends on the operation and on other arguments; the error record checks the address of each operation that the diagnosis knows. A detail would repeat that code for each operation.
- **A write of the details by the operation itself.** Each operation would carry the code of the collection and of the write; the operations stay as they are.

## Subtle points

- A detail after the first describes the argument as the kernel reads it after the refusal. An argument that the operation found good can be wrong now (a thread of the process closed the handle): the detail says so. An operation stops at the first wrong argument, so the arguments after it were never checked by the operation.
- **An argument that the operation does not read gets no detail.** The other values can make a handle unused: the budget of a decommit of `Memory_Commit`, the thread of `Thread_Control` with a command out of range, the thread of `Fault_Handler_Set` that ends the delivery. A detail about it would name a fault that no value of it causes. `op.argument_is_read` holds the rule, with host tests; the error record follows it too.
- A kind with the bit and no operation in its low bits gives `Unknown_Operation` with the kind that the process sent, bit included.
- The argument that the error record names gets no second detail. A record of the call as a whole (argument 0) leaves each argument to the checks.
- The checks of a form are sound, not complete: a count, a flag or a choice that the form refuses is refused by the operation in each case. Where a limit depends on another argument, the check is skipped: the pages of a contiguous `Memory_Create`, the counts of `Events_Set` that ends a table.
- The kernel writes a detail into memory of the process with the process lock held, as `Process_State` writes its stop report: no unmap runs between the check of the range and the copy.

## State

Built: the bit, the default branch, `diagnose_command`, the pure checks with their host tests, `system.call_with_error_details`, the machine check of the process `errors` and its measures, the measure of the two frames of `execute` at each build. Left: the wrappers of `system` (`memory_create`, `memory_map`, ...) take an error record and no table; a process that wants the details calls `system.call_with_error_details`.

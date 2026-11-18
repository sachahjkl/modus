# The writer of a module record

## Purpose

A module record says which module is at which addresses of a program ([`docs/glossary/code.md`](../../../docs/glossary/code.md), "Module record"). The readers of the records are the stop report, `inspect.modules()`, `manual.running()`, `manual.edges()`, `program_modules()` of the console and the debugger. Each of them names the code of a program by these records.

Before this design, the program itself could replace or remove each of its records with `Program_Module`. A record of the starter was then a claim of the program: a program could remove the record of its own module and write a record with the hash of another module. A reader could not tell which records its starter wrote.

Now the kernel marks each record with its writer, and a program cannot change a record that its starter wrote. A report then says which modules a program really holds.

## Constraints

- No new kernel operation. The kernel has 35, and each one past 32 needs its reason in a guide (property 1). The writer is a field of the record and a rule of three operations that exist.
- The kernel still does not read a module. The record stays what the loader asserts. The new fact is who asserted it.
- A program still loads and unloads modules in its own memory (the console, `imports`, `errors`), and records them.

## The chosen form

- **A field `writer` in `op.Module_Record`**, the word of an `op.Module_Writer`: `Program` when the program wrote the record for itself, `Starter` when another program wrote it through a program handle with **Control**. The kernel writes the field. It does not read the value that the caller passes. The record grows from 80 to 88 bytes. The field is a word and not the enum: each reader takes it through `op.module_writer_of_word`, and a word that names no writer leaves the field of its row empty, with a line of the log ([../infrastructure/choice_constants.md](../infrastructure/choice_constants.md)).
- **The writer is the party, not the handle.** A program that holds a program handle to itself is still the program: the kernel compares the target program with the caller, not the argument with 0.
- **A program handle never gives a program the authority over itself.** `Handle_Give` removes **Control** and **Give** from a program handle whose copy goes to the program that it names. Without this, a program that received its own handle with Control and Give would give it to a child; the child is another party, so its `Program_Module`, `Memory_Map` and `Memory_Unmap` on the program would be those of a starter, and the rule would hold for the direct call only. Today only `Program_Create` makes a program handle, and it goes to the creator, which is never the program that it names: so `Handle_Give` is the one path by which a program reaches its own handle, and the check there closes it. Read and Debug stay: they change nothing in the program.
- **The kernel writes the record of the root service as `Starter`.** The kernel is the starter of the root service.
- **Three refusals, with the status `No_Right`.** When the caller is the program of the record:
  - `Program_Module` that replaces or removes a record of the writer `Starter` is refused.
  - `Memory_Unmap` of a mapping that meets a record of the writer `Starter` is refused.
  - `Memory_Map` at addresses that meet a record of the writer `Starter` is refused. This check comes before the check of the other mappings, so a map over the module of the starter always gives `No_Right`.
- **The error record** has the kind `Starter_Module`: the value is the address that the call names, the limit is the base of the record of the starter, and found is its size.
- **The starter keeps each right.** A holder of the program handle with Control still writes, replaces and removes each record, and maps and unmaps in the program, as before. It can already write the memory of its child.
- **A chosen address avoids the module of a starter.** `Memory_Map` with the address 0 takes the first gap that meets no mapping and no record of the writer `Starter`. A starter never puts a module in the chosen range today; this keeps a map with the address 0 from a refusal that the program cannot avoid.
- **The readers show the writer.** `inspect.modules()` and `manual.running()` have a field `writer`, with `starter` or `program`. `program_modules()` of the console has a column `writer`.

## Why this makes the record true

The bytes at the addresses of a record of the starter change only through these paths:

- **A map or an unmap of the program.** The kernel refuses both, above.
- **A change of protection.** `Memory_Protect` cannot give a page more than its mapping was made with, and never Write with Execute. The code of a module is mapped with Execute and no Write, so the program cannot write it. A program can take away access (No_Access): that changes no byte, and a fault there names the same module.
- **A write through a memory handle.** The loader of the starter maps the segments from its own memory objects and gives the program no handle of them. A starter that gives such a handle with Write chose to.
- **The kernel.** No operation writes the memory of a program: the debugger uses breakpoints of the processor and reads with `Read_Memory`.

## Refused forms

- **A new operation to seal the records.** A seal at the start is the same rule with one more operation. The writer is known at each write: the kernel has the caller and the target.
- **A flag that the starter sets in the record.** A program would set it too. The writer is a fact that the kernel knows, not a claim.
- **The refusal of `Program_Module` only.** The program would unmap the code of its starter, map its own code at the same addresses, and keep the record of the starter. The record would name code that does not run.
- **A refusal of `Memory_Protect` in the module of the starter.** A protection change cannot change a byte of the code, and the loader and the runtime of a program use protection in their own data.
- **`Bad_Address` as the status.** The address is right and the moment is right; the program lacks the authority, which only the holder of the program handle has. `No_Right` says that the fix is with that holder.
- **Only a note that a self handle with Give delegates the authority of the starter.** The rule would then hold only while no starter gives such a handle, and nothing would tell a starter that it gave away more than a handle. The check in `Handle_Give` costs one compare.
- **A refusal of `Handle_Give` of a program handle to the program that it names.** A starter can have a reason to give a program its own handle with Read, to read its own state through the same call as a child. The copy with fewer rights keeps that use.
- **A writer field in each `Stop_Frame`.** A frame already names the base of its record, and the `Module_Report` of the program gives the record of that base with its writer. A field in each frame adds 128 bytes to each stop report for a fact that one report already holds.
- **A writer that names the program of the starter.** A slot number names another program, and a program sees no other program (property 20, row 1). Two values are enough to say which records are true for the reader.

## Subtle points

- **"Really holds", not "runs only".** A program still maps its own executable memory elsewhere and jumps there, and records it as its own module with the writer `Program`. The records of the starter stay true; the records of the program stay claims of the program.
- **A call host loads its isolated module itself.** The record of that module has the writer `Program`; the record of the module of the host has the writer `Starter`. This is the true fact: the host loaded that module from the files that its starter gave, and the starter mapped only the module of the host.
- **A record of the program can meet no record of the starter.** `Program_Module` already refuses two records that share an address, so a program cannot hide a record of its starter under one of its own.
- **The starter that replaces a record of the program makes it a record of the starter.** The writer is the last writer.
- **The check of `Memory_Map` is inside `map_region`**, after the address is known. The size of a mapping comes from the memory object, and the address can be chosen by the kernel.
- **The writer of a frame of a stack trace.** A `Stop_Frame` has the base and the hash of the record that holds its address, and no writer. A reader that must know whether a frame is a claim of the program matches the base of the frame with a record of the `Module_Report` of the program (`Inspect` with the kind `Modules`), which carries the writer. `Stop_Report.module`, the record of the instruction, carries the writer itself.
- **A record of the starter pins each mapping that it meets.** The range of a record covers the whole module: its code, its constants, and its data and its zero-filled data, which the program writes. The program cannot unmap or map there either: else it would map its own memory with Execute in place of the data and run it under the name of the module. A starter that writes a record over memory that the program mapped for itself (a heap, for example) pins that memory too: the program can no longer unmap it. That is the choice of the starter, which holds the authority over the program.
- **An address that wraps.** The test of a range against a record compares offsets from the lower start, so no sum of an address and a size from the program can wrap.

## State

Built: the field, the three refusals, the error kind, the chosen address, the rights of a program handle given to its own program, the field in the three readers, and a case of the program `imports` in the main machine test.

Left: nothing of this design. The nickname of a disk program still comes from the root service and not from a record: a disk program that starts a child gives it any record as its starter ([programs_from_a_disk.md](programs_from_a_disk.md)).

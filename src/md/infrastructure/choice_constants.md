# A closed set of choices is an enum

A closed set of choices is an `enum`, never a family of integer constants (`MODE_A :: 0`, `MODE_B :: 1`) passed as a `u64` or an `int`. A word that carries a choice across a border becomes its member at one place, which refuses a word that names no member. This file records the rule, the check of the tool that finds a family that breaks it, its exceptions, and the forms that were refused.

The check is in [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The rules that a check holds".

## The purpose

A family of constants is checked by nobody. A `switch` on a `u64` compiles with a member missing, and its default case quietly turns a value that names nothing into a known one. Three faults of this kind were in the system:

- `principals.mode_words` turned each mode that it did not know into "an unlock", and `unlock` ran an unlock for each word that named no mode. A host test checked that silent default.
- `random.generator_from_context` read a strength of the seed past the last one as the strongest: a starter that wrote a wrong word made each key of its child look as strong as `rdseed`.
- The console showed "holds" for a state of a client key that it did not know, and read an unknown cause of a refused change as `Unknown_Change`.

An `enum` gives the compiler the set: a `switch` with a member missing does not compile, and a member cannot hold a value of no member unless a cast skips the border.

## The constraints

- The context of a program is a fixed record of 16 handles and 24 values of 64 bits, and the records of a ring, of a call and of an error have words of 64 bits. A choice travels as a word. The word cannot become an enum in the record: the record is the layout that two programs agree on.
- The values of a word are the contract of the two sides. They do not move when a member is added.
- The kernel is freestanding and has no support package. A contract package has no kernel operation.
- The tool reads the sources with the parser of the compiler library. It has no type checker: it does not know the type of a parameter of another package, nor the value of a variable.

## The chosen form

**The enum.** A closed set is an `enum`. When its word crosses a border, each member has its value written: `Unlock = 0, Create_Principal = 1`. The type is the width of the word (`enum u64` for a context value, `enum u32` for the kind of a ring record).

**The border.** One procedure reads the word: `<enum>_of_word(word) -> (member, ok)`. It walks the members and gives `ok` false for a word that names none. Each place that reads such a word calls it, refuses the word with its error record, a line of the log or a stop, and passes the member past that place. `system.member_of_word` is the generic form for the support packages and the programs; a contract package has its own procedure, as it imports no support package.

**The switch.** Each `switch` on the member names each member. No `#partial` on a closed set, and no default case. A `switch` that must end with a `return` for the compiler gives a text or a status that says that no member was named; it never gives a member.

**The check** (`choice_constant_check`, `tools/modustool/choice_constant_check.odin`). It parses each source of the kernel, the boot program, the programs, the modules and the source library that is not a test, except the copy of the cryptography of Odin. For each package (one folder) it keeps the constants whose value is an integer literal, or a conversion of one, of at most 255. It then notes each such constant that the code uses as a choice:

- a value of a `case` of a `switch`;
- an operand of `==` or `!=` whose other operand has a name with a word of a choice;
- a value assigned or declared to such a name, a field of a literal with such a name, or the index of an index with such a name (`values[VALUE_MODE] = MODE_A`);
- an argument of a parameter with such a name, of a procedure of the package or of an imported package.

A word of a choice is one of `mode`, `kind`, `state`, `form`, `level`, `stage`, `strength`, `role`, `phase`, `action`, `origin`, `change`, `step`, `round`, `variety`, `reason`, `request`, `choice`, `strategy`, `answer`, whole, between two `_`. The constants that the code uses as choices, of one package and with the same first word, are a family. A family of two members or more is refused, with its members and its first use.

**The exceptions** are a short list in the source of the check, each with its reason. Each one is an open set of an outside standard: the frame types and the transport parameters of QUIC, the protocol numbers of IPv4, the message types of ICMP, the capability types of virtio, the entry types of IVRS, the structure and scope types of DMAR, the scan codes of the keyboard, the identity bytes of a PS/2 mouse, the exit codes and the event types of AMD SVM. A value that names no constant is legal there: the reader skips it, or answers it as the standard says. An exception that matches no family is refused too, so the list stays true.

## What stays a constant

A constant stays a constant when it is a quantity or a place: a size, a capacity, a limit, an address, an index in a fixed array. `GRANT_*` and `CONTEXT_*` are places in the context; `VALUE_MODE` is the place of the word of a mode, not a mode. A flag of one bit (`REMOTE_CLIENT_KEY_CAN_COME_BACK`) is not a set of choices. A mask, a magic number and a code of a standard past 255 are not read by the check.

## The refused forms

- **A check of every family of constants with one prefix.** Most families are places and sizes (`OFFSET_*`, `SCROLL_BAR_*`). The use as a choice is what makes a set of choices.
- **The enum in the record.** A record is the layout of a border. A field of an enum type would let the reader skip the border and take a word that names no member.
- **A cast at the border** (`Enum(word)`). It accepts each word. The refusal then depends on each `switch` that comes after it.
- **A clamp to the last member** (`min(word, max(Enum))`). It turns a word of no member into a member: the strength of the seed was read as the strongest.
- **A default member for an unknown word.** It is the fault that the rule removes.
- **A check of the types of the parameters.** It needs a type checker in the tool. The names of the parameters and of the fields say a choice in this system; review holds the rest.
- **A list of the families not converted yet.** Each family that the check finds is converted in the change that adds it, or is an exception with its reason.

## The subtle points

- **The values do not move.** A member added at the end keeps the words of the others. A host test of the border gives each word past the last member, the largest word, and 0 where 0 is no member, before it reads each member back.
- **`None` as a member.** `store.Entry_Kind.None`, `tpm_service.Command.None` and `Device_Step.None` are members, but no reader takes them for an entry, a command or a failed step: the border or the `switch` after it refuses them.
- **A cast that skips the border** still compiles. The check does not see it; review does. A `switch` that the compiler checks whole then gives the text or the status of no member, never a member.
- **The kernel.** Its operation contract keeps its numbers: a word that a test or another language reads is put behind an enum with the same values, not renumbered.

## What is built and what is left

Built: the check and its host tests; the families of the modes of `unlock` and of a twin, the words of the root ring (`Remote_Client_Action`, `Remote_Client_State`, `Principal_Change`, `Disk_Grant_Action`, `Machine_Key_State`, `Machine_Key_Form`, `Principal_Key_Origin`), the ends and the causes of a change of a passphrase, the strength of the seed, the authorization, the step, the command and the status of the TPM service, the kinds of a session of the TPM, the kinds of a storage entry, what did not answer in a `No_Answer` record, and the rounds of `kernel_events`.

Left: the casts at a border that the check does not see, as `Child_Mode(ctx.values[VALUE_MODE])` in `debugged`, and each `#partial switch` on a closed set: [`ROADMAP.md`](../../../ROADMAP.md).

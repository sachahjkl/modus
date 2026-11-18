# The kernel ring: a command runs only when its completion has room

A thread writes command records in its kernel ring and enters the kernel; the kernel runs each command and writes one completion record for each ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "K4. Rings and wait"). This file records what happens when the completion queue of the thread is full, and how the library writes the kernel ring: `system.commands_call`, under `command_call` and `wait_end`.

## Purpose

No queue drops a record in silence ([the subtle points of this folder](../README.md), and [the path of a key](../features/key_path.md)). Three writers of the kernel ring broke the rule:

- The kernel ran a command, then pushed its completion with no check of the answer of the push. A thread that left its completion queue full lost the answer of each next command, and the command had done its work: a handle made with no number for the program, a close with no word.
- `system.command_call` pushed its command with no check, then took the first completion of the queue as its own. A ring that held an older completion gave the answer of another command to the caller, and the command of the caller ran later, at the next entry, with no one to read its answer.
- `system.wait_end` did the same with its `Word_Wait`. With a held command, the `Word_Wait` stayed in the ring with the address of a list of words on the stack of `wait_end`, and the next entry read that list from a frame that had ended.

## Constraints

- The kernel allocates no hidden state for a command ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller"): a result goes to memory that the caller gives.
- No kernel operation blocks ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "4. Base interface: non-blocking command buffers"): a full queue cannot make the kernel wait.
- A command that the kernel does not run must change nothing, so that the program can send it again or drop it itself.
- The thread is the one reader of its completion queue, and it reads it only after the entry returns: a wait in the kernel on that queue would wait for the thread itself.
- **Only its own thread writes a kernel ring.** The ring is memory of the program, so the kernel cannot enforce this: it is a rule of the library. Each thread finds its ring through its thread record, and no code gives the ring to another thread. Three parts of the design depend on it:
  - the empty check of `commands_call`: a ring that is empty stays empty until the push, so the batch fits;
  - the check of the kernel before a command: between the check of the room and the push of the answer, only an honest reader changes the read counter, and it only makes room;
  - the check of the tag: with the ring empty before the push, the answer after the entry is the answer of the batch.

  Another thread of the program that writes the ring breaks these three only for that program: an answer is lost or refused, and no other program sees it.

## The chosen form

**The kernel runs a command only when the completion queue has room for its answer.** Before it takes a command from the command queue, the kernel checks the completion queue. When it is full, the kernel leaves the command, and each one after it, in the command queue, and ends the entry with no wait. The command did nothing. The thread reads its completions, enters again, and the kernel runs the command then, in its order.

Reasons:

- The room is checked before the work, so no answer exists that the kernel cannot give. The kernel keeps nothing: the command waits in memory of the program, in the queue where the program put it.
- The program learns it with no new status and no new word: its command queue still holds the command, and its completion queue is full. The answers that it has not read are all there, in order.
- No entry waits while a command waits: a wait that the thread asked for (a deadline, the words of a `Word_Wait` of the same entry) ends at once, as a changed word ends it. Else a thread that asked for a long wait would sleep with its own answers unread, and could wait for a word that only its held command changes.
- The order of the commands stays: a command after a held command is held too, so no answer comes before the answer of an earlier command.

**The library writes the kernel ring through one path, `system.commands_call`, on an empty ring only, and checks the tag of each answer.** It takes a batch of commands, enters the kernel once with a deadline, and writes the answer of each command. `command_call`, under each wrapper, is a batch of one with no deadline. `wait_end` is a batch of one `Word_Wait` with its deadline. A program that needs several commands in one entry (a wake and a wait) calls it with its batch.

- When the command queue or the completion queue of the kernel ring holds a record, the call pushes nothing and gives `Bad_Operation` with an error record `Busy` (unit `Requests`, value the records that wait, limit 0). No command runs. A record that waits belongs to code that writes the kernel ring itself; the call does not read it, and does not run before it.
- An empty batch, a batch past the capacity of the ring, and fewer places for the answers than commands are refused before the push (`Too_Small`, `Too_Long`).
- A push that the ring refuses gives `Busy`. With an empty ring and a batch that fits, only a write by another thread does it, but the answer of the push is read, never ignored.
- The batch takes consecutive tags from a counter of the program. After the entry it takes one completion for each command, in order. An answer that is absent or has another tag gives `Bad_Operation` with an error record `Refused`.
- `wait_end` on a ring that holds records gets the refusal and returns the time with no entry. An early end is an answer of each wait, because each caller reads its words again. No `Word_Wait` stays in the ring with the address of a frame that ends.

The two parts of the call are pure procedures on a ring (`kernel_commands_push`, `kernel_completions_take`), and the command of `wait_end` is one too (`wait_command`), so the host tests them with a ring in the memory of the test.

## The refused forms

- **The kernel keeps the completion.** A place for the answers that did not fit, in the thread record or in the kernel, is state for each command, with a bound, and its own count of losses past the bound. The command has also done its work by then: the place only moves the loss.
- **A refusal with a status.** The kernel would refuse the command with a status that the program reads, but the place to read a status is the completion queue, which is full. A status in a register of the entry is a second channel of answers, outside the ring, for one case.
- **A wait in the kernel until the queue has room.** The one reader of the queue is the thread that waits.
- **The kernel pops the command and drops it.** It stays the loss of today, moved from the answer to the command.
- **The library reads the completions until its own tag.** It would take and drop the answers of another code of the program, and the command of that code would already have run.
- **The library pushes behind records that wait.** Its answer then comes after theirs, and a full completion queue holds its command for a later entry: the caller would get an answer that is not its own, or none.
- **A raw push in each program that needs a batch.** Each copy is one more writer that can ignore its push or its tag. The batch is one call of the library.

## The subtle points

- **The check and the push in the kernel.** The kernel checks the room, runs the command, then pushes. The push fails only after a write of the ring by another thread of the program, and the answer is then lost by the program itself. The kernel does not trust the counters for anything else: `ring.full` reads a count that is past the capacity as full, as `push` does.
- **The test of a full queue uses the kind `None`.** It names no operation, so the kernel refuses each one with `Bad_Operation` and changes nothing: the answers differ only by their tags, and the test reads that each tag arrives once, in order. It leaves one place, which a `Word_Wait` on a word that keeps its value takes in the next entry, with a held command behind it: the entry must not wait on that word.
- **A held command and `system.log`.** `system.log` calls `command_call`. Code that leaves a record in its kernel ring cannot write a line of the log until it reads its completions: the machine test computes its results first, empties the ring, then writes its lines.

## The stop of a program

A program that asks to stop must stop, whatever its kernel ring holds. `system.stop` cannot use the rule of `commands_call` alone: on a ring that holds records it would get `Busy`, and a stop that returns has nowhere to go.

The chosen form, in rounds:

1. Drop each completion that waits. The program ends, so no answer is wanted.
2. If the ring is empty, send `Program_Stop` with the code of the program through `command_call`.
3. Else enter the kernel with no deadline, so that the held commands run, and go back to 1.
4. Stop the program by a fault when the ring does not empty: after a number of rounds equal to the capacity of the ring, or at once when a completion stays after the drop. A completion stays only when the program wrote false counters, and no entry changes them.

The bound is a count, never a time. With room in the completion queue, each entry runs at least one held command, so an honest ring is empty after at most one round for each place.

**The fault.** `stop` writes to the time page. A program can only read that page, so the write is a page fault at an address at or above `THREAD_AREA_BASE`. The kernel never gives a fault at such an address to a fault handler or a debugger, so it stops the program at once. It writes its report and one line of the log, with the stop code of a page fault (`STOP_CODE_FAULT` plus the vector 14). The same fault ends the program when `Program_Stop` itself is refused.

The refused forms:

- **A loop after the refusal.** It is the fault that made this design: a program that asked to stop ran for ever.
- **An instruction that the processor refuses (`ud2`).** A fault handler or a debugger of the program can ask for that kind, and the program then goes on.
- **A reset of the counters by the program.** The program writes only the write counter of its command queue and the read counter of its completion queue. A reset would drop held commands that the kernel has not seen, and false counters stay false.
- **A new kernel operation, or a stop with no ring.** The kernel has one entry, through the ring, and its operations are counted. The fault already ends a program, with no change of the kernel.
- **A wait with a time as the bound.** A test would then depend on the speed of the machine, and a time is no proof that the ring cannot empty.

The decision of each round is a pure procedure (`stop_step`), which the host tests. The machine case is the child of the program `errors`: it fills its completion queue, holds one command, and stops with its own code. Its starter reads that code with `Program_State`.

## State

Built: the check of the kernel before each command, the entry that ends with no wait when a command waits, `ring.full`, `system.commands_call` as the one path of the library with its pure parts and their host tests, `wait_end` and the batches of the programs `locks` and `scheduler` on it, and the machine case of the program `errors` that fills its completion queue, holds a command behind a `Word_Wait`, and reads each answer once, and `system.stop` that ends the program whatever its ring holds, with `stop_step` and its host tests and the stop of the child of `errors`.

Left: nothing of this part.

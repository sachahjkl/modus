# The kernel ring: a command runs only when its completion has room

A thread writes command records in its kernel ring and enters the kernel; the kernel runs each command and writes one completion record for each ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "K4. Rings and wait"). This file records what happens when the completion queue of the thread is full, and what `system.command_call` does with a ring that holds other records.

## Purpose

No queue drops a record in silence ([the subtle points of this folder](../README.md), and [the path of a key](../features/key_path.md)). Two writers of the kernel ring broke the rule:

- The kernel ran a command, then pushed its completion with no check of the answer of the push. A thread that left its completion queue full lost the answer of each next command, and the command had done its work: a handle made with no number for the program, a close with no word.
- `system.command_call` pushed its command with no check, then took the first completion of the queue as its own. A ring that held an older completion gave the answer of another command to the caller, and the command of the caller ran later, at the next entry, with no one to read its answer.

## Constraints

- The kernel allocates no hidden state for a command ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller"): a result goes to memory that the caller gives.
- No kernel operation blocks ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "4. Base interface: non-blocking command buffers"): a full queue cannot make the kernel wait.
- A command that the kernel does not run must change nothing, so that the program can send it again or drop it itself.
- The thread is the one reader of its completion queue, and it reads it only after the entry returns: a wait in the kernel on that queue would wait for the thread itself.
- The counters are in memory of the program. A false counter harms only the program that wrote it.

## The chosen form

**The kernel runs a command only when the completion queue has room for its answer.** Before it takes a command from the command queue, the kernel checks the completion queue. When it is full, the kernel leaves the command, and each one after it, in the command queue, and ends the entry with no wait. The command did nothing. The thread reads its completions, enters again, and the kernel runs the command then, in its order.

Reasons:

- The room is checked before the work, so no answer exists that the kernel cannot give. The kernel keeps nothing: the command waits in memory of the program, in the queue where the program put it.
- The program learns it with no new status and no new word: its command queue still holds the command, and its completion queue is full. The answers that it has not read are all there, in order.
- No entry waits while a command waits: a wait that the thread asked for (a deadline, the words of a `Word_Wait` of the same entry) ends at once, as a changed word ends it. Else a thread that asked for a long wait would sleep with its own answers unread, and could wait for a word that only its held command changes.
- The order of the commands stays: a command after a held command is held too, so no answer comes before the answer of an earlier command.

**`system.command_call` uses an empty kernel ring only, and checks the tag of its answer.**

- When the command queue or the completion queue of the kernel ring holds a record, the call pushes nothing and gives `Bad_Operation` with an error record `Busy` (unit `Requests`, value the records that wait, limit 0). The command does not run. A record that waits belongs to code that writes the kernel ring itself; the call does not read it, and does not run before it.
- A push that the ring refuses gives the same refusal. With an empty ring it does not happen, but the answer of the push is read, never ignored.
- The call gives each command a tag from a counter of the program. It takes one completion after the entry. A completion with another tag, or no completion, gives `Bad_Operation` with an error record `Refused`. With the ring empty before the push, only a write into this ring by another thread of the program makes it.

The two parts of the call are pure procedures on a ring (`kernel_command_push`, `kernel_completion_take`), so the host tests them with a ring in the memory of the test.

## The refused forms

- **The kernel keeps the completion.** A place for the answers that did not fit, in the thread record or in the kernel, is state for each command, with a bound, and its own count of losses past the bound. The command has also done its work by then: the place only moves the loss.
- **A refusal with a status.** The kernel would refuse the command with a status that the program reads, but the place to read a status is the completion queue, which is full. A status in a register of the entry is a second channel of answers, outside the ring, for one case.
- **A wait in the kernel until the queue has room.** The one reader of the queue is the thread that waits.
- **The kernel pops the command and drops it.** It stays the loss of today, moved from the answer to the command.
- **`command_call` reads the completions until its own tag.** It would take and drop the answers of another code of the program, and the command of that code would already have run.
- **`command_call` pushes behind records that wait.** Its answer then comes after theirs, and a full completion queue holds its command for a later entry: the caller would get an answer that is not its own, or none.

## The subtle points

- **The check and the push.** The kernel checks the room, runs the command, then pushes. Between the two, only the reader can change the read counter, and an honest reader only makes room. A thread of the program that writes a false counter into the ring of another of its threads can make the push fail: the answer is then lost, by the program itself, and no other program sees it. The kernel does not trust the counters for anything else: `ring.full` reads a count that is past the capacity as full, as `push` does.
- **The test of a full queue uses the operation `None`.** It changes nothing, so the answers differ only by their tags, and the test reads that each tag arrives once, in order.
- **A held command and `system.log`.** `system.log` calls `command_call`. Code that leaves a record in its kernel ring cannot write a line of the log until it reads its completions: the machine test computes its results first, empties the ring, then writes its lines.

## State

Built: the check of the kernel before each command, the entry that ends with no wait when a command waits, `ring.full`, the two pure parts of `command_call` with their host tests, and the machine case of the program `errors` that fills its completion queue and reads each answer once.

Left: nothing of this part.

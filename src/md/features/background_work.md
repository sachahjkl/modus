# The background work of a window

A process with a window draws on one thread, the thread of the window. A call that enters another process or the kernel and waits for an answer (a call of the store, a connection that the root service gives, a call of the compositor) must never run there: while it waits, the window takes no key and draws no frame. `interface.Background_Work` is the one form that the windows of the system use to move such a call to a worker thread and to get its result back in the loop of the window.

## Constraints

- No system call on the thread of the window, other than the wait of the loop and the calls of the window itself.
- No lock: the thread of the window never waits for the worker.
- The result reaches the loop of the window as a wake: the loop sleeps until an event of the window, a call, a time, or the end of a job.
- The state machine is testable on the host, with no thread.

## The chosen form

- **One worker thread and one job at a time.** `background_work_start` starts the thread once. `background_work_ask(work, job, parameter)` gives it a job: a procedure and a pointer. It is refused while a job is asked, runs, or is done and not taken: the window shows that state (paint says "saving" or "reading", and takes no second save).
- **A state word and two events.** The state is `Idle`, `Asked`, `Running` or `Done`, in one word that each side changes with an atomic store. The window wakes the worker with the event `asked`; the worker wakes the window with the event `done`. A side reads the count of an event before it reads the state, so no wake is lost (`system.Event`).
- **The memory of a job is its own.** A job reads what the window wrote before the ask and writes its result into memory that the window does not touch until `background_work_take` gives true. Then the window reads the result, on its own thread, and the state is `Idle`.
- **The loop of the window** adds the event `done` to its wait list with `background_work_wait`, which says when a result is ready already, so the loop does not sleep over it.
- **A work lives as long as its process.** Its thread is never stopped and the record is never freed: the thread holds the address of the record. A process keeps its work in a global variable, never on a stack that a call ends.
- **The count of the jobs** (`jobs_done`) is written by the worker and read by the window only after a take: the state word orders the two.
- **The pure steps** (`background_work_ask`, `background_work_step` that the thread runs, `background_work_take`) are procedures with host tests; the thread entry is a loop over `background_work_step` and `system.event_wait`.

## The users

- `paint` opens its store, keeps the changed rows of its picture, reads, creates, renames, deletes and lists its pictures in jobs. The window copies the rows into the file buffer of the job before the ask, and decodes a read picture after the take: the work in proportion to a picture runs once for each act, never in a frame. While a job runs, the principal draws on.
- `clock` asks the root service for its connection to the compositor, and calls `compositor.notify`, in a job at the end of its timer. An end while a job runs waits, and is asked at the next turn of the loop.

## Refused forms

- **A thread for each call.** A thread costs a stack and a kernel entry to start; the jobs of a window come one at a time.
- **A queue of jobs.** The two users have one act at a time; a refused ask is a state that the window shows. A queue waits for a user that needs one.
- **The call on the thread of the window with a short deadline.** A deadline bounds the wait; it does not remove it.
- **A lock around the shared memory.** The ownership of the memory moves with the state word: the window before the ask and after the take, the job between them.

## State

Built: the helper and its host tests, `paint` and `clock` on it. Left: no other window uses it yet.

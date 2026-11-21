# The policy of scheduling: the placement of a thread, and a share for each process

The scheduler is in the kernel, and its strategies are a closed set ([`docs/SCHEDULING.md`](../../../docs/SCHEDULING.md), "5. What this system refuses, and why"). A custom scheduling has this form: a process that holds a right sets the weights, the budgets and the placement of threads at a slow rate, and the kernel applies them at each tick with its own strategy. No code of a process runs on the path of the scheduler, and the kernel gets no verifier and no compiler: the policy is outside the kernel, the mechanism inside.

This file records the design of two layers of that policy. The placement of a thread on processors is built in the kernel. A share of processor time for each budget is not built in the kernel: it is a policy of the process `scheduler`.

The rules that a caller reads are in [`docs/SCHEDULING.md`](../../../docs/SCHEDULING.md), "The placement of a thread" and "The schedule of a live thread".

## The lesson that both layers start from

The first layer of the policy lets a process write the weight and the request of a live thread. Four designs of it failed their review, each with the same cause: the process chose the moment and the direction of a write while the strategy kept a history of the thread. A thread gained processor time by the moment of its writes, or an honest thread waited for seconds.

The rule that was built takes that choice away: a write by the process only lowers, and changes no field of the strategy. Only the holder of the machine handle with Schedule and Inspect raises, and a raised thread starts as a new thread.

So a design of a policy layer answers one question first: which history does a write convert, and who chooses its moment.

## The placement of a thread

### Purpose

The placement is the set of the processors that can run a thread. It is the mitigation that the properties name for side channels between two processes on one core: the holder of Schedule keeps two processes on separate processors. It also lets a process keep a thread on one processor for its own speed.

### The chosen form

- **No new kernel operation.** Two commands of the control of a thread read and write the placement, with the three ways to name a thread and the rights of the schedule commands.
- **A set of processors is one word of 64 bits.** The kernel has at most 64 processors, so one word names each one.
- **Two sets, not one: the set and its limit.** A set that a thread chose for itself is a choice of speed. A limit is a policy. With one field, a service that narrows its own thread gives that narrow set to each process that it starts. With two, a new thread gets the limit of its creator only, as it gets the new-thread weight limit of its creator.
- **The rule is the rule of the schedule.** A process, and the holder of a thread handle with Control, only narrow the set. The holder of the machine handle with Schedule and Inspect writes any set inside the limit, and writes the limit. A set with no processor of the machine is refused: a thread with no processor never runs, and that is a stop, which has its own right.
- **One byte on the hot line of the thread.** The hot line had 6 free bytes: a word of 64 bits does not fit, one byte does. The byte says "restricted". A thread that never gets a placement costs one test of one byte of a line that the path already read, and no new cache line. Zero is the default: a new record is not restricted.
- **No history is converted.** A thread that leaves its processor moves with the procedure that the balance already runs for each thread. A process only narrows, so one thread commands at most one move for each processor less in its life. This is why the cause of the four failed designs is absent here.

### The invariant

The home of a thread is in its set, or the thread is on the processor of its home.

- A thread in a list whose home leaves its set moves at once, in one section under the run locks of the two queues. No state "ready, in no list, on no processor, not held" appears: a change of strategy skips that state, and a stop relies on its absence.
- A thread that runs on a processor that leaves its set moves at its next pass through the scheduler, at most one time slice later.
- The test of a pick from another queue, under the two run locks, is the authority. Each other read of a set is a hint with no lock: a wrong read costs one wake of an idle processor that finds nothing.

### The refused forms

- **An interrupt to the other processor at a write.** An interrupt ends the stint of the thread that runs there when it arrives, and that can be a thread of another process. The wake preemption has a rate limit for this; a placement write would be a second way with no limit. A holder that must know when the thread left reads the thread report.
- **A new argument of the creation of a thread.** A process that wants a narrow new thread writes its placement after the creation. The thread can run one stint on the wider set first. The set is the process's own choice, so nothing depends on that stint.
- **A silent change of a set that is partly outside the limit to another set.** A write through the machine handle keeps the part inside the limit. An empty part is refused: a silent change hides a mistake of the holder.
- **The topology of the processor in the kernel.** The kernel does not know which processors are siblings of one core. The holder can find them itself: it places its own thread on each processor in turn and reads the processor identification there. The topology stays in the policy.

### The fault that this design found

The balance tried one other queue only: the busiest. A queue whose threads the processor cannot take stopped the balance, and a processor went idle while threads waited in a third queue. The fault existed before the placement, with a budget that has no processor time: its threads stay ready in one queue, which is the busiest for ever. The balance now tries the next queue when a move gives no thread. One pick takes at most one pair of run locks for each other processor, where it took one.

### What the placement does not give

- Two cores share the last level cache. A set of processors does not divide it.
- A thread that a process created just before the write of the limit of its creator keeps the old limit. The holder writes each thread of the process, reads the thread report again, and repeats.
- A service that starts processes gives its own limit to them. To start a process inside a limit, the service starts it from a thread that has that limit.
- Up to one time slice passes between the write and the move of a thread that runs.
- Interrupts and the tick of the kernel run on each processor, for the threads of every process.
- A process can keep a thread on one processor where a thread of another process also runs. This is not a new capability: a process with one thread for each processor is on each core already. The limit that the holder writes is the control.

## A share for each budget

### Purpose

Give two processes equal parts of the machine when both want it, and let each one use the whole machine when the other sleeps. The processor limit of a budget does not do this: it is a cap, and it stops a budget also when the processors are idle.

### The numbers that decided

One case, by arithmetic on the rules of the code, not measured: 4 processors, a process with 32 threads that compute with no end, and a process with one such thread. With equal shares the single thread can use 1.0 processor.

| Method | Change of the kernel | The single thread gets |
|---|---|---|
| No policy | none | 0.12 |
| A cap of 3 processors on the large process | none | about 0.32, and one processor idle when the other process sleeps |
| The holder of Schedule writes the weight "full weight / count of threads" to each thread of the large process | none | 0.80 |
| A share for each budget in each queue, with a fixed weight in each queue | about 500 lines | 0.50 |
| The same, with the weight of a group divided between the queues by its load | much more | 0.80 |

The smallest kernel form gives less than the policy that a process can run today. The kernel form that gives as much is the complex one. No form reaches 1.0 without a balance by weight, which the kernel does not have: the balance counts threads.

### The chosen form

The process `scheduler` runs the policy with no change of the kernel. One round reads the thread report of each process, counts the threads that are ready or that ran since the last round, and writes the weight and the weight limit of each thread through the machine handle. A process is a budget here, because the loader gives each started process its own budget. The rules that a principal reads are in [`docs/SCHEDULING.md`](../../../docs/SCHEDULING.md), "A share for each process".

### The refused forms

- **The weight of a group divided between the queues.** It needs a sum of the load of a group that each processor writes at each enqueue: a cache line that two processors write on a fast path, which the data rules of the kernel forbid. That weight also changes at each wake, wait and placement of a thread of the group. A process chooses those moments, so the kernel converts a history at a moment that a process chose: the cause of the four failed designs.
- **A fixed weight in each queue, now.** It makes each procedure of two strategies work on two levels: about 400 lines more in the code that needed five reviews for one rule of 40 lines. And it gives 0.50 where the policy outside gives 0.80. A process with threads in each queue has one full share in each queue; this form does not close that.

### The rule of one round

The process weight is a setting of the principal for the processes with one name: a number from 32 to 1024, and 1024 for a process with no setting. A round reads each process slot and the thread report of each process. It runs each 100 ms, by the clock of the system.

- **A thread counts** when the round saw it for the first time, when it is ready, or when its run time or its virtual time changed since the last round. `N` is the count of these threads, and `T` the count of the threads that live.
- **A thread that counts gets the process weight divided by `N`.** A thread that does not count gets the process weight divided by `T`. The division drops the rest. A process has at most 32 threads, so the least process weight, 32, keeps each quotient at 1 or more: the weights of the threads that count never sum to more than the process weight. The rest that the division drops is under `N` units of weight: under 3 % of the full weight.
- **The weight limit of a thread is its quotient.**
- **The new-thread weight limit of each process, and of each of its threads, is the process weight divided by 32.** The round writes the value of the process before it reads the report of the process. A thread that the process creates between two rounds gets the value as its weight limit and as its weight. The section "A thread that no round saw" says why.
- **The policy never raises a thread above what its process asked.** The first write of a thread reads its schedule. A weight under its limit is a weight that the process chose: the policy keeps it as the most of that thread. A weight equal to its limit is "the most that I can have": the kernel gives the same weight for the value 0. Later, a weight under the weight that the policy wrote is a weight that the process lowered: it becomes the most of that thread. The thread gets the smaller of its quotient and that most.
- **A write happens only when a value changes.** A round of a machine where no thread starts, ends or blocks writes nothing, so it raises nothing: a raise starts a thread again as a new thread.
- **The policy is off at the start of `scheduler`.** With the policy on, the process writes each thread of the machine, and a thread that wakes after a long wait has a small weight for one period. The principal turns it on. When it goes off, each thread gets back the weight that its process asked and the full weight limit. A process `scheduler` that starts gives the full limit back to each thread that an earlier one left under a limit.

### Why the moment of a wake gives nothing

The question of each layer is: which history does a write convert, and who chooses its moment. The process chooses when its threads wake. The rule answers with two quotients.

A process with `T` threads, of which `N` run, has `N` threads of the weight `P / N`: the sum is `P`. Its other threads have `P / T`. When they wake together, the sum is `P + (T - N) * P / T`, which is under `2 P`, until the next round: one period at most. That round gives each thread `P / T`. The threads must then stay out of a whole period before a round gives the runners `P / N` again, and in that period the runners have `N * P / T`. The two periods sum to `2 P`: what the wake took, the next period gives back. A weight of 1 for a thread that does not count gives a tighter bound, and it was refused: an honest thread that wakes on a busy machine then waits a whole period.

The run time of the report counts ticks. A thread that runs only between two ticks has a run time that never changes. Its virtual time changes at each charge under the fair strategy and EEVDF, so the round counts it.

### A thread that no round saw

#### The fault

This section replaces the rule where a new thread got the weight limit of its creator. Under that rule a new thread got the weight limit of its creator as its weight limit, and as its weight when it asked for none. A round gives a thread that counts the whole process weight when it is the only thread of its process that counts. A process used this: it kept one thread that counts, and just after a round that thread created 31 threads, each with the whole process weight, that ended before the next round. No round saw them, and the process had 32 process weights. A thread reads its own schedule, so it sees the moment of each round.

#### The chosen form

Two values that bound a creation, each written only through the machine handle: one for each thread, one for each process. They are a change of the kernel and of the contract, and not a new operation: a fourth field of the thread schedule, and two commands of `Thread_Control` that read and write the schedule of a process.

- **The value of a thread: its new-thread weight limit.** The weight limit that a thread gives to the threads that it creates, and to the first thread of each process that it starts. 0 in a write is the weight limit of the same write. A value above the weight limit becomes the weight limit: a thread under a limit cannot give a higher limit to a new thread, so a process under a limit stays under it.
- **The value of a process: its new-thread weight limit.** The schedule of a process (`op.Process_Schedule`) has one field. A new process has the full value. `Read_Process_Schedule` and `Write_Process_Schedule` take the machine handle with **Schedule** and **Inspect** only, and name the process by its slot and its serial.
- **A creation takes the smaller of the two.** A new thread gets it as its weight limit and as its own new-thread weight limit, so a thread that the new thread creates gets it too. `Thread_Create` refuses a weight above it; the weight 0 gives it.
- **A value above the full weight is refused**, for the value of a thread and for the value of a process, as a weight limit above it is: one rule for each limit.
- **What the policy writes.** At the start of the turn of each process in a round, before it reads the thread report of that process, the value of the process `P / 32`: the process weight divided by the most threads that a process has. Then, with the quotient of each thread, the same value for the thread. The least process weight is 32, so the value is 1 or more.
- **The default.** A thread and a process that the holder never wrote have the full value, and the value of a thread follows its weight limit. So without the policy a new thread gets the limit of its creator, as before.
- **No history is converted.** The kernel reads the values only at a creation, and a new thread has no history. The process chooses the moment of a creation, but the values that the creation reads are the same at each moment between two writes of the holder.

#### Why two values: the order of the write and of the report

The value of a thread alone left a gap. A round reads the report, then writes the threads one by one. A thread with the full value that is in the report can create a thread between the read and its own write; the new thread has the full value and is not in the report. If the new thread does the same in the next round, a chain of short threads, each of which creates the next one and ends, keeps the full value for as long as the policy is on, with no knowledge of the rounds.

The value of a process closes all its threads in one write. The round writes it before it reads the report, and the kernel orders the two:

- A creation holds the control lock for the whole operation, from its read of the two values to the entry of the new thread in the thread table. The write of the value of a process holds the control lock too, and the thread report is read under it.
- So a creation comes wholly before the write, or wholly after it. A thread created before the write is in the table when the report is read after the write: the round sees it, if it lives. A thread created after the write has `P / 32` at most.
- A thread that the report holds keeps its old values until the round writes it, a moment later in the same round. Each thread that it creates in that moment has `P / 32` at most, by the value of its process.

So the gap of the first round is closed in that round: a chain started before the policy goes on is cut by the first write of its process.

#### The bound

After the first round of a process, each thread of it either was written by a round or was created after the last write of its process:

- the threads that the last round counted sum to `P` at most;
- each thread that no round saw has at most `P / 32`; a process has at most 32 threads, so these sum to under `P`;
- a thread that the round saw and did not count has `P / T`, and these sum to under `P`: the wake of the section "Why the moment of a wake gives nothing", for one period.

So the process has under two process weights, plus the part of the wake (under one more) for one period. With `T` threads seen, `N = 1` of them counted, and the rest of the 32 threads unseen, the most is `P·(3 − 1/T − T/32)`: about `2.65 P` for `T = 6`. The bound does not depend on the moments of the rounds or of the creations: a process that knows the moments of the rounds gains nothing more.

#### The refused forms

- **Charge the time of a thread that ends to its process at its end, and let the round count that time.** The process report already counts the ticks of the threads that ended; a precise charge at the end adds the threads that ran between two ticks. But the round reads that time after the period. The weights of the threads that it did not see were in use during the whole period, and the correction is a lower weight for the creator in the next period only. A process that alternates a period of creations and a quiet period keeps about half of the gain: the quiet period gives back nothing. The round also needs a rule that turns a time into a weight. This gives a measure, not a bound.
- **A count of the threads that a process created, in its process report.** The same delay and the same alternation: the count says what happened, after the weights were in use.
- **A weight for a new thread that the kernel computes, such as the weight of the creator divided by its count of threads.** That is a policy in the kernel, and the kernel keeps the mechanism only.
- **A new thread whose weight is cut to the new-thread weight limit, with no refusal.** The policy reads the weight of a new thread to know what its process asked: a weight under the limit is a choice of the process. A cut weight equal to the limit reads as "the most", and the policy then raises the thread above the weight that its process asked. The refusal keeps the rule "the policy never raises a thread above what its process asked".
- **The value of a thread alone, with more passes of the round.** A chain of short threads is always newer than the last report, so no fixed count of passes closes it. One value of the process, written before the report, closes it in one write.
- **The weight 1 for a new thread.** `P / 32` is already the weight of a thread of a process with its 32 threads. A smaller value closes nothing more, and an honest new thread then waits longer for its first turn on a busy machine.

#### The subtle points

- **The first round.** The order of the write of the value of the process and of the report closes it, as above. What remains: a thread that existed before the first write of its process keeps its old weight from that write until the round writes it, in the same round; it creates no thread above `P / 32` in that moment.
- **A process weight that the principal changes.** The round writes the new value of the process before it reads the report, so the new value holds from the round after the change.
- **A process that asks a weight for a new thread.** Under the policy, `Thread_Create` refuses a weight above `P / 32`. A process reads its own schedule to know the value, or gives the weight 0. Without the policy, the value is the weight limit of the creator, and nothing changes.
- **What an honest process loses.** A new thread has `P / 32` until the next round: one period at most. With an idle processor it loses nothing. The round then raises it to its quotient, which starts it again as a new thread; it is a new thread, so it loses no history.
- **When the policy goes off.** Each process gets the full value, and each thread the full weight limit and the full new-thread weight limit.
- **A process that starts processes.** The first thread of the started process gets the limit of a new thread of its starter, `P_A / 32` for a starter `A`, until the next round gives the started process its own process weight. Until that round, the bound of a started process `B` is the process weight of its starter, not its own: a principal that set a lower process weight for `B` by its name sees it from the first round on. Each process in a chain started in one period has up to `P_A`, and the count of the processes of the budget limits the chain. Each started process has one share. The count of the processes of a budget is the limit: the starter of the process chose it.
- **The cost.** One word of the thread record, outside its first 64 bytes, and one word of the process record: a creation and a write of a schedule read them, and no path of the scheduler. The thread schedule has 16 bytes, not 12. A round costs one more kernel entry for each process whose value changes, and none when it does not change.

### Where the policy outside is weak

The holder writes at a slow rate. A thread that wakes after a long wait has the weight `P / T` until the next round. With an idle processor it loses nothing. With each processor busy, the process gets too little for one period. A raise of a weight also starts the thread as new. The measure run prints the shares; it does not say yet if this cost matters for a process of the desktop.

A write through the machine handle gives the four values of the schedule. The policy reads the schedule just before each write. A process that lowers its weight or its request between that read and the write loses that change, and can make it again.

### The event that starts a round

The round has a period by the clock of the system. The event table of the kernel was refused for three reasons. It needs the right Events, and `scheduler` does not hold it. The machine has one event table, and a developer tool uses it. It gives one record for each switch of threads: a process that reads them works at the rate of the scheduler, and the direction is a slow rate. The cost of one round is a measure of the measure run.

### What is a test and what is a measure

The balance between the queues counts threads, not weights. A thread of a large weight in a queue of four threads has between 44 % and 100 % of its processor, by which threads share the queue. So no bound of a share follows from the mechanism, and the share of each process is a measure.

The machine test checks states: the weights and the limits that the kernel gives back after a round, their sum for each process, the weight of a thread that lowered itself, and the weights after the policy went off. It also checks one order, as it does for the weights 1, 2 and 4: the part of the process with 8 threads against the process with 1 thread is smaller with the policy than without it. Each part is a count of ticks of the kernel over one interval, and each interval ends on a count of ticks, not on a time. A slow host makes an interval longer and leaves the counts. The expected numbers are 8 to 1 without the policy and near 1 to 1 with it.

The case of the short threads has two processes: one keeps 6 short threads alive, each of which ends after a count of iterations, and one has one thread that computes with no end. The test that breaks the old form is a state: the case runs the rounds itself, so it knows which threads no round saw, and it reads their schedules through the machine handle until it has read enough of them. It runs one round only before it reads. Each one has `P / 32` as its weight and as its two limits; that per-thread value is the condition that breaks the form where a new thread got the limit of its creator, above `P / 32`. The sum of one read under `P` is evidence only: it also held under that form. This read does not break a kernel that ignores the value of the process: the round wrote the creator with `P / 32` too, and only a thread created in the moment between the report and that write shows the difference. The condition that breaks that kernel is a creation by a thread whose own value is full: after the round, the machine handle gives the first thread of `scheduler` its full new-thread weight limit, which the kernel lowers to its weight limit, above `P / 32`. Then a weight of `P / 32 + 1` is refused with `P / 32` in the error record, a thread with the weight 0 has `P / 32` as its weight and its two limits, and the first thread of a process that this thread starts has `P / 32`. Each holds only by the value of the process. The parts of the two processes over the two intervals are printed as a measure and not checked: a weight orders the share only between threads of one queue, and the balance places the threads.

### The form to build if the measure asks for it

One level, fixed at creation: a budget can be a share group, and its threads are one entity in each queue.

- The share is one more argument of the creation of a budget. No write of a live budget exists, so no sequence of writes exists for a review to search.
- It needs the right Spend on the parent only. A group has at most the weight of one thread, so to make a group is a change that lowers.
- A budget under a group cannot be a group. Without this rule a process inside a group makes a second group and has two entities.
- A thread never enters a group after its creation.
- Not checked in the design: the lock order between the frame lock and the run lock when the budget of a group ends while its threads are in lists.

A smaller change is near and not designed: a write of the processor limit of a live budget. The limit is a filter, not a history, so it has no conversion.

## State

Built: the placement of a thread, with the correction of the balance; the policy of a share in the process `scheduler`, its two commands, its view of the window and its measure; the new-thread weight limit of a thread and of a process, which bounds a thread that no round saw. Not built: a measure of the cost of the policy for a process of the desktop. The kernel gets no share for a budget.

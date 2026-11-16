title: A thread that the share policy never saw gets a small part of its program
date: 2026-11-16
release: next
picture: none
kind: Fixed
guide: docs/SCHEDULING.md

The share policy of the program `scheduler` gives each program one program weight, whatever its count of threads. A round runs each 100 ms. A program could create threads just after a round that ended before the next one: no round saw them, and each one had the whole program weight. Now each thread and each program have a new-thread weight limit, which only the holder of the machine writes, and a new thread gets the smaller of the two. Each round writes the program weight divided by 32 to each program before it reads its threads. A program has at most 32 threads, so after its first round the threads that no round saw sum to under one program weight, also for a program that knows the moments of the rounds. The machine test starts a program that keeps 6 short threads alive and, after one round, reads 24 of its threads that no round saw: each one has the weight 32. Without the policy, a new thread gets the limit of its creator, as before.

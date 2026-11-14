title: A share of the processors for each program
date: 2026-11-14
release: next
picture: docs/screenshots/scheduler_shares.png
kind: Shown
guide: docs/SCHEDULING.md

A weight belongs to a thread, so a program with 8 threads that compute had 8 times the weight of a program with one. The program `scheduler` now has a share policy. The command `scheduler.policy(1)` turns it on. Each program then has one program weight, and the policy divides it between the threads of the program that are ready or that ran. Four programs with 1, 2, 4 and 8 threads that compute get the thread weights 1024, 512, 256 and 128: each program has 1024 in all. The command `scheduler.share("paint", 256)` gives the programs with one name another program weight. A program that lowered the weight of a thread keeps it. The kernel is not changed: the program reads the reports of the threads each 100 ms and writes the weights with its right to schedule. The key S of its window opens the view of the shares, with one row and one bar for each program. The policy is off when the program starts. It does not yet see threads that a program creates and ends between two rounds.

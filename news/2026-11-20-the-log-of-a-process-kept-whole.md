title: A starter keeps each log line of its child, and a reader follows the whole log
date: 2026-11-20
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

The log of the kernel keeps a fixed count of records for each process in each second, and drops the rest: it is for diagnostics. A starter that must keep every line of a child, for an audit, now wires the record output `log` of that child when it starts it. Each record also goes to the ring of that reader, and the child waits when the ring is full, so the reader loses none. In the test, the kernel log keeps none of the 602 log calls of a child whose budget is zero, and its starter reads all 605 records in order.

The log service gives a second stream, `log.follow`: each record of the whole log as it comes, to a reader that acts for the principal. The service never waits for a slow follower. If the kernel writes over records before the service passes them on, the follower reads one row that says how many it missed.

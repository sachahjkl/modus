title: A starter keeps each log line of its child, and a reader follows the whole log
date: 2026-11-20
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

The log of the kernel keeps a fixed count of records for each process in each second, and drops the rest: it is for diagnostics, and a process that writes too much must not fill it. A starter that must keep every line of a child, for an audit, now wires the record output `log` of that child when it starts it. Each record that the child writes goes first to the ring of that reader, and the child waits when the ring is full, so the reader loses none. In the test, a child whose log budget is zero writes 602 log calls: the kernel log holds none of them, and its starter reads all 605 records in order.

A process with no such wiring pays one more load of its context for each log call. The measure run prints the cost of a log call with and without the wiring.

The log service gives a second stream: `log.follow`, one row for each record of the whole log as it comes, to a reader that acts for the principal. The service never waits for a slow follower. If the kernel writes over records before the service passes them on, the follower reads one row that says how many records it missed, and the number of the next row agrees with that count. A test makes a follower fall behind on purpose, and checks that row and the rows around it.

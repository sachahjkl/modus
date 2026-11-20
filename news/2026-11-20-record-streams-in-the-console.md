title: The console reads the record streams of a process
date: 2026-11-20
release: next
picture: none
kind: Shown
guide: docs/CONSOLE.md

A process that writes records while it works declares a record output: a stream of records of one type, which the root service gives to a reader through a ring that loses no record. The console now reads one by its name: `output_counter.counts` is a value of the kind `Stream`, whose fields the console knows from the module file of the process.

`output_counter.counts |> where(status = 404) |> first(3)` reads records until three of them pass the condition, then closes the record stream and draws a table. A record stream at the end of a line draws each row as it comes, in columns as wide as their fields can be, and Escape ends it at once.

The condition goes to the writer: it writes into the ring of the console only the records that pass it. The console also joins two processes: `start("output_count_reader", wire(where(output_counter.counts, status = 404), output_count_reader.counts))` starts a reader whose record input gets those records from its first instruction on.

No text crosses between the two processes: the console checks each record against its record description, and a name that the process does not declare fails the line before anything is wired.

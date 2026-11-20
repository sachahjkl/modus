title: Two programs that work on a stream of any record: merge and filter
date: 2026-11-20
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

`merge` joins several streams of records into one, and `filter` keeps the records of a stream that pass one condition. Neither declares a record of its own: the first stream wired to it fixes its record, and the system refuses a later stream of another record before any record moves.

In the console, `start("merge", wire(alpha.requests, merge.sources) + wire(beta.requests, merge.sources))` starts it with its two sources, and `merge.merged |> where(status >= 500)` reads the joined stream with the fields of that record. In the test, one list chains a writer, `merge` and `filter`: the reader gets each record that passes, each source in its order.

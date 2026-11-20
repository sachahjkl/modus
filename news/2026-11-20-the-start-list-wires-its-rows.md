title: The start list wires a stream between two of its rows
date: 2026-11-20
release: next
picture: none
kind: Shown
guide: docs/ARCHITECTURE.md

The list that starts the machine now joins processes as well as starting them. Besides its start rows, it holds wiring rows: each joins a record output of one row to a record input of an earlier row. The start policy gives the wiring with the start of the writer, so the ring exists before the writer runs, and the reader reads every record from the first one.

The default list wires a demonstration pair at each start: `wired_writer` writes 16 numbers and their squares, and `wired_reader` reads them from the serial 0, in order, then the end. The build checks each row against the module files of its two rows: a stream that the writer does not declare, two records that differ, and a reader that starts after its writer are refused before an image is written.

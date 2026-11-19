title: Typed log facts, record outputs of a module, and a twenty-second property
date: 2026-11-19
release: next
picture: none
kind: Decided
guide: docs/PROPERTIES.md

modus is an operating system with a small kernel, in which programs call each other's functions with typed values, and no text goes between processes.

Two designs are decided. A log fact is a record type that a process writes to the log in place of a formatted line: a reader filters the log by field, as in `log.records(0) | facts(storage.Bad_Block) | where(block = 12)`, and a test waits for a fact and its fields. A record output is a stream of typed records that a module writes and another module reads, through a ring that loses no record; a starter wires the record outputs of a program it starts, its log included, for example to an append-only audit space.

A twenty-second property joins the list: each need has one general mechanism, and each frequent task is one expression that says what it does, with no trick and no hidden encoding.

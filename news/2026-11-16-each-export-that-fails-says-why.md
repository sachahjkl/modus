title: Each export that fails says why
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

A call of a service or a module that fails now gives an error record, in every export. Before, some exports gave only -1: `manual.show("nothing")` printed `-1` in the console. Now the console prints `error: manual.show: the argument name names none of the modules (-1)`. A refusal of the kernel inside an export, as the map of a lent handle, names the argument of the export, not an argument of the kernel operation. The tool refuses a new export that gives a negative number with no error record.

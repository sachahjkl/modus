title: An export takes more than six parameters
date: 2026-11-15
release: next
picture: none
kind: Decided
guide: docs/MODULE_CONTRACT.md

An export of a module takes up to 12 arguments: its parameters, the buffer of its result and its error record. The first six go in the registers of the processor, the others on the stack, as the C convention of the machine passes them, so each language that writes a C function writes an export.

The limit was six arguments, one for each register. It made a module take some of its work in pieces: the drawing module draws one damage rectangle in each call. The description of a module states each parameter of each export, at each count, so the console, a call from another machine and the manual call and show such an export.

The module format is version 2. A module of an earlier release does not load.

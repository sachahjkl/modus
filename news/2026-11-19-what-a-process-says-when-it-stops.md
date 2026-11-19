title: What a process says about its work when it stops
date: 2026-11-19
release: next
picture: none
kind: Shown
guide: docs/ARCHITECTURE.md

modus is an operating system with a small kernel, in which programs call each other's functions with typed values, and no text goes between processes.

A process that stops itself now says what its work gave: done, failed, refused, or stopped on request. The kernel takes that word only from the process itself: a holder that stops another process cannot say it in its place, so a parent that reads "done" knows that the child said so. `monitor.processes()` has the column `outcome`, and `where(monitor.processes(), "outcome", "refused")` lists the processes that refused their context or their input. The root service writes "root: settings stopped: itself, done", and the start policy no longer starts a row again after a finished work or a refused input. The open stop code, a number that each reader decoded, is gone.

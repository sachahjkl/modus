title: Why a process stopped
date: 2026-11-19
release: next
picture: none
kind: Shown
guide: docs/ARCHITECTURE.md

modus is an operating system with a small kernel, in which programs call each other's functions with typed values, and no text goes between processes.

The kernel records why each process stopped: the process itself, a holder of its process handle, a fault, the end of its last thread, or the close of its last handle. No other process can forge this stop cause. The kernel decides it from the target of the stop, not from a number that the caller gives. The console says "the process calendar stopped: a fault, page fault", the root service writes "root: net stopped: a holder" when a window is closed, and `monitor.processes()` has the column `cause`. A stop no longer carries a number with data: a child gives its results through memory that it shares with its parent.

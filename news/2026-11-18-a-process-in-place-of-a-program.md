title: What runs is a process, and the file is a module
date: 2026-11-18
release: next
picture: none
kind: Decided
guide: docs/MODULE_CONTRACT.md

modus is an operating system with a small kernel, in which each running piece of code holds only the handles that it was given.

The system had one word for two things: "program" named the file of code and that code as it runs. Now a module is the file, named by the hash of its bytes, and a process is a module that runs: the realisation of that module in time, from its start to its stop, with its own address space, its handles and its threads. The word is general: a chemical process runs in time too, and Unix took the word from common speech, as this system does. A process here has no parent that it inherits from, no fork, no global number and no environment: it has only the handles that its starter gave it. The kernel operations, the contract, the guides, the glossary and the lines of the log follow the two words. The menu of the bar that lists the modules to start is now `start`.

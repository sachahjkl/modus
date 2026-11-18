# The process

## Purpose

The system has two things that the reader must tell apart: the file that holds code, and that code as it runs. The file is a module, named by the hash of its bytes. What runs is a process: a module that the kernel runs with its own address space, its own handles and its threads, from its start to its stop.

The word for what runs was "program". That word names the file in common speech ("install a program"), and property 10 uses it for the file too ("a program and a library are the same thing"). So one word named two things. "Process" says what the thing is: a course of work in time.

## The chosen form

- **Module**: the file. It does not change and it does not run. Two processes of one module share its code.
- **Process**: a module that runs. The kernel object, its handle, its slot, its state, its stop report and its mappings take this name.
- The kernel operations keep their numbers and change their names: `Program_Create`, `Program_Start`, `Program_Stop`, `Program_State` and `Program_Module` become `Process_Create`, `Process_Start`, `Process_Stop`, `Process_State` and `Process_Module`. The kind of `Inspect` `Program_Mappings` becomes `Process_Mappings`.
- The term of the glossary states what a process of this system does not have: no parent that it inherits from, no fork, no global number, no ambient environment. A process has only the handles that its starter gave it.

## The refused forms

- **Program**: it names the file in common speech, and property 10 names the file with it.
- **Instance**: it reads as a copy at rest, not as a thing that runs in time.
- **Run**: the glossary has two terms "Run" already, and the word is a verb in each command of the tool.
- **Activity**: vague, and it names a part of an interface on another system.
- **Execution**: it reads as one step of work, not as a thing that lives.
- **A new word**: a reader must learn it before they understand the system. A common word with one definition costs nothing to learn.

## The subtle points

- The glossary refused "process" for the baggage of POSIX. The refusal was of the baggage, not of the word: the definition of the term carries what a process here does not have.
- The rename comes after the move of the folders, so that two large moves never cross in one tree.
- A line of the log that a test waits for changes with the rename, in the same commit as its scenario.

## State

Decided. Not built: the rename of the code, the contract, the guides, the glossary and the lines of the log ([ROADMAP.md](../../../ROADMAP.md)).

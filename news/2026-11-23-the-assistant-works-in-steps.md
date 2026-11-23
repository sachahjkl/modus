title: The assistant works in steps
date: 2026-11-23
release: next
picture: none
kind: Shown
guide: docs/ASSISTANT.md

The assistant answers a request in steps. In each step the agent reads the state of the system with calls that change nothing, reads each typed result, and then writes its next step or its answer.

The agent finds the commands itself: its instructions name no service, and it asks the manual for the modules, their exports and the signature of each export. A new module with a described export is a new command of the agent at once.

One request takes at most 16 steps of at most 16 calls. The agent stops when it answers, at 16 steps, at a step whose calls and results are those of the step before, or when you press Stop or Escape. The window says once why it stopped.

Each step shows once. The results of the older steps fold to one line, which a press opens. The conversation scrolls: the newest entry shows until you move up with the wheel, the bar or Page Up, and the view then stays where you put it.

A request holds 4096 bytes, so you can paste an error message. A reply holds 16 KiB, and a result table carries 64 rows, which the window shows page by page.

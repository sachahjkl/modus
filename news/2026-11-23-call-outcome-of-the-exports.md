title: A failed call says how it ended in one word
date: 2026-11-23
release: next
picture: none
kind: Decided
guide: docs/MODULE_CONTRACT.md

An export that can fail now gives its call outcome first and its value second. The outcome is one of 17 words, such as Argument_Refused, Nothing_Has_That_Name or Callee_Busy. Each word says what the call did to the state and what the caller can do next.

The console writes a failed call as `error: storage.read: Nothing_Has_That_Name: the argument name: the store has no object with this name`. The sentence after the outcome comes from the error record of the call.

A negative value is now only a value: `math.number("-5")` gives -5 and the outcome Succeeded. The compiler makes each caller read the outcome before the value.

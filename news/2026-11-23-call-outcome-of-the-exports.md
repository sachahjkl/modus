title: A failed call says how it ended in one word
date: 2026-11-23
release: next
picture: none
kind: Decided
guide: docs/MODULE_CONTRACT.md

An export that can fail now gives its call outcome first and its value second. The outcome is one of 17 words, such as Argument_Refused, Nothing_Has_That_Name or Callee_Busy. Each word says what the call did to the state and what the caller can do next.

The console keeps the headline `error: storage.read: the argument name: the store has no object with this name` and shows `outcome` (`Nothing_Has_That_Name`) and `effect` (`Nothing_Changed`) as the first two detail lines under it.

A negative value is now only a value: `math.number("-5")` gives -5 and the outcome Succeeded. The compiler makes each caller read the outcome before the value.

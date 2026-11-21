title: The console writes functions, lists and map
date: 2026-11-21
release: next
picture: none
kind: Shown
guide: docs/CONSOLE.md

A line of the console now writes a function: `(x) => x * 2`. A `let` names it, and a call by that name runs it: `let double = (x) => x * 2 in area({x = 0, y = 0, width = double(3), height = 4})` gives 24.

A list is `[1, 2, 3]`, and `map([1, 2, 3], (x) => x * 2)` gives `[2, 4, 6]`. With the pipe operator: `[1, 2] |> map((w) => area({x = 0, y = 0, width = w, height = 5}))` gives `[5, 10]`.

A line can end with a comment: `map([1, 2, 3], (x) => x * 2) // doubles` runs the call, and the console draws the comment in its own color.

A function stays in its line. No module takes one and no variable keeps one, because its body reads the values of the line around it. Lex has no condition yet, so a function that calls itself never ends: the line stops when the evaluator has taken 512 KiB of stack, and says so.

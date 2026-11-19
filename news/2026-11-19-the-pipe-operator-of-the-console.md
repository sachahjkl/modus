title: The pipe operator of the console
date: 2026-11-19
release: next
picture: none
kind: Shown
guide: docs/CONSOLE.md

modus is an operating system with a small kernel, in which programs call each other's functions with typed values, and no text goes between processes.

The console has the operator `|>`: the value on its left is the first argument of the call on its right. `processes() |> where("name", "server") |> columns("name slot")` is `columns(where(processes(), "name", "server"), "name slot")`, and reads in the order in which its calls run. The operator adds no meaning: the console writes the line with calls in calls before it runs it. A line with a fault of the operator runs nothing, and its error says what is wrong. After `|>`, the completion list offers the commands whose first parameter can take the value on the left.

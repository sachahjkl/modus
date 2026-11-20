title: The console writes records by their fields, and names values with let
date: 2026-11-20
release: next
picture: none
kind: Shown
guide: docs/CONSOLE.md

A line of the console now writes a record by its fields, in any order: `area({x = 0, y = 0, width = 11, height = 3})` gives 33. The record has no type of its own: the parameter of `area` gives it, so a field with a wrong name, such as `widht`, is refused with the fields of the record before the call runs.

A call gives a parameter by its name: `grow(r, by = 2)`. `r with {width = 10}` is the record `r` with one field changed. `let s = {x = 0, y = 0, width = 6, height = 7} in area(s) + area(s)` names a value for one line and computes it once.

After `|>`, the placeholder `_` puts the value on the left in another place of the call: `3 |> grow(r, _)` is `grow(r, 3)`.

These are the forms of Lex, the language of the console, that the declarations of a system will use.

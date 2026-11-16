title: The console colors each field by its value kind
date: 2026-11-16
release: next
picture: docs/screenshots/console_value_kinds.png
kind: Shown
guide: docs/CONSOLE.md

A table of the console now shows each field in the color of its value kind, as the log and the site do. A time is in the color of the boot program. A size and a number are in the color of memory. The unit of a size or a time is in the head of its column, one time: `resident (pages)`, `time (ms)`. A record writes the unit after each value: the field `used` of `memory()` shows `1204 pages`. The description of the record states the kind: a field of the type `value_kinds.Time_In_Milliseconds` in the source of a module is a time in milliseconds, and a text is never classified by its look. `columns` and `join` keep the kind of each field. The picture shows a record with a handle, then `columns(where(programs(), "name", "console"), "name slot threads resident time started")`: a text, two numbers, a size and two times.

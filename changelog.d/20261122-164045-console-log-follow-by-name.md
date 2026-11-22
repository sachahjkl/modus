type: Added

**The record output `log` and `log.follow` by name in the console.** `log.follow |> where(level = Warning)` draws the warnings of the whole log as they come and never shows the rows of the console itself, so a follow cannot feed on its own lines; `first(n)` and Escape end it. `wire(server.log, reader.input)` names the log of the module that `start` starts, a typed name whose owner has more than 31 bytes is refused, and `start` refuses a list row that repeats an earlier row, whose reader then takes each record twice.

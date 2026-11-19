type: Added

**The pipe operator `|>` of the console**: `a |> f(b)` is `f(a, b)`, so `processes() |> where("name", "server") |> columns("name slot")` reads in the order in which its calls run. The operator adds no meaning: the line checks and runs as the same line with calls in calls. A fault of the operator (no value on its left, no call on its right, a command that takes no argument or has 12 already, a `|` alone) fails the line before any call runs. After `|>`, the completion list offers the commands whose first parameter takes the value on the left.

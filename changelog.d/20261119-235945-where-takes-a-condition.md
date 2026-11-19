type: Changed

**`where` takes a condition on a field**: `where(t, block = 12)`, `where(t, level = Warning)`, `where(t, number >= 100)`, in place of `where(t, "block", 12)`, which the console no longer takes. The field is a name of the record, checked before a row is read, and before any call in a line with `|>` when the console knows the record; a status takes the name of a member of its enum, with `=` and `!=` only. The operators are `=`, `!=`, `<`, `<=`, `>` and `>=`. In a line with `|>`, the completion offers the fields and the members.

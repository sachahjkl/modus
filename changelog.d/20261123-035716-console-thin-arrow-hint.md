type: Added

**A function written with `->` gets its form in the error**: `map(x, n -> n * n)` fails with "`->` is no operator: a function is written (n) => n * n", at the `->`. Lex keeps one form of a function, `(n) => n * n`, and no alias.

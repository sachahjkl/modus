type: Added

**Canonical Lex formatter and static linter (`modustool lex fmt` and `modustool lex lint`).** Added the freestanding `modus:lex_tools` formatter and linter together with host CLI subcommands to format `.lex` declarations idempotently (with `--check` verification) and report unused or shadowed `let` bindings, duplicate record fields, redundant parentheses, empty containers, empty pipe targets, and malformed tokens.

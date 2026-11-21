type: Added

**Declarations in the console.** Lex adds `blake3:` hash literals, multi-line `.lex` files, `if ... then ... else ...`, comparisons, `filter`, call on a record literal (`plan { ... }`, `project { ... }`), and a pure lazy evaluator that runs in the zero-authority module `declaration_eval` with cycle detection, step and depth bounds, and deterministic canonical output.

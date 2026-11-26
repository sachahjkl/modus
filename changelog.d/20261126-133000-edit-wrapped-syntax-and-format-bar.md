type: Fixed

**Wrapped-token syntax highlighting and `Format` action-bar item in `edit`**: highlighting a wrapped display row now scans its enclosing logical line span (`text_model.syntax_highlight_layout_row`) so multi-character tokens (`blake3:` hashes, comments, directives, strings, identifiers, and numbers) keep uniform colors across line wraps, and `.lex`/`.recipe` files display the `Format` (`Ctrl+Shift+F`) item in the bottom action bar.

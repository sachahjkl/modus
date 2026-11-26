# Content-addressed AST codebase and structural code editor

`modus:ast_codebase` (`src/library/modus/ast_codebase`) and `code` (`src/modules/applications/code`, module group `applications`) represent programs as canonical binary abstract syntax trees (`MODAST1`), name definitions by their alpha-normalized BLAKE3 content hashes, and edit them through a projected text-like cursor with typed holes (`?`).

## Purpose

Flat source text couples a definition's identity to its human-readable name, mixes syntax parsing into every tool, and allows broken intermediate states on every keystroke. `modus:ast_codebase` separates content identity from human names in the style of Unison: a definition is identified by the BLAKE3 hash of its canonical, alpha-normalized AST, while human names live in a separate Name Table so renaming a definition or parameter is O(1) and leaves every definition hash unchanged.

`code` projects each definition into syntax-colored lines and tokens in the style of Dion Systems. You navigate and type like a text editor, while every edit mutates the AST directly and collapses incomplete parts to typed `?` holes so the tree stays well-formed after every keystroke.

## Constraints

- Pure freestanding Odin in `src/`: `modus:ast_codebase` and `code` allocate no heap memory and import no `core:` package.
- Every closed choice (`Node_Kind`, `Type_Kind`, `Bin_Op`, `Unary_Op`, `Codec_Error`, `Edit_Slot`, `Ast_Edit_Action`) is an `enum` with explicit contract values converted at one border (`enum_word.member_of_word`) and switched exhaustively.
- No O(N) work in a frame: AST projection, selection membership, and C preview generation run on edit, definition switch, or mode toggle, never inside `draw()`.
- No blocking call on the window thread: `code` runs all private store reads and commits on `interface.Background_Work`.
- No save action: every edit persists `"codebase.ast"` in binary `MODAST1` form to the private copy-on-write store.
- Fixed in-OS editor bounds are declared as explicit `Plan value` or `Format property` constants with overflow refusals.

## The chosen form

- **Typed flat-pool AST (`ast.odin`).** `Node_Id` is a 1-based `u32` (`NODE_NONE == 0`) indexing into a fixed pool (`MAX_NODES = 4096`) and a child-list pool (`MAX_LIST_ITEMS = 2048`) so zero-initialized records are valid and never alias node 1. Definitions (`MAX_DEFS = 128`) store parameters (`MAX_PARAMS = 8`), return type, root `Node_Id`, and 32-byte BLAKE3 hash. A separate `Name_Table` (`MAX_NAMES = 128`) maps human display names to definition hashes and caches `def_index`.
- **Alpha-normalized BLAKE3 definition hashing (`hash.odin`).** Hashing starts with domain tag `"MODAST1\x00"`, then hashes parameter count, parameter types (never parameter names), return type, and a canonical pre-order walk of the root node. Local variable bindings (`Param` and `Let_Stmt`) receive sequential canonical slot numbers during the walk so `Var` nodes hash only their canonical lexical slot, never their display name. External references (`Def_Ref`) hash only the callee's 32-byte BLAKE3 hash. Two alpha-equivalent definitions produce the exact same hash. Renaming a definition updates only `Name_Table`; renaming a parameter updates only display names; neither alters any definition hash.
- **Canonical binary `MODAST1` serialization (`codec.odin`).** A 24-byte little-endian header (`"MODAST1\x00"`, version `1`, flags `0`, counts) precedes deterministic little-endian node, list, definition, and name records. The decoder validates every magic byte, version, flag, enum member, index bound, identifier rule, name uniqueness, exact byte length (no trailing bytes), acyclic reachability (3-color DFS across all nodes), and stored definition hashes before accepting a codebase.
- **Dion-style projected structural editor (`editor.odin`).** `ast_editor_project` flattens the active definition into `Projected_Line` and `Projected_Token` arrays with precomputed `graphics.Code_Class`, column spans, `Edit_Slot`, and `in_selection` flags. Typing digits or letters on a `?` hole edits smoothly inline and resolves identifiers to local bindings or `Name_Table` definitions. Typing a binary operator wraps the focused expression as `lhs` with a fresh `?` hole on `rhs` and focuses the hole. Typing `(` on a `Def_Ref` wraps it in a `Call` populated with `?` argument holes. `Tab` jumps to the next `?` hole, or steps up to the enclosing expression when no holes remain. `Backspace` removes inline characters and collapses empty or compound nodes cleanly back to `?`. `F2` / `Ctrl+R` renames definitions or parameters inline without altering hashes.
- **C and Lex lowering (`emit.odin`).** `ast_emit_c` emits forward declarations and freestanding C definitions (`long <name>(long <param>, ...)`) using display names from `Name_Table` so the system C compiler can compile them natively. `ast_emit_lex` emits readable Lex syntax for one definition.
- **Native `code` application (`src/modules/applications/code/`).** A resizable window (`880 x 600` default, `480 x 320` least, `1280 x 960` largest) displays a `DEFINITIONS` sidebar with 8-hex BLAKE3 badges, a top header showing the active name and 16-hex `blake3:...` hash, a main syntax-colored AST editor pane (or `EMITTED C` preview via `Ctrl+E`), a status band, and an action bar. Edits push compact `MODAST1` snapshots onto a local undo/redo ring (`Ctrl+Z` / `Ctrl+Y`) and commit asynchronously to `"codebase.ast"` in the private store.

## The refused forms

- **Flat source text as the primary store format.** Reparsing text on every keystroke couples identity to spelling, breaks structural edits on incomplete input, and requires a full text parser in the editor.
- **Hashing display names of definitions, parameters, or local bindings.** Including names in the hash breaks alpha-equivalence and forces cascading rehashes and recompilation on every rename.
- **Projecting AST lines or walking parent chains inside `draw()`.** Frame rendering would scale with AST size and violate the main-thread frame rule.
- **Blocking `storage.read_whole` or `storage.write_whole` on the window thread.** A slow store would stall frames and input; all store calls run on `interface.Background_Work`.
- **Untyped integer tags or `#partial` switches.** Corrupt stored bytes could silently coerce into valid nodes; every tag crosses `enum_word.member_of_word`.

## Subtle points and hazards

- **Alpha-equivalent collisions during body edits.** Two distinct definitions can share the same 32-byte hash when their bodies are alpha-equivalent. `Name_Entry` records `def_index` alongside `def_hash` so editing one definition updates its own name entry and callers without overwriting an independent alpha-equivalent sibling.
- **Cycles in corrupt `MODAST1` blobs.** A malicious or truncated binary payload can encode `Node_Id` back-edges. The decoder runs a non-recursive 3-color DFS over every node in the pool before returning `.Ok`, guaranteeing termination for both hashing and projection.
- **Orphaned pool slots after long edit sessions.** Wrapping and collapsing expressions allocates fresh nodes in the fixed pool. Overflow returns `false` cleanly and shows a status message without corrupting existing nodes.
- **Stack budget.** `Codebase` (~550 KiB) and `Ast_Editor` (~170 KiB) live in module static memory, never on a thread stack.

## State

Built: `modus:ast_codebase` (`ast.odin`, `hash.odin`, `codec.odin`, `editor.odin`, `emit.odin`, and exhaustive host tests in `ast_codebase_test.odin`) and the native `code` desktop application (`src/modules/applications/code/facts.odin`, `main.odin`), wired into the boot image, start grant sets, bar icons, and Start Menu. Left: live C compilation dispatch from inside `code`.

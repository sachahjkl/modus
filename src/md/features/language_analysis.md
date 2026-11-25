# Shared-memory language analysis

## Purpose

A code editor needs syntax colors, diagnostics, hover signatures, definition targets, and completions as the principal edits source files. Running a language analyzer inside `edit` ties the editor to every language and exposes the editor to hostile inputs. Running JSON-RPC LSP over pipes or sockets parses text across a process border and allocates per message.

This design defines one binary shared-memory contract, **Language Analysis Exchange Format (`MODLAEF1`)**, between `edit` and any isolated language analyzer module. The editor lends a read-only source buffer and a writable snapshot buffer, sends one 32-byte ring request, and reads flat cache-friendly tables directly from the validated snapshot with zero JSON parsing and zero heap allocation across the border.

## Constraints

- **No text between processes.** Requests, responses, tokens, diagnostics, completions, definitions, and hover entries cross the border as fixed-size typed records in flat tables.
- **No blocking on the interface thread.** `edit` submits analysis requests to an off-thread worker and applies the newest validated snapshot when the worker completes.
- **A snapshot from an analyzer is hostile input.** The editor validates the `MODLAEF1` header, every section offset and count, pairwise section non-overlap, every enum word, every span bound, and every string offset before reading a single entry.
- **Zero ambient authority.** An analyzer runs as an isolated child module with no filesystem, network, or clock handle; it sees only the lent source bytes and the lent output snapshot buffer.
- **Contract packages stay self-contained.** `src/library/modus/contract/language_analysis` imports only `modus:contract/*` packages so the editor, analyzer modules, and host tools share the exact same encoder, validator, and zero-copy readers.

## The chosen form

### 1. Ring requests and responses

Requests and responses travel on fixed-size 32-byte ring records (`Analysis_Ring_Request`, `Analysis_Ring_Response`):

- `Analysis_Request_Kind` (`enum u8`): `Full_Document = 1`, `Hover = 2`, `Definition = 3`, `Completions = 4`.
- Every request carries `request_id`, `document_generation`, `cursor_offset`, `source_bytes`, and `kind_word`.
- Every response carries `request_id`, `document_generation`, `snapshot_bytes`, `diagnostic_count`, and `refusal_word`.
- The border converts `kind_word` and `refusal_word` through `enum_word.member_of_word` and refuses any unknown word.
- `edit` discards any response whose `document_generation` lags the current buffer generation.

### 2. Flat snapshot format (`MODLAEF1`)

One snapshot occupies a contiguous byte slice starting with a 72-byte `Analysis_Snapshot_Header`:

| Field | Bytes | Meaning |
|---|---|---|
| `magic` | 8 | ASCII `MODLAEF1` |
| `version` | 4 | Format version (`1`) |
| `total_bytes` | 4 | Total snapshot size in bytes |
| `document_generation` | 8 | Editor generation that produced the snapshot |
| `diagnostics_offset`, `diagnostics_count` | 8 | Flat array of 32-byte `Diagnostic_Row` |
| `tokens_offset`, `tokens_count` | 8 | Flat array of 16-byte `Semantic_Token_Row` |
| `completions_offset`, `completions_count` | 8 | Flat array of 24-byte `Completion_Row` |
| `definitions_offset`, `definitions_count` | 8 | Flat array of 24-byte `Definition_Span` |
| `hovers_offset`, `hovers_count` | 8 | Flat array of 24-byte `Hover_Entry` |
| `strings_offset`, `strings_bytes` | 8 | UTF-8 string pool referenced by `(offset, bytes)` pairs |

Every row table offset is 4-byte aligned. All six sections (five row tables plus the string pool) sit past the header (`offset >= 72`), stay within `total_bytes`, and must not overlap. Every row enum field (`severity_word`, `kind_word`) is checked against its closed enum at validation time, every reserved word must be zero, every byte span must satisfy `start <= end`, and every string slice must stay inside `[0, strings_bytes]`.

### 3. Freestanding Lex analyzer

`lex_analyze_into_snapshot` provides a zero-allocation Lex analyzer directly inside the contract package. It scans Lex tokens (keywords, identifiers, `let` bindings, numbers, checked units such as `MiB` and `ms`, strings, `blake3:` hashes, dotted `.enum` choices, operators, punctuation, and `//` comments), checks delimiter matching and literal well-formedness for diagnostics, resolves identifier uses back to their `let` binding definitions, emits hover signatures for bindings and built-in Lex forms, and encodes the complete `MODLAEF1` snapshot into the caller-supplied buffer.

## The refused forms

- **JSON-RPC LSP.** Refused. Serializing and parsing JSON strings across process boundaries violates no-text-between-processes, multiplies allocation cost on every keystroke, and creates an untyped stringly protocol.
- **Pointer-linked syntax trees in shared memory.** Refused. Cross-address-space pointers require rebasing and invite TOCTOU faults; flat offset-indexed tables validate in one linear pass.
- **Analyzer reading stores directly.** Refused. Giving an analyzer store handles turns syntax highlighting into ambient disk access; lending only the edited buffer preserves least privilege.

## Subtle points

- **Copy or freeze before validation.** When reading from memory shared with an analyzer, the caller validates either a private copy or a buffer whose write mapping the analyzer has released.
- **Inline analyzer capacities.** `lex_analyze_into_snapshot` uses fixed stack/inline capacities (`LEX_ANALYZE_TOKENS_LIMIT`, etc.) sized for interactive source modules; exceeding a capacity returns `Analysis_Refusal.Capacity_Exceeded` cleanly with zero partial writes.
- **Empty sections are valid.** A section with `count == 0` may carry `offset == 0` and takes no range in the overlap check.

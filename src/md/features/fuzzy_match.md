# The fuzzy match and the frecency

The console completion and the palette find a name from a few typed characters: `mcnt` finds `monitor.count`. One matcher serves both: `src/library/support/line_editor` (`fuzzy_match`, `rank_candidates`). This file records why the matcher has its rule, its vector form and its bounds, and why a name that the principal uses often comes first. The rule as a reader sees it is in [`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "3. The fuzzy match"; the vector form is in [`docs/SIMD.md`](../../../docs/SIMD.md), "8. The fuzzy match".

## The constraints

- **The names are hostile input.** The palette ranks the entry table of the palette provider; the console ranks the exports from the descriptions of other modules. The work of one name has a bound, whatever its bytes.
- **The loop of the compositor never ranks.** The ranking thread of the palette ranks; the first thread of the console ranks between two lines. A key must stay fast on both.
- **One rule for both.** A name has one score in the palette and in the console, so the guides state one rule.
- **The vector form gives the same result as the scalar form**, for every input ([`docs/SIMD.md`](../../../docs/SIMD.md), "1. The rule of the same bytes"): the same score, the same places, the same match or no match.

## The scoring rule: kept

The rule is the bounded rule of fzf, its algorithm v1: a pass forward finds the first character where the whole query has matched, and a pass back from it finds the latest start, so the shortest window that ends there. The places of that window give the score: a match, the start of the name, the start of a part after `.` or `_`, a run, a gap. The rule does not change, so no list changes its order for the same history of use.

Refused: **the best alignment** (Smith–Waterman with affine gaps, fzf v2, frizbee). It finds the window with the best score, not the shortest, so `set` in `manual.segments` takes the `e` beside the `s`. It costs one cell for each pair of a query character and a name byte (64 × 128 cells at the bound) in place of two passes, and it changes the order of known lists. A name of this system is short and has few parts: the shortest window is almost always the best. It waits for a list whose order shows a wrong first row.

## The vector form

The scalar form (`fuzzy_match_scalar`) decodes the name and the query into characters, then walks them. It is the reference: it stays, and it is the code of a name or a query with a byte past ASCII.

The vector form (`fuzzy_match_vectors`, `src/library/support/line_editor/fuzzy_match_vectors.odin`) uses portable 128-bit vectors (`#simd[16]u8`) and `base:intrinsics`, which lower to SSE2 on x86-64 and NEON on ARM64. It runs on every architecture with no target guard, reading the name in blocks of 16 bytes, after the idea of the prefilter of frizbee:

1. **The bit-7 mask.** The bytes of the name are OR-ed and their high bits taken (`simd_extract_msbs`). A name with a byte past ASCII goes to the scalar form. A query with a byte past ASCII also goes to the scalar form: an invalid byte decodes as the replacement character, which equals a control byte of the name.
2. **The lowered name.** Each byte from `A` to `Z` gets `0x20`, and each control byte (`< 0x20` or `0x7F`) becomes `0x80` (`CONTROL_MARK`), in lanes: compares, shifts and masks, so two control bytes equal each other as the replacement character.
3. **The mask of each query character.** For each character of the query, one compare for each block of the name and one `simd_extract_msbs` (`pmovmskb` on x86-64): a mask of 128 bits, bit n for byte n, cut to the length of the name. A mask of zero ends the match: this is the prefilter, and most names of a list end here, at the first character that they lack.
4. **The pass forward** is the lowest bit of each mask above the place before: the same place as the walk of the scalar form. **The pass back** is the highest bit of each mask at or below the place after. The positions are byte places, which are character places in ASCII, so the score is the score of the scalar form.

The cost of a name: its blocks (at most 8), then for each query character one compare and one mask for each block. A name never takes a load past its slice: the last part of a block is copied into a block of zeros, and the masks are cut to the length of the name, so a zero byte of the query does not match the padding.

Refused forms:

- **Lanes across candidates** (one candidate in each lane, as the first form of frizbee). The candidates must be interleaved and sorted by length, and frizbee measured only a small gain before it left that form. Our rule needs no matrix, so the work for one name is already a few compares.
- **A table of the letters of each name**, computed when the table of names changes. The console builds its table of names at each key, so the table costs as much as the masks; and a bit for each letter says nothing about the order.
- **A vector form for a name past ASCII.** The names are identifiers in ASCII; a name past ASCII is a text of a history line. The scalar form gives its result in the same bound.

## Typo tolerance: no

A typo-tolerant match (frizbee counts a missing or a changed character as a bounded penalty) lists names that do not hold the typed characters. Three facts refuse it here:

- The list draws the matched places in the accent color. A typo has no place to draw, so a row then says that it matches characters that it does not hold.
- The console completes a name to call it, and a principal types names from their start; a list with a wrong first row costs a key more, a typo costs one Backspace.
- With one typo allowed, a query of 3 characters matches most names of 20 bytes: the list stops narrowing, which is what the match is for.

## The frecency model

A name that the principal uses often, and lately, comes first among near equal matches. The term comes from Mozilla Places; zoxide gives the same idea for folders. This section is the whole model: it names no store and no process, so a program with another store (`gui_toolkit` keeps its table in LMDB) follows it as it is. The code is `src/library/support/line_editor/frecency.odin`.

**A use.** A use is one act of the principal that names one or more names: the run of an entry of a list, or a line that runs. Each name of a use counts once in that use, however often the use names it. A use counts its first 16 names (`FRECENCY_NAMES_PER_USE`); an empty name counts nothing. A use with no name still decays the table. A choice that does not run (a name taken into a line that never runs, a row that is only chosen) is no use. An act that destroys its thing (the close of a window) is no use: the name is gone after it.

**The key.** A name is kept by its key: the FNV-1a hash of 64 bits of its bytes (offset basis `0xCBF29CE484222325`, prime `0x100000001B3`), with 0 replaced by 1, so 0 means no key. The key is the name alone, not its kind: a use of the window `plasma` lifts the process `plasma` too. A collision of two keys gives one name the bonus of another: at most 8 points, never a match.

**The decay.** The decay counts uses, not time. With `W = 1024` (`FRECENCY_USE_WEIGHT`) and `D = 5` (`FRECENCY_DECAY_SHIFT`), one use does, in this order:

1. For each kept name: `score = score - ceil(score / 2^D) = score - ((score + 31) >> 5)`. A name whose score becomes 0 leaves the table.
2. For each name of the use: `score = score + W`, or `score = W` for a name that the table does not hold.

So one use gives 1024; each use of other names keeps 31/32 of a score, and a score halves after 22 uses (1024 to 501). The rounding up takes a score to 0: a name used once leaves after 128 uses of other names, and a name at the highest score after at most 260. No score reaches `L = W << D = 32768` (`FRECENCY_SCORE_LIMIT`): at a score near `L` the decay takes `W`, which is what a use adds, so the highest score that uses reach is 32 737.

**Stored records.** A store implementation reads each entry through one check: a score above `L - 1` is clamped to `L - 1`, an entry with key 0 or score 0 is dropped, and a damaged stored table fails the read and gives an empty table.

Why uses and not days: the order of the acts of the principal is what the ranking needs, a machine that was off for a week keeps it, a clock that the principal never set changes nothing, and a test needs no clock. Mozilla weighs each visit by its age in days, and zoxide ages its scores when their sum passes a bound; both read a clock.

**The bound in size.** A table holds at most 64 names (`FRECENCY_CAPACITY`), sorted by key: a lookup is a binary search of at most 6 steps, and the table is 64 × 12 bytes of data. A new name in a full table takes the place of the name with the lowest score that is not a name of the same use; on equal scores, the first in the order of the keys. Because a use counts at most 16 names, below the capacity, each name of a use always finds a place.

**The bonus, and how it joins the match.** With `B = 7` (`FRECENCY_BONUS_SHIFT`):

```
bonus = min(bit_length(score >> B), 8)
ranked score = match score + bonus
```

`bit_length(0) = 0`. A name that the table does not hold has the bonus 0. One use (1024) gives 4; 512 gives 3; regular use (16 384 and more) gives 8. The bonus is added only to a name that matches: it never makes a name match, and it changes the order, never the matched places. The highest bonus, 8 (`FRECENCY_BONUS_LIMIT`), is less than each structural bonus of the match: a run (16), the start of a part (24), the start of the name (32). So a used name passes a match that differs only by its gaps (each byte of a gap costs 1), never a match with one more start of a word or one more run. The order after the ranked score is the tie order of the caller, then the shorter name, then the order of the bytes.

Refused forms of the model:

- **A bonus without bound.** A used name is then first for each query that it matches, and the first row is no answer to the typed characters.
- **A bonus as a factor of the match score.** A long query with a high score then gains more than a short one, and the bound of the bonus is no longer a fact that the guides can state.
- **The key with the kind of the name.** Two rows of one name then gain apart, and a use of a window does not lift the start of its process.
- **A decay by the clock.** Above: the order of the acts, not their hour.

## Where modus keeps the table

- **The console** keeps no new state. A use is each line that its history adds; the names of a line are each run of letters, digits, `_` and `.` that does not start with a digit, without a `.` at its ends, and the part after its last `.`, because the completion of a member lists that part. A line that a completion gave, a line that a palette row ran in the console, and a line typed in full count the same. The table is built again from the kept lines at the load of the history, the oldest first, then each added line counts. The history already survives a stop in the store of the history of the console, for its principal, with its checks ([`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "6. The line history across a stop"): a history that a check refuses gives an empty history and an empty table, and `history_clear()` empties both. So the frecency adds no object, no commit and no grant, and the generations that the machine tests count do not move.
- **The palette** counts each run of an entry: a start, a window brought to the front, a command, a setting. It keeps its table in the memory of the compositor, beside its recent choices: [palette.md](palette.md) refuses a store for the choices of the compositor, and a restart of the machine loses the table. The commands of the palette run as lines in the console, so the line history of the console counts them across a stop; the entry table does not carry that count to the panel.

Refused forms:

- **A frecency object in the store of the history.** Each use then makes a commit, which moves the generations of the machine tests, and the store needs more than its limit of 4 blocks. The history already holds each use.
- **A store for the palette.** Refused by [palette.md](palette.md): a new store and a new grant of the compositor for an order of rows.

## The subtle points

- **The places stay the places of the match.** The bonus changes the order and never the drawn places.
- **The tie order stays.** After the score with its bonus: the recent choices of the palette and the age of a history line, then the shorter name, then the order of the bytes.
- **The search of the history has no bonus**: its candidates are lines, and their order is their age.
- **The table is in the memory of its owner.** Each procedure first brings a count out of its bounds back into them, as the history does, so a fault of the owner gives a wrong bonus and never a read past the table.

## Sources

- fzf, MIT licence: <https://github.com/junegunn/fzf>, `src/algo/algo.go`, `FuzzyMatchV1` (the pass forward and the pass back) and `FuzzyMatchV2` (the alignment with bonuses).
- frizbee, MIT licence: <https://github.com/saghen/frizbee>, the README, "Prefiltering" (blocks of the name and masks for each needle character) and "Smith Waterman" (why the form across candidates was left). fff, the file finder of opencode, uses frizbee.
- Mozilla Places frecency: <https://firefox-source-docs.mozilla.org/browser/urlbar/ranking.html>.
- zoxide, MIT licence: <https://github.com/ajeetdsouza/zoxide>, the aging of its scores.

No code is copied: the matcher is written for this system from the ideas above.

## State

Built: the scalar form as the reference, the portable vector form (`fuzzy_match_vectors.odin`) with its prefilter, the frecency table with its decay and its bound, the bonus in the ranking, the frecency of the console from its history, the frecency of the palette in the memory of the compositor. The host tests compare the two forms on edge cases and on 200 000 random inputs, and an opt-in measure (`-define:MEASURE=true`) prints the names matched per second of each form.

Left: the entry table of the palette provider does not carry the frecency of the console to the panel; the palette counts its own runs only, and loses them at a restart.

# The similarity finder: how similar the code is, and the template of a factoring

## Purpose

`modustool similarity` reads the Odin sources of the repository and measures how similar their code pieces are. It gives a similarity score from 0 to 1 for each pair of code pieces that it compares, and not only "equal" or "not equal". It groups the similar code pieces in similarity families. For each family it gives the factoring template: the code that the members share, with a blank where they differ, and the arguments of each member. It ranks the families by the size that a factoring saves, and proposes a home for the factored procedure.

A human or an agent then decides what to factor. A similarity can be deliberate: two modules that show one property each, a kernel copy of a support procedure, a test case beside the next case. The finder gives the facts and the measures. It never decides, and it never edits a source.

The study of prior art: [`docs/research/code_similarity_prior_art.md`](../../../docs/research/code_similarity_prior_art.md). The terms are in [`docs/glossary/project.md`](../../../docs/glossary/project.md): similarity finder, code piece, similarity score, similarity family, factoring template and blank.

## Constraints

- The tool uses the standard library of Odin only. `core:odin/parser` gives a syntax tree with no types and no resolved names. So each decision of the finder reads the syntax, and the finder states where the syntax is not enough.
- The corpus is the Odin sources of `src/` and `tools/`: about 312,000 lines, 785 files, about 9,700 procedures, about 3 million syntax nodes. A step that is linear in the nodes is cheap. A step over all pairs of procedures (about 47 million pairs) needs a filter.
- The finder runs outside the build and outside `modustool check`. It can take minutes. Its host tests are part of the host tests of the tool, as each other test is.
- The output is reproducible: the same sources give the same bytes of the report and of the tables. No order comes from a hash map, a thread or a random number.
- A factoring proposal obeys the import rules of the repository ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The imports of the sources of the system") and the rule that no source of the system calls an allocator ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The rules that a check holds"). The finder never proposes a home that breaks a rule.

## The chosen form

### 1. What the finder reads

- Each `.odin` file under `src/` and `tools/`, one folder as one package, parsed with `core:odin/parser`.
- It does not read a file that the reuse list names as a copy of a work of others (the cryptography of `origin.manifest`): that code is not the code of the project, and a factoring of it breaks its origin check ([reuse_list.md](reuse_list.md)).
- It does not read a source that a command of the tool writes: the files of the list `SIMILARITY_GENERATED_SOURCES`, which names the output constant of each converter (today `FONT_OUTPUT` of the command `font`), and each file whose first line starts with `// This file is the output of`. The source of such a file is not Odin code of the project.
- It reads the host tests and the test scenarios, and reports them in their own area. A test case is often similar to the next case on purpose.
- It keeps three areas apart in each measure: the system (`src/`, no test), the tool (`tools/`, no test), the tests.
- After the parse of a package, the finder copies each tree into a flat table of nodes: the kind, the role, the label, the parent, the first child, the next sibling, the size of the subtree, the byte range and the lines in the file. The subtree of a node is the interval of the table from the node to the node plus its size. Then it frees the trees of the parser of that package. A label is a slice of the source text, or a string that the normal form writes. The table stays in memory for the whole run; the memory of the parser for one package does not.
- The comparison of the near pairs runs on several threads: each thread takes the next pair and writes its own place of the result, so the threads change no output. The parse runs on one thread; the terminal prints its time beside the time of each other phase.

### 2. The code pieces

A code piece is a part of the code that a factoring can replace with one call. The finder compares three kinds:

- **A procedure**: the body of a procedure literal, with its signature.
- **A run of statements**: two or more consecutive statements of one block.
- **An expression**: an expression that is not a whole statement.

A code piece has a minimum size: 40 nodes for a procedure and a run, 12 nodes for an expression. A smaller code piece saves less than the call that replaces it. The report counts the families just below each minimum, so a change of a minimum is decided by a measure.

### 3. The normal form

Before it hashes or compares, the finder rewrites each code piece into a normal form. The normal form removes the differences that do not change what the code does. Each rule is one-way, and makes the tree smaller or puts it in a fixed order, so the rewriting ends.

What the normal form removes:

- **Layout and comments.** The syntax tree has none.
- **Parentheses.** A parenthesized expression becomes its inner expression.
- **The names of the locals.** A local is a parameter, a named result, a name that `:=` or `::` declares inside a body, a variable of a `for` or of a type `switch`, a label. The finder resolves the locals by the scopes of the syntax. Each local becomes its binding number: the order of its declaration in its procedure. `a := x; b := a` and `p := x; q := p` are then equal. `a := x; b := x` is not equal to them: the data flow is different, and the binding numbers keep that difference.
- **The name of an import.** `fmt.println` under `import fmt "core:fmt"` and under another import name become the import path and the name.
- **The direction of a comparison.** `a > b` becomes `b < a`, and `a >= b` becomes `b <= a`.
- **A negated equality.** `!(a == b)` becomes `a != b`, and `!(a != b)` becomes `a == b`. A negated order (`!(a < b)`) stays: for a floating-point NaN it is not `a >= b`.
- **A double negation.** `!!a` becomes `a`, and `-(-a)` becomes `a`.
- **An assignment with an operator.** `x += y` becomes `x = x + y` when `x` is a pure place: a local, or a field or an index of a pure place, with a pure index.
- **The order of the operands of `==`, `!=`, `&`, `|` and `~`.** The two operands go in the order of their shape hash, when both are pure. These five operators are commutative for every type that Odin gives them.
- **A counted loop.** `for i := a; i < b; i += 1 { ... }` becomes `for i in a..<b { ... }` when the body assigns no value to `i`.
- **A negated condition with two branches.** `if !c { A } else { B }` becomes `if c { B } else { A }`.
- **A boolean return.** `if c { return true }; return false`, and the same with `else`, become `return c` when `c` is a comparison, a negation or a logical operator: the syntax then shows that `c` is a boolean.
- **The arithmetic of two integer literals.** `4 * 1024` becomes `4096`. Odin computes such constants with no overflow, so the value is the same.

An operand is pure when it holds no call and no assignment. A call of a built-in procedure that reads only (`len`, `cap`, `size_of`, `align_of`, `offset_of`, `min`, `max`, `abs`) and a conversion to a built-in type are pure.

What stays, because the syntax does not prove that it is the same behaviour:

- The order of the operands of `+`, `*`, `&&` and `||`. In Odin `*` is not commutative for a matrix and a quaternion, and `+` is not commutative for two constant strings. A short-circuit operator with a call on one side evaluates the call or not.
- The names of the fields. `x.count` and `x.length` read different memory.
- The names of the globals: a procedure, a constant, a type or a variable of a package. A call of `send` and a call of `post` are different calls.
- The directives (`#force_inline`, `#no_bounds_check`), the calling convention, `defer`, `or_return`, `context`.

The finder records each rule that changed a code piece. When two code pieces are equal only after a rule, the report says which rules made them equal. This is the part of type 4 that the syntax can prove.

### 4. The hashes

Each node gets two hashes, from its kind, its label and the hashes of its children, bottom-up, with the 64-bit xxHash of `core:hash`:

- **The exact hash.** A local is its binding number, a literal is its value, a type is its name. Two subtrees with one exact hash are equal after the normal form. The finder confirms each match on the nodes, because two different subtrees can have one 64-bit hash.
- **The shape hash.** A local is "a local", a literal is its kind (integer, float, string, rune), the name of a type is "a type". Two subtrees with one shape hash differ only in the names of the locals, the values of the literals and the types: type 2.

A binding number counts from the start of the procedure, because a bottom-up hash cannot count from the start of each subtree. So two runs of statements at different places can have different exact hashes and still be equal. The shape hash groups them, and the anti-unification finds that they are equal (section 6).

### 5. The candidates

Three passes give the groups and the pairs that the anti-unification then compares:

- **Equal hashes.** The procedures and the blocks with one exact hash form a group. The procedures and the blocks with one shape hash form a group, unless all its members share one exact hash: the equal group holds them already. The expressions with one shape hash form a group from three members. A group of one code piece is no group.
- **Repeated runs.** In each block and each case, each statement becomes the number of its shape hash. A suffix array of all the lists, with its longest common prefixes (the algorithm of Kasai), gives each run of statements that occurs two or more times. The finder builds the suffix array by prefix doubling. The end of each list is a unique number, so no run crosses the end of a list. A run is kept when no longer run to its left has the same occurrences, and when its occurrences do not overlap: overlapping occurrences are one statement repeated in a row, which an expression family finds, and a run of them counts it many times.
- **Near procedures and blocks.** For type 3, each procedure and each block of at least the minimum size that no family of equal hashes holds, and that is not inside a procedure of such a family, gets two vectors: the count of each node kind, and of each pair of a parent kind and a node kind (the vectors of Deckard). The finder compares two code pieces only if the filter below cannot exclude them. The filter is sound: it never excludes a pair whose similarity score reaches the threshold.
  - The prefixes: the matched nodes of a pair have the same pair of kinds on both sides, so the overlap of the two multisets of pairs is at least the matched nodes. For a score `t`, that overlap is at least `t / (2 - t)` times the larger size. Each piece keeps the prefix of its multiset in one fixed order of the features, the rarest first, of `size - ceil(share · size) + 1` units; two multisets with that overlap share a feature of their prefixes (the prefix filtering of SourcererCC). An index of the features of the prefixes gives the candidates.
  - The sizes: the score of two code pieces of sizes `m <= n` is at most `2m / (m + n)`. The finder sorts the code pieces by size and compares each one only with the code pieces whose size keeps that bound at the threshold or more.
  - The vectors: the nodes that the template keeps are the same in both code pieces, so the difference of the two vectors comes only from the blanks and the unmatched children. The L1 distance of the vectors is thus at most the distance `D` of section 6, and the score is at most `1 - L1 / (m + n)`.

### 6. The anti-unification and the similarity score

The finder anti-unifies two code pieces from the top, as the least general generalization of Plotkin does:

- Two nodes match when they have the same kind and the same label. A matched node goes into the template, and the finder goes on with the children.
- Two nodes that do not match become a blank. The two subtrees under it are the arguments of the blank.
- The same pair of arguments, at two places, gives the same blank. So `f(x, x)` and `f(y, y)` give one blank, not two.
- Two locals match when their binding numbers match in a map that stays one to one across the whole code piece. A local that breaks the map becomes a blank: the two code pieces move their data in a different way there.
- A list whose length can differ (the statements of a block, the fields of a composite literal, the cases of a `switch`) is aligned before the children are compared, unless the two lists have one length and one kind at each place. The alignment is the longest common subsequence, where two children of the same kind can align, and the weight of a pair is the number of matched nodes of their own anti-unification. A child with no partner is an unmatched child.
- A call with another count of arguments is one blank as a whole.

**The bound of the alignment.** The weighted alignment keeps one weight for each pair of subtrees that it compares, so its memory and its time grow with the product of the sizes of the two pieces. Above `SIMILARITY_WEIGHTED_ALIGNMENT_NODE_PRODUCT_MOST` (1,000,000: two pieces of 1,000 nodes), the finder weighs two children by their shape only: the same shape weighs its size, the same kind weighs 1. Such an alignment can miss a better one; the report counts these pairs and marks each family that holds one. One pair then costs at most about one million weights, and the count of pairs is a measure of the report, so a run on the whole repository ends.

**The bound for the filter.** The comparison of the candidate pairs computes the weights alone, with no binding map: the map can only lower the matched nodes, so this count is at least the count of the anti-unification. A pair above the bound of the alignment is unified whole, because its weights are no bound. Only a pair whose count reaches the threshold is anti-unified with its blanks.

The distance of two code pieces `A` and `B` is `D`: the size of the two arguments of each blank, plus the size of each unmatched child. Their similarity score is `1 - D / (|A| + |B|)`, which is `2·|T| / (|A| + |B|)`, where `|T|` is the count of the matched nodes of the template. It is 1 when the two are equal after the normal form, and 0 when they share no node. It is the measure of CloneDR, computed on the template of the anti-unification.

A blank has a kind, from its place. The kind says if Odin can pass it as a parameter, and what it costs:

| Kind | Where | In the factored procedure | Cost |
|---|---|---|---|
| Value | An expression that is read | A parameter | 1 |
| Type | A type expression, a conversion to a type | A polymorphic parameter `$T` | 1 |
| Place | An expression that is assigned or addressed | A pointer parameter | 2 |
| Procedure | The name of a called procedure | A procedure parameter | 2 |
| Not a parameter | An operator, a field name, a directive, a node of another kind | None: Odin cannot pass it | none |

A template with an unmatched child, or with a blank that is not a parameter, is not one procedure. Its family is a family of similar behaviour (section 8).

For a run of statements, the template also has the data flow of an extracted procedure. A local that the run reads, and that is declared before the run, is an input. A local that the run declares or assigns, and that the procedure reads after the run, is an output: a result. A run with a `return`, a `break` or a `continue` that leaves the run, an `or_return`, or a `defer` is not one call: the report marks it "control leaves the run".

### 7. The families

- The first member of a family is its first member in the order of the table: the order of the packages, of the files and of the bytes.
- The template of a family is computed from the anti-unification of the first member with each other member. A node of the first member is in the template when it matched in each of them. A matched node has a matched parent, so the template is a tree, and the order of the members does not change it. A blank is a node of the first member outside the template whose parent is in it; its argument in each member is its partner there, or nothing where the member does not have it: such a place is a gap, printed `?-`.
- Each family keeps the coverage rule: the coverage of a member is `|T| / |member|`, and a member under 0.70 leaves the family, the member that the template covers least first, until each member reaches it. This holds for each pass, so a group of one shape hash with a few members that differ much keeps the others.
- A family of equal code pieces is a group of one exact hash whose anti-unification has no blank, or a group of one shape hash with no blank.
- A family of type 2 is a group of one shape hash, or a group of repeated runs.
- For type 3, the finder sorts the compared pairs by their count, from the highest. It joins the families of a pair when each member of the joined family keeps the coverage. This is complete linkage on the template: a member never joins through a chain of near neighbours while it shares little with the others.
- A family whose members are all inside the members of one larger family, with as many uses or more, is not reported: the larger family holds it. Of two families with the same members, the first found stays.
- The report gives the score of each member with the first member, and the lowest of these scores for the family.

### 8. The categories

Each reported family has one category. The first that applies, in this order: platform variant, similar behaviour, kept apart by the rules, repeated expression, utility to centralise or local repetition, parametric family.

| Category | What it is | What a factoring does |
|---|---|---|
| Utility to centralise | Equal code pieces in two or more packages | One procedure in one library package |
| Local repetition | Equal code pieces in one package | One procedure in the package |
| Parametric family | One template whose blanks are all parameters | One procedure with a parameter for each blank |
| Similar behaviour | A template with a gap, a child that only some members have, a blank that is not a parameter, or a run or an expression that control leaves | A design is needed: the members do close but different things |
| Repeated expression | An expression with three or more uses | A named procedure or a constant |
| Kept apart by the rules | Every home breaks an import rule or the allocator rule | None: the copies are forced, or the code moves to a contract package by a decision |
| Platform variant | The members are in files with the same name and another system suffix (`_linux`, `_other`) | None: the variants are the design of the platform code |

### 9. The home of a factored procedure

The finder proposes the home from the packages of the members and from what the template names:

- If all the members are in one package, the home is that package.
- If a member is in `src/modulus` or in `src/library/modus/contract`, the home can only be a contract package, because those two import no support package. The category is then "kept apart by the rules", and the home is "a contract package, by a decision". A contract package holds what two parties agree on, so the move is a decision, and the finder does not propose a package by name.
- Else the home is a support package. The finder proposes the support package that each file of the members already imports, if one exists. Else it proposes a new support package.
- A home under `src/` cannot hold a template that calls an allocator or names a package that the system does not import (`fmt`, `os`). A family with such a template, a member under `src/` and a member under `tools/` is kept apart by the rules.

### 10. The ranking

The rank of a family is the count of nodes that its factoring saves, in the sense of the compression of Stitch. Take a family of `k` uses whose template has `|T|` matched nodes and blanks of costs `c_1 ... c_h`:

- Each use becomes one call node. Its arguments stay at the place of the use, so they are not saved.
- The procedure costs its template, and the cost of the blank of each parameter.
- The saved nodes are `(k - 1) · |T| - k - (c_1 + ... + c_h)`.

The report gives the same measure in lines: the lines of the template, less one line for each call and two lines for the signature. The nodes rank; the lines are for the reader.

Two families can share code: a family of runs of statements inside a family of procedures. A factoring of both does not save both sizes. So the finder ranks as Stitch does. It takes the family with the most saved nodes, and marks the nodes of its members as used. It counts the saved nodes of each other family again, without those nodes, and repeats. The headline measure "a factoring of the ranked families saves N nodes and L lines" is the sum of this greedy selection, not of all the families.

A family of similar behaviour has no saved nodes: no one call replaces its members. It is ranked by the size of its template, in its own list.

### 11. The kept list

A family that a human or an agent decided to keep is one line of `tools/modustool/similarity/similarity_kept.txt`: the template hash in 16 hexadecimal digits, a space, and the reason in words. The template hash is the hash of the template with its blanks, after the normal form. It does not change when a file moves, when a local is renamed, or when an argument changes. The report lists the kept families in their own section, with their reason, and counts them in the measures but not in the ranking. A line whose hash names no family is listed as stale, so the file stays true.

### 12. The commands and the output

- `modustool similarity` reads the sources and writes the report on the terminal and in `build/similarity/report.txt`, with two tables beside it.
- `modustool similarity near <file>:<line>` gives the code pieces most similar to the procedure that holds the line, each with a score of 0.5 or more, with its template and its blanks.
- `modustool similarity pair <file>:<line> <file>:<line>` gives the score of two procedures, whatever its value, with their template and each blank.

The report:

1. **The measures.** The files read, and the files not read with the reason. The procedures, the nodes and the lines of each area. For the near pass: all the pairs, the pairs that share a feature of their prefixes, the pairs that the sizes and the vectors keep, the pairs whose count reaches the threshold, and the pairs above the bound of the alignment. The count of groups just below each minimum and of pairs just below the threshold. The families found, held, reported, kept and ranked, and the members that the coverage dropped.
2. **The totals.** For each area and each category: the nodes and the lines in a family, counted once where families share code, and their share of the area. The saved nodes and lines of the greedy selection.
3. **The ranked families.** For each: the rank, the category, the saved nodes and lines, the count of uses, the packages, the lowest score with the first member, the size of the template, its blanks and its gaps, the proposed home, the template hash, the rules that some members needed, the flow of a run. Then the template, and each member with its file, its first and last line, its coverage, its score with the first member and the argument of each blank.
4. **The factorable families that save nothing** after the ranked ones.
5. **The families that no call replaces**: similar behaviour, kept apart by the rules, platform variant, by the size of their template.
6. **The kept families**, and the stale lines of the kept list.

The terminal shows the first 30 families of each list (`SIMILARITY_TERMINAL_FAMILIES_MOST`), then the time of each phase: the read of the files, the parse, the normal form and the hashes, the candidates, the anti-unification of the near pairs, the families, the ranking. A time is a measure of one run, never a condition. It is printed on the terminal only: the report file holds no time, so the same sources give the same bytes.

The finder prints a template from the source text of its first member: it replaces the byte range of each blank with `?1`, `?2`, and so on, and the byte range of each gap with `?-`. The text keeps the layout of the source, and needs no printer of Odin.

The two tables are tab-separated, with one header line, in the order of the report:

- `build/similarity/families.tsv`: one row for each reported family, with its rank, category, saved nodes and lines, uses, lowest score, template size, blanks, gaps, home, template hash, first member and the reason of a kept family.
- `build/similarity/members.tsv`: one row for each member, with the template hash of its family, its file, first and last line, package, area, score with the first member, coverage, and the arguments of the blanks.

The finder writes only under `build/similarity/`.

### 13. The tests

Host tests of the tool, on small sources in the test, each with a known answer:

- Two procedures equal but for the names of the locals, in two packages of the support library: one family, "utility to centralise", score 1, no blank, the home in the support library.
- `a := x; b := a` against `a := x; b := x`: not equal; one blank at the second `x`.
- Two procedures that differ by one literal: one value blank; the template text holds `?1`; each member gives its literal.
- One procedure for `u32` and for `u64`: one type blank.
- The same pair of different expressions at two places: one blank, not two.
- `if a > b { return true }; return false` against `return b < a`: equal after the normal form, and the report names the two rules.
- `x * y` against `y * x`: not equal, because `*` keeps its order.
- An expression with five uses: one family "repeated expression" with 5 uses.
- A run of statements in two procedures, with one input and one output: the template names them.
- A run with a `return`: marked "control leaves the run".
- One member under `src/modulus` and one under `src/library/modus`: "kept apart by the rules", and the home "a contract package, by a decision", as section 9 says.
- Two procedures that differ by one field name: a blank that is not a parameter, "similar behaviour".
- Two procedures that differ by one added statement: one child that only the longer has, the shorter matched whole, and the score `1 - (difference of the sizes) / (sum of the sizes)`.
- The runs inside two equal procedures: held by the family of the procedures, and not reported.
- Two equal procedures and a run that they share with a third procedure: the greedy selection ranks one of the two families, and the headline is its saved nodes.
- A line of the kept list: the family leaves the ranking and stays in the measures. A line with the hash of no family is stale, and the report names it.
- Files `x_linux.odin` and `x_other.odin` with one procedure each: "platform variant".
- The filter of the near pairs: each pair whose count reaches the threshold, of all the pairs, is among the filtered pairs.
- Two runs on the same sources: the same bytes of the report and of the tables.

## Refused forms

- **A text or token comparison (Baker, CCFinder).** It is fast, but a repeated run of tokens is often not a unit of the syntax, so it gives no template and no procedure. The finder takes its one good idea, the suffix array over a stream, on the shape numbers of whole statements, as Koschke does on syntax trees.
- **A bag of tokens (SourcererCC).** It ignores the order and the structure, so `a - b` and `b - a` are equal for it. It is made for hundreds of millions of lines; this corpus has 312,000.
- **Locality-sensitive hashing of the vectors (Deckard).** It misses a near pair with a small probability, and its result depends on random numbers. The sound filter of sizes and vectors misses no pair at the threshold, and 9,700 procedures need no more.
- **A program dependence graph (Komondoor and Horwitz, Krinke).** It needs the types and the resolved names of each expression, which the standard library does not give, and the search for similar subgraphs is not polynomial. The binding numbers of the locals keep the part of the data flow that the syntax shows.
- **Random tests of behaviour (Jiang and Su).** A code piece of a freestanding module cannot run alone on the host: it reads shared memory, rings and the kernel entry.
- **An e-graph with equality saturation over the corpus (egg, babble).** Rules in both directions, such as associativity, make an e-graph of 3 million nodes grow past the memory. The rules that find the most (`x * 2` and `x << 1`, `x + 0`) are true only for some types, which the syntax does not give. The one-way rules of the normal form take the safe part of that theory, with no e-graph and no extraction.
- **A library learner as the search (Stitch, babble, DreamCoder).** They work on a few hundred small programs of a functional language with no side effects. The finder takes three of their ideas: the compression as the ranking, the rule "used at least twice, least general", and the greedy loop that takes one family and counts again.
- **Only "equal" or "not equal" for each pair.** Two code pieces that are 90% the same are the most useful finding, and a yes or no hides them. The score gives the measure, and a threshold only selects what the report lists.
- **Families as the connected parts of the near pairs.** A chain of near pairs joins code pieces that share little. The coverage of the template by each member keeps a family whole.
- **Options for the minimums and the thresholds.** The values are constants of the tool, and the report counts what each one excludes. A change of a value is then a decided change, with its measure.
- **A mark in the source for a deliberate copy.** It must be written in each member, and a move of the code loses it. One kept list, keyed by the template hash, names the family once.
- **A page of the site.** The report is a measure of one state of the sources, for a developer who factors. The site publishes the guides of the system; a measure of one run does not go there.
- **A check that fails on a similarity.** A similarity can be deliberate, and only a human or an agent can judge it. The finder reports; it never fails a build or a check.
- **An edit of the sources.** The finder proposes. A factoring changes the names, the imports and the comments, and needs a review that the finder cannot do.

## Subtle points

- **The syntax has no types.** A call `T(x)` is a conversion when `T` is a type. The finder knows the built-in types and the types that a package declares at its top level. A type of another package, written `pkg.T(x)`, is read as a call. So the report can call a type blank a procedure blank.
- **A name that `using` brings into a scope** is a field, but the finder reads it as a global of that name. Two code pieces with `using` on different records can look equal. The report marks a family whose members hold `using`.
- **`when` branches and build tags.** The finder reads each branch of a `when` and each file of each platform. Two branches of one `when` are often a deliberate pair, as the platform variants are.
- **A local constant or procedure inside a body** is a local. A procedure literal inside a body is a code piece of its own too.
- **The minimum of 40 nodes** is about 4 lines of Odin. A smaller family is often an idiom of the language, not a missing procedure.
- **The template depends on the first member.** Each alignment is with the first member, so a better alignment between two other members does not count. The first member is fixed by the order of the table, so the template is the same on each run, not the best one.
- **The weighted alignment is quadratic** in the sizes of the two pieces, and it recurses. The finder keeps the weight of each pair of subtrees that it computed, and does not compute it again. Its bound is in section 6.
- **The near pass leaves out the pieces of the families of equal hashes.** A procedure of an equal family is not compared with a third procedure that is near to it. The family of the near pass then lacks the two equal members; the equal family is reported on its own.
- **A run repeated in a row** (one statement many times) is not a run family: its occurrences overlap. An expression family finds its expression when it is large enough.
- **The lowest score of a family** is the lowest score of a member with the first member, not of each pair of members.
- **A score of 1 is "equal after the normal form",** not "the same behaviour". Two procedures that read different globals of the same name in two packages are not equal: the global keeps its import path.
- **The kernel and a support package** often hold the same small procedure on purpose, because the kernel cannot import the support package. Section 9 says that, and a move to a contract package is a decision, not a proposal of the tool.

## State

Built: the command `similarity` with `near` and `pair` (`tools/modustool/similarity/similarity_*.odin`), the kept list, the host tests of section 13, and the guide ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The similarity finder").

Left: the minimums (40 and 12 nodes) and the coverage (0.70) are first values; the counts of the report just outside them decide a change after the first runs on the repository.

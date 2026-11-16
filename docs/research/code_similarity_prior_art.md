# Code similarity prior art: research report

Status: research note for the design of the similarity finder ([`src/md/infrastructure/similarity_finder.md`](../../src/md/infrastructure/similarity_finder.md)). Each source below was fetched in the session that wrote this note.

## 1. The clone types

Roy and Cordy give the four types that the field uses. Type 1: the same code, with other spaces, layout and comments. Type 2: the same structure, with other names, literals and types. Type 3: type 2 with statements added, changed or removed. Type 4: other syntax for the same computation. Their survey also says that 5% to 20% of a large system is duplicated code in the studies that it reviews.

- C. K. Roy, J. R. Cordy, "A Survey on Software Clone Detection Research", Queen's University technical report 2007-541. https://research.cs.queensu.ca/TechReports/Reports/2007-541.pdf
- The same four types are the definitions of SourcererCC, section 2. https://arxiv.org/abs/1512.06448

## 2. Text and tokens

- **Suffix trees on a token stream.** Baker's `dup` finds the longest repeated runs of lines, with a parameterized match that renames identifiers consistently. It is linear in time, and finds type 1 and type 2 runs. A run does not follow the syntax: it can start in one procedure and end in the next. B. S. Baker, "On finding duplication and near-duplication in large software systems", WCRE 1995. https://doi.org/10.1109/WCRE.1995.514697
- **CCFinder.** It transforms the token stream (identifiers and literals become one token kind), then finds repeated runs with a suffix tree. It reports type 1 and type 2 clones in millions of lines. It also gives metrics for each clone set. T. Kamiya, S. Kusumoto, K. Inoue, IEEE TSE 28(7), 2002. https://doi.org/10.1109/TSE.2002.1019480
- **SourcererCC.** A block is a bag of tokens. Two blocks are clones when their overlap is above a threshold (for example 80% of the larger block). An inverted index with prefix filtering and a token order cuts the number of compared pairs, with no loss of a pair above the threshold. It finds type 1 to type 3 clones in 250 million lines on one workstation, in 4.5 days. It ignores the order and the structure of the tokens. H. Sajnani et al., ICSE 2016. https://arxiv.org/abs/1512.06448

## 3. Syntax trees

- **CloneDR.** It hashes each subtree, as the common subexpression elimination of a compiler does, and compares only the trees of one bucket. For near clones it uses a hash that ignores the identifiers, then a similarity `2·S / (2·S + L + R)`, with S the shared nodes and L, R the nodes of each side only. It also finds sequences of statements, and writes a macro with parameters that removes each clone. I. D. Baxter et al., "Clone detection using abstract syntax trees", ICSM 1998. https://doi.org/10.1109/ICSM.1998.738528 ; text: https://leodemoura.github.io/files/ICSM98.pdf
- **Deckard.** Each subtree becomes a characteristic vector: the count of each node kind in it. A sliding window over the serialized tree adds vectors for runs of statements. Locality-sensitive hashing groups the vectors that are near in Euclidean distance. It scales to the Linux kernel and the JDK. The hashing is probabilistic: a pair of near vectors is missed with a small probability. L. Jiang, G. Misherghi, Z. Su, S. Glondu, ICSE 2007. https://doi.org/10.1109/ICSE.2007.30 ; text: https://people.inf.ethz.ch/suz/publications/icse07.pdf
- **Suffix trees on syntax trees.** The tree is serialized, and a suffix tree finds the repeated runs of nodes; the runs are then cut to whole syntactic units. It is linear in time and space, and gives syntactic clones. R. Koschke, R. Falke, P. Frenzel, WCRE 2006. https://doi.org/10.1109/WCRE.2006.18 ; extended in Empirical Software Engineering 13(6), 2008. https://doi.org/10.1007/s10664-008-9073-9

## 4. Dependence graphs

- Komondoor and Horwitz find isomorphic subgraphs of program dependence graphs by backward slicing. They find clones whose statements are reordered or interleaved with other code. R. Komondoor, S. Horwitz, "Using slicing to identify duplication in source code", SAS 2001. https://doi.org/10.1007/3-540-47764-0_3
- Krinke finds similar subgraphs of attributed dependence graphs, with good precision and recall, and a cost that is not polynomial. J. Krinke, "Identifying similar code with program dependence graphs", WCRE 2001. https://doi.org/10.1109/WCRE.2001.957835
- Both need the data flow of the program, so a resolver of names and of types first.

## 5. Behaviour

- Jiang and Su run pieces of code on random inputs and group the pieces that give the same outputs: type 4 clones with no syntax in common. Each piece must run alone. L. Jiang, Z. Su, "Automatic mining of functionally equivalent code fragments via random testing", ISSTA 2009. https://doi.org/10.1145/1572272.1572283

## 6. Anti-unification

- **The operation.** The least general generalization of two terms keeps each node that the two have in common and puts a variable where they differ. The same pair of different subterms gets the same variable each time. G. D. Plotkin, "A note on inductive generalization", Machine Intelligence 5, 1970. https://homepages.inf.ed.ac.uk/gdp/publications/MI5_note_ind_gen.pdf
- **A survey.** D. M. Cerna, T. Kutsia, "Anti-unification and Generalization: A Survey", IJCAI 2023. https://arxiv.org/abs/2302.00277
- **Clone Digger.** The anti-unification distance of two statements is the total size of the subtrees that the variables replace. Statements are clustered by that distance, each cluster gets an id, and a suffix tree finds the repeated runs of ids. A final anti-unification of the whole runs checks them. A consistent renaming gives a smaller distance than an inconsistent one: in `i=0; i+=1; f(i)` against `j=0; j+=1; f(j)` one variable covers three places. It finds no clone with an added or removed statement. P. Bulychev, M. Minea, "Duplicate code detection using anti-unification", SYRCoSE 2008, http://syrcose.ispras.ru/2008/files/22_paper.pdf ; "An evaluation of duplicate code detection using anti-unification", IWSC 2009, https://staff.cs.upt.ro/~marius/papers/iwsc09.pdf ; tool: https://clonedigger.sourceforge.net/documentation.html
- **Refactoring tools.** HaRe for Haskell and Wrangler for Erlang find the clones that share a non-trivial anti-unifier, and turn the anti-unifier into a new function: each variable becomes a parameter, each common part stays in the body. The removal stays under the control of the programmer. C. Brown, S. Thompson, "Clone detection and elimination for Haskell", PEPM 2010, https://doi.org/10.1145/1706356.1706378 ; H. Li, S. Thompson, "Similar code detection and elimination for Erlang programs", PADL 2010, https://doi.org/10.1007/978-3-642-11503-5_10 ; "Incremental clone detection and elimination for Erlang programs", FASE 2011, https://doi.org/10.1007/978-3-642-19811-3_25

## 7. E-graphs and library learning

- **egg.** An e-graph holds many equivalent terms at once, in classes of a union-find. Equality saturation applies rewrite rules until no rule adds a term, then extracts the best term by a cost. Rebuilding and e-class analyses make it fast. M. Willsey et al., "egg: Fast and Extensible Equality Saturation", POPL 2021. https://arxiv.org/abs/2004.03082
- **DreamCoder.** It grows a library of functions from a corpus of programs, with a refactoring step that matches an e-graph (version spaces). It is slow on large corpora. K. Ellis et al., PLDI 2021. https://doi.org/10.1145/3453483.3454080 ; https://arxiv.org/abs/2006.08381
- **babble.** Library learning modulo an equational theory: equality saturation makes the corpus robust to syntax (for example `X + Y ≡ Y + X`), anti-unification of pairs of e-classes gives the candidate abstractions, and an extraction chooses the library that compresses the corpus most. Two rules decide which candidates count: an abstraction must be used at least twice, and it must be the least general pattern of the pair (`λx. x+1`, not `λx y. x+y`). It is 1 to 2 orders of magnitude faster than DreamCoder, on corpora of programs in a small functional language. D. Cao et al., POPL 2023. https://arxiv.org/abs/2212.04596 ; https://doi.org/10.1145/3571207
- **Stitch.** Corpus-guided top-down synthesis: it builds an abstraction with open places ("holes" in the paper) from the top, and prunes a branch with an upper bound of its utility. The utility is the compression of the corpus: the size that the uses save, less the size of the abstraction. It takes one abstraction at a time, rewrites the corpus with it, and starts again. It is 3 to 4 orders of magnitude faster than DreamCoder, on corpora of a few hundred programs of 76 to 189 symbols. M. Bowers et al., "Top-Down Synthesis for Library Learning", POPL 2023. https://arxiv.org/abs/2211.16605 ; https://github.com/mlb2251/stitch

## 8. What fits this repository

The facts of the repository when this note was written: `src/` holds 222,096 lines in 560 Odin files, `tools/` holds 90,682 lines in 225 files. A text search finds 7,035 procedure declarations in `src/` and 2,637 in `tools/`. 58,390 lines are host tests, and 16,235 lines are the copied cryptography of the reuse list. CloneDR measured about 10 syntax nodes for each line, so the corpus is about 3 million nodes.

- A hash of each subtree is linear, and a corpus of 3 million nodes is small for it.
- All pairs of about 9,700 procedures are about 47 million pairs. A filter that is sound (it never removes a pair above the threshold) brings that to a number that anti-unification can treat.
- The standard library of Odin has a parser (`core:odin/parser`, `core:odin/ast`) and hashes (`core:hash`). It has no resolver of types, no data flow, no e-graph and no suffix array. A form that needs the types of the expressions is out of reach, or must guess.
- Library learning works on small functional corpora with no side effects. The parts that carry over are the utility (compression), the rule "used at least twice, least general", and the greedy loop that takes one abstraction and then counts again.

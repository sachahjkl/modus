# Credits and licences: one checked document for all upstream work

## Purpose

`docs/CREDITS.md` is the one canonical document for every work of others that modus ships, reimplements, or draws ideas from. It unifies the former reuse list of `docs/PROPERTIES.md` with reimplemented algorithms, design inspirations, and upstream funding links. A reader sees in one place who produced the code, algorithms, and ideas that the system uses, under which licence, and how to fund or repay upstream authors if modus makes money.

The check of the tool is `reuse_list_check` (`tools/modustool/checks/reuse_list.odin`), documented in [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The reuse list". The site renders the document on the page "Credits and licences" (`docs/reference/licenses/`), documented in [`docs/SITE.md`](../../../docs/SITE.md), "The pages".

## Constraints

- **One canonical file.** `docs/CREDITS.md` holds the three tables. `docs/PROPERTIES.md` keeps a short section "Reuse list" that points to `docs/CREDITS.md` and holds no duplicate table.
- **Three categories.**
  1. **Reused code**: every work of others that the system ships in a module or in the boot image, or that the repository holds as a copy. It keeps every invariant of [reuse_list.md](reuse_list.md): each row names a place that matches the repository records, a valid SPDX expression (or `NONE`), and a licence file that exists and matches the record.
  2. **Reimplemented algorithms**: algorithms and papers implemented from scratch in `src/`, with their authors, upstream project, reference licence, place in `src/`, and funding link. Every place must exist in the repository.
  3. **Inspirations**: systems and ideas that shaped the design of modus (covering every **Reuse** field of `docs/PROPERTIES.md`), with their authors or project, what modus took and what it left, a link, and a funding link.
- **No empty required cell.** Every cell in all three tables must be non-empty. The funding column holds a GitHub Sponsors, Open Collective, Liberapay, or foundation donate URL, or `—` when none is known.
- **One page on the site.** The site maps `docs/CREDITS.md` to `docs/reference/licenses/` ("Credits and licences") and skips it in `docs/guides/`, so the site has no duplicate page. Keeping the folder `docs/reference/licenses/` preserves all existing links from module cards, search entries, and redirect pages.

## The chosen form

- **Three Markdown tables in `docs/CREDITS.md`** under the level-2 headings `## Reused code`, `## Reimplemented algorithms`, and `## Inspirations`:
  - `## Reused code`: `| Work | Place | Upstream | Authors | License | License file | Funding |`
  - `## Reimplemented algorithms`: `| Algorithm | Authors | Upstream | Reference license | Place | Funding |`
  - `## Inspirations`: `| System or idea | Authors | Took and left | Link | Funding |`
- **Checked by `modustool check`.** `reuse_list_problems` parses all three tables, refuses a missing section, a wrong header, a wrong column count, an empty cell, a duplicate key, a missing path in the repository (for Reused code and Reimplemented algorithms), a bad SPDX expression, or a mismatch with the repository records.
- **Rendered on the site.** The page "Credits and licences" (`docs/reference/licenses/`) renders the three tables from `docs/CREDITS.md`, followed by the generated tables of what the system holds (for module-card and search anchors) and what builds and tests it. The footer of every page links to it as "Credits and licences".

## Refused forms

- **Keeping the reuse table in `docs/PROPERTIES.md` beside `docs/CREDITS.md`.** Two tables of reused code drift apart.
- **Publishing `docs/CREDITS.md` as both a guide and a reference page.** One subject has one page on the site.
- **Moving the page URL from `docs/reference/licenses/` to `docs/reference/credits/`.** Moving the folder breaks module card anchors and adds redirects for no benefit.
- **Allowing empty cells in the funding column.** An empty cell does not tell a reader whether funding was checked or forgotten; `—` states that none is known.

## State

Built: `docs/CREDITS.md` with the three tables, `reuse_list_check` extended to verify all three tables and their paths with host tests, the "Credits and licences" page and footer link on the site, and the pointer in `docs/PROPERTIES.md`.

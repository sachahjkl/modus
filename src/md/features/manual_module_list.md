# The list of the modules of the manual

The manual shows the documentation of each module of the boot image. Its list at the left is the way a principal finds a module. This file records the order and the groups of that list, its filter, and why.

## Purpose

The list showed the modules in the order of the boot image, about two hundred names with no order that a reader knows, the test modules among the programs, and a number after some names that nothing named. A reader looked for a name line by line.

## Constraints

- The boot image does not change while the system runs: the facts of each module are read once, at the start.
- No work in a frame in proportion to the modules: the rows are made again only when the filter or the open groups change.
- The order of the list is the order of the keys Up and Down, so the keys go where the eye goes.
- The page of a module, the exports of the service (`show`, `about`, `signature`) and the table of all the modules keep the modules of the boot image by their place in it.

## The chosen form

- **Groups by the module category.** The header of each module file states its module category (`docs/glossary/communication.md`, "Module category"); the list reads it with `module.module_category_of` and gives each module a group: the applications, the tools (the system tools and the developer tools), the system services, the libraries, the demonstrations, the tests, and "other" for a file that states no category or that the header refuses, as the kernel. A heading names each group that has a module. The list never guesses a group from a name.
- **The order of the alphabet inside a group.** An insertion sort at the start (`module_list.order_build`): a few hundred names, once.
- **The tests closed.** The group of the tests shows its heading alone, "+ tests (N)", until a click on it opens it. A test module is wrong on purpose or shows nothing of its own; a principal reads it only when looking for it.
- **A filter field at the top of the list.** Each printable character that the principal types goes into the filter, Backspace takes the last one, Escape empties it. The list then shows the modules whose name, group heading or tag word holds the filter, with the case of ASCII folded and a space for each `_` ("hall of" finds `hall_of_fame`). A filter shows the tests that it finds, closed or not: a principal who types a name wants that module.
- **The count of the exports named.** The column at the right of the names has the head "exports".
- **The keys.** Up and Down take the module before and after in the rows, past the headings. The table of all the modules moved from the key `o` to Control+O, because a letter now goes into the filter.

The rows are made by the internal part `internal:manual/module_list`, which reads no file and has host tests; the window gives it the facts of each module.

## Refused forms

- **A filter field that takes a click before a key.** The list has no other use of a letter; a second step before each search would only cost.
- **The tests left out of the manual.** The manual documents each module of the boot image; a developer reads the page of a test module too.
- **The order of the boot image.** It is the order of the build, which says nothing to a reader.
- **The group from the folder of the source.** The module file holds no group, and the manual reads files, not the repository.

## Subtle points

- `selected` stays the place of the module in the boot image. A selected module that the filter hides keeps its page; the list then starts at its first row.
- The heading of the page is the name of the module, in the font of the heading. With Spleen it read as spaced letters, because a glyph of 8 columns stood in a cell of the heading size; the advance of a Spleen glyph is now its width ([text_rendering.md](text_rendering.md)).

## State

Built: the groups, the order, the closed tests, the filter with its log fact, the head of the column, the keys. Left: nothing planned.

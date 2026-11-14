# The text box: a text that is wider than its place

## Purpose

A window shows facts. A fact that is drawn over another text, or that stops at the edge of a panel, is a fact that the reader does not have. This fault came back many times, each time in another window: a name of a module over the page beside it, a stack trace that stops in the middle of a path, the last line of a window under its edge.

The cause was the same each time. A program placed a text at a fixed column and a fixed line, and the text was a value that the program does not choose: the name of a module, a path of a source, a sentence of an error record, a number.

The purpose of this design is one rule and one implementation of it, in the interface package, so that a program has no reason to place such a text by hand.

The guide: [`docs/INTERFACE.md`](../../../docs/INTERFACE.md), "The text in a box".

## Constraints

- **A text is never cut in silence.** This is a rule of the system for each text ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "A text is never cut in silence"): a text is whole, or it ends with the cut mark, or it is refused. A window is one more place where it holds.
- **The package never allocates** and keeps no state between two frames. A text that takes more lines cannot be laid out once and kept by the package.
- **A text is measured in the font that draws it.** The interface font is proportional; the font of the cells is not. A break at a count of characters is wrong in the interface font.
- **The values are paths and names.** A path of a source has no space. A name of the system has complete words joined by `_`. A break rule that knows only the space breaks such a text in the middle of a word, or not at all.
- **A window has a fixed size.** A text that takes more lines pushes the text under it; at some count of lines the window is full.

## The chosen form

Three procedures of `src/library/support/interface/text.odin` hold the rule:

- `text_wrap_line` gives the first line of a text in a width, and the rest. The caller loops over the rest.
- `text_wrapped_line_count` gives the count of the lines, so that a caller knows the height of a row before it draws it.
- `draw_text_wrapped` draws the lines and gives the same count.

Two elements use them, and take their height from a column: `label_value_lines`, a name and a value that each take the lines that they need; and `case_lines`, the row of a table of cases, which is the same row with a band and with both texts in the font of the cells. Four programs had the same table of cases, each with its own loop and its own fixed line: one element holds it now.

**A window that does not draw with the package takes the rule alone.** `text_wrap_line` reads only the font of a text. For the font of the cells it needs no draw table, so a window that draws its pixels with `src/library/support/graphics` (`tables`, `server`, `log`, `pages`, the boot display) asks the package where each line ends and draws the line itself. The rule has one implementation; a window is not converted for it.

**A text that the kernel keeps in parts is joined before it is broken.** The kernel keeps a log text longer than one record in several records, cut at a count of bytes. The window of `log` showed each record as one row, so a word was cut where a record ended. The record format is a storage format and stays; the window joins the records of one text and breaks the joined text by the rule.

**The order of the breaks.** A line ends at the last space that fits. When the last word of the line is wider than the whole box, the line ends after the last `/`, `:` or `_` of that word that fits. When the word has none of them, the line ends after its last character that fits.

The second case has a condition: the word must be wider than the whole box. A word that has room on a line of its own goes there whole, as a reader expects. A word that has no such room would leave the line before it short and then break anyway; it starts on that line.

**The three characters.** `/` ends a part of a path. `:` ends the package of a procedure (`fault::three`) and comes before the line of a source (`main.odin:15`). `_` ends a word of a name of the system. A break after one of them keeps each part readable. No hyphen is added: the text on the screen is the text of the fact, byte for byte, and a reader can copy a path from two lines.

**The caller owns the height.** The package gives the count of the lines; the caller decides what the window does with it. Three answers are in use:

- The row grows, and the rows under it move down (the list of `inspect`, the list of `manual`, a card of rows).
- The window has pages, and a page holds the rows that fit in its height (`errors`).
- The card ends with one line that counts the rows that it does not show, and names the command or the log line that has each of them (`inspect`, `quic_echo`, the tables of cases).
- The window is a view of the newest rows, and shows the rows that fit whole (`log`, the requests of `server`): the older rows are in the log.

A column that holds values of a known longest form has the width of that form, and needs no second line: the columns of `pages`, the answer column of a table of cases after its longest text.

A row is never drawn in part: a row that does not fit whole is one of the rows that the last line counts.

**The count is made when the data changes.** A program that knows when its texts change counts the lines there and keeps the counts: `errors` when a case runs, `inspect` when it reads the list of the programs, `manual` once for the boot image. The loop of a frame then reads the counts.

## Refused forms

- **Cut the text and end it with three points.** The reader then knows that something is missing, and does not know what. This is what the windows did, with and without the points. It stays allowed only where the whole text is at another place that the window names: the caption of a card, the start of a hash.
- **Make each buffer and each column larger.** A larger column moves the fault to the next longer name. The longest path of the sources has 80 bytes, the name of a procedure up to 99, and a module from another repository has no limit. The two fixed places that this design touches (`FRAME_NAME_CAPACITY` of `inspect`, the rows of the service `debugger`) now have the size of the longest text of the sources, stated with an `#assert`, and a longer text ends with the cut mark. The size is for the common case; the rule is for every case.
- **A smaller font for a long text.** The system has three scales and no scale under 1. A text that changes its size with its length makes a column of a table unreadable.
- **A horizontal scroll of a line.** A reader of a stack trace wants each frame at once. A line that scrolls hides the start when it shows the end.
- **A break in the middle of a word, with a hyphen.** The text of a path with an added hyphen is another path.
- **A layout kept by the package.** The package would need memory for the lines of each text between two frames, and a way to know that a text changed. The difference of the draw table already finds what changed; a second record of the same fact is a second source of faults.
- **Wrap in the element `label_value_line`.** That element has an area of one line, which its caller took from a column before the call. An element that draws past its area draws over the next row. The element with more lines is a second element, which takes its own height.

## Subtle points

- **The break rule works on bytes.** The fonts of the system hold ASCII. A text in UTF-8 with a character of several bytes can be broken inside the character by the third case of the rule.
- **A line can end with a space** when the whole rest of the text fits and ends with spaces. The count of the lines does not change.
- **A box narrower than a character** gives one character on each line. The loop over the lines ends, because the rest is always shorter than the text.
- **A page of `errors` is not a fixed count of cases.** The scenario of the test presses Tab and waits for the page 2, then for the page 1: it holds while the cases take two pages. A much longer sentence can make a third page.
- **The stack trace of `errors` is on the second page.** With each sentence whole, the first page has room for 18 cases; the case of the fault is the 19th.
- **`Text_Builder` drops the bytes that do not fit in its 128 bytes**, as its comment says. A caller that builds a sentence in it must know that the sentence is shorter. This place does not follow the rule of the system yet.
- **A window has a largest size.** The screen has 1024 by 768 pixels; a window with its borders, under the bar and its title, has at most 1000 by 708. A window that was as wide as the screen lost its right border and the edge of its cards.
- **The boot display has a fixed height**, and its card of the machine has room for one fact of two lines: the name of the processor. Two long facts on one machine would pass the card.
- **The joined text of `log` has at most four records**, the length of a text of `system.log`. A longer text starts a second row at a record edge.

## State

Built: the three procedures and the three elements (`label_value_lines`, `case_lines`, `cases_rest_line`), with their host tests; each window that the guide lists; the sizes of the names of a frame in `inspect` and of the rows of the service `debugger`.

Left: no check of the tool finds a text that passes its box in a picture: the fault is found by a reader of the pictures. The sizes of the two fixed places are stated numbers; no check compares them with the sources. `Text_Builder` and the text builders of `pages` and of the boot display drop the bytes past their size with no mark.

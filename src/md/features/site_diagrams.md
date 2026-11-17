# The diagrams of the guides

## Purpose

A guide holds diagrams in the text form of mermaid: a flowchart of the parts of the system, a graph of the order of construction, sequence diagrams of the start and of two flows. The site showed each one as its text. The tool now draws each diagram as a picture in SVG inside the page, when it builds the site.

The details of the page are in [`docs/SITE.md`](../../../docs/SITE.md), "The diagrams".

## Constraints

- The site runs no script that a page needs, loads no library from another host, and fetches nothing at build time. A diagram follows the same rules.
- No text is cut, and no text lies over another text. A text has a box, and its width comes from the font before it is placed.
- The colours are the tokens of the site, so the light and the dark form both work.
- The text of a diagram is in the page for a screen reader and for search.
- A diagram that the tool cannot draw stops the command with its file and its line: the site never shows a part of a diagram, and never shows the text in the place of the picture.
- A picture fits the column of the page.

## The chosen form

**A subset of mermaid, read whole or refused.** The reader knows the forms that the guides use, and no more: `flowchart LR` and `flowchart TB` with the nodes `id["label"]`, the edges `-->`, `-- "label" -->` and `-. "label" .->`, and `subgraph id["label"] … end`; `sequenceDiagram` with `participant id` or `participant id as name` and the messages `a->>b: text`, also to the same participant. Each other line is a fault with its line. A text with `<`, `>`, `#`, `;` or a backtick is a fault too: mermaid reads these as markup or as the end of a statement, so the picture would not show the text that mermaid shows.

**The font of the text is a font that the site serves.** The text of the pages is in the font of the system of the reader, whose advances no build can know. So a diagram names one font of its own: B612, the interface font of the system, whose subset the repository already holds with its license. The tool reads its advances and its pairs with the reader of fonts of the system (`vector_font`). Each line of text in the SVG carries the width that the layout measured (`textLength`): while the font loads, or in a browser that sets the pairs in another way, the line keeps its measured width, so it never passes its box. A character that the font lacks is a fault: another font would draw it with another advance.

**A text wraps; a word is never cut.** A label wraps at its spaces onto more lines, to one bound for each kind of text. A line is wider than its bound only when it is one word that is wider than the bound by itself: that word is a line of its own, and its box grows. The label of a subgraph keeps its bound when a node with a long word makes the column of the subgraph wide: a bound that followed the column would let a sentence pass the bound with no word that needs it.

**A flowchart is a layered layout.**

- The units of the top are the subgraphs and the nodes outside each subgraph. An edge joins the units that hold its two ends.
- The rank of a unit is its longest path from a unit that no edge enters, at two ranks for each edge. A cycle has no such rank: the tool refuses it, with the line of the first edge of the cycle and the ids along it. The diagrams of the guides are graphs of order ("must exist before") and of layers, where a cycle is a fault of the text.
- Each edge has a unit in each rank between its ends. The first one holds its label; the others are lanes of no width. So a label is a box of the layout, as a node is: it never lies on another box, and its edge passes through its middle, under its background.
- Eight passes of the barycenter, down and up, order each rank; the order with the fewest crossings is kept. Then four passes move each unit toward the mean of its neighbours, in its order, with the gap kept.
- An edge leaves the side of its source along the flow and enters the side of its target along the flow, with a straight part under its arrow head. Between two ranks it is one straight line. The ends of the edges that share one side of a box are spread along that side, so two arrow heads never share a point.
- A subgraph is a box around its nodes. Its label is at the start of the axis across the flow: at the left in `TB`, with its nodes in a row; at the top in `LR`, with its nodes in a column. An edge enters and leaves along the flow, so no edge crosses the label. An edge to a subgraph ends at its box; an edge to a node inside a subgraph ends at the box of that node.

**A sequence diagram is columns and rows.** The participants are columns in the order of their lines, each a box at the top with a lifeline. Two columns are apart by their boxes and a gap, and by the text of each message between them: the text wrapped to its bound, with a margin at each lifeline. The messages are rows in their order: the text, then the arrow under it. A message to the same participant is a loop at the right of its lifeline, with its text at the right of the loop, before the next lifeline.

**The picture shrinks to the column.** The SVG has its width and its height, and the style sheet holds it to the width of the column with its shape kept. The text of the diagram follows the picture in a `details` element, and the SVG has a `title` for a screen reader.

**Whole pixels, no randomness.** The same text gives the same picture.

## Refused forms

- **The script of mermaid in the page.** It is a library from another host or a large file of the site, a page would need a script to show its content, and the text would be measured by the browser after the page loaded.
- **mermaid at build time.** It needs a browser engine in the build, and the build fetches nothing.
- **A picture file.** A PNG has one form: the light and the dark form would need two pictures, and a text in a PNG is not text.
- **The reading font of the page, measured with a bound.** Its advances are not known. A bound wide enough for every font of a reader leaves wide gaps in most of them, and still fails on a font past the bound.
- **A monospace font.** Its advances are near one value in most fonts, but not one value. It is also wider than B612 for the same text, and the diagrams of the guides are already wide.
- **A cycle broken by a reversed edge.** The diagrams of the guides are orders; a cycle in one of them is a fault of the text that the tool must report, not draw.
- **Labels placed after the layout, at the middle of their edge.** Two labels in one gap, or a label and a long edge, can then lie on each other. A label as a unit of a rank cannot.
- **Orthogonal edges.** Several edges in one gap need a channel each, or their horizontal parts lie on each other. A straight line between two ranks crosses another line at one point at most.
- **The label of a subgraph above its nodes in `TB`.** An edge to a node inside the subgraph would cross it.
- **The rest of mermaid.** Notes, loops, other arrows, other shapes and styles: no guide uses them, and a form that no text uses is code with no test from a real case.

## Subtle points

- **The line of a fault** counts in the file: the line of the fence plus the line in its body. Line 0 of the body is the fence itself, for an empty diagram or a font that cannot be read.
- **A diagram in a source comment stays text.** A comment is rendered alone, in a page or in a cell, and has no picture. The command lists it as not rendered.
- **The guides are rendered twice.** A fault is recorded in the second pass only, so it is printed once.
- **A long edge passes beside the ranks between its ends** in its own lane, never through a box.
- **The text of a message across a lifeline** has a background that covers the lifeline under it.

## State

Built: the reader, the two layouts, the SVG writer, the font of the diagrams in the site, the stop of the command, the host tests (each refused form with its line, a cycle, an empty diagram, a label of 200 characters, 30 nodes, and the five diagrams of `docs/ARCHITECTURE.md`: no two boxes overlap, each text is inside its box, each edge ends at its two boxes).

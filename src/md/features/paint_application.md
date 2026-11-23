# The paint application

The process `paint` is a small paint program: brushes of several sizes, an eraser, a palette and a picker of any color, the tools line, rectangle, ellipse and fill, undo and redo, pictures that its private store keeps as they change, and a status line. It is also a service: the console draws on its picture with isolated calls (`paint.line`, `paint.write`), which shows that one process is an application and a service with one thread.

## Constraints

- One thread and no lock: a call of the console runs between two events of the window.
- The window is resizable ([window_resize.md](window_resize.md)). A resize must not lose a pixel of the picture.
- The drawing module draws one picture memory for a window: the picture is that memory.
- The process keeps its pictures in its private store (grant `Store`); no other process reads them.
- Each table and each history has a stated capacity; a refusal is said, never silent.
- Rectangular forms; no rounded blobs.

## The chosen form

- **The picture has its own size.** Its pixels are one array at the largest size, `PICTURE_WIDTH_LIMIT` by `PICTURE_HEIGHT_LIMIT` (the logical screen of the reference screen). Its extent is the part in use. A larger window grows the extent with paper; a smaller window shows the top left part and keeps the rest. So a resize never cuts the picture, and a coordinate of the picture never moves.
- **The layout**: a row of tools at the top (brush, eraser, line, rectangle, ellipse, fill, then smaller and larger for the size), a row of the palette under it (16 colors, the custom color when it is no color of the palette, and the button of the custom color), the canvas, and the status line at the bottom: the tool, the size, the color in hexadecimal, the place of the pointer on the picture, and the last message. The tool row says the tool by its chosen button only, and the size by no number, so the status line is the one place of each value. The action bar is at the right of the status line: undo, redo, pictures, clear.
- **The keys**: B brush, E eraser, L line, R rectangle, O ellipse, F fill, [ and ] the size, Ctrl+Z undo, Ctrl+Shift+Z and Ctrl+Y redo, Ctrl+O the panel of the pictures, C clear. The right button draws with the paper color, as the eraser does.
- **The sizes** are 1, 2, 3, 5, 8, 13, 21 and 34 pixels: each step is visible, and the list is short.
- **The shapes** show a preview while the button is held, as records of the draw table over the picture, and are drawn into the picture at the release. The ellipse is drawn by spans: for each row, the columns between the inner and the outer ellipse. A preview of an ellipse is a path of 64 points, at angles in turns.
- **The fill** is a scanline fill of the 4-connected region of one color, with a stack of a stated capacity and a bitmap of the visited pixels. When the stack is full, the fill continues by a scan of the visited pixels, so it never stops in the middle of a region.
- **Undo and redo** keep, for each change, the rectangle that it changed, with its pixels before and after, compressed with LZ4 (`modus:contract/lz4`) in one arena of `HISTORY_BYTES`. The history holds at most `HISTORY_STEPS_LIMIT` changes; the oldest goes when a new one does not fit. A change larger than the arena clears the history, and the status line says that it cannot be undone. A new change after an undo removes the changes that redo would give.
- **The custom color**: a sample of the color, three channels, red, green and blue, each a bar where a press or a drag sets the value, with buttons -16 and +16, and a field for `#RRGGBB` with the button apply.
- **No save action** (property 9, "Persistence: no save action"). The picture in the window is always a picture of the store: the store keeps it as it changes, and each keep is a version that the store keeps by its retention rule. The principal never saves, and never loses a picture by a forgotten act.
- **The open picture has a name from its start.** At the start, the window takes the first name `picture-1`, `picture-2`, ... that the store does not hold, for a new picture. A new picture is written at its first change: a picture that nobody touched leaves no object.
- **The keep is coalesced.** Each change of the picture (a stroke, a shape, a fill, an undo, a clear, a call of the console, a taller extent) adds its rows to a band of changed rows. A keep starts when the picture has not changed for `KEEP_PAUSE_MILLISECONDS` (1 second), and before another picture opens or a new one starts. One keep is one commit: one version for a pause of the principal, not one for each point of a stroke.
- **The keep writes the changed rows.** The file has a fixed row of `PICTURE_WIDTH_LIMIT` pixels, so a row of the picture is at one place of the file whatever the extent. A keep writes the header and the band of changed rows with `storage.write_range`, sets the size of the object, and commits: the store hashes and writes only the blocks of those rows. The first keep of a new picture writes all its rows.
- **The pictures panel** opens at the right of the canvas (Ctrl+O, or the action pictures): a field for a name with the buttons "new" (a new picture with that name) and "rename" (the open picture takes that name), the list of the pictures of the store, and the buttons "open" and "delete". The open picture cannot be deleted. The status line names the open picture. A name has 1 to 32 characters among the lowercase letters, the digits, `-` and `_`. A picture is the object `<name>.picture` of the private store. The canvas gets narrower; the picture keeps its extent.
- **The picture file**: a header of 20 bytes (the magic `MPIC`, then the version 2, the width, the height and the pixels of a row of the file, `PICTURE_WIDTH_LIMIT`, each a little-endian u32), then the rows of the picture, `PICTURE_WIDTH_LIMIT` pixels of 4 bytes each, from row 0 to the height. A reader checks each field before it uses it: a width or a height of 0 or past the limit, a row that is not `PICTURE_WIDTH_LIMIT` pixels, a size that is not the header and the rows, and a pixel whose top byte is not 0 are refused, and the picture does not change.
- **The exports** keep their contract on the picture: `line` and `write` take a color of the palette (0 to 15) and coordinates of the picture; `write` refuses a place outside the extent. `clear` and `lines` are as before. A call is a change of the picture with no step in the history: an undo after a call can paint over what the call drew, in the box of its step. A step for each call would let a caller fill the history of the principal.
- **The store runs on the worker thread** of the window ([background_work.md](background_work.md)): the open of the store, the keep, the read, the new picture, the rename, the delete and the list are jobs, one at a time. The window copies the header and the changed rows into the file buffer of the job before the ask, and decodes a read picture after the take. The principal draws on while a job runs; an act of the panel waits for the keep before it, and the status line says that it waits.
- **The pure parts** (the picture operations, the fill, the ellipse, the history, the file format, the name rule) are in `internal:paint/paint_model`, with host tests.

## Refused forms

- **A picture of the size of the window.** A smaller window would cut the picture, and a larger one would need a copy at each step of the drag.
- **A whole copy of the picture for each step of the history.** A picture at the largest size is 5.3 MB: 32 steps would need 170 MB.
- **A recursive fill.** The stack of the thread is 64 pages.
- **A picker by hue and value in a square.** It needs a conversion of colors that a principal does not read; three channels give each color with exact values.
- **A save action** (a button "save", a key Ctrl+S). Property 9 says that the system has no save action: a document in the store is always current, and a process sends each change. A save would make the store hold an older picture than the window until the principal acts.
- **A write of the whole object at each keep.** Property 9 asks the store for "apply this change atomically", not "replace the whole object". A picture at the largest size is 5.3 MB; a stroke changes a few rows.
- **A compressed file (LZ4).** A change of one row changes the bytes after it: no range of the file stays in place, so each keep would write the whole object.
- **A keep at each change.** A stroke is a change at each event of the pointer: one version for each point would fill the versions of the store with steps that no principal asks for.
- **A file format of another system (PNG).** It needs a deflate coder and a CRC, and it is compressed: see above.

## Subtle points

- The history is cleared when a picture is opened or a new one starts: an undo across two pictures has no meaning.
- A picture that a job read is taken only after the drag that runs ends: the drag holds a copy of the picture before its change for its step of undo, and a step of the old picture over the new one would paint old pixels into it. Undo, redo and clear are refused during a drag for the same reason.
- The cost of the pause: a stop of the process loses the changes of the last second at most, as a power loss does. Property 9 leaves open how a process groups small changes; this is the form of paint.
- A drag that starts on the canvas keeps drawing when the pointer leaves it: the points are cut to the extent, and the release ends the change.
- A change of the picture raises the generation of the Picture record, so the drawing module draws it again; the preview of a shape is records only, so it does not touch the picture until the release.

## State

Built: the tools, the sizes, the palette and the custom color, undo and redo, the resize that keeps the picture, the keep of the changed rows after a pause, the panel of the pictures, the status line, the exports. Left: a selection, a text tool, pictures larger than the screen.

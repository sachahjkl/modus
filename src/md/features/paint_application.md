# The paint application

The process `paint` is a small paint program: brushes of several sizes, an eraser, a palette and a picker of any color, the tools line, rectangle, ellipse and fill, undo and redo, pictures kept in its private store, and a status line. It is also a service: the console draws on its picture with isolated calls (`paint.line`, `paint.write`), which shows that one process is an application and a service with one thread.

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
- **The pictures panel** opens at the right of the canvas (Ctrl+O, or the action pictures): a field for a name, the button "save", the list of the saved pictures, and the button "open". The canvas gets narrower; the picture keeps its extent. A name has 1 to 32 characters among the lowercase letters, the digits, `-` and `_`. A picture is the object `<name>.picture` of the private store.
- **The picture file**: a header of 20 bytes (the magic `MPIC`, then the version 1, the width, the height and the byte count of the LZ4 block, each a little-endian u32), then the LZ4 block of the pixels, 4 bytes each. A reader checks each field before it uses it: a width or a height of 0 or past the limit, a byte count that is not the rest of the file, and a block that does not give exactly width × height × 4 bytes are refused, and the picture does not change.
- **The exports** keep their contract on the picture: `line` and `write` take a color of the palette (0 to 15) and coordinates of the picture; `write` refuses a place outside the extent. `clear` and `lines` are as before. A call is a change of the picture with no step in the history: an undo after a call can paint over what the call drew, in the box of its step. A step for each call would let a caller fill the history of the principal.
- **The store runs on the worker thread** of the window ([background_work.md](background_work.md)): the open of the store, the list, the read and the write are jobs. The window encodes a picture into the file buffer of the job before the ask, and decodes a read picture after the take. While a job runs, the status line says "saving" or "reading", a second save or open is refused, and the principal draws on.
- **The pure parts** (the picture operations, the fill, the ellipse, the history, the file format, the name rule) are in `internal:paint/paint_model`, with host tests.

## Refused forms

- **A picture of the size of the window.** A smaller window would cut the picture, and a larger one would need a copy at each step of the drag.
- **A whole copy of the picture for each step of the history.** A picture at the largest size is 5.3 MB: 32 steps would need 170 MB.
- **A recursive fill.** The stack of the thread is 64 pages.
- **A picker by hue and value in a square.** It needs a conversion of colors that a principal does not read; three channels give each color with exact values.
- **A file format of another system (PNG).** It needs a deflate coder and a CRC for a store that only this process reads.

## Subtle points

- The history is cleared when a picture is opened: an undo across two pictures has no meaning.
- A drag that starts on the canvas keeps drawing when the pointer leaves it: the points are cut to the extent, and the release ends the change.
- A change of the picture raises the generation of the Picture record, so the drawing module draws it again; the preview of a shape is records only, so it does not touch the picture until the release.

## State

Built: the tools, the sizes, the palette and the custom color, undo and redo, the resize that keeps the picture, the pictures in the store, the status line, the exports. Left: a selection, a text tool, pictures larger than the screen.

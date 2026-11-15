# The pictures of the mark

## Purpose

The mark is data in `src/library/support/mark`: the cells of the heron, the colors of its parts, the animations and the moves. Many files show it: the files of the repository, the pictures and the icons of the site, the tile maps of the animations, a picture for a developer. One generator of the tool turns a request into the bytes of a file, so that a change of the mark changes each picture, and no two places compute the same picture.

The command and its options are in [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The pictures of the mark". The variants and the table of the uses are in [`docs/DESIGN.md`](../../../docs/DESIGN.md), "The variants of the mark".

## Constraints

- The gradient of each part gives the heron its look. A picture, such as the head of the home of the site, keeps it.
- A small icon, one pixel for a cell, has no room for a gradient inside a cell: there it only lowers the legibility.
- The browser computes no color of the heron. The tool makes each pixel; a page shows a picture at its own size.
- A file loses no pixel: only a lossless encoding.
- The logic of the pictures is in one place. A command that writes pictures holds a list of requests, and no number of a picture.
- A request with no sense is refused with a sentence. It is never bent into another request.

## The chosen form

**Two variants, named by the request.** In the smooth variant a pixel takes the gradient of its part at the centre of the pixel. In the cells variant a pixel takes the gradient at the centre of its cell, so a cell is one color at every cell size. Each drawing procedure of `src/library/support/mark` takes the variant as a required argument: the choice is which mark a place wants, not an option of a renderer, and a caller that does not think about it does not compile.

**The rule of the choice.** A picture is smooth. A small icon is cells. The program `heron` and the boot display are pictures; the bar of the desktop and the bar of the site are small icons. For an icon of the site the cell size says which it is: an icon of one pixel for a cell is a small icon; an icon of two pixels or more for a cell is a picture. The vector icon has no pixel of its own: it is the cells.

**The smooth variant needs two pixels for a cell.** At one pixel the centre of the pixel is the centre of the cell, so the picture is the cells variant. The request must say so: `src/library/support/mark` draws nothing for the smooth variant at one pixel, and the generator refuses it.

**A request says what and how.** What: the still mark, a frame of an animation, an animation, a tile map, the table of a tile map, the picture for a developer. How: the variant, the cell size, the color scheme, the background, the size of the picture, the name under the heron, the rows of a tile map, the format of the file. The generator gives the bytes of the file, or the sentence of a refusal.

**Every format starts from the pixels of one picture.** The generator draws the pixels of a picture in one procedure. A PNG file is those pixels encoded. An icon file is several PNG files of the generator, one for each size, behind a directory. A vector file is the same pixels cut into rectangles of one color. An animated PNG file is the PNG data of each frame of an animation, with the time of each frame from `src/library/support/mark`. So a format adds no second way to compute a color, and a test reads each format back into the pixels of the picture.

**One table of the uses.** Each file of the mark of the repository and of the site is a row: where it goes, what it holds, how it is drawn. The icons of the site, the icon of a phone and the icons of the manifest are rows as the pictures are. An icon file has one row for each of its entries: the rows with the name of the file, in the order of the table, are the file. The command that writes the files of the repository and the command that writes the site ask for their rows. A new file is a new row. The guide shows the table, and the command prints it.

**A tile map carries its table.** The table says where each tile is, how long each picture of an animation stays, and how the heron moves, in whole cells. A script that plays the animations copies tiles and places them. It holds no number of the mark and computes no picture.

**The smallest file of the encoder.** The generator encodes at the highest level of the deflate of the standard library, once with each row filter, and keeps the smallest. The pixels decide the result, so the same pixels give the same bytes.

## Refused forms

- **One pixel for a cell on the home, made larger by the page.** The file is small, but a cell is then one color: the gradient of a part goes from cell to cell, and the heron loses its look.
- **A gradient that the script of the page draws.** It gives the same pixels from a small file, but the browser then computes the picture. The pictures of the site are made by the tool.
- **A palette.** A tile map has more than 256 colors in each color scheme. Two files for each color scheme cost more requests than the bytes that they save.
- **A variant chosen from the cell size.** It hides the choice: the same cell size can want either variant, and a picture at one pixel for a cell would be called smooth.
- **A variant as an optional argument with a default.** A caller that was written before the variants would compile and take a variant that nobody chose for it.
- **A lossy encoding.** A picture of square cells shows each wrong pixel.
- **A list of pictures in each command.** Two lists drift, and two places then compute one picture in two ways.
- **A table of the icons beside the table of the uses.** It was the first form. A developer then looks in two tables for the files of the mark, and the second table repeats the fields of a picture.
- **The smooth variant as a vector file, one gradient element for each part.** The gradient of a part is linear across the picture: the share of the way is the projection of the centre of a pixel on the diagonal of the box of the part, which is what a linear gradient of a vector file states. The file is still not exact. The reader of the file computes each color: it interpolates between the two rounded colors of the ends, it rounds in its own way, and it can take the color at another point than the centre of a pixel. A color is then one unit away from the color of `src/library/support/mark` on some pixels, on some readers. That is also a color that the browser computes. The generator refuses the request with a sentence. The vector icon of the site had this form before; it is now the cells variant.
- **A vector file written from the cells, beside the procedure that draws the pixels.** It needs a second copy of the place of the heron, of the name and of the background in a picture. The rectangles come from the pixels of the picture, so the vector file cannot differ from the PNG file of the same request.
- **An animated format with a loss, or a format that the standard library cannot write without a new encoder.** An animated PNG file needs three kinds of chunk around the data that the PNG encoder already gives. An animated WebP file needs an encoder that the tool does not have.
- **An animated file of the mark in the repository.** No page of the repository shows one now. The command writes one when a developer wants it.

## Subtle points

- **The first tile of a tile map of the home is the still picture of the home, pixel for pixel.** Else the heron changes when the script starts. The site refuses to build when the two rows of the table differ in their variant or their cell size.
- **The icon of the tab has a tile map of its own.** Its tiles are the cells variant at one pixel for a cell in the light scheme, as the icon of 32 pixels of the icon file. A tile of the home cannot be made smaller without a loss.
- **A tile map holds the heron alone, on nothing, each tile at the size of the heron.** A script lays a tile over a page. A request for a tile map with a name, a background or a size is refused.
- **The check of the files of the repository compares pixels, not bytes.** The bytes of the compressed stream depend on the compressor of the compiler release.
- **The cells variant is allowed at each cell size.** It gives one color for a cell in a large picture; the rule of the choice does not use it there, and the generator does not refuse it.
- **A host test reads the sources of the tool.** It fails when a file outside the generator calls a drawing procedure of `src/library/support/mark`, or builds an icon file, a vector file or an animated file of the mark. It runs from the root of the repository.
- **The picture for a developer keeps the rule on texts.** The text under a frame or a form is inside its box, on two lines where one is too long, and the tool stops on a text that is wider than its box.
- **A vector file can hold the two color schemes.** Its rectangles have the colors of the light scheme, and one rule of style gives the colors of the dark scheme to a reader that asks for dark, for the rectangles whose two colors differ. Both colors of a rectangle come from the pixels of the two pictures. A raster file holds one scheme, so the request for that rule with another format is refused.
- **An entry of an icon file is at most 256 pixels on a side.** The directory of the file holds a side in one byte. No two entries have one size: a reader chooses an entry by its size.
- **An animated PNG file shows the frames in their place.** It holds each frame of one animation for its time, and plays without an end. The move of the heron across a page is the work of the script of the home: the file does not show it.
- **The names of the files of the site stay names of the site.** A constant such as the name of the picture of the home says where the file goes. The types and the procedures of the generator say nothing of the site: the command and the files of the repository use them too.

## State

Built: the two variants in `src/library/support/mark`; the generator for the still mark, a frame, an animation, a tile map, its table and the picture for a developer; the formats PNG, icon file, vector file and animated PNG; the command; the one table of the uses, with the icons of the site; the two commands that write the files as callers; the host tests of each kind of request, of each format and of each refusal.

Left: nothing of this design.

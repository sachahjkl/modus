# The draw table: the 2D interface of the system

The draw table is the one 2D interface of the system: [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "18. One 2D interface: the draw table". A program describes each frame of its window as a table of draw records in its own memory. The drawing module finds the damage by difference and draws the records into the surface. The compositor draws its screen with the same records. When a GPU exists, the GPU draws the same table through WebGPU.

This file records the rationalised form of the record: a closed set of primitives, each record with the fields of its kind only. The guide of today's form is [`docs/INTERFACE.md`](../../../docs/INTERFACE.md), "2.1 Draw record". The border of the drawing module is in [library_modules.md](library_modules.md). The picture memories are in [picture.md](picture.md), and the cells of a grid in [text_grid.md](text_grid.md).

## What changed

Version 10 is a record of 40 bytes with one set of fields for all kinds. A review of it as a general interface found five faults:

- A field changes its meaning with the kind. `second_color` is a color, an ink margin, a stride or a count of columns. `text_start` and `text_count` are also a pixel index and a generation. It is a union with no tag for each field.
- Two kinds are the look of the system, not primitives: `Point_Grid` and `Folded_Gap`.
- Three text kinds overlap: `Text`, `Interface_Text` and `Text_Grid`.
- Primitives are missing: alpha and blending (a color is `0x00RRGGBB`), antialiasing, paths and curves (the vector font has them inside, the table does not), a gradient along a line other than the two axes, a stack of clips (a `Clip` replaces the cut), and places that are not whole pixels.
- The comments of the format tell its history.

## The constraints

These properties of version 10 work, and the new form keeps each one:

- **Fixed-size records in the memory of the caller** (property 14). A table is an array. The difference compares two records at one index. The program allocates nothing.
- **Damage by difference.** Two equal records damage nothing. A record that changes damages its old and its new rectangle. A record must therefore give its rectangle with no other memory, and equal bytes must mean equal pixels.
- **Values, not addresses.** A record names its text, its cells and its pixels by numbers in memory that the call passes. The record means the same in each address space, and a GPU can read it.
- **Refusal of a hostile record with bounds.** A record of a caller can hold any bytes. The execution refuses a record that it cannot draw within a stated cost, and no record makes a fault or a write outside the pixels.
- **The same pixels in each cut.** A frame drawn whole and a frame drawn in its damage rectangles give the same bytes. So the color of a pixel is a function of the records only, never of the rectangle that cuts them.
- **No contract depends on a language** (property 19). The record is bytes at stated offsets, not a type of Odin.

## The chosen form

### The record: a header and the fields of one kind

A draw record is 48 bytes, little-endian: a header of 24 bytes, then 24 bytes that belong to its kind.

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `kind` | u8 | The word of the kind: `Draw_Kind` after the border |
| 1 | `reserved` | 3 x u8 | 0 |
| 4 | `element` | u32 | The low 32 bits of the identity of the element that wrote the record, 0 for none |
| 8 | `box` | 4 x i32 | `left`, `top`, `right`, `bottom`, in units of 1/64 pixel: the record draws no pixel outside it |
| 24 | the fields of the kind | 24 bytes | Each kind below gives its own fields; each byte that the kind does not name is 0 |

- **The box is the one rectangle of the record.** For a rectangle and a gradient it is the shape. For a path, a text, a picture and a grid it holds every pixel that the record draws. The execution cuts each record to its box. A box that is too small therefore cuts only the drawing of its own record, and the damage of a record is its box rounded out to whole pixels: never too small.
- **One border.** The procedure `draw_record.read` of the contract package `draw_record` takes the one copy of a record that its reader made (a volatile read) and gives a `Draw_Primitive`: a union of Odin with one record type for each kind. It refuses a kind word that names no member, a reserved byte that is not 0, a box that is inverted or past the limit, and a field out of its bounds, each with its `Problem`. Past it, the execution and the difference switch on the primitive, whole, with no `#partial` and no default case. `draw_record.record_of` writes the record of a primitive, so the kind of a record always matches its fields. The bytes are the contract; the union is the view of one reader.
- **The record is a contract package.** The writer (the interface package) and the readers (the drawing module, the compositor, the tool that draws the byte layouts of the site, a fuzz target) compile in one form. The described exports name `draw_record.Draw_Record` by its package: the check of the declarations of an import reads the layout of a struct by its name, not through an alias. The box is four fields, not a nested record, because a description holds no record in a record.
- **Unused bytes are 0, and the border checks it.** So two records that draw the same thing have the same bytes, and the comparison of the bytes stays the comparison of the drawing.

### The unit: 1/64 pixel

Each place and each size of a record is a signed number of 1/64 pixel.

- The measure of a text is in 1/64 pixel already: the advances of the interface font, and the right-aligned text of `draw_text_right`. A text needs no conversion, and its origin goes to the nearest third of a pixel as today.
- The rasterizer of the vector font works in 1/256 pixel. A place of a record goes to it with a shift of 2 bits, with no rounding.
- An i32 of 1/64 pixel reaches ±2^25 pixels. Each place of a record stays inside ±2^30 units (`COORDINATE_LIMIT`, 2^24 pixels), so the difference of two places fits an i32 and no sum of the execution wraps.
- A shape whose edges are on whole pixels (multiples of 64) has a coverage of 0 or 1 at each pixel: it draws the bytes of version 10.

### The color and the blending rule

A color is a u32 `0xAARRGGBB` with straight alpha (`Draw_Color`). Alpha 255 is opaque. A color of 0 is transparent black, so a record of zeros draws nothing (ZII).

The one blending rule: at each pixel that a record reaches, its cover is the alpha of its color times the coverage of its shape at that pixel. The coverage is 1 inside a shape, a part of 1 on an antialiased edge, and one value for each channel for a glyph with subpixel bands. The color goes over the pixel by source over, in linear light with a gamma of 2, for each channel:

    result = sqrt((d * d * (255 - a) + c * c * a) / 255)

with d the pixel, c the color and a the cover. It is the blend of the text of today (`blend_coverage_row`, [`docs/FONTS.md`](../../../docs/FONTS.md), "3. Subpixel bands"), in integers with the table of square roots. A cover of 255 writes c, with no blend: an opaque record on whole pixels is a fill, as today.

- **One rule for every kind.** The edges of a path, the text, a translucent rectangle and a picture with alpha blend the same way.
- **The colors of a gradient mix in encoded values**, alpha too, as `graphics.mix` mixes them today; then the mixed color blends by the rule. A gradient of opaque colors on whole pixels draws the bytes of version 10.
- **The pixels of a surface stay opaque.** A surface is `0x00RRGGBB`: the window layer paints the background into each damage rectangle before the records draw, so the result of a translucent record is the same in each cut.

### The kinds

`Draw_Kind` is a closed set, with the values of its contract:

| Value | Kind | Fields after the header |
|---|---|---|
| 0 | `None` | None: the record draws nothing |
| 1 | `Rectangle` | `color` u32 at 24; `cell_width`, `cell_height`, `step_x`, `step_y` 4 x i32 at 28 |
| 2 | `Gradient` | `start_x`, `start_y`, `end_x`, `end_y` 4 x i32 at 24; `start_color`, `end_color` 2 x u32 at 40 |
| 3 | `Path` | `first` u32 at 24, `count` u32 at 28, `fill_color` u32 at 32, `stroke_color` u32 at 36, `stroke_width` u32 at 40 |
| 4 | `Text` | `first` u32 at 24, `count` u32 at 28, `color` u32 at 32, `origin_x`, `origin_y` 2 x i32 at 36, `font` u8 at 44, `scale` u8 at 45, `weight` u8 at 46 |
| 5 | `Picture` | `memory` u8 at 24, `format` u8 at 25, `first` u32 at 28, `stride` u32 at 32, `width`, `height` 2 x u32 at 36, `generation` u32 at 44 |
| 6 | `Clip_Push` | None: the box is the clip |
| 7 | `Clip_Pop` | None, and a box of zeros |
| 8 | `Text_Grid` | `first` u32 at 24, `count` u32 at 28, `columns` u32 at 32; kept until the measure below decides |

**Rectangle.** The box in one color. With `step_x` and `step_y` above 0, the rectangle repeats: a cell of `cell_width` by `cell_height` at the top left corner of the box, then one each step, cut to the box. A step of 0 on both axes is one rectangle, the whole box, and then the cell fields are 0. The border refuses a step below 1 pixel, a step below the cell, and one step of 0 with the other above 0. So a rectangle reaches each pixel at most one time, and its cost is bounded by the pixels of its box. A repeated rectangle is a pattern: points, stripes, the lines of a grid.

**Gradient.** The box in a color that goes from `start_color` at the start point to `end_color` at the end point. The color of a pixel comes from the projection of its center on the line of the two points, cut to the two ends, in steps of 1/255. A start point equal to the end point is refused. A gradient along an axis on whole pixels gives the bytes of the vertical and the horizontal gradient of version 10, and keeps their fast form: one mix for each line, or one row of colors that each line copies.

**Path.** A list of points in the byte table: `count` points from the byte `first`, a multiple of 4. A point is 12 bytes: a word of `Path_Point_Kind` (`Move` 1, `Line` 2, `Curve_Control` 3), then `x` and `y` in 1/64 pixel. `Move` starts a subpath. `Line` adds a line segment to the point. `Curve_Control` is the control point of a quadratic curve, and the next point, a `Line`, is its end.

- The fill is in `fill_color` with the nonzero rule. Each subpath is closed for the fill.
- The stroke is `stroke_width` wide, in `stroke_color`, along the subpaths: butt ends, and miter joins that become bevel joins past a miter of 4. A subpath whose last point is its first point is closed for the stroke. A stroke width of 0 is no stroke.
- Both are antialiased: the coverage of each pixel by exact area, with the rasterizer of the vector font ([`docs/FONTS.md`](../../../docs/FONTS.md), "4. Fixed point"). A quadratic curve is cut into 1 to 16 line segments within a tolerance, as for a glyph.
- The fill draws first, then the stroke over it.
- The border refuses: a first point that is not `Move`, a `Curve_Control` that is not followed by a `Line`, more than `PATH_POINT_LIMIT` (1 024) points, a range past the byte table, a first byte that is not a multiple of 4, a point past `COORDINATE_LIMIT`, and a stroke width past `STROKE_WIDTH_LIMIT` (64 pixels).

**Text.** One text form for every font. The UTF-8 bytes of the run are in the byte table: `count` bytes from `first`, at most `TEXT_BYTES_LIMIT` (256). `font` is a `Font_Kind`: `Cells_8x16` 0, `Interface` 1. The origin is the top left corner of the line box, in 1/64 pixel: the font of the cells puts it on the nearest whole pixel, the interface font on the nearest third of a pixel, as the glyph cache asks. `scale` is 1 to 3, `weight` a `Font_Weight`. The box holds the ink, with the ink margin of the font: the field `second_color` of version 10 that held the margin is gone, because the box says it.

`Text` and `Interface_Text` of version 10 were one concept with two places for the origin. A text in the font of the cells is a text run whose font is the font of the cells.

**Picture.** The pixels of a picture of the caller, by values in its picture memory, as in version 10 ([picture.md](picture.md)): `memory` is the number of the picture memory, `first` its first pixel, `stride` the pixels from one line to the next, `generation` a new number when its pixels change. `format` is a `Picture_Format`: `Opaque` 0, which reads `0x00RRGGBB` and copies it, and `Straight_Alpha` 1, which reads `0xAARRGGBB` and blends by the rule. The box is the place of the picture and its size: whole pixels, and exactly `width` by `height` pixels; another box is refused. A picture is drawn at its size: no scale and no repetition.

**Clip_Push and Clip_Pop.** A `Clip_Push` makes the cut of the next records the intersection of its box with the cut before it. A `Clip_Pop` gives back the cut before the last push. The box of a push is on whole pixels: a clip with antialiased edges would need a mask for each pixel, and a GPU cuts by a scissor rectangle of whole pixels. The stack holds at most `CLIP_DEPTH_LIMIT` (16) pushes. The execution refuses a push past the limit and a pop with no push: each of these records draws nothing, and the cut stays as it is. The table ends with each cut gone.

**Text_Grid.** The grid of cells of the terminal, as in version 10 ([text_grid.md](text_grid.md)): the cells in the byte table, 16 bytes each, with their colors as draw colors. It stays its own kind only if a measure shows the need (below).

### The byte table

The field `text` of `Draw_Table` becomes `bytes`: the byte table. It holds the bytes that the records name: the UTF-8 of the texts, the cells of the grids and the points of the paths. Cells and points start at a byte that is a multiple of 4. The difference compares two records with their `first` fields set to 0, then compares the bytes that each names, as it compares the bytes of a text today. Two paths with the same points in another place of the table are equal.

### The look of the system: elements, not kinds

`Point_Grid` and `Folded_Gap` leave the format. Each becomes an element of the interface package, drawn with the primitives. The tokens of their colors stay in the package, where the appearance in force chooses them ([../features/appearance.md](../features/appearance.md)).

- **The grid of points** (`background` and `draw_point_grid`): a `Clip_Push` of the area, a repeated `Rectangle` of `colors.point` with a cell of `POINT_SIZE` and a step of `POINT_STEP`, whose box starts at the point of the grid before the area (12 + 24 n of the surface), then a `Clip_Pop`. Three records in place of one. The points stay at the same places of the surface, so two areas of one surface show one grid.
- **The folded gap** (`draw_folded_gap`): a `Rectangle` of `colors.track`, then a `Path` of two subpaths of one segment each, stroked 1 pixel wide in `colors.dim`, with its ends on the centers of pixels. The two lines become antialiased: these pixels change.
- **The line** (`draw_line`): a `Path` of two points, stroked. The kind `Line` leaves the format with the paths. Its pixels change too: the squares of the line of Bresenham become an antialiased stroke.

### The limits of the format: cost, never look

The format puts no limit of look on what a program draws. Each bound of a kind (`PATH_POINT_LIMIT`, `STROKE_WIDTH_LIMIT`, `TEXT_BYTES_LIMIT`, `CLIP_DEPTH_LIMIT`, `COORDINATE_LIMIT`) is there to bound the cost of a hostile record, and for no other reason. The look of the desktop of the system is sober by choice: rectangles, sharp shadows, transparency only where it informs, short animations that inform ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "2. Forms"). That look is a rule of the elements of the interface package and of the compositor. It is never a reason to refuse a primitive.

- A program can draw any form: round, at an angle, curved. A round form is a path.
- A shadow is a rectangle or a path with alpha. A sharp shadow needs no new kind.
- An effect that the set lacks today (a blur, a blend mode, an even-odd fill, a cubic curve, a round join, a dash, a gradient of more than two colors) is added when a program needs it, as a kind or a field under the version rule. A blur waits for the GPU, where it costs little; on the processor it is the largest cost of a frame.
- The set stays closed: each kind that is added has its fields, its border and its bound of cost, as each kind of today.

### The text grid: the measure that decides

A grid as text runs needs one `Text` record for each run of one color in each row, and a `Rectangle` for each run of reverse or filled cells. A plain terminal is one run for each row: about 32 records. The worst case is one run for each cell: 3 328 runs and up to 3 328 rectangles, past the 512 records of a usual window memory.

The measure: the terminal at 104 by 32 cells, in the frame of a plain text, of colored code, and of one color for each cell, in both forms, through the drawing module. It gives the records, the bytes of the two tables, and the time of the build, of the difference and of the draw. The rule: the grid stays its own kind if the form in runs costs more than 1 ms more for one frame in the worst case, or needs more than 4 096 records. Else the kind goes, and the terminal draws runs. Until the measure, the grid stays: it works today.

### The version rule

`DRAW_RECORD_VERSION` is the version of the form of the record. Each change of a kind, of a field, of a bound that changes what a record draws, or of the blending rule is a new version. The format changes in place: the package, the drawing module and each writer move in the same step, and no reader reads two versions. The names of the exports carry the version (`damage_of_draw_table_<version>`, `execute_draw_table_in_rectangles_<version>`): a module of another version has no export with the name that an importer binds, so the load fails before the check of the descriptions ([`docs/INTERFACE.md`](../../../docs/INTERFACE.md), "7. Where it lives: the elements in each program, the drawing in a module"). A constant check in the package and in the module stops a build whose names do not follow the version.

### The execution

**The drawing module** keeps its two exports and the calls of a frame: one for the difference, one for the draw of all its damage rectangles.

- The draw export takes one more parameter: `work: Bytes(Change)`, the work memory of the rasterizer, `DRAW_WORK_BYTES` (64 KiB) of the caller (property 14). The rasterizer of a path works in bands of rows: a band holds as many rows as the work memory holds for the width of the cut. With the error record the export has 8 arguments, inside the bound of 12 ([call_form_arguments.md](call_form_arguments.md)).
- For each damage rectangle, the module paints the background when the shape asks for it, then reads each record through the border, keeps the clip stack, and draws each record whose box meets the cut, cut to it.
- A path is drawn again in each rectangle that its box meets. The coverage of each pixel comes from every segment of the path, also the segments outside the cut, and the module writes only the pixels inside the cut. So the bytes are the same in each cut.
- The difference reads each record through the same border. Two pushes at one index whose boxes differ damage the union of the two boxes: a record inside them draws nowhere else. A push or a pop at one index where the other table has another kind damages each record from there to the end, as a changed `Clip` does today.

**The compositor** draws the parts of its screen with the same export, one call for each part ([picture.md](picture.md), "The compositor: one call for each part"). The surface of a window is an `Opaque` picture. With alpha, a menu, a shadow or the palette can lie translucent over the windows, by the one rule.

**Through a GPU, later.** When a GPU exists, a back end of the drawing module draws the same table through the WebGPU subset of the system, whose shaders the build compiles from WGSL to SPIR-V ([../features/gpu_access.md](../features/gpu_access.md)):

- each record is one instance over its box; a rectangle and a gradient are a quad with the coverage of its edges in the shader;
- a path gets its coverage in a pass of its own, as a glyph gets it; a text reads the glyph caches in a texture;
- the clip stack is a scissor rectangle, which is why a clip is on whole pixels;
- the rule in linear light with a gamma of 2 is not the sRGB curve of the hardware: the pass draws into a target of 16-bit floats that holds the squares of the values, blends there with the source over of the hardware, and a last pass takes the square roots.

The GPU gives the same picture within an error that a test states, not the same bytes. The damage stays the damage of the records: the GPU draws in the damage rectangles only. The table, the difference and the elements do not change.

### What costs more than version 10

Each line is an estimate to measure, not a claim:

| Cost | Estimate | The measure |
|---|---|---|
| A record of 48 bytes in place of 40: the difference and the copy of the frame before read 20 % more | The difference costs about 13 ns for each record today (`interface_elements`, 68 records); about 16 ns | The same window, the mean of 100 rounds |
| The border reads and checks each record in each damage rectangle | 2 to 5 ns for each record and each rectangle | `clock`: the draw of 34 records in 1 rectangle, 16.3 µs today |
| The memory of the tables | 8 bytes more for each record: 8 KiB more for a window of two tables of 512 records | The size of each window memory, from the build |
| The work memory of the rasterizer | 64 KiB more in each program that draws a path | — |
| A translucent pixel or an antialiased edge: the blend in linear light in place of a write | The cost of a pixel of text today, for each such pixel | `blend_coverage_row` against `fill` over a row of 512 pixels |
| A path, drawn again in each rectangle that it meets | 10 to 50 µs for a path of 100 points over 64 by 64 pixels, from the glyph with no cache (2.4 to 5.5 µs at 13 pixels) | A host test that draws a folded gap, a line and an icon of 64 by 64, and prints the times |
| The line and the folded gap as antialiased strokes in place of the line of Bresenham | More for each pixel; the count of the pixels is about the same | `inspect`: the frame of its band of folded gaps |
| The grid of points as three records | The same loop over the points as today | `clock`: the whole frame |
| A general gradient | One multiply and add for each pixel; an axis keeps the form of today | A host test: a gradient at 45 degrees over 512 by 512 |

The text, the pictures and the opaque rectangles on whole pixels cost what they cost today.

## The refused forms

- **A software adapter of WebGPU as the 2D interface.** It needs a compiler of WGSL for the processor, larger than the whole 2D drawing, and it draws a rectangle through a shader. The draw table is drawn through WebGPU when a GPU exists, not the other way round. The processor back end of the WebGPU subset, for 3D, is not this form: its shaders are a fixed set in Odin, and the draw table never goes through it ([../features/desktop_to_browser.md](../features/desktop_to_browser.md), "F. 3D").
- **A union of the language as the contract.** The layout and the tag of a `union` of Odin belong to the compiler, and property 19 forbids a contract that depends on one language. The record is bytes with an explicit kind; the union is the view past the border.
- **Records of variable size**, as a stream of commands. The difference compares two tables at one index, and a table of fixed records has that index with no parse. A length in each record is one more field that a hostile caller sets.
- **One record with the fields of every kind**, the form of version 10. It is the union with no tag that the review found.
- **Floating-point places.** Two equal drawings must have equal bytes; a float has two zeros and many NaN. The rasterizer works in integers, so its pixels are the same at each build. The base types of a contract have no float (property 19, "Open").
- **1/16 pixel.** It loses two bits of the measure of a text, which is in 1/64, so a right-aligned text could move by a third of a pixel. **1/256 pixel**, the unit of the rasterizer, gives no visible gain and a range four times smaller.
- **Premultiplied alpha in a record.** A transparent color then has many forms, and a token of the appearance names a straight color. The execution multiplies.
- **The blend in encoded values for the colors**, as the pointer pictures blend. It darkens the edges of a shape and of a text, which is why the text blends in linear light today. One rule serves every kind.
- **Blend modes past source over, in this version.** No program needs one yet. One comes as a field under the version rule when a program needs it ("The limits of the format: cost, never look").
- **The even-odd rule, cubic curves, round joins and ends, dashes, in this version.** The fonts and the pointer theme are quadratic outlines with the nonzero rule, and a writer cuts a cubic curve into quadratic curves within a tolerance. Each comes when a program needs it. The look of the desktop is never the reason: it binds the elements, not the format.
- **A limit of the format that is a rule of the look.** It would make the one 2D interface of the system unfit for a program of a third party, whose look is its own.
- **A clip by a path, or a clip with edges inside a pixel.** It needs a mask for each pixel, and a GPU cuts by a scissor rectangle. A form with a curved edge is a path.
- **A gradient with more than two colors, or a gradient that fills a path, in this version.** No program needs one yet. Each is a list of variable length or a second kind of paint for each shape; a need comes first.
- **The point grid as a repeated picture.** The tile of pixels must be in the one picture memory of the call, which the program owns: the interface package has no place for it. A repeated rectangle needs no pixels.
- **`Point_Grid` and `Folded_Gap` kept as kinds.** The look of the system is in the elements of the package; the format holds primitives only.
- **The old and the new form side by side in the drawing module.** The rule of the project is no backward compatibility: change a format in place and remove the old path. Each step below changes the format in place, with its version, and each writer moves in the same step.

## The subtle points

- **A box that lies.** A box that is smaller than the drawing cuts the drawing; a box that is larger damages more. Neither harms another record or another program.
- **A transparent record still damages its box.** A change of a color from opaque to transparent changes pixels.
- **A record that the border refuses** draws nothing and damages its box, at each frame: it is equal to no record. Its fields are not trusted, so its box is the box of its bytes, cut to `COORDINATE_LIMIT`.
- **The cost of a hostile record is bounded.** A rectangle reaches each pixel of its box at most once. A path has at most 1 024 points, so at most 16 384 segments, and its work is bounded by the rows of its box times its segments. A stroke is at most 64 pixels wide. A text is at most 256 bytes. The clip stack is at most 16 deep.
- **The record of zeros is valid.** It is a `None` with an empty box. A zero color is transparent, a zero step is no repetition, a zero stroke width is no stroke, a zero font is the font of the cells, a zero format is an opaque picture.
- **The pointer is not a draw record.** The compositor draws the pointer after the last call of a frame, with the blend of its premultiplied pictures in encoded values ([`docs/POINTERS.md`](../../../docs/POINTERS.md)). That second blend stays outside the draw table until the pointer becomes a record.
- **Two spaces, each for one reason.** The colors of a gradient mix in encoded values so that the gradients of today keep their bytes; the cover blends in linear light so that edges and text keep their weight.
- **The kind of a record is read one time.** The border takes one copy of the 48 bytes, and every check and every draw reads that copy: a caller that changes its table during a call changes nothing that was checked.

## What is built and what is left

Built: version 11 of the record, the tagged form: the header with the box in 1/64 pixel and the fields of each kind, in the contract package `src/library/contract/draw_record`, with its border, the writer of each kind, its byte layouts on the site and its fuzz target. The kinds are still those of version 10, each with its own fields, and every window draws the pixels of version 10: no kind draws inside a pixel yet, so the border refuses a box off the whole pixels. Two fields of version 10 became places: the ink margin of a text in the interface font is the distance from the left edge of its box to its origin, which is a place in 1/64 pixel on a third of a pixel; a line holds its two ends, and its box holds each square of its path. A record that the border refuses damages its box: in version 10 a refused line damaged nothing. The text table keeps its name `text`; the name `bytes` comes with the paths, which put points in it.

Left: each other step of `ROADMAP.md` whose design link is this file, in order. The steps change the format in place. Each one ends with every window on the new version.

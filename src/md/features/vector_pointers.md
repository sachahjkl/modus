# The pointer theme of the system as outlines

## Purpose

The theme of the system is the pointer of every release image. It was 15 grids of squares of 2 pixels: each slanted side was a staircase, and a reader saw a pixelated pointer beside the smooth pointer of the Posy theme. This design draws each shape from outlines and draws them at the build with exact coverage, so the edges are smooth and the straight edges stay sharp.

## Constraints

- **The compositor does not change.** The pointer theme file already holds 8 bits of alpha for each pixel, premultiplied ([`docs/POINTERS.md`](../../../docs/POINTERS.md), "3. The format of the system: one pointer theme file"). A smooth edge is a value of alpha between 0 and 255, so the format, the validation, `choose` and the blend stay as they are.
- **One rasterizer.** The system draws the outlines of its fonts with exact coverage in integers (`src/library/support/vector_font`, [`docs/FONTS.md`](../../../docs/FONTS.md), "4. Fixed point"). The pointers use the same code: no second rasterizer, no floating point, the same pixels on each machine.
- **Text in the repository.** A shape is reviewed as a diff of a few lines. No picture file and no pixel goes in the repository.
- **Own work under MIT.** Each shape is drawn for this system, not traced from a theme of another license.
- **Readable on any background.** The pointer passes over the dark desktop, light text, pictures and the light form of the site.

## The chosen form

**The source is the manifest, with outlines in place of grids.** One grammar keeps the two sources of a theme: the files of an Xcursor theme, or outlines in the manifest ([`docs/POINTERS.md`](../../../docs/POINTERS.md), "4. The manifest"). An outline is the term of the glossary: closed contours of lines and quadratic curves, here in units of the design size.

- **The unit is a pixel of the first size of the shape** (24 for the theme of the system). A coordinate is a number of units with at most three decimals, kept as an integer of thousandths. The statements are `contour x y`, `line x y`, `curve cx cy x y` and `circle x y radius`; a contour closes itself.
- **Layers in paint order.** `layer dark`, `layer light` and `layer clear` each start a layer: its contours, joined as a union, are painted over the layers before it, with the coverage of each pixel as the weight. `clear` makes its contours transparent: a hole in a ring is a clear circle, not a contour in the opposite direction.
- **Frames.** The layers before the first `frame` are in each frame; each `frame <delay>` adds its own layers on top. An animation is a phase: the shape that moves is written once in each frame, the rest once for all frames.
- **The hot spot** is a pixel at the design size; at another size it is that pixel times the ratio of the sizes.
- **Every point is inside the square of the design size.** The parse refuses a coordinate or a circle outside it, so no picture is cut.

**The build** draws each layer of each frame at each size: the contours go to an accumulation of `vector_font` (`line_add`, `quadratic_add`), `coverage_finish` gives the coverage of each pixel from 0 to 255, and the paint goes over the pixel with that weight, in premultiplied integers. A channel never passes its alpha, so the result passes the validation. The pictures of one size share one box: the pixels that some frame draws, with the hot spot. The file is the pointer theme file of today.

**Two colors: a dark edge of 1 unit around a light fill**, black `0x000000` and white `0xFFFFFF`. The desktop, the cards and the windows of the system are dark: there the light fill carries the contrast (19 to 1 on `COLOR_BACKGROUND`) and the pointer is the brightest thing on the screen. Over white text, a light picture or the light form of the site, the dark edge carries it. For any background, black or white has at least 4.58 to 1, so one of the two stands out everywhere. The reverse (a dark fill with a light edge) puts a line of 1 pixel of light on the dark desktop: the pointer then reads as a thin outline over a dark shape.

**Hinting by design.** The rasterizer does no grid fit for a pointer. The drawing does it: each level and upright edge is on an integer coordinate, so it falls on a pixel border at 24 and, at twice the size, at 48. A stroke of 1 pixel is drawn as a band between two integers; its centre line is then on a half unit. A symmetric shape has its centre on the middle of the pixel 11, so its stroke of 1 pixel is one whole column. A slanted side is smooth by its coverage; its edge is moved out by 1.414 units at 45 degrees, so the edge is 1 unit thick across.

**The sizes stay 24 and 48.** The compositor asks for 24 (`POINTER_NOMINAL_SIZE`); 48 is for a screen with twice the pixels. The system has no table of scales of 1.25 or 1.5 that would ask for 32 or 64. With outlines, a size is one number of the statement `sizes`: it is added when a scale asks for it, not before. Each size that is a multiple of 24 keeps the sharp edges.

## Refused forms

- **Grids of squares.** They are the fault that this design removes: a slanted side or a curve is a staircase at every size.
- **SVG files and an SVG reader.** SVG brings XML, paths with arcs and cubic curves, transforms, styles and units. The tool would parse a large format to use one fifth of it, and a shape would be a file that a diff does not show well. The few statements of the manifest are the part that a pointer needs.
- **PNG or other pictures drawn outside.** A picture is a result, not a source: a review sees no geometry, and a new size needs a new drawing.
- **Cubic curves.** The rasterizer cuts quadratic curves. A circle is eight quadratic curves at 0.3 % of the radius, under 1/30 of a pixel here.
- **A stroke statement.** A stroke needs an offset of curves, joins and caps: much code for one look. The edge is the light contour moved out by hand, which also lets each edge sit on the pixel grid.
- **Holes by the direction of a contour.** A hole that depends on the order of the points fails without a sign. The tool adds each contour in one direction, so the contours of a layer are always a union, and a hole is a `clear` layer.
- **A rotation of the frames by the tool.** A rotation by 45 degrees needs a sine and puts every point off the grid. A dot that moves around a ring from frame to frame is one circle for each frame.
- **A second rasterizer, or a filter of a picture at 4 times the size.** A downscale gives an approximate coverage and adds code; the coverage of `vector_font` is exact for the cut polygon.
- **A change of the pointer theme file or of the compositor.** The file already holds premultiplied alpha.

## Subtle points

- **The coverage is exact for the polygon of the cut points.** `quadratic_add` cuts a curve into lines at most 1/8 of a pixel from it. A small circle is up to 3 % under its area; the host test holds the bound.
- **A union of layers of one paint, not a sum.** The coverage of two contours of one layer that overlap is clamped to a whole pixel: the overlap is not darker or lighter.
- **The order of the layers is the drawing.** A light layer over a dark one is the fill inside the edge; a dark layer after it draws details on the fill (the dot of `wait`).
- **The box of the picture is cropped**, with its hot spot in it. The pointer theme file stores fewer transparent pixels, and the compositor blends fewer.
- **The compositor without a valid theme** still draws its own arrow of squares (`pointer_arrow_without_theme`): that path has no file to read.

## State

Built: the outline statements of the manifest and their errors, the drawing at the build with the rasterizer of `vector_font`, the 15 shapes of the theme of the system at 24 and 48 (`wait` and `busy_with_arrow` with 8 frames of 125 ms), and the host tests: golden coverage, the union of contours, the area of a circle, each shape inside its square with its hot spot, the dark edge around each light pixel, the contrast of the two colors, the round trip of the file.

Left: nothing of this design.

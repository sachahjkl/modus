# The pointer theme of the system as outlines

## Purpose

The theme of the system is the pointer of every release image. It was 15 grids of squares of 2 pixels: each slanted side was a staircase. This design draws each shape from outlines at the build with exact coverage, in two forms (one for a dark desktop, one for a light desktop), with a touch of an accent color on the parts that carry a meaning.

What changed after the first outlines: the edge was a second contour drawn by hand and scaled with the size, so it was 2 pixels at 48 and the shapes looked coarse. The edge is now made by the tool, 1 pixel at every size, and the shapes are finer.

## Constraints

- **The compositor changes as little as possible.** It already blends 8 bits of premultiplied alpha. A form is one more argument of `choose`.
- **One rasterizer.** The pictures are drawn with the exact coverage of `src/library/support/vector_font` ([`docs/FONTS.md`](../../../docs/FONTS.md), "4. Fixed point").
- **Text in the repository.** A shape is a diff of a few lines, and a color is the name of a token of the design rules, never a value.
- **Own work under MIT.** Each shape is drawn for this system.
- **Readable on the surfaces of its appearance.** The dark form passes over the dark desktop and the cards; the light form over the light surfaces.

## The chosen form

**The source is the manifest** ([`docs/POINTERS.md`](../../../docs/POINTERS.md), "4. The manifest"). An outline is the term of the glossary: closed contours of lines and quadratic curves, in units of a pixel at the first size of the shape (24), with up to three decimals kept as thousandths.

**Layers by role, not by color.** A layer paints its contours over the layers before it:

- `fill`: the fill color of the form, with an edge;
- `accent <token>`: an accent, with an edge;
- `fill inside`, `accent <token> inside`: no edge, for a part that lies on the fill (the dot of `wait`);
- `edge`: the edge color, as drawn (the lines between two fingers);
- `clear`: transparent, with an edge around the hole.

The contours of one layer are a union: the tool adds each contour in one direction, so two contours that overlap do not cancel.

**The edge is made by the tool, inside the contour, 1 pixel at every size.** For a layer with an edge, the tool paints the contours in the edge color, then the same contours moved in by 1 pixel in the color of the layer. The contours are the whole shape at every size: the point of the arrow and the hot spot scale together, and only the edge stays thin. A move of a contour moves each side along its normal; two sides meet where their moved lines cross, and a curve keeps its control point where its two moved tangents cross, so a circle stays a circle. The arithmetic of the move is IEEE double precision: its operations are exact roundings, and each machine makes the same points. A contour that the move turns inside out adds nothing.

**Two consequences for a drawing.** Two contours of one layer that must join overlap by 2 units: their moved contours then meet. Two contours that overlap by 1 unit leave 1 pixel of edge between them at 24 and none at 48; a line of `edge` half a unit wide on the integer next to the overlap parts them at 48 by exactly 1 pixel, and adds nothing at 24. The fingers of the hands use this.

**Two forms in one file.** The dark form has a white fill in a dark edge (the color of the desktop, `COLOR_BACKGROUND`); the light form a dark fill in a white edge. The fill is the large part, so it carries the contrast on the surfaces of its appearance: white has 19 to 1 on the dark desktop, the dark 17 to 1 on the light background. The edge separates the pointer from a surface of the other kind. The file holds one set of shape entries for each form (`form_count` in the header, which was a reserved word); a theme of sources, such as the Posy theme, has one form, which `choose` gives for both. A second resource for the light form was refused: the root service, the context values, the packaging of a release and the setting of the theme would each need a second path.

**The accents are tokens of the design rules**, by the name of the constant without `COLOR_`: `title` (the blue of the focus), `stop_program` (the red of the close button), `boot_program` (the amber of a match). Each token has a value for a dark surround and a value for a light surround, the second a darker shade, as on the light form of the site. An accent takes the value for the color around it: an accent inside the fill has the fill around it, an accent with an edge has the edge. So the blue dot on the white ring of the dark form is the darker blue, and the blue question mark in its dark edge is the brighter blue. The accents are on the parts that mean something only: the dot that turns in `wait` and `busy_with_arrow`, the slash of `forbidden`, the question mark of `help`, the dot at the hot spot of `crosshair`. The arrow, the hands, the I-beam and the resize arrows stay neutral.

**The compositor takes the form of the appearance in force.** One procedure of the compositor (`pointer_form_in_force`) reads the settings page; until the page holds the appearance in force, it gives the dark form. A change of the settings calls it again, as it calls the choice of the theme.

**Hinting by design.** Each level and upright side is on an integer coordinate, so it is sharp at 24 and at 48. A stroke is 3 units wide: 1 pixel of fill between two pixels of edge at 24, 4 pixels of fill in 1 pixel of edge at 48. A symmetric shape has its centre on the pixel 11.

**The sizes stay 24 and 48.** The compositor asks for 24. A size of 32 helps only a compositor that asks for 32, and no scale of the system does; the details are drawn for 24. A size is one number of the statement `sizes` when a scale needs it.

## Refused forms

- **Grids of squares.** A slanted side or a curve is a staircase at every size.
- **An edge drawn by hand as a second contour.** It scales with the size: 2 pixels at 48. It also doubles each drawing.
- **An edge outside the contour.** The contour of the fill would then be the shape, and the edge would add 1 pixel around it at every size: the point of the arrow would be at another place than the scaled hot spot at 48.
- **Colors in the manifest.** A value in a manifest is a second table of colors. A token keeps one table.
- **One value for each token.** A blue that has 3 to 1 on white has less on the dark of the desktop; the value depends on the color around it.
- **A second resource for the light form.** See above.
- **SVG files and an SVG reader, PNG pictures drawn outside, cubic curves, a stroke statement, holes by the direction of a contour, a rotation of the frames by the tool, a second rasterizer.** The first outlines refused them for the reasons that hold today: a large format for a small use, a result in place of a source, curves that the rasterizer does not cut, the joins and caps of a stroke, a hole that fails with no sign, points off the grid, approximate coverage.

## Subtle points

- **The coverage is exact for the polygon of the cut points**; a small circle is up to 3 % under its area.
- **A part thinner than 2 units disappears** at 24 when its edge is made: its moved contour is inside out. Each stroke is 3 units wide.
- **The join of a move is the crossing of two moved lines**, held to 4 pixels from its corner, so a sharp corner gives a long but finite point.
- **The box of a picture is cropped**, with its hot spot in it, and one box serves the frames of one size.
- **The compositor without a valid theme** still draws its own arrow of squares (`pointer_arrow_without_theme`).

## State

Built: the roles of the layers and the accent tokens, the edge of 1 pixel made by the tool, the two forms in the theme file and in `choose`, the form in the compositor with the dark form until the settings page holds the appearance in force, both forms in the program `pointers`, the 15 shapes at 24 and 48, and the host tests: golden coverage in both forms, the edge of 1 pixel at two sizes, the union, the area of a circle, each shape in each form inside its square, the edge around each fill pixel, the contrast of each form on its surfaces and of each accent on its surround, the accents on their parts only, the round trip of the file.

Left: the read of the appearance in force in `pointer_form_in_force`, when the settings page holds it.

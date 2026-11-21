# The process heron: the animations of the mark in a window

The process `heron` plays the animations of the mark in a window of the system. It is a demonstration of the graphics of the system: a large form that moves each frame, a small damage, and a picture that is shown whole. What it shows and its keys are in [`docs/DESIGN.md`](../../../docs/DESIGN.md), "The animations". This file records why it has its form.

## The purpose

- A reader sees the heron move in the system, not only on the site.
- A reader sees how an animation is made: a few cells change, and a move is another drawing in the same cells.
- The process is a load for the window layer that no other process gives: a form of up to 32 by 26 cells changes its place 60 times a second.

The animations play in a process that a reader starts. They never play on a mark beside a text or a control: a picture that moves takes the eye from the text.

## The constraints

- One source of each rule. The site and the module must not hold two copies of a rule that can drift.
- A cell of the heron is a square of one size at a place of the grid, also while the heron moves. A squashed or a stretched heron is another drawing in whole cells, and the heron travels by whole cells: no transform changes the size of a cell, and nothing rounds a smooth move.
- A test of the process checks a condition, never a time. The play must give the same lines on a slow host.
- The log of the system is shared and bounded. A process that runs for hours must not fill it.

## The chosen form

**The rules are in `src/library/modus/mark`.** The cells and the frames, the order of play and the still times (`play.odin`), the forms and the keys of the moves (`motion.odin`) are data and pure procedures there. The modus tool runs the same procedures to check the script of the site. The process holds no rule: it asks for the next animation, the frame at a time, the form and the place at a time, and draws.

- The rule of the order takes a number of chance as a parameter. A test gives the numbers of a generator with a seed; the process gives numbers of its random generator. The rule itself has no source of chance, so the tool and the process can share it.

**A move on the grid is the rule; the free way is the comparison.** On the grid the process draws the drawn form of `src/library/modus/mark` for the frame, at a place in whole cells. The free way reads the same keys, stretches the frame as it is to the box of the form, and moves the box pixel by pixel.

- The free way stretches the frame, not the form. A stretched form would look almost right, and the comparison would show only the travel between two cells. A stretched frame shows what a form is for: the eye is no longer one cell, the beak and the legs change their thickness.
- The grid way is not a filter over the free way. It never draws a scaled picture and never rounds a smooth place: the form and the place are cells from the data.
- The free way lives in one file of the module. It is not a rule of the system, so it is not in `src/library/modus/mark`.

**The play goes forward by at most 40 ms for a picture.** A picture that comes late slows the animation. The shortest frame is 70 ms, so each frame is in one picture at least, and the dash always has a picture with the heron outside the window. The lines of the log are then the same on each host: "17 frames", "left the window".

**The stage is a picture of the process, cut in tiles.** Each tile is a Picture record with a generation. A picture of the heron clears and draws two rectangles of the stage and raises the generation of the tiles under them. The window layer then finds a damage of a few tiles by its usual difference: the process tracks no damage rectangle for the window.

**The window is shown whole or not at all.** This is the rule of the system for every window: [infrastructure/whole_frame.md](../infrastructure/whole_frame.md). The surface of a window has two pictures. The process draws one while the compositor reads the other. `Present` names the picture that is complete. The process draws only when the compositor took the picture before.

- The fault that made this rule was found in this process: its window had one picture. The window layer paints a damage rectangle with the background, then draws its records. The compositor read the rectangle between the two, and one picture of the screen showed the head of the heron with no body. A window that changes a number shows such a mix as nothing. A window that moves a large form shows it as a flicker.
- The process serves calls in the thread of its window, so it never waits for the compositor: it asks `display.canvas_free`, and when the answer is no, its wait ends when the compositor has read, at a key or at a call.
- The cost: each picture of the surface is drawn from its own older frame, two steps of the heron. The damage is about two times the damage of one step. It is still a few tiles.

**Each key writes one line, after the picture.** A line says a state that the screen has: the process writes it after it presented that state. A scenario of a test or of a film waits for the line, then takes its picture.

- An animation of the own order writes a line too, but only the first 32: the heron plays as long as its window is open.
- The line of an animation of the own order does not start as the line of an asked animation. A wait for the dash that a key asked for must not take a dash that chance played.

## The refused forms

- **A copy of the order rule or of the moves in the module.** It was the first form of the moves, for the time when `src/library/modus/mark` did not hold them. Two tables drift.
- **A sampling of the cell grid for a squashed heron** (each cell of the wider heron shows the nearest cell of the frame). It keeps square cells, but it leaves out the row under the eye and makes a leg two cells wide. A form is drawn by hand: lines chosen on the heron, then corrections.
- **One Picture record for the whole stage.** It does not make a frame whole: the copy of that picture into a surface with one picture is torn in the same way. And each frame damages the whole stage.
- **A second buffer in the process, copied at the end of a frame.** The stage is that buffer already. The compositor never reads it. The tear is in the surface.
- **Rectangle records for the cells, with no picture.** A cell has a gradient over the box of its part, at an angle. A record has a flat color, or a gradient along one axis.
- **A count of the pictures in a test** ("the dash drew 100 pictures"). It is a speed. The test waits for a line that says what the heron did.
- **A line of the log for each animation, for ever.** It fills the log of the system in an hour.

## The subtle points

- A tile that changed in one step must be drawn in both pictures. The window layer does this with no code of the process: the rectangle of the tile is in the damage of that step, and it joins the debt of the picture that was not drawn in that step.
- The process takes its keys also while it waits for the compositor. Only the picture waits.
- The line of what the window shows is written after `Present`, not after the compositor drew. The tool takes a picture when the compositor says that it drew each `Present`.
- The first line of the process comes after its first picture, and the main test waits for it. The proof that the window shows whole frames is not a line of this process: it is the count of the compositor for each window.
- The band is in the font of the cells: 8 pixels for a character in both settings of the font. Each text has a box for its longest value, and a box that is too small stops the build.

## The state

Built: the play, the two ways, the tiles, the lines of the log, the exports `play`, `animations` and `grid`, the scenario of the main test and the film.

Left:

- No host test of the free way: a module with an entry has no host tests.
- No check that reads the screen for a part of a heron. The compositor counts the `Present` records that named the picture that it already read; it does not see what a process wrote.

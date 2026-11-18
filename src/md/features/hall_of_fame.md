# The hall of fame

The process `hall_of_fame` shows the people whose work inspired modus: one card for each person, with the name, one line on what they made, and a portrait when the repository can hold one. It replaces a process that showed one turning portrait in a temple, with no credit on the screen.

## Purpose

- A reader sees where the ideas of the system come from: the language that it is written in, the emulator that runs its tests, the immediate-mode interface, the engines, the browsers and the streams that showed how to build a system from scratch.
- A person is in it for work that the system learned from or uses. Fame, a following or an opinion is no reason. A new person comes with a line that says what of their work reached modus.
- The list is one table of the process (`people` in `src/modules/demonstrations/hall_of_fame/main.odin`). This file names nobody: the table is the one place of the names.

## Constraints

- The process follows the design rules ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "10. Elements"): the background with its grid of points, cards with a border of 1 pixel, the interface font for the names and the lines, no rounded form, no shadow.
- No cut text and no text over text: each text is measured in the font that draws it, and wraps inside its card ([text_box.md](text_box.md)).
- The window fits the screen of 1024 x 768 with the bar and a title bar.
- A picture of a real person is a fact with an author and a license. The repository holds it only when the license allows it, and the credit is visible wherever the picture is.

## The chosen form

- **A grid of cards, three columns, in whole rows.** Each card is as tall as its texts, measured at each frame, and each card of a row has the height of the tallest one. The view shows whole rows only: a row that does not fit is not drawn, so no card is cut at the edge. The view moves by rows, and its scroll bar is in rows.
- **A card with a portrait**: the portrait of 96 x 128 pixels at its top left, the name and the line at its right, and under the portrait the portrait credit: "Picture: <author>", then the license, in the dim color. The credit takes the whole width of the card, so a long credit takes lines, not a cut.
- **A card with no portrait**: the name and the line on the whole width. It is a tile in the sense of the glossary: a rectangle that stands for one person, with the name inside. It has no picture in place of the portrait, no initials and no form that imitates a face.
- **The choice**: one chosen card, with a border of 2 pixels in the chosen blue. The arrows, Home and End move it; a press of the pointer on a card chooses it, through the input of the interface package. The view moves to keep the chosen card in it. Each card has its element name (the name of the person), so a machine test presses it by name ([../infrastructure/test_pointer.md](../infrastructure/test_pointer.md)).
- **The pictures**: each picture is a PNG file of `resources/hall_of_fame/`, a crop of 480 x 640 pixels of its source. `modustool portraits` makes the pixels of each portrait, the mean of each square of 5 x 5 pixels, into `src/modules/demonstrations/hall_of_fame/portraits/`. The process holds them with `#load`, so the build and the process decode no image file. The five portraits are one picture memory: the drawing module reads one picture memory for each call.
- **The credits file**: `resources/hall_of_fame/CREDITS.md` is a table with one row for each picture: the file, the person, the source with its address, the author and the license. It is the one list of the pictures: the command reads it, the page of the licenses of the site shows one row for each picture from it, and a host test checks that the process has the author and the license of each row.

## The rule of the pictures

- A portrait is a picture under a free license that allows a copy with a credit (CC0, CC BY, CC BY-SA), cropped and reduced, with no other change.
- One exception, kept on purpose: one portrait is a frame of a video talk, all rights reserved by its producers. It is credited to its source, as the credits file says, and the site shows that license as it is written. No second exception is made: a new picture follows the rule above.
- Each other person has a card with no portrait until a picture with such a license exists.

## Refused forms

- **A photograph with no license, or with a license that is not known.** A picture found on the web is not a picture that the repository may hold.
- **A generated portrait of a real person.** It invents a face, and the design rule "a display invents nothing" holds for a person as for a number.
- **Initials in a circle, or a drawn silhouette, in place of a photograph.** It is decoration with no fact, and a rounded blob.
- **A cut name or a cut credit.** A credit that a reader cannot read whole is no credit.
- **A view that scrolls by pixels.** The edge of the view would cut the texts of a card.
- **The credits only on the site.** The credit goes with the picture, so it is in the window too.
- **The turning portrait of the earlier process.** One person on a pedestal does not say where the ideas of the system come from.

## Subtle points

- The pixels files are generated, but they are in the repository: a build reads them, never the PNG files. After a change of a picture or of the credits file, run `modustool portraits`; the host test fails when the size of a pixels file is not the size of a portrait.
- The process checks the length of each pixels file. A wrong length gives a card with no picture and one line on the log, not a fault.
- The heights are measured in the font that draws the text: with Spleen 8x16 the texts are wider, the cards are taller, and fewer rows fit. The view and the scroll bar follow the measure.
- The first frame writes `hall_of_fame: ok, the first frame drew <count> of the 16 people in <time> us`, after the window presented it. The time is a measure: no test asserts it.

## State

Built: the window, the cards, the choice by keys and by the pointer, the scroll bar in rows, the conversion of the pictures, the rows of the licenses of the site, and a step of the main scenario that takes the picture `hall_of_fame` and checks a choice by key and by pointer. Left: nothing planned.

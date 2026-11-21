# Angles in turns

Each angle of the system is in turns: 1 is a whole circle, 0.25 a right angle. The type or the name of a value says so: `angle_turns`, `phase_turns`, `hue_256ths_of_a_turn`. The trigonometric routines of the system, `modus:support/trigonometry`, take turns. The glossary term is "Turn" ([`docs/glossary/code.md`](../../../docs/glossary/code.md), "Turn").

## Why turns

- **The common angles are exact.** A quarter, a half and an eighth of a turn are exact in binary. In radians each of them is a multiple of π, which no f64 holds, so the cosine of a right angle in radians is about 6e-17 and not 0. In turns it is 0.
- **No π in the code.** A routine in radians multiplies by 2π to find the angle, then divides by π/2 to find its quadrant. The factor 2π is inside the coefficients of the polynomials, so the code holds no π and does one multiplication less.
- **A wrap is exact.** The direction of an angle is its fraction of a turn: the subtraction of the whole turns is exact for each f64. An angle in radians loses digits at each reduction by 2π.
- **Other places already count in turns.** The phase of a wave is the part of its period. A sine table of 256 entries is indexed in 256ths of a turn. A hue is a part of the circle of colors. A style sheet of the site takes the unit `turn`.

## The routines

`trigonometry.cosine` and `trigonometry.sine` take the fraction of the turn, find the nearest whole quarter turn and the rest, from -1/8 to 1/8 turn, and compute a Taylor polynomial of nine terms in turns on that rest. Each step before the polynomial is exact, so a whole number of quarter turns gives an exact 1, 0 or -1, and a right angle gives +0. An infinite angle or a NaN gives a NaN. The host tests check the exact angles first, then the wrap, then the precision against the radian form of the Odin core library: under 4 units of the last place of an f64, times 1 + the angle in radians, because the radian form rounds 2π · t.

## The subtle point

A derivative of a function of an angle in turns gains a factor of 2π: the derivative of `cosine(t)` is `-2π · sine(t)`. A formula of calculus from a book is written for radians. Code that takes one must add that factor. This is the one place where 2π appears in code that uses turns.

## Host code

The Odin core library (`core:math`) takes radians. Host code that must call it converts at that one call, with a comment. Host code that only needs a sine or a cosine imports `modus:support/trigonometry`, as the tool does for the tone of its sound test.

## Refused forms

- **Radians.** The common angles are not exact, the code holds π, and each call multiplies by 2π.
- **Degrees.** The common angles are exact as whole numbers, but a routine divides by 360, which is not a power of two, and the fractions of a degree are not exact.
- **A fixed-point angle of 2^n steps for each turn everywhere.** It is exact and wraps by overflow. It suits a table, as the sine table of `plasma`. A program that needs a fine angle then needs a second form, so the system keeps the turn as the unit and a table counts its steps in 256ths of a turn.
- **A sine or a cosine of its own in each module.** `tone` held a cosine series in radians, and `plasma` the approximation of Bhaskara, wrong by up to 0.0016. One package, with its host tests, serves each module.

## State

Built: the package `modus:support/trigonometry` with its host tests, `tone`, the sine table of `plasma` and the sound test of the tool on it, the phase of the wave of `threads`, the hue of `graphics.hue_color`, the comments of the outlines of circles and the chevron of the site in turns. The text sample of `interface_font` keeps "θ = 45°": it is a text that shows the glyph °, not an angle that code computes.

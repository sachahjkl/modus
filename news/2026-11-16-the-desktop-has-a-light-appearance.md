title: The desktop has a light appearance
date: 2026-11-16
release: next
picture: docs/screenshots/desktop_light.png
kind: Shown
guide: docs/DESIGN.md

The desktop has two appearances: dark and light. The setting `appearance` chooses one: `dark`, `light`, or `auto`, the default, which gives the light appearance from 07:00 to 19:00 and the dark one at night. The system has no time zone yet, so these are the hours of UTC.

Each color of the design rules has a value in each appearance, in one table. The light appearance has the colors of the light page of this site: dark text on a light background, white cards, each concept in a darker shade of its color. The blue of a title bar and the red of a close button are the same in both.

A change draws each window once: the background, the bar, the windows, the palette, the console and its results. The boot display stays dark. In the console, `settings.set("appearance", "light")` changes it at once, and the log says why the appearance in force is what it is.

title: The diagrams of the guides are drawn
date: 2026-11-17
release: next
picture: none
kind: Fixed
guide: docs/ARCHITECTURE.md

modus is an operating system whose site publishes its guides. The guide of the architecture holds five diagrams in the text form of mermaid: the layers of the system, the order of construction, and three flows in time. The site showed each one as its text.

Now the tool draws each diagram as a picture in the page when it builds the site, with no script. The boxes, the lines and the labels take the colors of the site, so a diagram follows the light and the dark form. The tool measures each label with the font of the diagrams, so a long label wraps onto more lines and no text passes its box. The text of each diagram stays under its picture, for a screen reader and for the search. A diagram that the tool cannot draw stops the build of the site, with its file and its line.

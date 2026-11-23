type: Fixed

**A line with more than 63 pairs of brackets keeps the order of its text**: the rule N0 of UAX #9 no longer keeps the first 63 pairs and silently leaves the others neutral; the whole line keeps the order of its text, as a line past the glyph limit of the bidi algorithm does.

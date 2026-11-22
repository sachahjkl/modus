type: Added

**An HTML parser that fuzz targets try to break.** The fuzz target `html_css` gives any page of up to 16 KiB to the parser, the style sheet and the layout of the light browser core, and checks the bounds and the links of the tree and of the boxes, and that the border of the drawing takes each draw record of the paint. The fuzz target `software_machine` runs any x86-64 code on the software processor of the browser machine, and checks that a fault changes no register and no byte, and that no step writes a page that the user cannot write.

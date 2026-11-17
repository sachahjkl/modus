type: Changed

**The draw record in one tagged form**: a draw record is 48 bytes, a header with its kind, its element and its box in 1/64 pixel, then the fields of its kind only, in the contract package `draw_record`. One border reads each record and refuses a word that names no kind, a reserved byte that is not 0, an inverted box and a field past its bound. The drawing module has the exports `damage_of_draw_table_11` and `execute_draw_table_in_rectangles_11`, every window draws the same pixels, the site shows the byte layout of each kind, and a fuzz target tries the border.

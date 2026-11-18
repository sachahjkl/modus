type: Changed

**One text kind in the draw record**: a text in the font of the cells and a text in the interface font are one record `Text`, with its font as a field: the draw record is version 13, and the drawing module exports `damage_of_draw_table_13` and `execute_draw_table_in_rectangles_13`. Each text draws the same pixels. The word 11 of the kind `Interface_Text` now names no kind, and a text in the font of the cells that starts past the coordinate limit has no record.

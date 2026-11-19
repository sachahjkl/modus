type: Changed

**A text size in the draw record.** The draw record is version 18: a text record and a text grid carry a text size in 1/64 pixel, from 4 to 256 pixels, in place of one of three scales, and the border refuses a size out of that range, 0 too, with no clamp; the exports of the drawing module are `damage_of_draw_table_18` and `execute_draw_table_in_rectangles_18`. A text of the interface font takes its bold weight at each size, and the pictures of the desktop do not change.

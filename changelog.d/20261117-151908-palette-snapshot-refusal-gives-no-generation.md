type: Fixed

**A refused palette table gives no generation.** When an entry of the palette table is refused, the snapshot holds no entry and the generation 0, so a reader that keeps the generation of its last snapshot reads the table again.

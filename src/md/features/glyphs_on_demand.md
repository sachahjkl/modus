# Glyphs drawn on demand

## Purpose

The glyph caches of the boot image hold 192 characters: ASCII, the Latin-1 Supplement and the euro sign ([../data/text_encoding.md](../data/text_encoding.md)). Each character of a cache costs about 2.2 KB of drawn words in each cache, at each scale and each position. So each new character of each font makes the boot image larger, and each font must draw each character of the list.

A principal reads and writes words in more languages, and names things with more signs than these 192. This design lets a program draw a character past the glyph cache: a font service draws its glyph into one shared cache that each program maps read-only. The boot image then carries the outline of a character (about 200 bytes), not its drawn words at every size.

The guide of the subject is [`docs/FONTS.md`](../../../docs/FONTS.md), "13. Glyphs drawn on demand".

## Constraints

- **A program never waits for another program in its frame.** A program cannot hold the compositor, and a service cannot hold a window ([../infrastructure/whole_frame.md](../infrastructure/whole_frame.md)). A font service that is stopped by a debugger must not stop each window.
- **A font file is hostile input.** Only one program reads outlines at run time: the font service. The other programs read words of coverage only.
- **No program writes a glyph that another program draws**, except the font service. A program can only ask.
- **A count, an offset or a length from another party is copied, then checked** (subtle point 5 of [../README.md](../README.md)). The shared cache changes while a program reads it: a reader checks each entry that it copies against constants of the contract, never against a field of the shared memory.
- **No queue drops a record in silence.** A request that does not fit, and a glyph that does not fit the shared cache, are counted.
- **No shared state tells a program what another program draws.** A cache that each program reads and that fills at the requests of the programs is a channel between them: [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", row 17.
- **The same font and the same renderer give the same pixels.** A glyph drawn on demand must have the bytes that the build would give it, so that a picture does not depend on the order of the requests.
- **The first frame needs no service.** The boot display is drawn before any service runs, and the compositor, the terminal and the console draw their first frame at once.
- **The measure and the draw of one frame agree.** A text is measured, then placed, then drawn. A glyph that becomes ready between the measure and the draw would change its advance and put a text over another.

## The chosen form

**What stays built at build time.** Each glyph cache of the boot image stays as it is: the 192 characters of each font, Spleen 8x16, and the boot display. The first frame of each program, the compositor and the terminal need no service, and a text of the 192 characters never meets the service. The demand cache is only for a character that no glyph cache holds.

**The font service** is the program `glyphs`, a part of the system that the root service starts after the compositor. It holds the outlines: the subset of the interface font in its module (`resources/fonts/b612.ttf`, the same file whose glyph cache the boot image carries). It is the only program that reads outlines at run time. It draws a glyph with the renderer of the build (`vector_font.demand_glyph_draw`), with the style of the glyph cache of the same font file, at each scale and each position of that cache: three positions at scale 1, one at scales 2 and 3.

**The service draws its whole subset at its start.** Before it reads any request, it draws each character of `demand_cache.subset_ranges`, in the order of the code points. A request then finds each one published before, and a character outside the ranges is answered as absent with no entry (`demand_cache.in_subset`). So the entries of the cache are the same whatever the programs draw: a program reads in it which characters the subset holds, and nothing about another program. The channel of the constraint above is closed for the subset. It opens again only for a cache that fills on demand beyond a fixed subset; each later layer that does that states how it closes the channel ([`ROADMAP.md`](../../../ROADMAP.md)).

**The demand cache** is one memory object that the root service creates at its start. The font service holds it with Write. Each program with a request ring maps it read-only at the fixed range `Demand_Cache`. Its format is `src/library/contract/demand_cache`:

- a header: the hash of the font file of its outlines, the renderer version, the flags of the style, and the generation;
- a table of 1024 entries, a hash table keyed by the code point, with at most 16 probes;
- the words of coverage, written one glyph after the other, 1 MiB.

An entry holds the code point, a state (`Drawn`), the generation that published it, the advance of each scale and the five glyph entries, in the form of `glyph_cache.Glyph_Entry`. The service writes the words and the fields of an entry, then the code point with release, then the generation of the header. An entry never changes after its publication.

**Which program gets a ring.** `start` of the root service gives a request ring and the demand cache to each program that it gives a ring to the compositor: each program of the boot image but a program with a terminal, whether it opens a window or not. The compositor, the input service, a terminal and a program started from a disk get none, and draw the replacement glyph past the glyph cache. The font service serves 28 rings at one time (`demand_cache.CLIENT_CAPACITY`); a program past them gets none, with one line of the log.

**A program asks with a ring.** The program maps its ring with Write at the fixed range `Glyph_Requests`. The service receives it with a `Client_Add` record on its control ring, as the compositor receives the ring of each window. A frame collects the code points that it did not find (`demand_cache.Reader.wanted`). At the end of the frame, the program sends them in records of 14 code points each, and each code point once in the life of the program. The service answers each record with one record: the generation, and the counts of drawn, absent and refused characters. The wait of the program adds the answers of the ring, so an answer wakes it, and it draws again. With the whole subset drawn at the start, a program asks only in the frames before the end of that work, and for characters outside the subset.

**A glyph that is not ready draws the replacement glyph.** The program never waits for the service. A frame where a character is not in the demand cache draws the replacement glyph with the advance of `0`, as for a character that no font draws. This happens only before the service ended its start: a program whose first frame comes after it draws each character of the subset in that frame. A program whose first frame comes before it finds no magic or a lower generation, draws the box, asks, and draws the glyph from the frame after the answer; its request waits in its ring until the service reads it, after the subset. The decision follows the rule of the whole frame: each picture is whole and true for the state of the frame, and no program is held by another.

**One generation for each frame.** At the start of a frame, the program reads the generation of the header once (`demand_cache.reader_frame_begin`). The measure and the draw of the frame take an entry only when its generation is at most that value. So a glyph that the service publishes during the frame is used from the next frame, by the measure and the draw together.

**The placed glyph of a character on demand** is `text_shaping.DEMAND_GLYPH_FIRST` plus its code point. Its advance is the advance of the entry at the scale of the spacing. It has no pair: the pairs of the font are pairs of character indexes of the glyph cache.

**The table holds the subset only.** The service publishes no entry for a character outside the ranges, nor for a character that the font cannot draw. The 48 Greek letters take under a quarter of the 1 MiB of words (the host test `the_greek_letters_and_the_refusals` checks the bound). The state `Absent` of the contract is what a reader gives to an entry that its check refuses.

**What a full cache does.** The first layer never evicts. A character that does not fit the entry table or the words is refused: the service counts it in the header, and the program keeps the replacement glyph. A program does not ask for a character again, so a full cache costs no loop of requests. With the subset of today, the cache never fills.

**The log of a program that asks.** The service writes one line for each program, at its first request with a character that is absent or refused, and one line at its first answer that does not fit its ring. It counts the next ones, and writes the totals at the stop of that program. So a program that asks for absent characters with no end does not fill the log of the machine.

**The work of one program in one turn.** The service reads at most `REQUESTS_OF_A_PROGRAM_IN_ONE_TURN` records of one ring in one turn of its loop: the capacity of the ring. Each other ring gets its turn, so one program cannot hold the service from the others. The time that a program costs the service has no other bound; a budget of requests for each program is in [`ROADMAP.md`](../../../ROADMAP.md).

## Eviction, when it is built

An entry is reused only when no program can still draw it. Each program writes, in the head of its request ring, the generation of the frame that it draws (`reader_frame_begin`). The service withdraws an entry at a generation `g`: it writes a code point that is no character of a text in its place, so a search passes it and finds nothing there, then raises the generation. It reuses the words and the place of that entry only when the frame generation of each client is above `g`. A program that draws no new frame holds the reuse; the service then refuses new glyphs, counted, and never tears a glyph that a program draws. A program that stops is removed by the root service (`Client_Remove`) and holds nothing. Eviction makes a cache that fills on demand: it comes with the closure of the channel of the constraint above.

## Determinism and the size of the boot image

- The words of a glyph on demand are the words of the build. The host test `a_glyph_on_demand_is_the_glyph_of_the_build` draws characters of the glyph cache through the on-demand path and compares each word, each box and each advance with the proportional cache that the build writes from the same file.
- The service draws the subset in the order of the code points, so the place and the generation of each entry are the same at each start.
- The boot image gains the outlines of the new characters in the subset, and the module of the font service. It loses nothing: the glyph caches stay. The measure before and after is in [`docs/FONTS.md`](../../../docs/FONTS.md), "13. Glyphs drawn on demand". The gain comes with the next characters and fonts: each one costs its outline, not 2.2 KB of words in each cache.

## The first range: the Greek letters

The first range is the Greek letters of B612, U+0391 to U+03A9 and U+03B1 to U+03C9 (`demand_cache.subset_ranges`), 48 characters: B612 1.008 has no small rho, U+03C1, so a text with ρ draws the replacement glyph there. The modus tool adds them to the subset of B612 Regular, after the characters of the glyph cache, so the glyph cache of the build does not change.

Latin Extended-A was the first wish: B612 1.008 does not have it. Past the Latin-1 Supplement, it has Œ, œ, Š, š, Ÿ, ƒ, Greek, the dashes, the quotation marks, the arrows and mathematical signs. So a range of Latin Extended-A needs another font, or a font that the system adds for it.

## The forms that were refused

- **Every glyph on demand, no glyph cache at build time.** The boot display is drawn before any service runs, and the first frame of the compositor and of the terminal would wait for a service. The 192 characters of each text of the system stay built.
- **A subset that fills at the requests of the programs.** Each program would read in the cache which characters the others asked for, in their order and at their time, across principals. For a fixed subset, the drawing at the start costs under 64 Ki words and closes it.
- **A wait for the glyph in the frame.** A program would be held by the font service, and a font service under a debugger would stop each window. The rule of the whole frame refuses it.
- **A wait of a fixed time for the glyph.** It is a fixed delay: a frame late for nothing when the service is fast, and a box anyway when it is slow.
- **Each program draws its own glyphs.** Each program would read outlines, a hostile input, and hold the code of the renderer and memory for the glyphs. The same glyph would be drawn once in each program.
- **One request ring for all the programs.** One program that fills it stops the requests of each other program. A ring for each program is the rule of the windows of the compositor.
- **An export of the font service, called with `call_isolated`.** The call waits for its answer: the same as a wait in the frame. A call that does not wait needs a call region for each program and a form of call that the support library does not have.
- **The compositor as the broker of the requests.** The compositor cannot be held by a service, and the work of the fonts would enter its turn.
- **A program writes the shared cache.** Each program could change the glyphs that the others draw.
- **The code point as the index of a table.** The code points of Unicode are 1 114 112 places; the characters that a principal uses are a few hundred. A hash table with a bound of probes keeps the table small and the search short.
- **A reader that trusts the fields of the shared cache.** The service writes the cache while a program reads it, and a fault of the service must not make a program read outside the cache. A reader copies each entry and checks it against the constants of the contract.
- **A reuse of an entry with no generations.** A program could read the words of a glyph that the service rewrites for another character: a torn glyph.
- **A line of the log for each request.** A hostile program would fill the log of the machine through the service.
- **Latin Extended-A as the first range.** The interface font does not have it.

## Subtle points

- **The demand cache names its font by the hash of the font file.** A program uses the demand cache with a glyph cache only when the two hashes are equal and the forms agree (`demand_cache.reader_matches`). So a glyph on demand has the baseline and the scale of the glyphs of the cache beside it.
- **The magic comes before the subset.** The service writes the header, the magic last, then draws the subset. A program that reads the cache during that work finds part of the subset; it asks for the rest, and the answers come after the subset.
- **A program asks for a code point once.** It keeps the asked code points (`display.DEMAND_ASKED_LIMIT`). An answer, a refusal or an absent glyph never makes it ask again. A program that asked for more code points than its list holds asks no more, with one line of the log.
- **A full request ring keeps the code points.** They stay wanted, and the next frame sends them. Nothing is dropped.
- **A full control ring.** The root service checks the room of the control ring before it gives a ring to the font service, so no given handle stays unnamed in the table of the service. A `Client_Remove` that does not fit is told on the log, and the root service keeps that place counted as taken, so it never gives more rings than the service has places.
- **The pairs of a character on demand are 0.** The pair table of a glyph cache is keyed by character indexes; a pair of a Greek letter is not in it. A font with pairs past the cache needs its pairs in the demand cache.

## State

Built: the contract `demand_cache` and its host tests; the subset of B612 Regular with the Greek letters; the font service `glyphs`, which draws its whole subset at its start; the root service, which creates the demand cache, starts the service, gives a request ring and the cache to each program that `start` gives a ring to the compositor, and removes a client at its stop; the shaper and `graphics.text_proportional` with a demand cache; the program `interface_font`, which draws the Greek letters through it, with a machine test and a picture.

The font service is not started again after a stop: it is a part of the system, and `start("glyphs")` is refused. After its stop the programs keep their mappings and the entries of the subset, and a new program gets no ring, until the next boot. No machine test stops it.

Left (`ROADMAP.md`): the elements of the interface package and the drawing module with the demand cache; the compositor and the programs started from a disk; the font of the cells and the terminal; the bold weight; eviction; more scripts; a budget of requests for each program.

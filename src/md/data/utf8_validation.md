# The check of a text, sixteen bytes at a time

## Purpose

Each border that takes a text from another party checks it with `text_valid` ([text_encoding.md](text_encoding.md)): a palette table, a store name, a history file, a clipboard paste, a display text, a remote call. The scalar form reads one character at a time with `character_decode`. The vector form checks sixteen bytes in one pass of comparisons with no branch for each character. Measured on the host for the module target (`-o:speed -microarch:x86-64`, a load of 1.7, the least of 5 runs):

| Text | Scalar form | Vector form |
| --- | --- | --- |
| ASCII, 64 bytes | 482 MiB/s | 11 505 MiB/s |
| ASCII, 4 KiB | 482 MiB/s | 17 316 MiB/s |
| ASCII, 1 MiB | 480 MiB/s | 17 742 MiB/s |
| French and CJK, 63 bytes | 591 MiB/s | 3 243 MiB/s |
| French and CJK, 4 KiB | 609 MiB/s | 5 891 MiB/s |
| French and CJK, 1 MiB | 341 MiB/s | 5 949 MiB/s |
| Random bytes, 64 bytes, refused | 4.6 ns | 4.0 ns |

So the vector form is 5 to 17 times faster on mixed text and 24 to 37 times on ASCII. Random bytes are refused at their first bytes by both forms, so their number is the time of one refusal.

The rule does not change: a text is well-formed UTF-8 (RFC 3629) with no control character (U+0000 to U+001F, U+007F, U+0080 to U+009F). The vector form gives the answer of the scalar form for every input.

## Constraints

- **A module is compiled for SSE2 only** ([`docs/SIMD.md`](../../../docs/SIMD.md), "2. One form: SSE2"). SSE2 has no lookup of a byte in a table of 16 (`pshufb` is SSSE3).
- **`text_encoding` is a contract package**: it imports `base:` only, and the kernel compiles it in. The kernel has no vector unit, and the build refuses a vector instruction in the kernel.
- **The bytes can be in memory that another party writes.** Each byte is read once, as `character_decode` reads it.
- **No load outside the slice of the caller.**

## The algorithm

The algorithm is the one of John Keiser and Daniel Lemire, "Validating UTF-8 In Less Than One Instruction Per Byte", Software: Practice and Experience 51(5), 2021 (arXiv:2010.03090), as the library simdutf uses it. In plain words:

1. Load a group of 16 bytes. Make three more groups by a shuffle of constant places over the previous group and this one: the byte one before, two before and three before each byte.
2. If no byte of the group has bit 7 set, the group is ASCII: only a control byte, or a lead at the end of the previous group that waits for more bytes, is an error. Go to the next group.
3. Else, check each byte against the bytes before it:
   - **The count of continuations.** A byte must be a continuation (10xxxxxx) when, and only when, the byte one before is a lead from C0, or the byte two before from E0, or the byte three before from F0. A saturating subtraction puts each of these answers in bit 7 (a byte from C0 minus 40 is 80 or more), and an exclusive or with the bit of a continuation gives a lone continuation, a sequence cut short and a fifth byte, in one pass.
   - **The special cases of two bytes.** The paper finds them with three lookups in tables of 16: the high half of the byte one before, its low half, and the high half of this byte. The three results are sets of error bits, and their intersection is the error. Here the same cases are comparisons: C0, C1 and F5 to FF are no lead; after E0 the byte is A0 or more; after ED, 9F or less; after F0, 90 or more; after F4, 8F or less.
   - **The controls.** A byte from 00 to 1F, 7F, and a byte from 80 to 9F after C2 (U+0080 to U+009F). These are the rule of the system, not of the paper.
4. Keep the leads of the end of the group that wait for bytes past it, for the next group and for the end.
5. Copy the last bytes of the text, fewer than 16, into a group of spaces, and check it as a group. At the end, a lead that waits is an error.

The vector form stops at the first group with an error: a text from another party can be wrong from its first byte, and a test of the mask costs one compare.

## The chosen form

- **One source for every target.** `text_valid_sixteen_bytes_at_a_time` (`src/library/modus/contract/text_encoding/text_valid_sixteen_bytes_at_a_time.odin`) is written with `#simd[16]u8` and the operations of `base:intrinsics`: compares, saturating subtraction, shuffle by constant places, `simd_extract_msbs`. Each one compiles for SSE2, NEON and the SIMD of WebAssembly, so the source names no instruction and no target, and has no `_amd64` suffix. Some take more than one instruction on some units: SSE2 has no unsigned compare of bytes (the compiler writes a saturating subtraction and a compare of equality, or a flip of bit 7 and a signed compare), and NEON has no mask of bit 7 (the compiler writes an and with the weights of the lanes and additions across them). `core:simd` is a package of the core library, which a source of the system does not import; it wraps the same intrinsics.
- **Comparisons in place of the three lookups.** On SSE2 the compiler writes a lookup of 16 entries (`simd_runtime_swizzle`) as 16 loads of one byte. A form with the three lookups was measured on the host, then removed (`-o:speed`, a load of 5.6, two runs, French and CJK text of 1 MiB). For the module target (`-microarch:x86-64`): the lookups 554 to 561 MiB/s, the comparisons 5 726 to 5 818 MiB/s. With SSSE3 (`-microarch:native`): the lookups 8 415 to 8 435 MiB/s, the comparisons 7 943 to 8 126 MiB/s; on 63 bytes and on 4 KiB the lookups were 4 to 7 % faster too. So the system keeps one vector form, the one with comparisons.
- **The scalar form stays.** `text_valid_byte_by_byte` is the reference of the host tests and the code of `invalid_sequence_find`, which gives a place. `text_valid` calls the vector form.
- **Groups of 16 bytes.** A group of 32 bytes was not measured: a text of a contract is often shorter than 64 bytes, and a group of 32 doubles the copy of the last bytes.

## Refused forms

- **The library simdutf.** It is C++, and it holds conversions between UTF-8, UTF-16 and UTF-32, Latin-1 and base64 that the system does not need. The system takes the algorithm, not the code.
- **A state machine with a table of the bytes (DFA).** One load and one step for each byte: faster than `character_decode`, still one byte at a time.
- **The three lookups with SSSE3 and a test of the processor.** A contract package imports no support package, so it cannot read `instruction_sets`; and where SSSE3 exists the lookups were 4 to 7 % faster (see "Comparisons in place of the three lookups"), less than the cost of a second vector form to test.
- **A test of the mask only at the end of the text.** It saves one compare for each group of a valid text and checks the whole of a long invalid text.

## Subtle points

- Only bit 7 of each lane of an error group has a meaning. A comparison gives FF; a saturating subtraction gives a byte whose bit 7 is the answer and whose other bits are not 0. The mask of bit 7 reads all of them.
- The compare of the second byte is signed (one SSE2 instruction): as a signed byte, 80 to 9F are below A0. It is right only for a continuation; a byte after a lead that is no continuation is a count error already.
- The group of the end is filled with spaces: a space is a character of a text, it completes no sequence, and a lead cut short before it is a count error.
- The kernel replaces invalid sequences with `invalid_sequences_replace`, which keeps the scalar form: it needs each place, and the kernel has no vector unit.

## Source and license

Keiser and Lemire publish the algorithm in the paper; simdutf is under Apache-2.0 or MIT. The system has no line of simdutf. A design is not a reused work, so the algorithm is not a row of the reuse list ([../infrastructure/reuse_list.md](../infrastructure/reuse_list.md)).

## State

Built: the vector form, `text_valid` on it, the host tests (each length around a group, each sequence at each place, slices that start at each place of a group, each window of three bytes across a group boundary, one in 251 by default and all 2^24 with `-define:EXHAUSTIVE=true`, the leads of four bytes at the end of a group, a lead cut before groups of ASCII, 400 000 random texts against the scalar form) and the measure `text_valid_speed_of_each_form` with `-define:MEASURE=true`; the fuzz target `text_encoding` compares the two forms.

Left: `invalid_sequence_find` reads the whole text with the scalar form. The vector form can find the first group with an error, and the scalar form then finds the place in it. `display_text_valid` checks with the vector form, then reads each character with `character_decode` to find a hidden character.

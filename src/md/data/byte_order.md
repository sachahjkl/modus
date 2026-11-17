# The byte order and the checksum of the Internet

Formats of the network, of the TPM and of the files of the system hold numbers in a fixed byte order. The package `src/library/contract/byte_order` is the one place that reads and writes them, and the one place of the checksum of RFC 1071. What the network does with it is in [`docs/NETWORK.md`](../../../docs/NETWORK.md), "One place for the byte order and the checksum".

## Constraints

- Each copy of a shift is a place for a fault of a shift. Before this package, eleven copies had two signatures, and the checksum had two forms that a reader had to compare.
- The kernel, the contract packages, the support packages, the programs and the boot program must all reach it. The import rule of the tool lets each folder import a contract package, and a contract package imports no support package ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The imports of the sources of the system").

## The chosen form

- A contract package, for the import rule alone: it has no party. Its folder changes with the layout of the library, not its form.
- Each procedure takes a slice and the offset of the first byte. A slice too short stops the program on the check of the bounds of the slice, so each caller checks its lengths first.
- The checksum sum does not fold: a caller adds the parts (the pseudo-header, the header, the data) in 64 bits and folds once in `internet_checksum_end`. Each part but the last has an even count of bytes. Folding early or once gives the same 16 bits, so the two old forms are one.
- The little-endian procedures serve the history file, the files of the principals, the disk grant table, the manual pages and the event log of the boot program.

## Refused forms

- **The types `u16be` and `u32le` of the language.** A cast of a pointer into a slice reads past its bounds with no check, and an unaligned field of a record of bytes needs the cast.
- **A package of `support`.** A contract package and the kernel could not import it, so the copies in `contract` stayed.
- **A sum that folds at each call.** It needs a second signature for the parts, which was one of the two forms.

## State

Built: the package, its host tests, and its callers in the network, the TPM, the boot program, the line editor, the principals, the disk program and the manual pages. Left: `src/library/support/vector_font` and `src/kernel/iommu` keep their own reads.

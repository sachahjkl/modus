type: Added

**The byte layout of each record of the module file**: the guide of the module contract shows the header, the table directory and one record of each table as a diagram in rows of 8 bytes, with each field as a rectangle over its bytes, its type and its comment under the pointer. The tool takes the offsets and the sizes from the compiler and the types from the source, writes the same layouts as text in the guide, and `modustool check` fails when that text differs from the code.

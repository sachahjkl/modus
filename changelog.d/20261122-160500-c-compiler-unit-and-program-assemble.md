type: Added

**Multi-unit C compilation and program-tier assembly in system modules.** `c_compiler.compile_unit` compiles named translation units with caller-supplied headers and export lists into an on-demand arena, and `assemble` / `assemble.assemble_program` dynamically scale up to the program tier (512 KiB code, 16,384 labels, 4 MiB text) and return the BLAKE3 hash of the built module.

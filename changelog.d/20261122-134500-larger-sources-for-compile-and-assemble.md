type: Changed

**Larger sources for compile and assemble**: `compile` takes a C source of up to 256 KiB and `assemble` a text of up to 256 KiB, in place of 64 KiB each. A text that `assemble` takes now holds up to 128 KiB of code, 128 KiB of data, 2048 labels and 4096 references, in place of 64 KiB, 64 KiB, 512 and 2048.

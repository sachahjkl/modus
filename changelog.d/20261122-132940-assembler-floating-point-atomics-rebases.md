type: Added

**The assembler takes floating point, atomics and tables of addresses**: `assemble` now takes the scalar SSE2 instructions (`movss`, `movsd`, `movq`, `addsd`, `ucomisd`, `cvtsi2sd`, `cvttsd2si` and the others) on `%xmm0` to `%xmm15`, `xchg` and `lock cmpxchg`, numeric local labels (`1:`, `1f`, `1b`), and `quad label + offset` in the data, which the module rebases at its load.
So `compile` turns C with `float`, `double`, `alloca`, the atomic builtins and global tables of functions or of strings into a module that runs; a floating constant and `long double` are still refused.

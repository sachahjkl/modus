type: Added

**The C compiler takes floating constants**: `compile` now reads decimal, scientific and hexadecimal floating constants (`3.141592653589793`, `.5`, `2.5E+10`, `0x1.8p+1`, `1.5f`) and gives each the nearest `double` or `float`, so a C source with a constant of floating point is no longer refused.

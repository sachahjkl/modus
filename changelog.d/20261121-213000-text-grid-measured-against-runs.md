type: Added

**Text grid benchmark against text runs.** `interface` now includes a pixel-for-pixel verification and opt-in `-define:MEASURE=true` benchmark comparing `Text_Grid` against equivalent `Text` and `Rectangle` runs across 104 by 32 terminal frames and a full 1 920 by 1 080 terminal (240 by 67 cells). In the 104 by 32 worst case (one color and fill per cell), runs require 6 656 records (past the 4 096-record bound) and 322 816 bytes against 1 record and 53 296 bytes for `Text_Grid`, so `Text_Grid` stays its own draw record kind.

type: Added

**The console writes a character from its code point**: `character(233)` gives the text of é, two bytes of UTF-8, so a line of ASCII can build a text of another language before the keys type it. A control character, a surrogate and a number past 1114111 are refused.

type: Added

**Language-neutral module ABI and hardened ELF converter**: the build tool now converts freestanding System V AMD64 relocatable ELF objects (`ET_REL`) paired with a plain-text `Module_Manifest` directly into validated modus module files without Odin AST scraping or dynamic linking, and hardens ELF header, string table, symbol, and relocation checks across both object and linked converters.

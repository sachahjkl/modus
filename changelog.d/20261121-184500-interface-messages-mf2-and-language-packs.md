type: Added

**Interface messages contract, MessageFormat 2 evaluator, and MODLANG1 binary language packs**: added the freestanding `interface_messages` contract package with canonical BCP 47 language preference lists (at most 8 tags) and RFC 4647 Lookup resolution, a zero-allocation W3C MessageFormat 2 parser and evaluator supporting `.input`, `.local`, `.match` selectors with CLDR cardinal plural rules and `:integer`/`:number`/`:string` functions, and the BLAKE3-verified `MODLANG1` binary language pack format with O(log N) sorted lookup and adversarial host tests.

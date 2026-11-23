type: Changed

**The index of the glossary under the size bound of a page**: the glossary index lists each term as a compact row with its name, group and link to its entry on its group page, without repeating short definitions in the page body or in the JSON-LD page graph. Each `#term-<name>` anchor still lands on its row without JavaScript and redirects to the group entry with `glossary.js`, keeping the index well under half the 1 000 000-byte page bound even as the glossary doubles.

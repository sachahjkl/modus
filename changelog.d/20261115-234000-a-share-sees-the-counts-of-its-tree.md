type: Security

**A share of a tree sees the counts of its own tree only.** `storage.usage()` through a share of a tree gave the counts of the whole store, so its holder could learn whether the rest of the store holds the bytes of an object of its tree, or whether the maker wrote bytes that it guessed. It now gives the objects, the trees, the versions and the blocks of that tree only, from a walk of at most 4096 reads; a larger tree gives `USAGE_NOT_COUNTED`. A root that the storage service finds damaged now leaves the hash index, so a rewrite of the damaged object can share its blocks again.

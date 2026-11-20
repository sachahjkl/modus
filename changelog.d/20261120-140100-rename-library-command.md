type: Added

**The rename of the library as a command.** `modustool rename-library` moves the folders of the source library into its two source libraries with `git mv`, rewrites the import lines, the comments and the documents, and names each string of a source that still holds an old form. A second run changes nothing, so each branch runs it after its merge of `master`, and the rename waits for no branch.

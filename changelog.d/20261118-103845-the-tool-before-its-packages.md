type: Fixed

**The tool checks itself as packages**: a change of a package of the tool that the tool imports now builds each module again, a change of a source in any folder under the tool gives the fuzzing of `modustool check` another seed, git no longer ignores a folder named `build` below the root, and `modustool check` refuses a code span of a guide that names a file of the tool that does not exist.

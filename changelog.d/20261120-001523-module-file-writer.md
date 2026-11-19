type: Added

**The module file writer.** The contract package `modus:contract/module_file_writer` writes a module file from its parts into memory that the caller gives, and refuses a part that a loader or a reader would refuse with a record that names the part; the tool writes each module through it with the same bytes as before, and a program of modus can write a module with the same code.

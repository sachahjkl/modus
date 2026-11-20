type: Fixed

**A long command survives a new build of the tool.** A command such as `modustool screenshots` starts the tool again for each step of a module, and it named the file `build/tool/modustool`; when another command compiled the tool again while it ran, every module step failed with "cannot start …/build/tool/modustool (deleted)". Each step now runs the binary of its command, whatever happens to that file.

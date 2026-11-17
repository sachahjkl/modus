type: Added

**A machine case for each refused ring word.** The machine test now sends `None`, the word one past the last command and the largest word to the block service and to the network service, which answer each one with `Bad_Command` and the record `Unsupported` and serve the next command, and to the compositor on the ring of a window and to a terminal, which each write one line at the first word and the count 3 at the end. The new test program `hostile_terminal` writes the words to its terminal.

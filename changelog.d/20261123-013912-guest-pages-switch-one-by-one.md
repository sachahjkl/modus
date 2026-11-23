type: Changed

**Guest memory that switches page by page.** Each page of a guest mapping made with `Write`, `Execute` and `No_Access` is writable or executable, never both, and the kernel switches the one page that a nested page fault asks for, with no exit to the process, which no longer switches the mapping itself. An instruction that writes the page that holds it ends the run with the new exit `Writes_Own_Page` and the address that it writes, and the machine of a Linux guest does that one write. The kernel writes the count of switches of a guest in the log when the guest ends.

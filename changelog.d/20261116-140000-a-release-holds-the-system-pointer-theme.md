type: Changed

**A release image holds the pointer theme of the system only.** `modustool release image` builds its boot image with the MIT pointer theme of the system, and refuses to package a boot image that holds the Posy theme, by its resource name or by the CC-BY-NC-4.0 license in the header of any pointer theme file. The release workflow and the checks of the flake no longer fetch the Posy theme; the default development shell keeps it.

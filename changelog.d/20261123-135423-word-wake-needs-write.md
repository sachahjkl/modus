type: Security

**A wake needs Write on its word.** `Word_Wake` now refuses, with `Bad_Address`, a word that the process can read and not write, and its error record says that the process can read it (`found` 1). Before, a process that maps a page read-only, such as the date page, the settings page or an end page of a wiring, could wake each thread of another process that waits on a word of that page: a signal between two processes that share no right to write. A wait still needs Read only.

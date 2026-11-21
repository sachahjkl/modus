type: Added

**The clipboard, the search and any object in the editor `edit`**: the clipboard carries multi-line UTF-8 text (LF line ends and tabs) and Control+X cut while single-line fields keep refusing line ends; `edit` adds Ctrl+A, Ctrl+C, Ctrl+X, Ctrl+V, incremental Ctrl+F search with match highlights and wrap-around navigation, and `edit(store, name)` in the console to edit any text object of a store of the principal.

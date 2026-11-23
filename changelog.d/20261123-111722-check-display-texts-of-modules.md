type: Added

**A check of the display texts of the modules.** `modustool check` and `modustool rule-checks` now run `display_text_check`, which inspects module `member_texts`, setting descriptions and labels, window problem sentences, action bar items, buttons, and context menu items and refuses forbidden words from `docs/WRITING.md`, contractions, "Error" or "Failure" titles, "failed" alone, wrong sentence case, and wrong end periods.

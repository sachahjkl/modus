type: Added

**The language list in settings.** A principal orders the languages that it reads with `settings.set_languages`, a table of `language_tag.Locale` records, or with the row "languages" of the window of `settings`, and `settings.languages()` gives the list with the canonical tag of each; each tag is read once into a typed record, its case and its deprecated language made canonical (`iw` is `he`), and a damaged list on the page or in the store is refused whole.

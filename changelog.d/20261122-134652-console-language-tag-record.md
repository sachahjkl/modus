type: Added

**The console reads a language tag into its record**: `language("fr-CA")` gives the `Locale` record of a BCP 47 tag in its canonical form, which `settings.set_languages([language("fr-CA"), language("en")])` takes, and `language()` gives the first language of the principal. A refused tag names the byte of the subtag at fault and the reason.

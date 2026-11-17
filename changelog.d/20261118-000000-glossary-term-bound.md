type: Changed

**The bound of a glossary term in the check.** `modustool check` and `modustool site` refuse a term of the glossary whose explanation has more than 100 words, as they refuse a term with no short definition: the fault names the term, its file, its line and its count of words. The count takes the words between the short definition and the line "Do not use", so a term stays a definition and its guide holds the detail. Ten terms that passed the bound are shorter now.

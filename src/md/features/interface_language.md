# The interface in the language of the principal

## Purpose

Each text that a principal reads comes from the code of a module today, in English. A principal who reads French, Arabic or Japanese reads English, a date in the form of one country, and a list sorted by bytes.

This design gives the interface of the system the form of the world: each language, each script, each direction, each convention of numbers, dates and order. It takes each part from a standard of the world: Unicode, CLDR, BCP 47 and Unicode MessageFormat. It invents nothing that one of them defines.

The first build is a subset: English and French, the Latin script, left to right, and no input method. Each part that waits says why the interfaces of the subset already take it with no change of a contract.

The guide of the subject does not exist yet. The parts that this design changes are in [text_rendering.md](text_rendering.md), [glyphs_on_demand.md](glyphs_on_demand.md), [keyboard_layout.md](keyboard_layout.md), [time_zone.md](time_zone.md), [log_facts.md](log_facts.md), [enum_parameters.md](enum_parameters.md), "The display text of a member", and [../data/text_encoding.md](../data/text_encoding.md).

**The term.** An interface message is a text of the interface with typed variables, in the form of Unicode MessageFormat 2.0. This file says "interface message" for it, and "a message of MF2" for the unit of the standard. The word "message" alone names other things in the system: a message of TLS, the message that a signature covers, a message interrupt.

## Constraints

- **No text between processes** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes"). A language tag and an interface message cross a border as typed records. No process parses the text of an interface message or of a tag that another wrote.
- **Module metadata is flat tables** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "12. Module metadata in flat tables, read through functions"). The interface messages of a module are tables of its module file.
- **A module and a data object are named by their hash** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system"). A translation is a data object; it must not change the hash of a module.
- **No shared state tells a process what another does** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", row 17). A table that each process maps holds the same bytes for each process.
- **One general mechanism, and a plain expression for each frequent task** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task"). One mechanism serves a window, a log fact, an error sentence and the display text of a member: the interface message.
- **Reuse proven software where it fits** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Objective", rule 2), and **the code of the system writes its drawing from nothing** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "18. One 2D interface: the draw table").
- **A text from another party is hostile input.** A translation comes from a party that did not write the module. Its bytes are checked at a border before a reader uses them ([../data/text_encoding.md](../data/text_encoding.md)).
- **Code stays English.** A name of a module, an export, a field, a member and a keyword of Lex is an identifier with one form on every machine ([../data/text_encoding.md](../data/text_encoding.md), "What stays ASCII, and why").
- **No work in a frame in proportion to the data.** A text is rendered when its data or the language changes, and kept.

## The standards

The tool reads each standard from a pinned release, which is a recipe input ([recipes.md](recipes.md)). A new release is a change of the pin, never a change of a contract.

| Concern | Standard | The pin of today |
|---|---|---|
| The identity of a language | BCP 47: RFC 5646 (tags), RFC 4647 (matching), RFC 6067 (the extension `u`) | the language subtag registry in the validity data of CLDR 49 |
| Locales and their data | UTS #35, "Unicode Common Locale Data & Rules (CLDR)", parts 1 to 7 | CLDR 49 |
| Interface messages | UTS #35 part 9, MessageFormat (Unicode MessageFormat 2.0) | LDML 49 |
| A file of interface messages | The message resource of the W3C Internationalization WG, a draft | the draft of 2026-10-07 |
| Characters and their properties | The Unicode Standard and its character database | Unicode 18.0 |
| Normalisation | UAX #15, Unicode Normalization Forms | Unicode 18.0 |
| Segmentation | UAX #29, Unicode Text Segmentation | Unicode 18.0 |
| Line breaks | UAX #14, Unicode Line Breaking Algorithm | Unicode 18.0 |
| Direction | UAX #9, Unicode Bidirectional Algorithm | Unicode 18.0 |
| Width in a grid | UAX #11, East Asian Width | Unicode 18.0 |
| Script of a character | UAX #24, Unicode Script Property | Unicode 18.0 |
| Case | The Unicode Standard, section 3.13, "Default Case Algorithms" | Unicode 18.0 |
| Order | UTS #10, Unicode Collation Algorithm, and UTS #35 part 5, Collation | Unicode 18.0, CLDR 49 |
| Identifiers | UAX #31, Unicode Identifiers and Syntax | Unicode 18.0 |
| Security of a text | UTS #39, Unicode Security Mechanisms | Unicode 18.0 |
| Keyboards | UTS #35 part 7, Keyboards (the format "keyboard3") | CLDR 49 |
| Shaping | OpenType (ISO/IEC 14496-22), through HarfBuzz | a pinned commit |

## The chosen form

### 1. The identity of a language

**A language tag is a tag of BCP 47.** The principal writes `fr`, `fr-CA` or `ar-EG-u-nu-latn`. The syntax is RFC 5646, section 2.1, "Syntax", and the extension `u` is UTS #35 part 1, "Unicode BCP 47 U Extension". The canonical form is the canonical Unicode locale identifier of UTS #35 part 1: the case of each subtag, the aliases (`iw` is `he`), the order of the keywords.

**A locale is a record, not a text.** A tag crosses a border as the record `locale.Locale` of a new contract package, 48 bytes:

| Field | Bytes | Content |
|---|---|---|
| `language` | 8 | the language subtag in lower case ASCII, 2 to 8 letters, then zeros |
| `script` | 4 | the script subtag (`Latn`), or zeros |
| `region` | 4 | two letters or three digits, then zeros |
| `variants` | 16 | at most two variant subtags of 8 bytes |
| `calendar` | 1 | the enum of the keyword `ca` |
| `numbering_system` | 1 | the enum of the keyword `nu` |
| `first_day` | 1 | the enum of the keyword `fw` |
| `hour_cycle` | 1 | the enum of the keyword `hc` |
| `measurement_system` | 1 | the enum of the keyword `ms` |
| `collation` | 1 | the enum of the keyword `co` |
| `region_override` | 6 | the value of the keyword `rg`, or zeros |
| reserved | 4 | zero |

- **All zeros is the root locale**, `und`: no language, the defaults of CLDR. So a page and a record keep ZII.
- **A keyword is an enum.** The values of `ca`, `nu`, `fw`, `hc`, `ms` and `co` are closed sets that the pinned CLDR lists (its file `bcp47/*.xml`). Each is an enum with explicit values, 0 for absent, and a member for each value: `hour_cycle` has `h11`, `h12`, `h23` and `h24`. A new CLDR adds members at the end, so no value moves. The rule of the project holds: a word becomes its enum at one border, which refuses a word that names no member.
- **A subtag is not an enum.** The registry of languages, scripts and regions has thousands of entries and changes each year. It is a registry of names, as a module name is. The border checks it against the validity data of the pinned CLDR.
- **One border.** `locale.tag_read(text)` gives a record or an error record; `locale.tag_write(record, buffer)` gives the canonical text. The console, the export of `settings` and the tool call them. They are pure procedures of a contract package, so a reader of a record compiles them in.
- **What the record refuses:** a private use subtag (`-x-`), the extension `t` (RFC 6497), an extension other than `u`, a keyword of `u` outside the six and `rg`, a third variant, a duplicate keyword. Each refusal is an error record at its place in the text.

**The language list.** The principal orders the languages that it reads: `fr-CA`, then `fr`, then `en`. It is one setting, `languages`, on the settings page: at most 8 records of `locale.Locale` and their count. A principal who reads more than 8 languages is rare, and each more language is 48 more bytes of the settings page. An empty list is the source language of each interface message, English. The process `settings` is its one writer, as for each other setting ([`docs/FONTS.md`](../../../docs/FONTS.md), "7. The setting").

- The window of `settings` has a row "languages": the list in its order, a button to move a language up, a button to remove it, and the languages whose language pack the machine holds, to add. Each language shows its name in its own language and in the first language of the list, from the locale data ("4. Locale data").
- The console: `settings.set_languages([language("fr-CA"), language("en")])` and `settings.languages()`. `language(text)` is a built-in of the console that reads a tag at the check of the line and gives a `Locale` record: the console is the border of the text of the principal. `language()` with no argument gives the first language of the list.
- The palette: the languages whose pack the machine holds, as entries of a form, since the list is not one member of a closed set.

**The match: RFC 4647 Lookup, for each interface message.** The chain of an interface message is, for each tag of the language list in its order, the tag and then its parents; then the source language. The parent of a tag is its parent locale in CLDR where CLDR names one (`es-MX`, then `es-419`, then `es`), else the tag with its last subtag removed, as RFC 4647, section 3.4, "Lookup", does. UTS #35 part 1, "Locale Inheritance and Matching", defines that chain. The first language of the chain that holds a valid translation gives it. So a pack that lacks one interface message, or holds a stale one, costs that interface message only: it falls back alone.

**An interface message is formatted in the locale of its language.** An interface message that comes from English is written with the numbers and the plural rules of English, so one sentence has one convention. The keywords of the first tag of the list (an hour cycle, a first day) apply to each interface message: they are the choices of the principal, not of a language.

**The time zone stays the setting `time_zone`.** It is a fixed offset ([time_zone.md](time_zone.md)), and the keyword `tz` of the extension `u` names a zone of the tz database, which the system does not hold: the record has no `tz`. The locale gives the forms: the localized GMT format of UTS #35 part 4 ("UTC+08:00", "UTC+8"), the patterns of a date and of a time, and the hour cycle. When a later form brings named zones, `tz` becomes a field of the reserved bytes, and the setting of the zone stays the one source of the offset.

### 2. Interface messages

**Unicode MessageFormat 2.0, in the model of Fluent.** The owner asked for Fluent. MessageFormat 2.0 (MF2) grew out of Fluent and ICU MessageFormat, with the authors of Fluent in its working group, and it is now the standard:

- It is UTS #35 part 9, Stable since CLDR 47 (2025-03), with a stability policy that is normative: a valid message of MF2 stays valid, and its meaning stays. LDML 49 has `:string`, `:number`, `:integer`, `:percent` and `:currency` Stable; `:unit`, `:date`, `:time` and `:datetime` are Draft.
- It keeps what Fluent gave: a message of MF2 is a pattern or a matcher, a translation has its own selectors (asymmetric localisation), and a message of MF2 has a fallback when a value fails.
- Its functions are defined over the data of CLDR, which this design imports anyway: the plural categories, the forms of numbers and dates. One family of standards gives the data and the interface messages.
- Its data model represents a message of Fluent: a tool converts `.ftl` to MF2. A translation that exists in Fluent is not lost.

What Fluent has and MF2 lacks, and the answer here:

- **A file of messages: the pinned draft of the W3C.** Fluent defines `.ftl`; MF2 defines one message. The W3C Internationalization WG incubates the message resource (`.mf2`): `@locale`, then `identifier = message`, sections and properties. The tool reads the draft of 2026-10-07, pinned as each other standard, and the build of layer 2 does not wait for the standard. Its syntax is small, and a change of the draft is a change of the reader of the tool only: the compiled tables do not move.
- **A term** (`-brand-name`) **and a reference to another message.** The texts that an interface message inserts here are the display texts of members ("The display text of a member is an interface message", below), through one function of the namespace `modus:`, which MF2 allows ("Function" in part 9).

**What an interface message is.** An interface message has:

- an **identifier**: a member of the enum `Interface_Message` of its package, `disk_full`;
- **variables**: the fields of one record type of the source, as a log fact has. An interface message with no variable has no record;
- a **pattern** in its source language, English: text and placeholders `{$free}`;
- **selectors**, when the words change with a value: the plural category of a number (`:number select=plural`, the default, or `select=ordinal`), an exact number, the member of an enum field (a gender, a kind). Each translation has its own selectors.

An example, English:

```
@locale en
---
disk_full =
  .input {$free :integer}
  .match $free
  0   {{The disk is full.}}
  one {{The disk has {$free} free block.}}
  *   {{The disk has {$free} free blocks.}}
```

French has the same identifier, and its own variants: French puts 0 in `one` (UTS #35 part 3, "Language Plural Rules"), so it needs no variant `0`.

**The source of the interface messages.** Each package with interface messages has one message resource of its source language, `messages/en.mf2`, beside its source. A support package has its own: `interface` and `sentence` are compiled into many modules, and their interface messages are translated once.

**The enum and the record.** The package declares an enum `Interface_Message` with one member for each interface message, and pairs each interface message that has variables with its record type in an attribute, as `enum_getters` pairs a parameter with its getter ([enum_parameters.md](enum_parameters.md)):

```odin
@(interface_message_variables = "disk_full = Disk_Full")
Interface_Message :: enum u16 {
	None,
	disk_full,
	disk_lost,
}

Disk_Full :: struct {
	free: u64,
}

interface_message.write(.disk_full, Disk_Full{free = blocks}, &line)
```

- `interface_message.write(member: $E, values: $T, out)` is polymorphic, so the compiler checks the enum and the record at each call. The tool checks the rest before the compile, from the syntax tree, as for a log fact: the record of a call is the one that the attribute pairs with its member.
- A member names an interface message; an interface message has a member. A member with no message in `en.mf2`, a message with no member, a variable that names no field, and a field that no variant of the source uses, fail the build.
- A field has a kind, from `modus:contract/value_kinds` ([console_value_colors.md](console_value_colors.md)). The tool refuses a function that the kind does not take: `:number` on a Text, a selector on a hash.

**The interface message key.** A row of a translation names its interface message by its interface message key: SipHash-2-4, with the key of the fact keys ([log_facts.md](log_facts.md), "The fact key: why the typeid"), over `<package>.<identifier>` in UTF-8. A name, not a value of the enum, so a new member never moves a translation. The code finds a row by the typeid of the enum and the value of the member: the table `Interface_Messages` of the module maps both to the interface message key.

**The source hash.** Each interface message has a source hash: BLAKE3 of the compiled form of its source, 16 bytes. A translation names the source hash that it translates. When the source changes, a translation of the old source no longer matches and falls back alone. A translation is bound to one interface message, not to a module: a module changes its hash at each change of its code, and its translations stay valid while its English stays.

**The build compiles; no process parses.** The tool reads each `.mf2` file, checks each message against part 9 (its syntax, its data model errors: a duplicate declaration, a variant key mismatch, a missing fallback variant), and writes two tables of the module file:

| Table | A row |
|---|---|
| `Interface_Messages` | the interface message key, the typeid of its enum, the value of its member, the index of its record description in `Records`, the source hash, the place of its compiled form |
| `Interface_Message_Parts` | one part of a compiled form: a declaration (a field, a function, its options as enums and integers), a selector, a variant with its keys, a text run (an offset and a count in the string table), a placeholder (a declaration) |

A key of a variant is typed at the build: a plural category is an enum (`zero`, `one`, `two`, `few`, `many`, `other`), an exact number is an integer, a member is its value. So the render compares integers. The text reaches a process as text runs only, and no process reads a brace.

**The render: one pure procedure.** `interface_message.render(form, values, record, locale_data, out)` in the contract package `interface_message` selects the variant (part 9, "Pattern Selection"), formats each placeholder, and writes the text and one value run for each placeholder, as the render of a log fact does. The console, the window `log`, a window and the tool call it, so two readers never write two sentences for one interface message.

- A placeholder with no function writes its field by its kind, as a fact template does today: an Integer in decimal digits with no group separator, a hash in hexadecimal. It is an identifier, and a group separator in a block number is a fault.
- `:number` and `:integer` write the number in the convention of the locale: its digits, its group separator, its decimal separator.
- `modus:member` writes the display text of an enum field, in the language of the interface message.
- A function or an option that the tool does not take fails the build. A Draft function of part 9 is taken only after the pin of LDML reaches its form, so the tool refuses `:date` today; a date is a field of the kind Time, written by its kind.
- A refused render (a count of values that is not the size of the record, a part out of its bounds) writes the fallback of part 9, "Formatting Fallback Values": `{$free}`, never a part of a sentence.

**A log fact is an interface message.** The fact template leaves the attribute: `@(log_fact)` marks the fact type, and the fact type has one interface message, of the identifier of the type, in the message resource of its package. The row of `Facts` names its interface message key in place of its template. A reader renders a fact in its own language: it finds the module file of the writer by its hash, as today, takes the interface message of the fact, and the translation from the packs that it maps. The tool and the machine tests render the source language, English, so each wait of a test keeps its sentence. The template language of today (no condition, no plural) becomes the subset of MF2 that this design takes: a template of today is a valid message of MF2 with no selector.

**The display text of a member is an interface message.** The display text of `scale_factor.Scale.fourteen_eighths` is the interface message `Scale.fourteen_eighths` of the package that declares the enum, with no variable: "1.75". The table of display texts "by member and language" ([enum_parameters.md](enum_parameters.md), "The display text of a member") holds the source language in the module file; each other language is a row of a language pack. The language of a row is a `locale.Locale` record. The name of the member stays the code: a line types `.fourteen_eighths` on every machine.

**Direction inside an interface message.** A placeholder of another direction than its sentence (a Latin name in an Arabic sentence) needs the isolates of UAX #9. Part 9, "Handling Bidirectional Text", gives the default strategy: the render puts FSI and PDI around a placeholder whose direction differs. The render writes them only when the locale of the interface message is right to left, so the subset writes none, and a text of today keeps its bytes.

### 3. Language packs

**A language pack is a data object.** It holds the translations of one language for many packages, and the locale data of that language. It has no code. It is named by the BLAKE3 hash of its bytes, as a module is ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system").

| Part | Content |
|---|---|
| Header | the format version, the `locale.Locale` of the pack, the pins of CLDR, LDML and Unicode, the counts and places of the other parts |
| Translations | one row for each interface message, sorted by interface message key: the key, the source hash that it translates, the place of its compiled form |
| Compiled forms | the parts of each translation, in the form of `Interface_Message_Parts` |
| Strings | the text runs |
| Locale data | the tables of CLDR for this locale ("4. Locale data") |

- **A pack of a region holds the differences.** `fr-CA` holds what CLDR and its translators give for `fr-CA` only; its parent `fr` holds the rest. The match walks the chain of parents, so a reader maps both.
- **The source language has a pack too.** The English interface messages are in the module files; the pack `en` holds the locale data of English and no translation. One format serves each language.
- **Signed.** A pack of the boot image is listed by its hash in the signed system description, as each resource of the image. A pack from the cache is the output of a recipe, with the signed realisation of its publisher, which the substitution policy of the plan trusts ([recipes.md](recipes.md)).
- **Named in the plan.** The plan of a principal names the packs of its languages by their hash. The cache gives a pack by its hash, as it gives a module. A machine holds only the packs that a kept plan or the signed system names, so it holds only the languages of its principals.

**The check at the border.** A pack is hostile input until its check passes. `language_pack.validate`, a pure procedure of a contract package, checks the whole pack:

- the header, the counts, each offset and each count within the bytes of the pack, after a copy ([../README.md](../README.md), subtle point 5);
- the rows sorted by interface message key, with no repeat;
- each compiled form within its bounds: its count of parts, its depth, its count of variants, its bytes;
- each text run: UTF-8 with no control character ([../data/text_encoding.md](../data/text_encoding.md)), in the normalisation form NFC, and the rule of a display text, `text_encoding.display_text_valid`, which the display text of a member adds: no hidden character (a default ignorable code point) and no character of direction (the embeddings, the overrides, the isolates and the marks of UAX #9). A pack of a right to left language takes balanced isolates in a later layer: the rule then takes more, and refuses nothing that it took;
- the locale data: each table in its bounds, each plural rule in its compiled form.

The service that takes a pack into the machine (`plans.apply`, and the tool for the image) runs the check once, and refuses the whole pack on a fault: no pack is taken in part. Each reader checks the header once at its start, and each part of a translation at its render, as the render of a log fact checks each fact. The bytes are mapped read-only from an object whose hash the root service checked, so the check of a reader is cheap and finds a fault of the code, not of the bytes.

**The root service maps the packs at the start of a process.** It maps the packs of the session of the principal, read-only, at the fixed range `Language_Packs`, in each process that maps the settings page: each process with a surface, each terminal, the compositor and the console. A directory page at the start of the range lists each pack: its hash, its `Locale` and its place. The root service maps the whole pack, not the rows of one module:

- a translation of a support package serves each module that compiles it in, so the rows of a module are not one span;
- the pack is the same bytes for each process, so the map tells no process what another does;
- the pages are shared: the second process pays its page tables only.

Refused: a map of the rows of each module, page by page. The rows of `interface` are in each window, so the sections repeat, and each section pays up to a page of padding: about 240 KiB for 60 modules, for no secret.

**A change of the language at run time is at once.** The principal moves `fr` before `en`. The process `settings` writes the list on the settings page; the compositor sends `Settings_Changed` to each window, as for each setting. Each window renders its texts again from the packs that it maps, and draws once. A text is rendered at that change, not in each frame. A change among the packs that a process maps needs no map.

**A new pack reaches a process at its next start.** A pack that a plan adds is mapped into each process that starts after the apply. A process that runs keeps its map: its texts fall back along the chain until it starts again. The window of `settings` marks a language whose pack came after the start of the windows.

Refused: a map of a new pack into each process that runs, at the apply of a plan. The root service then writes into the address space of each process of a session at a moment that the process does not choose, and each process reads its directory page while it changes. A start is the one moment when a process gets its ranges.

### 4. Locale data

**What the system takes from CLDR.**

| Data | UTS #35 | Its use |
|---|---|---|
| Plural rules and ordinals | part 3, "Language Plural Rules" | the selectors of an interface message |
| Number symbols and patterns | part 3, Numbers | `:number`, `:integer`, `:percent`, a size, a measure |
| Date and time patterns, names of months and days, the hour cycle by region, the first day of the week | part 4, Dates | the bar, a date of a store, a log |
| The localized GMT format | part 4, "Time Zone Names" | the offset of the setting `time_zone` |
| Units | part 2, General | the sizes and the times of `value_kinds` |
| List patterns | part 2, General | "a, b and c" |
| Names of languages, scripts and regions | part 2, General | the row of the languages; the name of a language in its own language |
| Parent locales, likely subtags, validity | part 1, Core, and part 6, Supplemental | the match; the check of a tag |
| Collation: the root order and the tailorings | part 5, Collation | `sort` and the search of the console |
| The character order of a locale | the layout data of CLDR | the direction of the interface |

The time zone names of CLDR, the currencies, the person names (part 8) and the number spellout are not taken: the system shows none of them. A need adds a table, not a format.

**How it enters.** The archive of the pinned release of CLDR (`cldr-common`, its XML) is a recipe input, fixed by its hash. The tool reads it with the XML reader of the Odin core library, checks it, and writes the typed tables: the locale data of each pack and the shared tables of the boot image. A plural rule is compiled from its syntax (part 3, "Plural rules syntax") into conditions on the operands `n`, `i`, `v`, `w`, `f`, `t` and `e`, which the render evaluates with integers. No process reads XML or JSON, and no process reads a rule as text.

Refused: the JSON of CLDR. It is a derived form of the XML, and it holds no collation: one input and one reader serve every table.

**The size.** Measured: the JSON of CLDR 49 for `fr`, for the files that this design reads, is 338 KiB (units 138.7 KiB, currencies 61.9, time zone names 50.5, date fields 26.4, names of languages 19.3, the Gregorian calendar 18.7, names of regions 9.8, numbers 6.3, names of scripts 4.8, list patterns 1.6). The shared supplemental files: likely subtags 217.1 KiB, plural rules 73.9, ordinals 18.9, parent locales 5.7.

Estimated, to measure when the tool writes the tables: the locale data that this design takes for one locale is 25 to 40 KiB once compiled. The large files of the source are mostly what it does not take (the currencies, about 150 units of 160, the names of the zones), and a compiled table holds no key and no quote. The shared tables of the boot image (the likely subtags of the languages of the image, the plural rules) are under 20 KiB. The tool prints the size of each part of each pack, as a measure.

### 5. Text processing

The character properties are tables of one resource of the boot image, `unicode_data`, from the character database of the pinned Unicode. The root service maps it read-only at a fixed range, as the font outlines; the procedures are a support package, `unicode_text`, compiled into the process that uses them. Estimated: normalisation 30 to 60 KiB, the break properties 10 to 20 KiB, direction and mirroring 10 KiB, case 15 KiB, script and width 13 KiB. The root collation and the confusables are larger, 150 to 300 KiB and 60 to 100 KiB, and come with their layers.

**Normalisation: NFC at the border (UAX #15).** A text that becomes a name (a name of an object of a store, the name of a principal, a nickname) must be in NFC. The border checks it with the quick check of UAX #15, section 9, "Detecting Normalization Forms", and refuses a text that is not NFC: it never changes a name in silence. The keys and an input method give NFC, so a principal never sees the refusal. A passphrase is written in NFC before its derivation: the keys of today give NFC, so each passphrase of today keeps its bytes.

**Segmentation (UAX #29).** The line editor moves, deletes and selects by extended grapheme cluster, not by code point: é written as e and U+0301 is one step. The word boundaries give the double click of a word and the moves of Control with an arrow. The sentence boundaries wait for a need. A grapheme cluster of Latin is one code point in the subset, so the line editor of today already gives the same steps.

**Line breaks (UAX #14).** The break of a text in its box ([text_box.md](text_box.md)) follows UAX #14: the break opportunities of the algorithm, then the last that fits. The rule of today, a break after `/`, `:` or `_` in a word wider than the box, stays as a tailoring, which UAX #14 allows in its section "Customization". A break is between two grapheme clusters. Hyphenation is not taken.

**Direction (UAX #9).** A text is stored in its logical order. The text rendering module computes the levels of a paragraph, breaks the lines, and reorders each line (rule L2), with the mirrored glyphs of `BidiMirroring.txt`. The base direction of a paragraph is the direction of its locale for a text of the interface, and the first strong character (rules P2 and P3) for a text of a principal or of a file.

**The mirror of the layout.** In a locale written right to left, the interface package places each element from the start edge: the first column of a table, the caret, the arrow of "next" and the close button of a title bar go to the right. The elements name the start and the end, and the interface package turns them into the left and the right once, from the direction of the locale. The draw table stays in pixels of the screen: a mirror is a fact of the layout, not of the format ([../api/draw_table.md](../api/draw_table.md)). A picture, a graph of time and a number do not mirror.

**Case (the Unicode Standard, section 3.13).** The full case mapping of `SpecialCasing.txt`, with the rules of a language (the dotted and dotless i of Turkish and Azeri, the final sigma of Greek) from the locale of the text. The search of a text that a principal reads compares with the full case folding of `CaseFolding.txt` after NFC: the canonical caseless match of section 3.13. The completion of a name of the console still folds ASCII only: a name is ASCII code.

**Order (UTS #10 and UTS #35 part 5).** A sort for a principal compares with the Unicode Collation Algorithm, the root order of CLDR and the tailoring of the locale. In CLDR 49 the root order is the order of the DUCET. `fr` has no tailoring; `fr-CA` sorts its accents from the end; Swedish puts ä after z. The search that ignores case and accents compares at the primary strength (UTS #10, "Searching and Matching").

- **The console's `sort` keeps the order of code points by default.** The bytes of UTF-8 sort as their code points, so the `sort` of today already has that order. A line then sorts the same on every machine, which a declaration needs. The order of a language is an argument that the line states: `sort(name, language = language())` ("8. The console and Lex").

**Identifiers (UAX #31).** The names of Lex and of the module contract are a profile of the default identifiers of UAX #31, section 2, "Default Identifiers", restricted to ASCII: the profile is the rule of [../data/text_encoding.md](../data/text_encoding.md), "What stays ASCII, and why". A display text is any script, and is never an identifier.

**Security of a text (UTS #39).** A text that names a thing for a principal can imitate another:

- **The name of a principal and a nickname** must pass the restriction level "Moderately Restrictive" (UTS #39, section 5.2, "Restriction-Level Detection"): one script, or Latin with the scripts that a language writes with it. A mix of Latin and Cyrillic (`раypal`) is refused.
- **Two names of one list** (the principals of a machine, the objects of a store, the nicknames of the disk grant table) must have two skeletons (UTS #39, section 4, "Confusable Detection"). A name whose skeleton equals the skeleton of another is refused at its creation.
- **A display text of the palette** whose skeleton equals the skeleton of an entry of the system is shown with the name of its module, so a module cannot dress an entry as "Lock the screen".

### 6. Shaping and fonts

**HarfBuzz, as a library module, for the scripts that need it.** The written shaper of [text_rendering.md](text_rendering.md) stays for the scripts that it shapes right: Latin, Greek, Cyrillic and the symbols, with advances and pairs, compiled into each process. A run of a script that needs the shaping of OpenType goes to a library module, `complex_shaping`: Arabic and Syriac, the scripts of India, of Southeast Asia, Tibetan, Mongolian, Hangul by jamo, the scripts of the Universal Shaping Engine, and a run that holds a combining mark. The module is HarfBuzz, a work of others in C++, under the license MIT-Modern-Variant ("Old MIT").

The reasons:

- **The work is the OpenType shaping models**: the joining of Arabic (`ArabicShaping.txt`), the reordering of the Indic scripts, Khmer and Myanmar, the Universal Shaping Engine, the eight kinds of GSUB lookup and the nine of GPOS, and the faults of the fonts of the world. HarfBuzz holds 15 years of them; Chrome, Firefox, Android and the toolkits of Linux shape with it, and OSS-Fuzz fuzzes it. A shaper written here is tens of thousands of lines whose proof is that work again. The rule of reuse holds: proven, permissively licensed, and too large to write again.
- **It fits the border of today.** The placed glyph of the text rendering module already has the font of the chain, the glyph index in that font and the cluster ([text_rendering.md](text_rendering.md), "The interface"). A module that gives placed glyphs over the font outlines of the caller is the form of the library module `text_rendering`.
- **Its configuration is small.** The shaper only: no subsetter, no FreeType, no ICU, no GLib; its own Unicode functions; its memory through its hooks (`hb_malloc_impl`) from an arena of the caller. Estimated: 600 KiB to 1 MiB of code, to measure.

**Why HarfBuzz keeps property 18.** Property 18 says that the code of the system writes its drawing and its WebGPU subset from nothing, and ports no 2D library ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "18. One 2D interface: the draw table"). Shaping is not drawing:

- **Shaping gives numbers, drawing gives pixels.** HarfBuzz turns a text and a font into glyph indices, positions and clusters. It reads no outline to fill, writes no pixel, holds no surface and blends no color. The rasterizer, the private glyph cache, the blend in linear light and the draw table stay written for the system.
- **What the property guards stays whole.** The property keeps one 2D interface and its execution in the code of the system, so that the look, the cost and the proof of each pixel are the system's. A placed glyph from HarfBuzz enters the same draw as a placed glyph of the written shaper: the same rasterizer draws it, and the golden hashes of the faces still prove the pixels.
- **The property names the 2D libraries that it refuses**: wgpu, Dawn, Skia, a toolkit. Each of them draws. HarfBuzz is the shaper that those libraries call; it is not one of them.

So the reuse of HarfBuzz falls under rule 2 of the objective, and property 18 is unchanged. The field **Reuse** of property 18 names HarfBuzz as planned, for the shaping of complex scripts. The reuse list of the properties gets its row in the commit that adds its source to the repository: a candidate is not a row ([../infrastructure/reuse_list.md](../infrastructure/reuse_list.md), "Constraints").

**The C++ path.** The outside source path compiles C today ([../infrastructure/outside_source.md](../infrastructure/outside_source.md)). HarfBuzz needs `clang++` with no exceptions and no RTTI, and the few procedures of a C++ runtime that it calls (the placement of an object, the guard of a static), which the thin libc of the outside source gives. A run of a complex script is a call of a module, not a compiled procedure: it is the large code called a few times ([../api/library_modules.md](../api/library_modules.md)).

Refused:

- **A shaper written here.** See above: the size and the proof.
- **`kb_text_shape`.** One C file, zlib, about 22 000 lines, with a binding in the vendor folder of Odin, and no C++ path to build. Its own header gives no security guarantee for an untrusted font file, and a font of the cache comes from a third party. It is younger, and was not run against the tests of HarfBuzz.
- **A shaper in a service.** A process then waits for another in its frame, and the service sees what each process writes ([glyphs_on_demand.md](glyphs_on_demand.md), "The forms that were refused").

**Fonts for the scripts of the world.** A font past the boot image is a data object named by its hash, from the cache, named in the plan, as a pack is; the root service maps it with the font outlines at the start of a process. The fallback chain by script ([glyphs_on_demand.md](glyphs_on_demand.md), "The fallback chain by script") takes a row for each script from the Script and Script_Extensions properties (UAX #24). The fonts are the Noto families (SIL OFL 1.1), one object for each script, so a machine holds the fonts of the scripts of its principals. The roadmap holds the steps: "A font for the missing Greek letters, Cyrillic and Latin Extended-A" and "A font for the CJK ideographs", with a cell of two columns from UAX #11.

**French needs added characters.** French text uses characters past the Latin-1 Supplement: œ and Œ (U+0153, U+0152), Ÿ, the narrow no-break space U+202F that CLDR puts before `;`, `:`, `!`, `?` and between the groups of a number, the right single quotation mark U+2019, the dashes and the ellipsis. Each joins the list of the added characters when each font of the system draws it ([../data/text_encoding.md](../data/text_encoding.md), "A character past Latin-1 is added to a list, not by a range"), else its fallback chain draws it.

### 7. Input

**Layouts as data: the CLDR keyboard format.** A layout is a file of UTS #35 part 7, the format `keyboard3`: its keys by their place, its layers by modifier, its dead keys as markers and transforms, its forms of hardware (`us`, `iso`, `jis`, `abnt2`, `ks`). The tool compiles each file into the tables of the private part `keyboard_layout` of the input service ([keyboard_layout.md](keyboard_layout.md)). The two layouts of today become two files of that format in the repository: CLDR has no layout of the United States, and its `fr.xml` is the normalised AZERTY of AFNOR (NF Z71-300), not the AZERTY of today. The rules of a dead key of today are transforms of the file, and the host tests of today stay the proof. The normalised AZERTY of CLDR comes as a third layout with no code.

Refused: the data of XKB. Its text format has includes, symbols and types written for the X server, and the meaning of a file needs the code of `xkbcommon`. Part 7 states that it is an interchange format, to compile into a form for an engine: the form that this design takes.

**The setting of the layout.** While the layouts are the files of the boot image, the setting stays an enum of the layouts of the image. When a layout comes from the cache, the setting names it by its keyboard identifier, a tag with the extension `t` and the key `k0` (part 7, "Keyboard IDs"), in a record of its own: the `Locale` record keeps no `t`.

**Dead keys and compose.** The dead keys of today stay, as transforms. A compose key is a set of transforms of the same format, with no new code; it waits for a principal who asks for it.

**Input methods for Chinese, Japanese and Korean.** An input method is a process, with a grant, between the compositor and the window in front:

- When the text field in focus asks for an input method, the compositor sends each key to the input method process in place of the window, through a ring of its own.
- The input method sends back records: a composition (the text that is not committed, its segments and its caret), a commit (a text), and the place of its candidate window.
- The window receives the composition and the commit as text events of the window ring, not as keys, and draws the composition in its text field. It gives the compositor the rectangle of its caret, so the candidate window stands at the text.
- The candidate window is a surface of the input method process, which the compositor places at the caret and marks as a surface of the system input.
- A field of a passphrase asks for no input method: its keys never leave the path of the keys.

The contract follows the text input and input method protocols of Wayland (`text-input-v3`, `input-method-v2`) as prior art, in records of a ring. The input method holds the keys of a text field, which property 20, row 7 gives only to the window in front: so it is a grant of the principal, visible and revocable. Its dictionaries are data objects named in the plan.

The subset needs none of it, and its interfaces already take it: a key record carries a code point, and a commit of several code points is one more event of the window ring.

### 8. The console and Lex

- **Code stays English.** The names of modules, exports, fields and members, and the keywords of Lex, are identifiers. A line means the same on every machine, and a declaration that a principal shares stays valid for a principal of another language.
- **Results, error sentences and help come from interface messages.** The sentence of an error record is an interface message of the package `sentence`, with the fields of the record and the names of the operation and of the argument as variables. The help line of an export is an interface message of its package, written by the describe step from its documentation. The head of a column shows the name of the field: it is code, as a member is. A display text of a field is the same mechanism as the display text of a member, when a need asks for it.
- **`sort` and `where` with a locale.** `sort(name)` keeps the order of code points. `sort(name, language = language())` sorts by the collation of the first language of the principal; `sort(name, language = language("sv"))` by Swedish. `where(name == "été")` compares the bytes of two texts in NFC. `where(matches(name, "ete", language()))` compares at the primary strength of the collation: case and accents ignored.
- **A number in a result** is written in the convention of the locale only where the kind of its field is a measure (a size, a time, a count). A number that is an identifier (an address, a block, a serial) keeps its digits, so a principal can type it again.

### The frequent tasks

| Task | Its expression |
|---|---|
| Read the interface in French | the row "languages" of `settings`, or `settings.set_languages([language("fr"), language("en")])` |
| Know the languages of the principal | `settings.languages()` |
| Sort names as a French reader expects | `files |> sort(name, language = language())` |
| Find a word with no regard to case and accents | `files |> where(matches(name, "ete", language()))` |
| Read the log in the language of the principal | `log.records(0)`: each fact is an interface message in the reader's language |
| Write a sentence in the code of a module | `interface_message.write(.disk_full, Disk_Full{free = blocks}, &line)` |
| Translate a module | a file `messages/fr.mf2` of its packages, and a pack that the tool builds from it |

## The refused forms

- **Fluent itself.** It is a project of one vendor with no standard body, and its functions and data are its own, beside the CLDR that the system imports. A second form beside the standard form is two mechanisms for one concept.
- **A wait for the standard of the message resource.** Layer 2 then waits for a body that has no date. The pinned draft gives the same compiled tables; a new version changes the reader of the tool only.
- **A language as an enum.** A closed set of languages makes a new language a change of a contract. A tag is a registry name, checked against the data of a pinned CLDR.
- **A tag as text across a border.** Each reader then parses it. The record is typed once, at the border of the principal.
- **The source text of interface messages in the module file, parsed at run time.** Each reader holds a parser of MF2, and a fault of a translation appears in a window, not at the build.
- **The interface messages in the code** (a table of strings in each module, a switch on the language). A translation then changes the hash of each module, and a third party cannot translate a module.
- **A string as the identifier of an interface message** (gettext, the English text as the key). A fix of the English is a new identifier for each translation, and the compiler checks nothing.
- **A pack bound to the hash of a module.** Each build makes each translation stale. The source hash of each interface message is the bound.
- **A fallback for the whole pack.** One stale translation then sends the whole interface to English.
- **A locale chosen by each process**, or a `LANG` of the environment. The language is a choice of the principal, on the settings page, read by each process.
- **The locale in the kernel.** The kernel log stays the bytes of its writer; a reader renders.
- **`sort` in the order of the principal by default.** A line then sorts in two orders on two machines.
- **A translation of the names of Lex.** A line and a declaration then mean another thing in another language.
- **The tz database through `-u-tz-`.** See [time_zone.md](time_zone.md), "The refused forms".
- **ICU or ICU4X as a library of the system.** Each is the implementation of these standards with its own data format (ICU data files, ICU4X postcard blobs) and a large runtime. The system takes the standards and their data, and writes tables in its own flat form, which the tool checks: one format for the module file and the packs. ICU4X stays a reference for the tests of the tool.
- **More than 8 languages in the list.** See "The language list".

## The subtle points

- **Two chains, one result.** The language of an interface message comes from its chain; its numbers come from the locale of that language. A French principal who reads an English fallback reads "1,234 blocks", not "1 234 blocks", so one sentence keeps one convention.
- **A plural needs the operands of the number as written.** The category of 1.0 is not the category of 1 in some languages (the operand `v`). The render computes the operands from the value and the digits that it writes, never from the value alone.
- **French puts 0 and 1 in `one`.** "0 bloc libre". A translation that keeps the variant `0` of English is valid, and the tool does not refuse it.
- **A stale translation is not an error.** It is a fallback of one interface message, which the tool counts for a pack, as a measure.
- **The source of a fact is the sentence of a test.** A change of the English of a fact changes each wait of a test that reads its words, in the same commit, as today.
- **NFC is checked, not applied.** A border that normalises makes two different byte texts one name in silence. The input path gives NFC, so the refusal reaches only a text that a process built.
- **A narrow no-break space in a number.** French numbers have U+202F; a principal who copies "1 234" from a window gets it. `matches` and a number of the console take it; a name never holds it.
- **The isolates of an interface message** are characters of the rendered text, not of a translation: the check of a pack refuses them, and the render adds them.
- **A pack from the boot image is trusted by the image signature**; a pack from the cache by the substitution policy. Both pass the same check.
- **The settings page holds choices only**: the language list is records, and no address, size or hash of a pack ([`docs/FONTS.md`](../../../docs/FONTS.md), "7. The setting"). The packs are named by the plan and mapped by the root service.

## The layers

Each layer is a step that works on its own. The subset (English and French, Latin, left to right) is the first six.

1. **Language tags and the language list.** The contract `locale`, its border, the setting `languages`, its row, its exports and `language(text)` of the console. The principal states the languages that it reads, and the system writes each of them in its canonical form.
2. **Interface messages in English.** The tables `Interface_Messages` and `Interface_Message_Parts`, the tool that compiles `en.mf2` in the form of the pinned draft, the enum `Interface_Message` and its records, the render; the log facts and the display texts of members become interface messages. The English of the interface takes the plural of each count ("1 block", "2 blocks").
3. **Locale data of CLDR.** The pinned CLDR as a recipe input, the tables of `en` and `fr`, the numbers, the dates and the hour cycle, the localized GMT format. The bar and the windows write dates and numbers in the convention of the principal.
4. **Language packs, and French.** The pack format and its check, the pack `fr` of the boot image, the map of the root service, the change at run time. The principal reads the interface in French, and a stale translation falls back alone.
5. **Unicode text for Latin.** NFC at the borders of names, grapheme clusters in the line editor, the breaks of UAX #14, the full case folding, the root collation and the confusables of UTS #39. A principal sorts and searches French words as a reader expects, and no two names of a list look the same.
6. **Layouts as CLDR keyboard files.** The two layouts of today as files of part 7, and the normalised AZERTY. A new layout is a file, not code.
7. **Packs and fonts from the cache.** A pack and a font object named in the plan, fetched by hash, and mapped at the next start of each process. A machine holds the languages and the scripts of its principals only.
8. **Direction: right to left.** UAX #9 in the text rendering module, the mirror of the layout, the isolates of the render, Arabic and Hebrew fonts, shaped by HarfBuzz through the C++ path. A principal reads Arabic and Hebrew.
9. **Complex scripts.** The library module `complex_shaping` from HarfBuzz for the scripts of India and of Southeast Asia. A principal reads them as they are written.
10. **CJK.** The font and the cell of two columns (the roadmap entry "A font for the CJK ideographs"), then the input method process and its candidate window. A principal reads and writes Chinese, Japanese and Korean.

## State

Not built. This file is the design. The roadmap holds the layers.

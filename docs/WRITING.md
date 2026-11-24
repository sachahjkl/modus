# The words of the system

Each screen text of modus follows this guide: an error sentence, a notification, the text of a dialog, the label of a button, the description of a setting or of an export, and a status line. The guide says what a text says and in which form.

The rules come from three sources:

- What a message says: the Windows User Experience Interaction Guidelines, for [error messages](https://learn.microsoft.com/en-us/windows/win32/uxguide/mess-error), [warnings](https://learn.microsoft.com/en-us/windows/win32/uxguide/mess-warn), [notifications](https://learn.microsoft.com/en-us/windows/win32/uxguide/mess-notif), [dialog boxes](https://learn.microsoft.com/en-us/windows/win32/uxguide/win-dialog-box), [style and tone](https://learn.microsoft.com/en-us/windows/win32/uxguide/text-style-tone) and [user interface text](https://learn.microsoft.com/en-us/windows/win32/uxguide/text-ui).
- The words and the tone: the [Microsoft Writing Style Guide](https://learn.microsoft.com/en-us/style-guide/welcome/).
- The form of each sentence: ASD-STE100 Simplified Technical English, the rule of all the texts of the project. Short sentences, one term for one concept, the active voice, simple verb forms.

The examples below show a bad form, then a good form.

## 1. An error sentence

An error sentence says three things, in this order:

1. The problem: what did not happen, and to which object.
2. The cause, when the system knows it.
3. What the reader can do, when the system knows it.

A part that the system does not know is left out. A guess is worse than no part: the Windows guide says that it is better to say that the cause is not known than to give a cause that is likely wrong.

- Bad: "Operation failed."
- Bad: "Check your network and try again." The problem is missing, and the cause is a guess.
- Good: "storage.write: the argument name has 270 bytes; it can have at most 255 bytes". The problem, then the limit, which is what the reader can do.
- Good: "monitor.processes: the caller has no grant for this: to act for the principal; only the starter of the process can give this grant".

### No blame

The problem names the object as the subject of the sentence: the call, the argument, the file, the disk. It never names the reader as the actor of a fault. The Windows guide uses the passive voice to avoid blame; ASD-STE100 prefers the active voice. modus keeps the active voice and makes the object the subject, so both rules hold.

- Bad: "You entered an invalid name."
- Good: "The name has a byte '/', which a name cannot have."

### Specific numbers and names

A sentence gives the value that was wrong, the limit, and the name of the object. A general word that the reader cannot act on is refused.

- Bad: "Value out of range."
- Good: "The scale 3 is too large: the largest scale is 2."

### A code or a status

A code, a status number or the result of a call is never the message. It goes in the detail lines under the sentence, when it helps a reader who searches or reports the problem.

A status that the sentence can name is said in words: what the status means, not its name and not its number. A status that the sentence cannot name, because the record does not say whose status it is, is left out of the sentence.

- Bad: "monitor.count: the receiver refused the call with the status 2"
- Bad: "monitor.count: refused with the outcome Argument_Refused"
- Good: "monitor.count: the kernel refused an operation of the call: a handle names no object of the kind that the operation needs". The record has the unit `Kernel_Status`, so the sentence knows that the status is a status of the kernel.

The negative result of a failed export is not shown at all. The error record holds the facts, and the number tells the reader nothing. The Windows guide gives "-1" as its example of an incorrect error code.

- Bad: "error: settings.set: the call names nothing that exists (-1)"
- Good: "error: settings.set: the call names nothing that exists", then the kind, the operation, the argument and the values of the record on the detail lines.

## 2. Words that a text does not use

| Do not use | Use | Why |
|---|---|---|
| invalid, illegal, bad (of a value) | the fact: "has the byte 0", "is larger than 2048", "names no module" | The word says that something is wrong, not what. |
| fatal, catastrophic | the effect: "the process stopped" | The word adds fear and no fact. |
| abort, kill, terminate | stop | One verb for one action. |
| "Error" or "Failure" as a title | the problem as the title: "The note was not saved" | A title that says "error" repeats the icon and says nothing. |
| "failed" with nothing after it | "failed" with its object and its cause, or the problem itself | "Failed" alone gives no fact. |
| please, sorry | nothing | A tool states facts. The Windows guide limits both words; modus does not use them. |
| contractions: can't, don't, isn't | cannot, do not, is not | ASD-STE100 uses one form of each word. |
| unable to | cannot | ASD-STE100 approves "can" and "cannot". |

- Bad: "Fatal error: invalid handle."
- Good: "The handle 0x30004 was closed."

## 3. The form of a text

### Sentence case

A title, a label, a button, a menu item and a heading use sentence case: a capital letter at the start and for a name, lower case for the other words.

- Bad: "Delete All Notes"
- Good: "Delete all notes"

A sentence in a window or a notification ends with a period. A title, a label and a button have no end period.

The case of the words is the case of the text in the source. The design can draw a text in another case: the title of a card is drawn in capital letters (`docs/DESIGN.md`, section 5). Its text stays in sentence case, so a reader of the source, a screen reader and a translation get the same words.

A name keeps its form: a window whose title is the name of its module, such as `clock`, keeps the name in lower case.

The name of the system is `modus`, in lower case, at the start of a sentence too.

### The reader is "you"

A text that addresses the reader uses "you" and the imperative. It uses no "we" and no "the user".

- Bad: "The user must restart the machine."
- Good: "Restart the machine."

The word "principal" names a concept of the access model. It stays in the technical guides, the console and the reference. A window, a notification and a setting say "you", or name the person.

- Bad: "The principal has no private store."
- Good: "You have no private store yet."

### One fact once on one screen

On one screen, a title, a sentence, a label and a button do not repeat the same fact. Before a screen is shown, read each line: if another element already says it, remove the line.

- Bad: the title "Delete the note", the sentence "Do you want to delete the note?", the button "Delete the note".
- Good: the title "Delete note1.txt?", the sentence "The note and its 12 versions are removed.", the button "Delete note".

## 4. Warnings, notifications and dialogs

### A warning

A warning tells the reader about a risk before it occurs: a loss of data, of access or of time. Show a warning only when the reader can act on it. If the reader cannot change the outcome, do not show the warning.

### A notification

A notification tells the reader about an event that is not the result of the current action. Show it only when the reader can act, or needs to know. It is not for progress, for an advertisement of a feature, or for a fact that changes all the time.

- Bad: "The settings service started."
- Good: "The disk is 95 % full: 2 GiB free."

### A confirmation dialog

A confirmation dialog names the action on its buttons. A reader understands each button without the other text. "OK", "Yes" and "No" are refused when a verb can name the action. "Cancel" stays the button that changes nothing.

- Bad: "Are you sure?" with "OK" and "Cancel".
- Good: "Delete note1.txt?" with "Delete note" and "Cancel".

An error dialog has "Close", not "OK": the Windows guide notes that "OK" says that a problem is OK.

## 5. Descriptions of settings and exports

The description of a setting says what changes for the reader when the setting changes. It does not say how the setting is stored or which service reads it.

- Bad: "Sets the value of the keyboard_layout word in the settings page."
- Good: "The layout of the keys: the letter that each key types."

The description of an export, in its module file, follows the same rule for the caller: what the call does, its result, and the kinds of its error records.

## 6. The console

The console is a technical tool. Its sentences can name exports, arguments, kinds of error records and kernel operations: "storage.write", "the argument name", `Too_Long`. They follow the order of an error sentence all the same: the problem, the cause, what to do.

A failed line of the console is one line, then its detail lines:

```text
error: tally.add: the argument note has 40 bytes; it can have at most 36 bytes
  kind       Too_Long
  operation  add
  argument   2 note
  values     value 40, limit 36, found 0, unit bytes
```

- The sentence continues the name of the call after the colon. It starts in lower case and has no end period, as a line of a compiler does.
- The mark `error:` at the start of the line is the tag of a failed line, the same in the console and in the tool on the host, so that a reader and a test find each failed line. It is not the title of a message, and no window uses it.
- The result of the export is not on the line (section 1, "A code or a status").

## 7. Where the sources disagree

| Subject | Windows and the Microsoft guide | ASD-STE100 | modus | Why |
|---|---|---|---|---|
| Contractions | Use them for a conversational tone | Not used | Not used | One form of each word, for a reader of English as a second language and for a translation. |
| "please" | For an inconvenience to the reader | Not in the approved words | Not used | A tool states facts. The word adds no fact. |
| The voice of an error | The passive voice, to avoid blame | The active voice | The active voice, with the object as the subject | The object as the subject avoids blame and keeps the active voice. |
| "failed to" | "unable to" | "cannot" | "cannot" | ASD-STE100 is the rule of the form of each sentence. |
| The line of the console | A message is a complete sentence with an end period | One instruction or one fact for each sentence | No end period; lower case after the name | The line continues the name of the call, as the line of a compiler. A window keeps the Windows rule. |

## 8. What checks the rules

- The host test `each_sentence_keeps_the_words_of_the_guide` of `src/library/modus/sentence` writes the sentence of each error kind with each unit. It refuses a word of section 2, a bare negative number, a capital letter at the start and an end period.
- The machine test refuses a failed line of the console, or of the tool on the host, that ends with a bare number in parentheses.
- `display_text_check` (`tools/modustool/checks/display_text_check.odin`), run by `modustool check` and `modustool rule-checks`, parses each non-test module source and refuses forbidden words of section 2, contractions, `Error` or `Failure` titles, `failed` with no cause after it, non-sentence case, and wrong end periods in `member_texts`, setting descriptions and labels, window problem texts, action bar items, buttons, and context menu items.
- Review holds the other rules.

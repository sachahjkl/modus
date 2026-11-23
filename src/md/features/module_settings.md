# Settings and plan values

State: **Decided.** Built, but for the readers of "State" at the end. The prior art, the inventory and the joint critique are in [`docs/research/module_settings_study.md`](../../../docs/research/module_settings_study.md) and [`docs/research/module_settings_critique.md`](../../../docs/research/module_settings_critique.md).

This file records how a value that changes the behaviour of a process reaches it: a choice of a principal (a font, the time that a notification shows), a value of the plan (the retention of the snapshots, a static network address), and a lock. It records one value model, two doors to change a value, and one order of precedence, with no registry and no constant of policy in the code.

## Purpose

- A principal changes a taste at once, with no dialog, and the choice survives a stop, a restart of its owner and a change of the module that holds a role.
- Principal 0 declares a value that widens an access, spends a resource of the machine, lowers a protection or destroys data, and sees it in a difference on the trusted display before it holds.
- A value has one description: the description of the export that sets it. The console, the palette, the window of settings and the plan read that one description.
- A number that bounds memory or work is never a setting: it is a budget, a length in a region, or a fact of the machine.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "8. No global, mutable, shared file system": no registry, no tree of keys, no shared configuration folder.
- "9. A storage engine with one private store per process": a value is in the store of its owner, and only the owner changes it.
- "11. Reproducible system": a value changes no hash. A plan value is a part of the plan, which has a hash.
- "12. Module metadata in flat tables, read through functions": the module format gets no table for settings.
- "19. A command is a function: no text between processes": no configuration text, no environment variable.
- "20. No ambient access": a value of a sandbox never reaches another sandbox.
- "22. General mechanisms, and a plain expression for each frequent task".
- "23. A role is a contract; its implementation is replaceable": a replaced holder keeps the values of its role.
- "24. Every input of a process passes through a channel that can be recorded".

## The value model

**One owner.** Each value has one owner: the holder of a role, or an application. The owner keeps the value, checks it at one border, and serves its getter. The process `settings` owns the values of the contract of Settings (the font, the appearance, the scale, the zone, the languages), and no value of another role. The compositor owns the values of the role Display (the edge of the bar, "do not disturb", the factor of the magnifier, the time that a notification shows, the arm time of the principal). A window of settings is a client of the setters that its start grant set lists; it keeps no value.

**A setting is a parameter.** A setting is an optional parameter of a setter export that names its getter, as `settings.set` does today ([enum_parameters.md](enum_parameters.md)). The module format gets no table `Settings`: a second description beside the description of the exports would drift from it.

Why the owner and not a keeper: a keeper that is not the owner keeps a value that the owner refuses, or makes each change wait for a second process. `display.windows_that_declined_the_scale` is the side path that such a split needed.

## The two doors

A value changes through one of two doors. The split is irreducible: it is the line of consent.

- **The setter**: a call of a caller that acts for the principal. It holds at once, with no dialog.
- **The plan**: one typed record for each owner in a declaration, with its difference on the trusted display ([declarations.md](declarations.md), "Apply, the difference and the rollback").

**The line.** A value has no setter, and changes only through the plan (a **plan-only value**), when one of these holds:

1. it widens an access that the grants do not give: an admitted host, a listen port, a callable service;
2. it spends a resource of the machine or of another principal: a quota, a budget, a restart bound;
3. it lowers a protection, or it destroys data that the principal cannot get back: the retention of the snapshots, the longest duration of a wide grant.

Each other value has a setter. The owner draws the line once, in its contract: the value has a setter or it does not. No process classifies a change at run time.

When a plan value holds is a fact of its owner: at its start, or at once. Its contract says which.

**Plan generations for each live change: refused.** A commit "with no new authority" through the door of the plan makes a process decide, on a difference, that a change gives no authority: a fault there passes the trusted path with no dialog. And `plans` would hold each value of each module and push it to each owner, which is a registry. A chosen value is data of the principal, as a document: a rollback of a module does not undo it.

## The precedence

Four layers, the first that has a value wins:

1. **Locked** by the plan of principal 0.
2. **Chosen** by the principal, kept by the owner.
3. **Plan default**: of principal 0, then of the principal.
4. **Contract default**: the zero value of the field (property 13, ZII).

Three rules make it hold:

- **The kept record holds only chosen values.** A field that the principal did not set is absent. A full record would keep each default as if the principal chose it, and a later default of the plan would then change nothing (the owner would tattoo its own defaults).
- **A lock writes nothing.** Under a lock the setter refuses with `No_Grant`, the chosen value stays kept, and holds again when the lock ends.
- **An apply never resets a chosen value.** The state export of the owner gives the layer of each value, so a reader sees that a choice hides a default.

A **reset** export makes a chosen value absent. An absent optional parameter means "no change", so it cannot also mean "not chosen".

## The description of a parameter

The description of a parameter grows by three general fields. None is special to settings: each export uses them.

1. **The range** of an Integer: its least and its largest value. The range of a Text is the bound of its bytes, from 0: `parameter_ranges = "home = 1..160"`. The console refuses a value or a text out of it before the call, the palette offers the stops of an Integer, and the owner checks it again at its border. The table `Parameter_Settings` carries both in its fields `least` and `most`, so the module format stays 8.
2. **A choices export**: a table export that gives the identity and the display text of each choice of an open set (the fonts of the image, the screens). It is `enum_getters` for a set that the code does not know. The value is the identity of a choice, never its place in a list.
3. **An instances export**: a table export that gives the instances that a setter takes as its first argument (a screen, a keyboard, a store). The owner keeps one value for each instance, in memory that its budget pays.

**An optional parameter crosses as a pair**: a `module.Presence` word, then its value. `Absent` is 0 and `Given` is 1; the border of the export refuses any other word. In the source, the pair is two parameters: `<name>_presence: module.Presence`, then `<name>`; the build describes them as one parameter of the file with the flag Optional, and the call form gives it two words.

- Absent is the zero value, so a caller that passes zeros passes absence: zero is initialization (property 13).
- Zero stays a real value when the word before it is `Given`: a time zone of 0, a count of 0. The former form gave an absent Enum the word of all its bits set, and an Integer had no absent word at all.
- Any parameter can be optional, of any type that a word carries: Integer, Enum, Handle, and a Text, whose word is the address of its text: an absent Text crosses as Absent and the address 0, so the export reads no text. A Record, a Table and Bytes are never optional: they are places that the callee reads or writes in the memory of the caller. No bitmask of 16 bits bounds their count; the call form counts two words for each, within `module.CALL_WORD_CAPACITY`, 16 words: the seven settings of `settings` and an error record take 15. The call form grew from 12 words to 16 for that setter; an export still has 12 parameters at most.
- The pair is two parameters, not one struct of 16 bytes: the C convention passes such a struct on the stack when one register is left, and later words then take that register, so the words of the call would no longer follow the parameters in order.

The range, the choices export and the instances export are written in the source as attributes of the export (`parameter_ranges = "notification_time = 1000..60000"`, `parameter_choices = "font = fonts"`, `parameter_instances = "screen = screens"`). The module file holds them in its table `Parameter_Settings`, one record for each parameter that has one. A role contract names the range of each setter parameter from the constants of its contract, so the check of a holder compares the numbers of its file with the one place of each fact.

One **state export** for each owner gives one row for each of its settings: whether it applies now, its range in force, and the layer that gives its value. It replaces any static condition: two sources of one condition drift.

A **view act** of the owner opens its own window for a setting that needs one (the arrangement of the screens). The window of settings never draws a surface of another process (property 20, lines 6 and 8).

## The role store

The store of a role belongs to the role in its scope, not to the module that holds it. The root service gives the holder of a role the store named by the role. A new holder (a holder that the plan replaced, or the same module after a restart) reads the objects of the one before through the record types of the role contract.

- A setting of a role is an export of the role contract, so the check of a holder refuses a module that does not serve it.
- A value that only one holder has (an export past the contract) is an object of the same store with its own description. Another holder leaves it in place.
- The conformance suite of a role has one case for each setting: set, stop the holder, start it, read.
- The grants of a role follow its holder: a holder that the plan names gets the start grant set of the role, its store too.

## The presentation record

The settings page ends for windows. The holder of the display gives each window a **presentation record** on its window ring: the scale of its surface, the appearance in force, the font and its grid fit, the order of the stripes, the contrast, the motion, one resolved locale, and the time zone. The holder writes it at the start of the window and at each change.

Why: presentation is a fact of a surface, and only the holder of the display knows it. One page cannot give two scales to two screens, or a scale to a viewer of the remote display, and a page that each window maps passes around an interposed holder (property 23). The window ring is a recorded channel already; the page was one more point copy (property 24).

What each window still reads, and why: **the scale and the time zone are an accepted fingerprint.** A window draws at the scale of its surface, so it knows the scale; a window shows the local time, so it knows the zone (the date page gives the zone too). The record lowers what a window reads: the pointer theme goes to the holder of the display only, the layout of the keyboard to the holder of the input only, and the full language list is a grant for a process that sends it.

**How a window keeps the record.** The record comes in the window event `Presentation`, at the first event of each window and at each change. The display library of the window writes it on a page of its own process at the address of the settings page, in the format of that page: the drawing module of the process, which keeps its own copy of the display library, reads that page at its fixed address. The root service gives each process with a surface a page of its own, which no other process maps; only `settings` (the writer), the date service (the zone of the date page), the input service (the layout of the keyboard) and the holder of the display map the page of the machine.

- The record carries the words that a window draws with: the appearance in force, the font, the grid fit, the order of the stripes, the scale and the time zone, and one locale: the language, the script and the region of the first language of the principal. Contrast and motion join it when they are settings.
- The forms refused: an export of the holder that each window calls (a call at each frame, and the drawing module has no connection); a page per window that the holder writes (the holder would map a page of each window, and a holder that is replaced loses them).
- A window that starts before the boot pass of `settings` gets the defaults on its page (an empty page reads as the defaults), then the record of the first change: no window misses a change, because the holder tells each window, with a surface or not.

**A remaining channel.** A caller that acts for the principal (an agent console with a wide grant) can change the appearance at a rhythm that each window receives. Each change by a caller that is not the window of settings is an act record of the collector ([wide_grants.md](wide_grants.md)), and the setter keeps a rate that is one constant of its contract.

## Plan records

The plan carries one typed record for each owner, keyed by the names of its fields. Its type is a record type of the contract of the owner, so the evaluation types each value by the description of the owner, at the border of the plan. A record that names a field that its owner lacks is refused whole: a tolerant reader would leave a value that the principal thinks holds. The difference of an upgrade lists each plan record that the new image refuses, before the principal accepts the upgrade.

The owner reads its plan record at its start from a page that nobody writes after the start: the page is recorded once, as the context is (property 24). A rule across the fields of one record (the three times of the retention rule have an order) is one pure procedure of the contract of the owner: the check at the apply and the border at the start call that one body.

**How the values reach their owner.** The holder of Plans gives the core the plan values of principal 0 with the command `Plan_Values`, as it gives the roles with `Plan_Roles`: on a page that the core lends, the whole set of the generation that the principal accepted. The core copies the set once, checks it whole (`modus:contract/plan_values`) and replaces its values in one step: the core never runs with a part of a plan. At the start of an owner, the core maps the values of that owner, read-only, at the fixed range `Plan_Values_Page`; an owner that started before the change keeps the values that it started with, and takes the new ones at its next start.

- The set names each owner by the name of its store: the role for a role holder, the module name for another module, `root` for the core itself.
- Each value is a name and a word, with its layer: `Plan_Default` or `Locked`. The owner checks each word at the border of its field, as it checks a chosen word: a word that its border refuses holds as no value of the plan.
- The record of chosen values and the plan values share one form of entry (`modus:contract/chosen_values`): a name of 32 bytes and a word. One reader, one border.
- The forms refused: a value that the owner reads with a call to the holder of Plans at each use (a plan holder that is slow or replaced would stall each owner); a page that the core writes during the life of the owner (a value that changes under a running owner is a live edit, refused).

The owners and their fields, as built:

- `settings`: each setting by its name in `settings.descriptions`, and `time_zone`, a default or a lock (`settings.choice_of_kept`).
- `display` (the holder of the display): `bar_edge`, `do_not_disturb`, `notification_show_milliseconds`, `magnifier_eighths`, `consent_arm_milliseconds` (`display_choices.choices_of_record`).
- `storage`: `keep_all_minutes` and `hours_end_hours`, the retention rule, with their order (`storage_retention.rule_of`).
- `root`: `budget_share`, and the start size and the largest size of the screen of memory (`root_plan_values.root_plan_of`); the core reads them at the start of the holder of the display.
- any owner of a store: `store_blocks`, the quota of its store, which the core reads when it opens the store (`root_plan_values.store_blocks_of`).

First plan-only values:

- **The retention of the snapshots** of the storage service ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Persistence: no save action, and versions for all processes", leaves "who sets the retention rule" open: the plan of principal 0 sets it).
- **The network address**: DHCP gives it by default; a plan record of the network service gives a static address.
- **The quota of a store** and **the budget share of a process**, which today are rows of the start grant sets and a quarter of the budget of the machine.

## The lock

A value of the layer `Locked` of the plan of principal 0 holds over the choice of the principal. Its owner reads the lock on its plan values page at its start (`plan_values.locked`), and each door of a change of a locked value refuses it:

- A setter and a `reset` refuse a call that names a locked setting with `No_Grant`, unit `Plan_Lock`, and the argument of that setting, from 1. A call that gives a locked setting and other settings changes none of them: a call holds whole or not at all.
- A press of the principal on the desktop that would change a locked value of the role Display changes nothing.
- The chosen value stays kept under the lock, and holds again when a later plan removes the lock.
- `settings_state` gives the layer `Locked` (3) and the value of the lock.

Why `No_Grant` and not `Bad_Value`: the value is valid, and the caller lacks the authority to change it; the authority is the plan of principal 0. Why its own unit: the sentence names the plan as the fix, where a missing start grant names the starter of the process.

The forms refused: a lock that writes the value of the plan in the kept record (the choice of the principal would be lost when the lock ends); a lock that the getter hides (a reader would see the choice and not the value in force); a setter that takes a locked value in silence (the caller would think that it holds).

## Module settings

A module that holds no role declares its settings in the same form as an owner of a role: a setter export whose optional parameters are its settings, each with its range or its enum getter, a getter for each setting, `reset` and `settings_state`. It keeps its chosen values in its private store (the grant Store), in one object, `settings`, in the form of `modus:contract/chosen_values`. Its plan values are those of the owner of its module name. A module setting is a taste: the plan alone holds a value of the line of "The two doors", as for a role.

**A text value.** A setting is a word or a text. A kept record holds both kinds of entry (`chosen_values.Entry_Kind`): a text entry gives the place and the length of its text in the bytes after the entries, in the order of the entries with no gap, so one record has one form. The reader refuses a text that is not UTF-8 or longer than `chosen_values.TEXT_BYTES_MOST`, 1024 bytes, before any owner sees it; the owner checks its own bound and its own rules after. `plan_values.text_in_force` gives a text by the same precedence as a word. A plan gives no text yet: a plan entry of the kind `Value` carries a word (`ROADMAP.md`).

**The keeper.** `modus:kept_choices` keeps the record of one owner: it reads the object on a worker thread after the first frame, holds each change that comes before the read ends and puts it on the record that the store gives, writes the record after each change, and leaves a record that this release cannot read as it is until the principal changes a value. The owner checks each word at its border before the keeper sees it, and computes the values in force from the record of the keeper and its plan values. The compositor, the browser and the monitor use it.

Why one library: each owner with a window must never wait for the store in its loop, so each needs the same states (no store, read asked, read, write asked) and the same rule for the changes of before the read. Three copies of those states drift.

The first module settings:

- **The browser**: `home`, the address that the browser opens at its start, a Text of 1 to 160 bytes (`modus://welcome` by default): a built-in page or an address of HTTP or HTTPS. Its border is the border of the address field of the browser (`home_problem_of`): the bound of the bytes, UTF-8, then `address_parse`; the browser keeps the canonical form that its address field writes. The first frame shows the home of the plan or of the contract; when the read of the store gives another home, it takes the place of the first page, unless the principal loaded a page already.
- **The monitor**: `sample_interval`, the time between two samples and two pictures, 250 ms to 5000 ms, 500 ms by default.

The form refused: a module that keeps its settings in an object of its own format. The window of settings, the plan and the console read one form, and the precedence holds only where the owner reads the plan with the same procedure (`plan_values.value_in_force`).

## Evolution

- The key of a kept value is the name of its field in the description of the kept record ([data_evolution.md](data_evolution.md)). No index is a key: an index moves when a contract inserts a field.
- An owner that reads a description that it does not know reads the newest earlier version of the object that it knows (property 9 keeps the versions), else the defaults. It writes nothing until the principal changes a value. So the values of version 1 are still in the store when version 1 comes back.
- Before 1.0, a changed description gives the defaults, as each format does.

## One fact, one number

The faults that the inventory found, fixed before any mechanism:

- **The rule of the day** (07:00 to 19:00) is in one package, `src/library/internal/settings/appearance`; the copy left.
- **The consent arm time** is one constant, `powerbox.CONSENT_ARM_MILLISECONDS`, 500 ms, for each consent door. The grant dialog held 250 ms while its guide said 500. A principal may ask for a longer arm time; nothing makes it shorter.
- **The notifications**: one rate (`notifications.RATE_INTERVAL_MILLISECONDS`) and one range and default of the time that a card shows (`SHOW_MILLISECONDS_LEAST`, `_MOST`, `_DEFAULT`), which the post checks. The compositor passed a literal past that check.
- **The answer bound**: a service that waits for a peer names a deadline of its contract from `system.ANSWER_BOUND_MILLISECONDS`. The hang bound of the tests is for a check, and `modustool rule-checks` refuses it in a service or a library.

## Frequent tasks

| Task | Expression |
|---|---|
| Change a setting | `settings.set(font = .spleen)` |
| Change a text setting | `browser.set(home = "modus://guide")` |
| Change two bound settings at once | `settings.set(light_from = 6:30, dark_from = 20:00)` |
| Undo a choice | `settings.reset(font = true)` |
| See each setting of an owner, its layer and its range | `compositor.settings_state()` |
| Change the setting of one screen | `display.set_for(display.screens() \|> first(1), scale = .sixteen_eighths)` |
| Set a plan-only value | `plan { storage = { keep_every_version_minutes = 30 } } \|> plans.apply` |
| Lock a setting | `plan { display = { appearance = locked(.dark) } } \|> plans.apply` |

## Refused forms

- **A table `Settings` in the module file.** Seven of its ten fields copy the description of the setter.
- **A central keeper of every value.** Its keys would be an open set that any module defines, a registry under another name; and a replaced holder of the role Settings would lose every value of every role.
- **The holder keeps its values in a store of the module.** A replaced holder loses them (property 23).
- **Everything in the plan.** A change of a font would need a dialog and a restart.
- **A plan generation for each live change.** See "The two doors".
- **A full kept record.** It tattoos the defaults.
- **A value keyed by an index.**
- **A static condition of a setting in the description.** The state export gives it.
- **A choice kept as its place in a list.**
- **A setting for a limit, a deadline, or a protection.** A limit is a budget, a length or a fact of the machine; a deadline is the answer bound; a protection has a floor that only goes up.
- **The bound of the tests as a deadline of a service.**
- **A text configuration file, an environment variable, a free key-value bag.** Properties 8 and 19.

## Subtle points

- **A value of an absent instance stays kept.** A screen, a keyboard or a font that comes back gets its value back.
- **A plan record is refused whole.** A plan that names a field that its owner does not have is refused with the name of the field.
- **The difference of a plan must page.** Each plan record adds items to the difference. The bound of 8 items on each side ([declarations.md](declarations.md)) must go before plan records grow past it, or a change is refused with `Display_Refused`.
- **The first frame does not wait for a store.** The compositor reads the record of its role store after its first frame; until then it draws with the contract defaults.

## Layers

1. One fact, one number. **Built.**
2. The role store, with the compositor: the edge of the bar, "do not disturb", the factor of the magnifier, the time of a notification, the arm time of the principal.
3. Only chosen values in the record of `settings`; the state export; `reset`.
4. The range, the choices export and the instances export in the description of a parameter; the window of settings and the palette read them.
5. The presentation record on the window ring, then the page leaves the windows.
6. Plan defaults and plan-only values: the retention of the snapshots, the quota of a store, the budget share of a process. The DHCP client of the network service, with a static address from the plan, is a layer of its own after them.
7. Module settings, with the browser.
8. The lock.

## State

Built: layers 1 to 8, and the DHCP client.

- The compositor keeps the settings of the role Display in the store of the role, on a worker thread, and the root service gives a holder of a role the grants and the store of the role.
- `settings` keeps chosen values only, keyed by name (`modus:contract/chosen_values`), with `reset` and `settings_state`.
- Module files are version 8: any word parameter can be optional, as a Presence word then its value, and the table `Parameter_Settings` holds the range, the choices export and the instances export of a parameter. The console refuses a value out of a range before the call; one `compositor.set` takes the five settings of the role. The palette and the window of settings do not read the ranges and the choices yet.
- Each window gets its presentation record in the event `Presentation` and keeps it on its own presentation page; only `settings`, the date service, the input service and the compositor map the settings page of the machine.

- A plan of principal 0 holds values of the kind `Value` (`owner.field`, a word, `Plan_Default` or `Locked`); the holder of Plans sends them with `Plan_Values` before the roles, and each owner of "The owners and their fields, as built" reads its page at its start. No reader turns a Lex `plan { ... }` into rows yet: a plan gives its values as rows of `plans.apply`.
- The network service takes its address from DHCP, or the static address of the plan ([dhcp_client.md](dhcp_client.md)).
- The browser (`home`) and the monitor (`sample_interval`) have module settings, kept in their private stores through `modus:kept_choices`, which the compositor uses too.
- A lock of the plan makes each setter and each `reset` refuse a locked setting with `No_Grant`, unit `Plan_Lock`; a press on the desktop changes nothing under it.

Not built: the palette and the window of settings do not read the ranges and the choices yet, and no reader turns a Lex `plan { ... }` into rows (`ROADMAP.md`).

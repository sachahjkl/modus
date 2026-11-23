# Module settings: a critique of the two studies

This file reads [`module_settings_study.md`](module_settings_study.md) and the proposed intent [`src/md/features/module_settings.md`](../../src/md/features/module_settings.md) (study A) against the independent study [`module_settings_independent.md`](module_settings_independent.md) (study B). It names the faults of each, then the points of agreement, the disagreements, one joint recommendation, the order of the work, and the questions that only the owner can decide.

Facts marked "checked" were read in the worktree for this critique. The other facts are taken from the two studies.

## 1. The verdict in short

| Question | Decision | Whose form |
|---|---|---|
| Binary table or typed exports | Typed exports. No table `Settings`. The description of a parameter grows by three general fields | B, with the content of A |
| One mechanism or a split | One value model and one precedence. Two write doors, and the line between them is consent | Neither |
| Keeper of a role setting | The holder of the role, in a store that belongs to the role and not to the module | Neither |
| Precedence | Locked by the plan, then chosen by the principal, then default of the plan, then default of the contract. The kept record holds only chosen values | B, with one rule added |
| The global settings page | It ends. The display gives each window a presentation record on the window ring | B, for another first reason |
| Plan generations for live edits | Refused | A and B, for a reason that neither gives |
| The 131 class C limits | None becomes a setting. The classification leaves the settings design | A |
| The six faults | Five need no settings mechanism. One needs the store of the role | A found them; the fix is smaller than A plans |

## 2. Points of agreement

Both studies agree on these points, and this critique keeps them.

1. No registry, no tree of keys, no configuration text, no environment variable (properties 8 and 19).
2. A change of authority goes through the plan and the trusted display. A change of taste does not.
3. The owner of a value checks it, at one border. An invariant across two values is checked by the owner.
4. A value of an absent device stays kept. Desired state and state in force are two things.
5. A choice that the machine gives is kept as an identity, never as a place in a list.
6. A custom view is a window of the owner. The settings window draws no surface of another process.
7. A secret is never in the plan and never on a shared page.
8. The precedence is the same in both: a lock of principal 0, then the choice of the principal, then a default. A names it "the order of the values"; B names it tiers 1 to 4.
9. A deadline of a service and the hang bound of the tests are two concepts. Neither is a setting.
10. A limit of a table is not a setting.

## 3. Faults of study A

### 3.1 The table `Settings` adds one field of knowledge and seven fields of copy

The record of the table holds a name, a help line, a kind, a group, a range, a default, a floor, four export indexes and one condition.

- The name, the help line, the type, the enum and its texts are already in the description of the setter parameter. A says so.
- The range of an Integer is a fact of the parameter. Each export needs it for completion and for the argument check of property 19, not only a setting.
- The source of the choices is a fact of the parameter too. The field `enum_getters` already links a parameter to an export. An open set of choices is the same link with a table export.
- The group is the setter. A already makes bound settings the parameters of one setter.
- The kind follows from the place of the export: a role contract, or a module.

So the table is a second description beside the description of the exports. Two descriptions of one fact drift apart. That is the fault that the inventory of A found four times in the code.

### 3.2 The key of a kept value is an index

A keeps a role value under "the role, the index of the setting in the role contract". A plan row holds "the hash of the module or the role, the index of the setting". An index is a place in a list. A refuses a place in a list for a choice ("A choice stored as its place in a list"), and uses one for the setting itself. A contract that inserts one setting moves each kept value to its neighbour.

### 3.3 The keeper and the checker are two processes

A states both of these:

- "The process `settings` keeps the values of each setting of each role", and it writes the store first.
- "The owner is the one border. Its setter refuses a value that breaks an invariant."

For a role setting of Display, the owner is the compositor and the keeper is `settings`. One of the two must hold. If `settings` writes first, it keeps a value that the owner refuses. If `settings` asks first, a change waits for another process. B names this in its section 2.3, and the code shows it today: `display.windows_that_declined_the_scale` (checked, `src/library/modus/display/display.odin:592`) is the side path that a keeper needs when it cannot check.

A does not say which module serves the setter of a role setting. Its frequent tasks call `settings.set(light_from = ...)` and `settings.describe("compositor")`. The second names a holder by a text, which property 23 forbids.

### 3.4 The central keeper does not survive the replacement of its own holder

A's reason for the central keeper is property 23: "A principal who replaces the compositor keeps its time of notifications." The same reason fails for the role Settings. `src/md/features/declarations.md` records that a holder of Settings that a plan names gets "no settings page with Write, no Serve, no Store" (checked, line 134). A principal who replaces `settings` loses each value of each role. The central keeper moves the fault to one place; it does not remove it.

### 3.5 The intent contradicts itself on who reads the page

The check against properties 2 and 20 says: "The role settings page is a read-only grant to the holder of its role only". The row "fingerprint" says: "Each process with a surface reads the font, the scale and the languages". The settings page of today "becomes the page of the role Display". If each window reads it, the first sentence is false. If only the holder reads it, the design does not say how a window learns the font and the scale.

### 3.6 "Holds at the next start" is in the definition of machine policy

The time when a value holds is a fact of its reader, not of its kind. A puts it in the definition, then asks in its open question 3 if the network address needs a live change. The definition makes the question.

### 3.7 The inventory is a list of candidates, not a list of work

Class (b) holds a port of a demonstration, fifteen rates of a QUIC library and five timeouts of a remote client. No use asks for another value of any of them. Property 25 says: "Each reuse names its first user." A value becomes a plan value when a named use needs a second value. Until then it is one constant in one contract.

### 3.8 Smaller faults

- A adds one read-only page per role and one policy page per process. Each page that another party writes is a point copy of property 24. A grows that channel.
- The rate of an agent that changes a setting is "a policy with a floor in the contract". A constant in the contract and an act record are enough.
- "A contract range of the time of a notification that no code reads" is not exact. `desktop_layout.odin:146` checks the range in its own procedure (checked). The fault is that the literal of the compositor does not pass through that check.
- A lists nine sites that read `TEST_HANG_BOUND_MILLISECONDS`. 57 files of `src` that are not `_test` files name it (checked by a count; some are test modules). The size of this fault needs a check of the tool, not a list.
- The intent file is not in the file index of `src/md/README.md` (checked). `intent_index_check` refuses it.

## 4. Faults of study B

### 4.1 B audits a design that A did not propose

B's "candidate under audit" keeps each schema in its module and each value in `settings`. A puts a role setting in the role contract and a module setting in the module. Half of B's section 2.1 and its point "global mutable registry" do not apply to A.

### 4.2 The hash argument is wrong

B says that a changed description of a setting changes the module hash, and counts it as a cost. The documentation text and each export description are already in the hashed file. A changed range is a changed behaviour. Property 11 wants the hash to change.

### 4.3 The five-year examples have no first user

Firewall rules, ICC profiles, keyboard chords and plugin schemas are not in the system. A design for them is speculative. B is right on a narrower point, with evidence of today: the time zone and the language list already do not fit the Enum description, and `settings` serves them with `set_time_zone` and `set_languages` (checked, `src/modules/system/settings/main.odin:522`, `:590`). That evidence is enough to refuse a scalar table.

### 4.4 B binds a role setting to the contract and keeps it in the store of the holder

B: "Replacing `compositor` with `tiling_compositor` preserves every role-contract setting because both modules fill the same contract hash." The contract is preserved. The value is in "the owning service's private versioned CoW store". A new module is a new process with a new store. B does not say how the value crosses. This is the fault that A's alternative 2 refuses, and B does not answer it.

### 4.5 B's own section 2.4 refuses B's own recommendation

B writes that two persistence layers break property 22, then recommends two persistence layers "unified by one precedence algebra". The honest statement is in B's section "Is the split irreducible?": the consent boundary is irreducible, the storage split is not. B does not carry that result into its design. Its four classes are not four mechanisms: class 2 is class 3 where the owner is the holder of Settings, and class 4 is not configuration.

### 4.6 The trio of `plans` commands makes `plans` a broker

`plans.overrides()`, `plans.reset_overrides()` and `plans.export_settings()` need `plans` to read the live values of each owner. `plans` then holds a connection to each service and sees each value. That is the central broker that B refuses in its section 5.

### 4.7 The presentation record does not hide what B says it hides

- **The time zone.** B says that an untrusted window can no longer read it. The date page holds `zone_offset_seconds` (checked, `src/library/modus/contract/date/date.odin:60`), and the root service maps the date page into each disk process with a window (checked, `src/modules/system/root/disk_processes.odin:431`). The zone leaves the settings page and stays readable.
- **The fingerprint.** Scale, font, stripe order, grid fit, contrast, motion and appearance are still given to each window. B lowers the entropy; it does not end the fingerprint.
- **The covert channel.** A caller that acts for the principal can still change the appearance at a rhythm, and each window receives a record. B does not name this channel. A does.

### 4.8 B's fifth question has one answer

B asks the owner if `plans.apply` keeps or resets a live choice that differs from a new default. A reset is a silent overwrite of a choice of the principal. B's own rule "no silent overwrites" answers it: keep.

### 4.9 `config_check` is a second place for one rule

A pure check export and the setter of the owner are two procedures that must agree. If they are two bodies, they drift. B does not say that they are one.

### 4.10 "Falls back to declared defaults on mismatch"

`src/md/features/data_evolution.md` says that an unknown description is refused, never overwritten. B's fallback is sound only if the owner does not write the defaults over the kept object. B does not say so.

## 5. The decisions, with reasons

### 5.1 Typed exports, no table

**Decision: no table `Settings`.** A setting is an optional parameter of a setter export that names its getter export. That form exists and works (`src/md/features/enum_parameters.md`). The description of a parameter grows by three fields, each general:

1. The least and the largest value of an Integer.
2. A choices export: a table export that gives the identities and the display texts of an open set. It is `enum_getters` for a set that the code does not know.
3. An instances export, for a parameter that names an instance.

Each field serves every export: the console completes a screen for any command that takes a screen. No field is special to settings.

One more export per owner replaces the state export of A: a table with one row per setting, which gives its availability, its range in force and the layer that gives its value (section 5.3).

Refused from A: the static condition "applies when setting S holds member M". The state export gives the condition. Two sources of one condition drift.

Kept from A: the view act, as a plain export of the owner.

### 5.2 One mechanism, two doors, and where the line is

**One value model.** A value has one owner. The owner is the holder of a role, or an application. The owner keeps the value, checks it and serves its getter. `settings` is one owner among the others: it owns the values of the contract of Settings. It keeps no value of another role.

**Two doors to change a value**, and this split is irreducible:

- **The setter**: a call of a caller that acts for the principal. It holds at once, with no dialog.
- **The plan**: a typed record in a declaration, with its difference on the trusted display.

**The line.** A value has no setter, and changes only through the plan, when one of these holds:

1. A larger or a smaller value gives a process an access that its grants do not give: an admitted host, a listen port, the list of callable services.
2. It spends a resource of the machine or of another principal: a quota, a budget, a restart bound.
3. It lowers a protection, or it destroys data that the principal cannot get back: the retention rule, the longest duration of a wide grant.

Each other value has a setter. The line is drawn once, by the owner, in its contract: the value has a setter or it does not. No process classifies a change at run time.

**Not irreducible**, and so removed:

- The three keepers of A. The keeper is always the owner.
- The kind "holds at the next start". An owner can apply a plan value at once or at its start. Its contract says which.
- The split between principal 0 and a principal as a kind of value. It is the scope of the role (property 23: the machine, a session). A role of the machine has values of the machine; a role of a session has values of its principal.
- The class "secret" of B. A secret is data of its owner, with the grant to erase versions. It is not configuration.

**Plan generations for live edits: refused.** B refuses it for the churn of the generations. That reason is weak: a generation of a copy-on-write store is cheap. Two stronger reasons:

1. A "config-only commit" passes with no dialog through the door that guards authority. A process then decides, on a difference, that a commit changes no authority. A fault in that decision is a consent bypass in the trusted path. The door of the plan must do one thing.
2. `plans` would hold each value of each module and push it to each owner. That is alternative 1 of A, which A refuses as a registry.

The atomic rollback of code and values is also not wanted. A value that a principal chose is data of that principal, as a document is. A rollback of a module does not undo a document.

### 5.3 Precedence and non-tattooing

**Decision: the four layers of B**, which are the order of A:

1. Locked by the plan of principal 0.
2. Chosen by the principal, in the store of the owner.
3. Default of the plan (of principal 0, then of the principal).
4. Default of the contract, which is the zero value.

Three rules make it hold. Neither study states the first.

- **The kept record holds only chosen values.** Each field is absent (zero) until the principal sets it. `Kept_Settings` of today is a full record: it keeps each default as if the principal chose it. A later default of the plan then changes nothing. That is tattooing by the owner itself. The enum member 0 is already "default" (property 13, ZII), so the form exists.
- **A lock writes nothing.** Under a lock the setter refuses, and the chosen value stays kept. When the lock ends, the chosen value holds again.
- **An apply never resets a chosen value.** The state export of the owner gives the layer of each value, so a reader sees that a choice hides a default.

One more export per setter group: `reset`, which makes a value absent. An absent Optional parameter means "no change", so it cannot mean "not chosen".

The plan layers reach the owner as one typed record at its start, on a page that nobody writes after the start. Such a page is recorded once, as the context is, and needs no point copy (property 24).

The slot of the lock costs nothing. Its code waits for a use: several principals, or a kiosk.

### 5.4 The global settings page

**Decision: the page ends for windows.** The display gives each window a presentation record on its window ring, beside the work area.

The first reason is not the fingerprint. It is that presentation is a fact of a surface, and only the holder of the display knows it:

- One page cannot give two scales to two screens, or a scale to a viewer of the remote display.
- A nested compositor or a membrane (property 23) must be able to give its own values. A fixed page that each window maps passes around each interposed holder.
- The window ring is already a recorded channel. The page is one more point copy.

The fingerprint is the second reason, and B is right on the fact: the root service maps the page into each disk process with a window, and the page holds the pointer theme, the layout and eight ordered languages, which no window draws with.

What the decision must add to B:

- **The time zone.** The date page gives it to each window. Either the zone leaves the date page and the local time becomes a grant, or the design states that the zone is not hidden. This critique takes the second: a window shows the local time.
- **The language.** One resolved locale in the presentation record. The full list is a grant, for a process that sends it (a browser).
- **The layout** goes to the holder of the input only. **The pointer theme** goes to the holder of the display only.
- **The covert channel** of A stays: a change by a caller that is not the settings window is an act record, and the setter keeps a rate that is one constant of the contract.
- **The honest claim**: the record lowers the entropy that a window reads. It does not end the fingerprint.

The cost is real: `interface` and `drawing` read the page at a fixed address today. The record must reach them before the first frame.

### 5.5 Role replacement

**Decision: the store of a role belongs to the role, not to the module that holds it.** The root service gives the holder of a role the store of that role, in its scope. A new holder reads the objects of the old one through the record types of the contract.

- This is needed with no settings at all: `ROADMAP.md` already plans that "the grants of a role follow its holder" (`declarations.md`, line 134).
- It answers A's alternative 2 with no central keeper, and it answers the fault of 3.4.
- A setting of a role is an export of the role contract. The check of a holder then refuses a module that does not serve it, with no new rule.
- A setting that only one holder has (the gap of a tiling compositor) is an export of that module past the contract. Its value is an object of the same store with its own description, which another holder leaves in place.
- The conformance suite of a role gets one case per setting: set, stop the holder, start it, read. That case is the test that the bar edge and "do not disturb" fail today.

### 5.6 Schema evolution

- The key of a kept value is the name of its field in the description of the kept record. `data_evolution.md` derives a migration from names. No index is a key.
- An owner that reads a description that it does not know reads the newest earlier version of the object that it knows (property 9 keeps the versions), else the defaults. It writes nothing until the principal changes a value. This is the answer to B's rollback case: the values of version 1 are still in the store when version 1 comes back. The retention rule bounds it.
- A plan record that names a value that its owner lacks is refused whole, as A says. The cost that A does not state: a new image that removes a value refuses the plan of the principal at the next start. The difference of an upgrade must list each plan record that the new image refuses, before the principal accepts the upgrade.
- Before 1.0, a changed description gives the defaults, as today.

### 5.7 The dynamic cases

| Case | Decision |
|---|---|
| Conditional availability | The state export of the owner. No static condition |
| A list that the machine gives | The choices export of the parameter. The value is an identity |
| Per instance | The setter takes the instance first: `display.set_for(screen, scale = ...)`. It is an export of the owner, not of `settings` |
| A rule across values | One setter with both parameters. For a plan record, a pure check export that a call host runs at the apply. The setter and the border at the start call that same procedure: one body |
| A custom view | The view act of A |
| A stopped module | The description is read from the module file. The value is read by starting the module, as A says |
| A schema that a plugin brings at run time | Not designed. It has no first user |

The pure check is built with the first plan record that has a rule across its fields. The retention rule is that record: its three times have an order.

### 5.8 What the six faults need

| Fault | What it needs | Does it need a settings mechanism |
|---|---|---|
| The rule 07:00 to 19:00 in two packages | Delete one package. The log template asserts the copy that stays | No |
| Arm time 250 ms and 500 ms | One least arm time of the trusted display, in one contract. A dialog can arm longer: it names its reason and asserts that it is not under the least. Read why the plan dialog has 500 before any value changes; never lower either in the same change | No |
| Notification rate 1 000 and 500 | The default argument 1 000 of `queue_init` has no user but hides a second number. Remove the default argument. One constant in the contract of notifications | No |
| The literal 8 s and the range 1 to 60 s | One named default in the contract, asserted inside the range, and the post of the compositor passes through the border that checks the range. Then it is the first role setting of Display: a reader who needs more time has a reason that WCAG 2.2.1 states | Not for the fault. Yes for the setting |
| A restart of the compositor loses the bar edge and "do not disturb" | The compositor keeps one record in the store of its role, and reads it at its start. With A this fault waits for layers 2 and 3. With the owner as keeper it is the first layer | Only the store of the role |
| Deadlines of services read the test hang bound | Read each site to its cause. A wait for a peer that can stop needs the end of the peer, not a time. A wait that needs a time gets a named deadline in its contract, with its reason. Then `modustool check` refuses the test bound outside a test | No. And never a setting |

Five of the six are the first layer of A, "One fact, one number". A is right to put it first.

### 5.9 The 131 limits

A's result holds: none becomes a setting. Two remarks:

- 81 rows become "the budget of the process", and the budget is a number in the plan. Property 22 says that no task needs a number of an implementation. The answer must be stated: the module asks for its budget, the plan only bounds it, and the principal sees it as a cost in a difference.
- The classification is the work of `src/md/features/memory_without_a_bound.md`. It is evidence for this design, not a part of it.

## 6. The joint recommendation

1. A setting is an optional parameter of a setter export that names its getter. The module format gets no table for settings. The description of a parameter gets a range, a choices export and an instances export.
2. Each value has one owner, which keeps it, checks it and serves it. `settings` owns the values of its own contract only. The settings window is a client of the setters that its start grant set lists.
3. The store of a role belongs to the role. A new holder gets it.
4. A value has a setter, or it changes only through the plan. The three tests of section 5.2 draw the line, and the contract of the owner records the result.
5. One precedence: locked, chosen, default of the plan, default of the contract. The kept record holds only chosen values.
6. A window gets a presentation record from the display on its ring. The settings page ends for windows.
7. The plan carries typed records, one per owner, keyed by names. A pure check export validates a record at the apply.
8. A constant becomes a plan value or a setting only when a named use needs a second value.
9. No limit becomes a setting. No protection has a setting that lowers it. No deadline reads the bound of the tests.

The intent file `src/md/features/module_settings.md` must change before any code: the table, the three keepers, the role settings page and the policy page leave it.

## 7. The order of the work

Each layer adds one capability to a system that works.

1. **One fact, one number.** The four duplicates and the deadlines of section 5.8. No mechanism.
2. **The store of a role.** The compositor keeps the bar edge, "do not disturb" and the factor of the magnifier. The conformance case "set, restart, read".
3. **Only chosen values.** The kept record of `settings` holds absent fields. The state export gives the layer of each value. `reset`.
4. **The range and the choices export** in the description of a parameter. First users: the time of a notification, the fonts of the image.
5. **The presentation record** on the window ring, with one screen. Then the page leaves the windows. Then one scale per screen, with the instances export.
6. **The defaults of the plan**: one typed record per owner, read at the start. The field "the settings" of the plan in `declarations.md` becomes this. It needs the bounds of a plan and of its difference to page first, as A says.
7. **Plan-only values**, with the pure check. First user: the retention rule. Then the quotas, the restart bounds and the table `start_grant_sets` as the default of the image.
8. **Module settings**, with the browser.
9. **The lock**, when a use asks for it.

Layers 1 to 3 need no change of the module format and no change of the plan.

## 8. The questions that the owner must decide

1. **The store of a role.** Does a new holder of a role get the store of the old holder? Sections 5.2 to 5.5 stand on a yes. A no brings back the central keeper of A, with the fault of 3.4.
2. **The time zone and the scale as a fingerprint.** Is it accepted that each window reads the zone, the scale, the font and one locale? A no makes the local time a grant, and each window draws at a scale that it does not know.
3. **The retention rule.** Does a principal set the retention of its own stores, or principal 0 only? This is the open point of property 9. It decides whether a principal can lose its own history without principal 0.
4. **The network address.** Is it a fact that DHCP gives, with the plan as a fallback, or a value of the plan? It decides whether the first plan-only value needs a live apply.
5. **The arm time.** Is 500 ms for the plan dialog a decision or an accident? The fix of 5.8 keeps both numbers until this is answered.

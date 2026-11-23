# Module settings and machine policy

State: **Proposed, not built.** The prior art, the inventory of the constants and the classification of the limits are in [\`docs/research/module_settings_study.md\`](../../../docs/research/module_settings_study.md).

This file records how modus configures the choices of a principal and the policy of the machine, in every module, with no registry, with no policy written as a constant of the code, and with the dynamic cases: a setting that applies only in some conditions, choices that the machine gives, a setting for each instance of a device, an invariant across settings, a custom view.

## Purpose

- A principal changes each choice that is a taste (a font, a time, a speed of the pointer) in one place, while processes run, and the choice survives a stop.
- Principal 0 declares each policy of the machine (an address, a quota, a retention rule, a timeout of a remote client) in the plan, and sees its difference before it holds.
- A module states each of its settings once. The console, the palette, the settings window, the manual and the check of a plan read that one statement.
- A number that bounds memory or work is never a setting. The principal cannot know it (property 22).

## Constraints

- [\`docs/PROPERTIES.md\`](../../../docs/PROPERTIES.md), "8. No global, mutable, shared file system": no registry, no shared configuration directory.
- "9. A storage engine with one private store per process": a value lives in the store of one process, and only that process changes it.
- "11. Reproducible system": the system is a list of hashes. A value of a setting changes no hash.
- "12. Module metadata in flat tables, read through functions": a description is flat records of fixed size, valid when zero.
- "14. Memory is supplied by the caller": a list of choices is written into memory of the caller.
- "19. A command is a function: no text between processes": no configuration text that a process parses.
- "20. No ambient access": reading a value needs a grant; a sandbox writes nothing that another sandbox reads.
- "21. Principals": a choice belongs to a principal; machine policy belongs to principal 0.
- "22. General mechanisms, and a plain expression for each frequent task".
- "23. A role is a contract; its implementation is replaceable": a principal who replaces the holder of a role keeps its choices for that role.
- "24. Every input of a process passes through a channel that can be recorded".

## The three kinds of value

| Kind | Example | Who changes it | When it holds | Keeper |
|---|---|---|---|---|
| **Role setting** | the font, the appearance, the time of a notification, the double press time, the rate of speech | the principal, through a caller that acts for it | at once | the process \`settings\`, per principal and per role |
| **Module setting** | the home page of the browser, the refresh of the monitor | the principal, through a caller that acts for it | at once | the module itself, in its private store |
| **Machine policy** | the address of the network, the quota of a store, the retention rule, the restarts of a service, the budget of a guest | principal 0 (or a principal, for its own stores and grants), through the plan | at the next start of the process that reads it | the plan, applied by the root service |

Two other kinds are not settings and get no description:

- **State**: what a process keeps for itself (the size of its window, its last tab).
- **Limits**: the capacity of a table or the size of a text. It is a budget, a length in a region, or a fact of the machine (the screen, the disk, the processors). [\`docs/research/module_settings_study.md\`](../../../docs/research/module_settings_study.md), section 4, classifies the 131 class C limits of the audit: none becomes a setting.

## The chosen form

### One description, in the module file

A module that has settings or policy has one more flat table, \`Settings\`. One record describes one setting:

- its name, one line of help, its kind (role setting, module setting, machine policy), its group in the view;
- its value: the parameter of a setter export and the getter export of that parameter. The type, the enum and its display texts, the integer unit, and the absent word of an optional parameter are already in the description of the export ([enum_parameters.md](enum_parameters.md)). The record adds the range of an Integer, the default, and for a machine policy the floor and the ceiling that the contract allows;
- its **sources of live data**, each an index of an export of the same module, 0 for none:
  - the **state export**: for each setting, available, not applicable with its reason, absent device, fixed by policy, and the range in force;
  - the **choices export**: a table of the choices that the machine gives now, each with its identity and its display text;
  - the **instances export**: a table of the instances (displays, keyboards, stores), each with its identity and its display text;
  - the **view act**: an act of the module that opens its own window for the setting;
- one simple **condition**: "applies when setting S holds member M", for a reader that does not run the module.

Why this form:

- The static table never holds a dynamic list. It names the export that gives it. So the description is complete for a reader that does not start the module, and the live data is always from the process that knows it.
- The value is a parameter of an export that exists. The console, the palette and \`modustool call\` need nothing new to set it.
- A setting of a role is part of the role contract ([roles_and_contracts.md](roles_and_contracts.md)): the contract is a description in the module format, so it holds the table \`Settings\` of the role. A holder fills the contract only when it serves each setting of the role.

### Role settings: the process \`settings\` keeps them

- The process \`settings\` keeps the values of each setting of each role, per principal, in its private store. The key of a value is the role, the index of the setting in the role contract, and the identity of an instance or none.
- It gives each holder of a role a **role settings page**: read-only, at a fixed range, with the change count of the settings page of today ([\`docs/FONTS.md\`](../../../docs/FONTS.md), "7. The setting"). The settings page of today becomes the page of the role Display.
- Why the process \`settings\`, and not the holder. A principal who replaces the compositor keeps its time of notifications. A value in the store of the old holder would be lost with it: a new module has another store.
- Why this is no registry. The set of keys is closed: the roles are a closed list (property 23), and each role contract lists its settings. No module writes a key of its choice. Each value has one writer, \`settings\`, and each page one kind of reader, the holder of its role.

### Module settings: the module keeps them

- An application keeps its own settings in its private store, serves its setter and its getter, and draws its own window for them.
- The settings window lists the applications that the plan names for it, by the start grant set of the window (\`callable\`), and calls their exports. It never discovers a module at run time (property 23).
- A module that does not run: the window reads the description from its module file and shows the default. A setter call starts the module as a service when its start grant set says \`on_demand\`.

### Machine policy: the plan holds it

- A declaration names a policy by its module and its setting: \`plan { policy = { storage = { keep_all_minutes = 30 }, network = { address = "192.168.1.20/24" } } }\`. The evaluation types each value by the description of the module, at the border of the plan.
- The plan holds typed rows: the hash of the module or the role, the index of the setting, the instance, the value. The root service checks each row against the description and refuses a row that names no setting, a value out of the range, or a value under the floor of the contract. A plan with one refused row changes nothing.
- \`plans.apply\` shows each changed policy in the difference on the trusted display ([declarations.md](declarations.md), "Apply, the difference and the rollback"). A rollback restores the policy of the older plan.
- The root service gives each process a read-only **policy page** at its start, with the rows of its module. The process reads each value through one border at its start. A change holds at the next start, as each other part of a plan.
- The signed boot image gives the default policy, as it gives the default holder of each role. The table \`start_grant_sets\` and the budget rows of the root service become that default ([../api/root_service_split.md](../api/root_service_split.md)).

### The order of the values

For a role setting: the default of the role contract, then the default that the plan of principal 0 gives to each principal, then the value of the principal. A policy of principal 0 can **fix** a role setting: the setter refuses a change with \`No_Grant\` and names the policy, and the state export says "fixed by policy". That is the lock of dconf and the forced value of an MDM profile, with one source.

For a machine policy: the default of the boot image, then the plan of principal 0, then, for the stores and the grants of a principal only, the plan of that principal inside the bounds of principal 0.

## The dynamic cases

- **Conditions.** The description holds one simple condition. Each other condition is in the state export. A setting that does not apply keeps its value.
- **Choices that the machine gives.** The value is the identity of the choice (a hash of a font file, the identity of an output), never its place in a list. A kept identity that the list does not hold shows as absent and keeps its value; the owner draws with its default.
- **Instances.** An instance is a stable identity that the owner computes from its device. The setter takes it as its first argument. The values are in an arena of the keeper: no count is fixed.
- **Invariants.** The owner checks them, at one border. Two settings that one invariant binds are optional parameters of one setter, so a principal changes both in one call, or neither. The error record names the other setting.
- **Evolution.** Kept values follow [data_evolution.md](data_evolution.md). A setting that a new holder removes is a stated loss of its migration. A plan that names a setting that its module lacks is refused, never ignored.
- **Custom views.** The view act opens the window of the owner. The settings window draws no view of another process.

## Frequent tasks

| Task | Expression |
|---|---|
| Change a role setting | \`settings.set(font = .spleen)\` |
| Change two bound settings | \`settings.set(light_from = 6:30, dark_from = 20:00)\` |
| Change a setting of one display | \`settings.set_for(display.screens() \|> first(1), scale = .sixteen_eighths)\` |
| See every setting of a module, with its state | \`settings.describe("compositor")\` |
| Set a module setting | \`browser.set(home = "modus://guide")\` |
| Set a policy | \`plan { policy = { storage = { keep_all_minutes = 30 } } } \|> plans.apply\` |
| Fix a setting for every principal | \`plan { policy = { display = { appearance = fixed(.dark) } } }\` |

The names of these exports are proposed. Each is a short form of the setter and the getter that the description names.

## Check against the properties

| Property | Result |
|---|---|
| 2, 20 | Kept. A setter serves only a caller that acts for the principal. A getter needs a connection that a start grant set lists. The role settings page is a read-only grant to the holder of its role only |
| 8 | Kept. The keys of \`settings\` are closed by the role contracts; module settings stay in their module; policy is in the plan, an immutable value with a hash |
| 9 | Kept, with a cost. Only \`settings\` reads the store of \`settings\`. A module setting of a stopped module is readable only by starting it |
| 11 | Kept. A setting changes no hash. A policy is a part of the plan, which has a hash and a rollback. Two machines with the same list behave differently with different settings, as with different documents: a setting is data of a principal, not code |
| 12 | Kept. \`Settings\` is a flat table of fixed records. Each dynamic part is an export |
| 14 | Kept. Choices and instances are written into memory of the caller |
| 19 | Kept. No configuration text. Lex is the text between the principal and the console only |
| 20, line 17 | **Tension.** A caller that acts for the principal (an agent console with a wide grant) can change a role setting at a rhythm that each process with a surface sees: a one-way channel from a process that reads documents to a sandboxed process that holds the network. Answers: each change by a caller that is not the window of \`settings\` is an act record of the collector ([wide_grants.md](wide_grants.md)); the change redraws the desktop where the principal sees it; the setter keeps a rate for such callers. The rate is a policy with a floor in the contract |
| 20, fingerprint | **Cost.** Each process with a surface reads the font, the scale and the languages. A role page holds only the values that its readers draw with |
| 21 | Kept. Role settings are per principal. Machine policy is principal 0. Layer 4 (several principals) gives each session its own role pages |
| 22 | Kept. One mechanism: a description and an export. Each frequent task is one expression above |
| 23 | Kept, and needed. Settings of a role are in its contract, so a replaced holder keeps the choices of the principal. A holder that does not serve a setting of the contract does not get the role |
| 24 | Kept. A role settings page and a policy page are pages that another party writes and the process maps without Write: they join the row of the settings page in the table of property 24 |

## Alternatives

1. **One central store of every setting of every module.** The process \`settings\` keeps the values of each module, keyed by the module and the setting, and gives each module a page. It shows each value of a stopped module, and the window is simple. Refused as the whole design: \`settings\` would hold an open set of keys that any module defines, which is a registry under another name; the values of an application would leave its store (property 9); \`settings\` would read the descriptions of foreign modules for each key. Kept for the closed set of the role settings only.
2. **Each owner keeps everything, roles too.** No central process. Simplest. Refused: a principal who replaces the holder of a role loses each choice for it (property 23).
3. **Everything in the plan.** One mechanism, a hash, a rollback. Refused for the choices of a principal: a change of a font would need a dialog on the trusted display and a restart. Kept for machine policy.

## Refused forms

- **A mutable registry, a tree of keys, dconf.** Property 8; and the inventory shows the faults of a shared place: values that outlive their writer, any writer for any key.
- **A text configuration file that a process reads.** Property 19, and [start_policy.md](start_policy.md).
- **Environment variables.** Property 19. The variables of \`modustool assistant\` are of the host and never reach the machine.
- **A free key-value bag.** No type, no range, no view: each reader parses and guesses.
- **The dynamic data in the static description.** A list of fonts or of displays in the module file is wrong on the first machine that differs.
- **A choice stored as its place in a list.** A place moves when the list changes.
- **A setting for a limit.** A limit is a budget, a length or a fact of the machine. A principal cannot choose a number of an implementation.
- **A setting that lowers a protection.** The arm time of the trusted display, the tries of the TPM, the bounds of property 9: each is a floor of a contract. A setting may only raise an arm time, for a principal who needs more time.
- **A test bound as a deadline of a service.** The hang bound of the tests ends a hang in a test. A deadline of a service is a constant of its contract, with its own name.

## Subtle points

- **One fact, one number.** The inventory found one rule in two packages (07:00 to 19:00), one protection with two values (250 ms and 500 ms of arm time), one rate with two values (500 ms and 1 000 ms), and a contract range of the time of a notification that no code reads. A setting has one description, and its default is in it.
- **A choice that a restart loses is a fault.** The edge of the bar and "do not disturb" are role settings of Display.
- **The value of an absent choice stays.** A display, a keyboard or a font that comes back gets its value back.
- **A policy row is refused whole.** A plan that names a setting that its module does not have is refused, with the name of the row. A tolerant reader would leave a policy that the principal thinks holds.
- **The difference of a plan must page.** Each policy row is one more item of the difference. The bound of 8 items on each side ([declarations.md](declarations.md)) must go before policy rows come, or a policy change is refused with \`Display_Refused\`.

## Layers

1. **One fact, one number.** Move each duplicate of the inventory to one contract constant. Part the deadlines of services from the hang bound of the tests. No new mechanism.
2. **The table \`Settings\`** in the module format, read by the console, the palette and the manual. The settings of \`settings\` of today get their rows.
3. **Role settings of Display** past the page of today: the time of notifications, the edge of the bar, "do not disturb", the double press, the wheel, the factor of the magnifier, the hours of \`auto\`. The process \`settings\` keeps them; the compositor reads its page.
4. **The state, choices and instances exports**, with the first users: the fonts of the image, the displays of the machine.
5. **Module settings** with the first user: the browser.
6. **Machine policy in the plan**, after the bounds of a plan and of its difference become pages. First users: the retention rule, the quota of a store, the restart bounds, the network address. Then the table \`start_grant_sets\` and the budget rows as the default policy of the image.
7. **The lock of a role setting** by a policy of principal 0.

## Open questions

1. **Locks.** Is a role setting that principal 0 fixes needed before layer 4 (several principals)? On a machine with one principal, the lock fixes a choice of that principal against itself.
2. **The rate of an agent.** Which rate of changes of a role setting by a caller that is not the window of \`settings\`, and is it one policy of the machine?
3. **A policy that holds at once.** Each policy holds at the next start of its process. Is a live change of one policy needed (the network address), or is a restart of the service enough?
4. **The network.** Does the address come from the plan, or from DHCP with the plan as a fallback?
5. **A principal's own policy.** Which policies may a principal set in its own plan (the quota of its stores, the retention of its versions), inside the bounds of principal 0?
6. **The text of a setting.** The help line of each setting needs translations ([interface_language.md](interface_language.md)): one more use of the table \`Member_Texts\`, or a table of its own?
7. **New terms.** Role setting, module setting, machine policy, role settings page and policy page need entries in \`docs/glossary/\` before their first use in a guide.

## State

Proposed, not built. Built today: the settings page, the setter and the getters of \`settings\` with Enum parameters, the kept record, the plan without its field of settings.

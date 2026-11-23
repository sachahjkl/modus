# Settings and policy across the system: prior art and the state of modus

Status: research note, 2026-11-23. Sources were fetched on that date unless marked UNVERIFIED. "Inference" marks a deduction of this note from verified facts. The design that this note supports is the proposed intent file [\`src/md/features/module_settings.md\`](../../src/md/features/module_settings.md).

| Key | URL |
|---|---|
| GSET | https://docs.gtk.org/gio/class.Settings.html |
| GSCH | https://docs.gtk.org/gio/struct.SettingsSchema.html |
| GKEY | https://docs.gtk.org/gio/struct.SettingsSchemaKey.html |
| DLOCK | https://help.gnome.org/system-admin-guide/dconf-lockdown.html |
| WREG | https://learn.microsoft.com/en-us/windows/win32/sysinfo/about-the-registry |
| WGPO | https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/group-policy/group-policy-overview |
| WADMX | https://learn.microsoft.com/en-us/windows/client-management/understanding-admx-backed-policies |
| WCS | https://learn.microsoft.com/en-us/troubleshoot/windows-client/group-policy/create-and-manage-central-store |
| APREF | https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFPreferences/Concepts/PreferenceDomains.html |
| AMDM | https://support.apple.com/guide/deployment/intro-to-device-management-depc0aadd3fe/web |
| NIXOS | https://nixos.org/manual/nixos/stable/ ("Writing NixOS Modules", options, types, freeform submodules, the \`settings\` option convention) |
| FSC | https://fuchsia.dev/fuchsia-src/development/components/configuration/structured_config |
| FSCREF | https://fuchsia.dev/fuchsia-src/reference/components/structured_config |
| FCAP | https://fuchsia.dev/fuchsia-src/concepts/components/v2/capabilities/configuration |
| ADS | https://developer.android.com/topic/libraries/architecture/datastore |
| APS | https://developer.android.com/develop/ui/views/components/settings |
| ASEC | https://developer.android.com/reference/android/provider/Settings.Secure |
| AGLOB | https://developer.android.com/reference/android/provider/Settings.Global |
| P9ENV | https://9p.io/magic/man2html/3/env |
| P9FAC | https://9p.io/magic/man2html/4/factotum |
| P9NS | https://9p.io/sys/doc/names.html |
| P9CFG | https://9p.io/wiki/plan9/configuring_a_standalone_cpu_server/index.html |
| HBM | https://www.haiku-os.org/docs/api/classBMessage.html |
| HPREF | https://www.haiku-os.org/docs/userguide/en/preferences.html |
| AUDIT | \`docs/research/limits_audit.md\` on \`master\` |

## 1. The question

The owner asked how modus configures policy and preferences across the whole system:

- with no global mutable registry ([\`docs/PROPERTIES.md\`](../PROPERTIES.md), "8. No global, mutable, shared file system");
- with no policy constant hardcoded in dozens of modules;
- with no loss of the dynamic cases: a setting that applies only in some conditions, a list of choices that the machine gives at run time, a setting for each instance of a device, an invariant across two settings, a custom view.

The short answer of this note:

1. **Most hardcoded numbers are not settings.** Of the 131 class C rows of AUDIT, none becomes a setting of a principal. 81 become a budget (an arena that the budget of the process pays), 25 become a text or a table of variable length, 10 come from the machine or the device in force, 3 become plan policy, 3 become options of a tool of the host, 9 refuse no use today. Section 4 classifies each row.
2. **The real settings are few, and three kinds.** A choice of a principal for a role of the system (font, appearance, notification time). A choice of a principal inside one application (the home page of the browser). A policy of the machine (the address of the network, the retention of versions, the quota of a store). Section 3 lists 61 constants of these kinds that the code holds today.
3. **A static description in the module file does not break the dynamic cases**, on one condition: the description names *where* the dynamic part comes from (an export of the owner), and never holds the dynamic data itself. Section 6 checks each case.

## 2. What modus has today

- **The settings page** ([\`docs/FONTS.md\`](../FONTS.md), "7. The setting"): one page that the root service creates. The process \`settings\` is its one writer. Each process with a surface maps it read-only. It holds 7 enum values, a time zone, 8 languages and the appearance in force.
- **The setter and the getters**: \`settings.set(font, ..., scale)\` with one optional Enum parameter for each setting, and a getter export for each, which the parameter names (\`src/md/features/enum_parameters.md\`). The palette builds a row of buttons from this description, with no list of its own. **This is already a static schema in the module metadata**, and it works.
- **The kept record**: \`Kept_Settings\`, version 3, one object of the private store of \`settings\` (\`src/library/modus/contract/settings/settings.odin:775\`). A record of another version gives the defaults. \`src/md/features/data_evolution.md\` gives the rule after 1.0: the object carries its description, and a migration is derived or declared.
- **The plan** (\`src/md/features/declarations.md\`, "The plan"): it lists "the settings, each a member of \`Setting\` with its value" as a field. That field is not built.
- **The start grant sets** (\`src/modules/system/root/start_grant_sets.odin\`): a table in the source of the root service. It holds grants, and also store quotas (\`store_blocks\`), terminal sizes, and the list of the services that a process can connect to. \`src/md/api/root_service_split.md\` already plans to move it out of the code of the root service.

What is missing:

- Settings that are not on the page (notification time, bar edge, double press, speech rate) are constants of the code, or state that a restart loses (the edge of the bar, "do not disturb").
- Policy of the machine (network address, retention, quotas, timeouts) is constants of the code.
- No form describes a setting whose choices or instances come from the machine.

## 3. The inventory of the policy and preference constants

The classes of this section:

- **(a) Principal setting**: a choice of the principal, changed while processes run, kept across a stop.
- **(b) Machine policy**: a decision for the whole machine or for one principal, declared in Lex, applied with its difference on the trusted display. It takes effect at the next start of the process that reads it.
- **(c) Contract or safety constant**: a value that must stay in the code. A change of it is a change of a contract, of a property, or of a protection against an attacker.
- **(s) State**: a value that a process keeps for itself in its store (the size of a window, the last tab). It is not a setting and needs no description.

Each line was read in the worktree at its \`file:line\`.

### 3.1 Appearance, desktop and input

| Class | Where | Name | Value | Why this class |
|---|---|---|---|---|
| (a) | \`src/library/internal/settings/appearance/appearance.odin:17-18\` | \`LIGHT_FROM_SECOND\`, \`DARK_FROM_SECOND\` | 07:00, 19:00 | The rule of \`auto\` is a taste and a latitude. A pair with an invariant (light before dark), the example of section 6.4 |
| (a) duplicate | \`src/library/internal/settings/appearance_rule/appearance_rule.odin:17-18\` | \`LIGHT_START_SECOND\`, \`DARK_START_SECOND\` | 07:00, 19:00 | A second copy of the same rule. A fault today: two values of one fact. The log template asserts the first copy only (\`src/modules/system/settings/facts.odin:30\`) |
| (a) | \`src/modules/system/compositor/desktop_features.odin:1090\` | literal \`8_000\` in \`queue_post\` | 8 s | The time that a notification shows. The contract already states its range: \`NOTIFICATION_MIN_TTL_MS\` and \`NOTIFICATION_MAX_TTL_MS\`, 1 s to 60 s (\`src/library/modus/contract/desktop_layout/desktop_layout.odin:34-35\`), and nothing reads it |
| (a) | \`src/library/modus/contract/notifications/notifications.odin:73\` | \`do_not_disturb\` | false at each start | A choice of the principal that a restart of the compositor loses |
| (a) | \`src/modules/system/compositor/desktop_features.odin:49\` | \`desktop_bar_position\` | \`.Top\` at each start | The edge of the bar: chosen in a menu, lost at a restart |
| (a) | \`src/modules/system/compositor/desktop_features.odin:120\` | magnifier factor \`16\` | 2× | The zoom of the magnifier. Its range is a contract: \`ASSISTIVE_MAGNIFY_FACTOR_LEAST\`, \`_MOST\` 12 to 64 eighths (\`src/library/internal/compositor/bar/assistive.odin:204-205\`) |
| (a) | \`src/library/internal/compositor/bar/title_press.odin:11,16\` | \`DOUBLE_PRESS_MILLISECONDS\`, \`PRESS_STILL_DISTANCE\` | 400 ms; 4 px | Double press time and distance: an accessibility setting in each desktop of today |
| (a) | \`src/library/modus/interface/scroll_bar.odin:79\` | \`SCROLL_WHEEL_LINES_PER_NOTCH\` | 3 | Lines for one notch of the wheel |
| (a) | \`src/library/modus/graphics/scroll_bar.odin:25-26\` | \`SCROLL_BAR_REPEAT_AFTER\`, \`SCROLL_BAR_REPEAT_EVERY\` | 400 ms; 60 ms | The repeat of a held button. The same choice as the repeat of a held key, which the input service does not have yet |
| (a) | \`src/library/modus/contract/speech_output/speech_output.odin:24,29\` | \`SPEECH_RATE_DEFAULT\`, \`SPEECH_PITCH_DEFAULT\` | 100 %, 100 % | The default of the speech role. The range (\`:22-23\`, \`:27-28\`) is (c) |
| (a) default | \`src/library/modus/contract/scale_factor/scale_factor.odin:41\` | \`DEFAULT\` | 1.25 | The value of a new principal. The setting exists. The default is (b): principal 0 can choose it for a new principal |
| (a) | \`src/library/modus/contract/wide_grants/wide_grants.odin:23\` | \`DEFAULT_WIDE_GRANT_DURATION_MS\` | 1 h | The duration that the dialog of a wide grant offers first |
| (b) | \`src/library/modus/contract/wide_grants/wide_grants.odin:20\` | \`MAX_WIDE_GRANT_DURATION_MS\` | 24 h | The longest grant: a policy that principal 0 lowers. Never raised past a value of the contract |
| (c) | \`src/library/modus/graphics/rules.odin:12-22\` | \`GAP\`, \`MARGIN\`, \`TEXT_*\` | 8, 16, 14 to 48 | Design tokens. The size of text for a reader is the scale setting (\`src/md/features/accessibility.md\`), not a second setting of each token |
| (c) | \`src/library/internal/compositor/bar/window_free_place.odin:20-24\` | \`CASCADE_*\` | 64, 56, 40, 32 | Design of the placement |
| (c) | \`src/library/modus/graphics/forced_colors.odin:16-17\` | WCAG ratios | 7:1, 4.5:1 | An outside standard |
| (s) | \`src/modules/system/root/start_grant_sets.odin:44-45\` | \`TERMINAL_COLUMNS_DEFAULT\`, \`TERMINAL_ROWS_DEFAULT\` | 96 × 26 | The first size of a terminal. A resized terminal keeps its size as state of its window |

### 3.2 Policy of the trusted path

| Class | Where | Name | Value | Why this class |
|---|---|---|---|---|
| (c) floor | \`src/library/internal/powerbox/powerbox_core/powerbox_core.odin:51\` | \`MIN_DISPLAY_ARM_MILLISECONDS\` | 250 ms | A protection against a press that a process places before the dialog shows. A setting that lowers it is an attack |
| (c) floor | \`src/library/modus/contract/plans_recipes/private_store.odin:172\` | \`PLAN_DISPLAY_ARM_MILLISECONDS\` | 500 ms | The same protection for the dialog of a plan, with another value. A fault: one concept, two numbers. One arm time of the trusted display, in one contract |
| (a) above floor | the two above | — | — | A principal with a slow hand can ask for a longer arm time. The setting takes values at or above the floor only |
| (b) | \`powerbox_core.odin:54,57,61,65\` | \`RATE_LIMIT_MILLISECONDS\`, \`DIALOG_EXPIRY_MILLISECONDS\`, \`QUIET_TIME_AFTER_REFUSAL_MILLISECONDS\`, \`MAX_WHOLE_REFUSALS_PER_RUN\` | 500 ms; 60 s; 60 s; 3 | How much a process may ask the principal. A policy, with a floor in the contract |
| (b) | \`src/modules/system/compositor/desktop_features.odin:119\` | \`min_interval_ms = 500\` | 500 ms | The rate of notifications of one source. The contract default is 1 000 ms (\`notifications.odin:95\`): two values again |
| (b) | \`src/library/modus/contract/notifications/notifications.odin:18\` | \`CARDS_PER_SOURCE_LIMIT\` | 3 | Cards of one source at once |

### 3.3 Storage, network and remote access

| Class | Where | Name | Value | Why this class |
|---|---|---|---|---|
| (b) | \`src/library/internal/storage/storage_retention/retention.odin:13-15\` | \`KEEP_ALL_MILLISECONDS\`, \`HOUR_MILLISECONDS\`, \`DAY_MILLISECONDS\` | 10 min, then hourly for a day, then daily | The retention rule. [\`docs/PROPERTIES.md\`](../PROPERTIES.md), "Persistence", leaves "who sets the retention rule" open. Answer: the plan, for each principal, with the store as an instance |
| (c) | \`src/modules/system/storage/engine.odin:27\` | \`RETENTION_INTERVAL\` | 60 s | The cost of the rule, not the rule |
| (b) | \`src/modules/system/root/start_grant_sets.odin:43\` and the \`store_blocks\` terms of its rows (\`:95\`, \`:109\`, \`:202\`, \`:268\`, \`:277\`) | \`STORE_BLOCKS_DEFAULT\` and quotas | 64 blocks; 3 to 12 000 | The quota of each private store: a decision of principal 0 |
| (b) | \`src/modules/system/network/main.odin:90-93\` | \`LOCAL_ADDRESS\`, \`GATEWAY_ADDRESS\`, \`PREFIX\`, \`NETWORK_MASK\` | 10.0.2.15/24 via 10.0.2.2 | The network of the machine. A policy of the plan, or a fact that DHCP gives |
| (b) | \`src/library/modus/contract/remote/remote.odin:45,51\`; \`remote_display/remote_display.odin:35\` | \`LISTEN_PORT\`, \`HOST_ADDRESS\` | 7100, 7101; 10.0.2.2 | Where the remote services listen, and the one host that they admit |
| (b) | \`src/modules/system/root/network.odin:25\` | \`QUIC_ECHO_PORT\` | 4433 | A port of a demonstration |
| (b) | \`src/modules/system/remote/main.odin:135,142-149,163\`; \`remote_display/main.odin:113\` | \`IDLE_TIMEOUT_MILLISECONDS\`, \`REQUEST_TIME_LIMIT\`, \`ANSWER_TIME_LIMIT\`, \`RELEASE_TIME_LIMIT\`, \`CALL_LIMIT\` | 30 s; 10 s; 5 s | How long a remote client may hold a connection or a call |
| (b) | \`src/library/modus/quic/server.odin:111\` | \`SERVER_LIMITS_DEFAULT\` | 15 rates | Limits of a QUIC server against a flood. A default of the library; the server that uses it reads its policy |
| (c) | \`src/library/modus/tcp/tcp.odin:39-50\` | \`RTO_*\`, \`RETRIES\`, \`DELAYED_ACK\`, \`TIME_WAIT\` | RFC 6298, 9293 | Values of the standards, with one reasoned change (\`RTO_LEAST\`) |
| (c) | \`src/library/modus/quic/connection.odin:49-83\` | QUIC constants | RFC 9000, 9002 | Standards |
| (c) | \`src/modules/system/date/main.odin:184\` | \`RESYNC_MILLISECONDS\` | 10 s | The cost of a read of the clock |
| (c) | \`src/modules/system/root/entropy.odin:40-41\` | \`FRESH_BYTES_PERIOD_MILLISECONDS\`, \`FRESH_BYTES_REFUSALS_LIMIT\` | 30 s; 3 | A mechanism of security |

### 3.4 Start, budgets and supervision

| Class | Where | Name | Value | Why this class |
|---|---|---|---|---|
| (b) | \`src/modules/system/root/start_grant_sets.odin\` (the whole table \`start_grant_sets\`) | grants, \`callable\`, \`on_demand\`, \`asks_acts\` | one row per module | The authority of each process of the image. It is the default plan of the signed image (property 23: "the signed boot image gives the default holder of each role"). The plan of principal 0 changes it with a difference. The table stays as the default; it leaves the source of the root service (\`src/md/api/root_service_split.md\`) |
| (b) | \`src/modules/system/root/budgets.odin:25,69\` | \`LEAST_BUDGET\`, \`budget_exceptions\` | 2 048 pages; 3 rows | A budget written as code (AUDIT: D-const) |
| (b) | \`src/library/modus/contract/module/format.odin:517\` | \`LARGEST_BUDGET_PAGES\` | 16 384 pages | The largest budget that a module may ask for (AUDIT, rank 2) |
| (b) | \`src/modules/system/root/budgets.odin:51\` | \`LOG_RECORDS_OF_LIMITS\` | 40 per s | A log rate written for one module |
| (b) | \`src/modules/system/root/devices_delegation.odin:34\`; \`disk_processes_delegation.odin:44\`; \`wirings.odin:34\`; \`principals.odin:72\`; \`principals_delegation.odin:40\` | \`*_RESTART_LIMIT\` | 3 | The restarts of a delegated service. The start list already has a restart bound for each row (\`start_list.RESTART_LIMIT\`): these rows join it |
| (b) | \`src/modules/system/linux/main.odin:36\`; \`guest_builder/main.odin:38-39\`; \`guest_builder.odin:39-47\`; \`guest_registers.odin:9\` | guest memory, disks, processors | 128 MiB to 1 GiB; 4 | Budgets of a guest: a term of the plan or of the recipe (AUDIT: D-const) |
| (c) | \`src/library/modus/contract/operation/operation.odin:1395\` | \`REQUEST_DEFAULT\` | 3 000 µs | A contract of the scheduler. The strategy itself is not a setting ([\`docs/FONTS.md\`](../FONTS.md), "7. The setting"); its choice across a stop is (b) |
| (c) | \`src/modules/system/root/main.odin:485\` | \`SHORTAGE_KEEP\` | 24 pages | The reserve of the root service |
| (c) fault | \`src/library/modus/system/test_bounds.odin:14\` used by \`answer_wait.odin:15\`, \`entropy_read_deadline.odin:10\`, \`devices_delegation.odin:38\`, \`wirings.odin:37\`, \`start_policy.odin:60\`, \`plans/roles.odin:18\`, \`gpu_device/main.odin:47\`, \`sound/main.odin:90\`, \`wiring_core.odin:45\` | \`TEST_HANG_BOUND_MILLISECONDS\` | 60 s | A bound of the tests serves as a deadline of production code. The two concepts must part: an answer deadline of a contract (c, one name per contract), and the hang bound of the tests. Neither is a setting: a principal who tunes a timeout fixes nothing |
| (c) | \`src/modules/system/tpm/main.odin:92-113\` | \`STEP_BOUND_MILLISECONDS\`, \`REQUEST_BOUND_MILLISECONDS\`, \`UNSEAL_TRIES\` | 120 s; 300 s; 3 | The TPM: a device bound and a protection against guessing |

### 3.5 Applications

| Class | Where | Name | Value | Why this class |
|---|---|---|---|---|
| (a) module | \`src/modules/demonstrations/browser/pages.odin:103\` | \`HOME_ADDRESS\` | \`modus://welcome\` | The home page of the browser: a setting of one application |
| (a) module | \`src/modules/system/monitor/main.odin:79\` | \`INTERVAL\` | 500 ms | The refresh of the monitor |
| (c) | \`src/library/internal/notes/note_list/note_list.odin:24,28\`; \`src/library/internal/paint/paint_model/paint_model.odin:832-833\` | pause and longest wait | 1 s; 5 s | The bound of property 9 ("a stop loses at most 5 seconds"). A setting would break a property |
| (c) | \`paint_model.odin:906\` | \`KEEP_RETRY_MILLISECONDS\` | 5 s | The same bound |
| (c) | \`src/modules/system/compositor/main.odin:163\`; \`terminal/main.odin:183\` | \`FRAME_INTERVAL\`, \`FRAME_TIME\` | 16 ms | Must follow the refresh of the display in force: a fact of the device, not a choice |
| (host) | \`tools/modustool/agent_runner/model.odin:77-79\`, \`:190\`, \`:205\`; \`command.odin:16\` | \`MODUS_ASSISTANT_ENDPOINT\`, \`_KEY\`, \`_MODEL\`; \`MODEL_ANSWER_DEADLINE\`; \`SYSTEM_PROMPT\`; \`IDLE_PAUSE\` | variables of the host; 120 s; a text; 500 ms | The runner is a program of the host. Its endpoint and its key never reach the machine (\`src/md/features/assistant.md\`). They are options of \`modustool assistant\` and the keyring of the host, never a setting of modus |

### 3.6 Faults that the inventory found

1. **One fact, two numbers.** The rule of the day (07:00 to 19:00) is in two packages. The arm time is 250 ms in the powerbox and 500 ms in the plan dialog. The rate of notifications is 1 000 ms in the contract and 500 ms in the compositor. The time of a notification has a contract range that no code reads.
2. **A choice that a restart loses.** The edge of the bar, "do not disturb", the factor of the magnifier.
3. **A bound of the tests in production code.** Ten deadlines of services read \`TEST_HANG_BOUND_MILLISECONDS\`.
4. **A policy in the source of the root service.** Quotas, budgets, restart bounds and authority are in \`start_grant_sets.odin\` and \`budgets.odin\`.

## 4. The 131 class C limits of AUDIT

The question for each row: is the number a setting, a policy, or no number at all?

The targets:

- **BUD**: no number. The table grows in an arena that the budget of the process pays ([\`docs/PROPERTIES.md\`](../PROPERTIES.md), "14. Memory is supplied by the caller"). The budget of the process is the one bound, and its parent or the plan sets it.
- **TXT**: no number. A text or a table of variable length passes in a region, by pages or by ranges.
- **DER**: derived from the machine or the device in force: the screen, the disk, the memory, the processors.
- **POL**: machine policy in the plan (section 3, class b).
- **SET**: principal setting.
- **TOOL**: an option of a command of the host tool.
- **KEEP**: AUDIT notes that it refuses no real use today. It becomes BUD when its code changes.

**Result: no class C limit becomes a principal setting.** A limit that a principal must tune is a defect of the design: the principal cannot know the number (property 22: "No useful task needs knowledge of a detail of an implementation: a number").

### Kernel (15 rows)

| Row | Target | Note |
|---|---|---|
| \`PROCESS_SLOTS_OF_THE_MACHINE\` | DER | Kernel tables have a fixed size (property 13). The size comes from the memory of the machine at boot, with a reserve of address space |
| \`REGION_CAPACITY\` | DER | As above |
| \`THREAD_TABLE_CAPACITY\` | DER | As above |
| \`BUDGET_CAPACITY\` | DER | As above |
| \`HANDLE_TABLE_CAPACITY\` | BUD | Per process: property 20, line 16 |
| \`MAPPING_CAPACITY\` | BUD | Per process |
| \`THREAD_CAPACITY\` | BUD | Per process; the budget counts threads already |
| \`WORD_WAIT_CAPACITY\` | BUD | Per thread |
| \`PROCESS_MODULE_CAPACITY\` | BUD | Per process |
| \`PROCESSOR_CAPACITY\` | DER | The processors of the machine |
| \`LOG_PAGES\`, \`LOG_RECORD_CAPACITY\` | BUD | The log service pays its ring. How long the log keeps records is POL |
| \`REPLACEMENT_CAPACITY\` and rows | BUD | |
| \`DEBUG_IMAGE_LIMIT\` | BUD | |
| \`IOMMU_DEVICE_CAPACITY\` | DER | The devices of the machine |
| \`MAX_MIXER_STREAMS\`, \`MAX_CAPTURE_READERS\`, \`STREAM_LIMIT\` | BUD | The sound service pays each stream; the client lends its region |

### Root (21 rows)

| Row | Target | Note |
|---|---|---|
| \`CONNECTION_CAPACITY\` | BUD | |
| \`STARTED_CAPACITY\` | BUD | |
| start list \`ROW_CAPACITY\`, \`SUPERVISION_NODE_CAPACITY\` | BUD | Read by pages |
| \`PRINCIPAL_CAPACITY\` | BUD | How many principals the machine admits can be POL; the table itself has no number |
| \`NAME_LIMIT\`, \`PRINCIPAL_NAME_CAPACITY\`, \`NICKNAME_CAPACITY\` | TXT | |
| grant table \`ROW_CAPACITY\`, \`STORE_ROWS_LIMIT\` | BUD | Pages in the store of the principal |
| disk process page \`ROW_CAPACITY\`, \`KEPT_STOP_REPORT_*\` | BUD | |
| \`LIST_PAGE_ROWS\`, \`LIST_PAGE_LIMIT\` | BUD | A cursor |
| \`SCAN_*\` | BUD | |
| \`HOLDER_CAPACITY\`, \`LOCAL_BINDING_CAPACITY\` | BUD | |
| \`MAX_PLAN_ENTRIES\`, \`MAX_PLAN_DIFF_CHANGES\`, \`MAX_PLAN_CANONICAL_BYTES\` | BUD | A plan as a tree in the store. Settings and policy rows join the plan: this bound must go first |
| \`PLAN_ROLES_OVERRIDE_CAPACITY\` | BUD | |
| \`PLAN_DIFFERENCE_ITEM_CAPACITY\`, \`_BYTES\` | TXT | A difference that pages. Policy rows add items to each difference: this bound must go first |
| wiring capacities | BUD | |
| \`DEBUG_OBJECT_BYTES_LIMIT\` | BUD | |
| \`MAX_TARGET_WINDOWS\`, collector spaces | BUD | |
| \`SETTING_CAPACITY\`, \`LANGUAGE_LIST_CAPACITY\` | KEEP | The design of the intent file replaces the fixed record of 8 values |
| notification sizes | TXT | |
| \`MAX_REQUEST_ITEMS\`, \`MAX_PICKER_CANDIDATES\` | BUD | A picker that pages |
| \`MAX_DOCUMENTS\`, \`MAX_DOC_GRANTS\`, \`MAX_DOC_NAME_BYTES\` | BUD | |
| \`PIN_PRINCIPAL_LIMIT\` | KEEP | |

### Storage (11 rows)

| Row | Target | Note |
|---|---|---|
| \`DISK_BLOCKS_LIMIT\` and coupled tables | DER | The size of the device |
| \`STORE_CAPACITY\` | BUD | A tree of stores |
| \`ENTRY_NAME_CAPACITY\` | TXT | |
| \`STORE_BLOCKS_LIMIT\` | POL | The quota of the store \`module_files\` and of a disk process. The one storage row that stays a number, set by the plan |
| \`SHARE_CAPACITY\` | BUD | |
| \`PLACE_CAPACITY\` | BUD | |
| \`MAX_TREE_ENTRIES\` | BUD | Tree nodes |
| \`MAX_SNAPSHOTS\`, \`MAX_OBJECTS_PER_SNAPSHOT\` | BUD | How long snapshots stay is POL (the retention rule) |
| \`MAX_FILES_PER_SUBTREE\` | BUD | |
| data evolution description bounds | TXT | |
| \`PATH_LIMIT\`, \`LIST_PAGE_LIMIT\` of \`module_files\` | TXT | |

### Display and compositor (15 rows)

| Row | Target | Note |
|---|---|---|
| \`CLIENT_CAPACITY\` | BUD | |
| literal draw buffers | BUD | Scratch arena of the frame |
| \`Window.title\`, \`resource\` | TXT | |
| switcher, places, grants, workspaces, taskbar, tray | BUD | Sized with the client table |
| \`CLIPBOARD_TEXT_LIMIT\` | BUD | The budget of the process that copies |
| \`SURFACE_LIMIT\` and copies | DER | The screen in force |
| semantic tree capacities | BUD | The arena of the assistive holder |
| \`SPEECH_UTTERANCE_TEXT_LIMIT\` | TXT | Split into utterances |
| remote screen limits | DER | The screen in force |
| terminal \`COLUMNS_LIMIT\`, \`ROWS_LIMIT\` | DER | The screen in force |
| \`MAX_IMAGE_WIDTH\`, \`_HEIGHT\` | BUD | The pixel budget of the caller |
| \`MAX_FRAME_WIDTH\`, \`_HEIGHT\` | BUD | As above |
| palette capacities | TXT | |
| \`POWERBOX_TEXT_LIMIT\` | TXT | |
| capture capacities | KEEP | |

### Interface (13 rows)

| Row | Target | Note |
|---|---|---|
| \`CHARACTER_COUNT\` and fallback counts | BUD | A glyph cache by code point; which fonts the image holds is data |
| \`TEXT_CAPACITY\`, \`COLUMNS_LIMIT\`, \`SEARCH_QUERY_CAPACITY\` | BUD | |
| \`LINE_CAPACITY\` | TXT | |
| line history capacities | BUD | How many lines a history keeps can be a module setting; today no person asks for it |
| \`NOTE_CAPACITY\`, \`TITLE_BYTES\` | BUD | |
| paint picture and history | BUD | |
| \`PICTURE_LIST_CAPACITY\`, \`LIST_PAGES_LIMIT\` | BUD | |
| \`CONTEXT_MENU_MAX_ITEMS\`, \`ACTION_BAR_ITEM_CAPACITY\` | KEEP | |
| \`FONT_LIMIT\` | BUD | |
| language pack capacities | BUD | |
| IME and bidirectional capacities | TXT | |
| manual row buffers | BUD | |
| debugger rows and texts | TXT | |

### Console and Lex (14 rows)

| Row | Target | Note |
|---|---|---|
| \`TEXT_BYTES_MOST\`, \`NODE_CAPACITY\` | TXT | |
| evaluator capacities | BUD | The depth stays a B bound of the stack |
| declaration capacities | BUD | |
| kept list capacities | BUD | |
| console variables | BUD | |
| \`COLUMN_LIMIT\` | TXT | Columns that scroll |
| \`PIPE_STAGE_CAPACITY\` | KEEP | |
| fact capacities | BUD | |
| \`TABLE_KEPT\` | BUD | |
| \`SANDBOX_CAPACITY\`, \`LOADED_CAPACITY\`, names | BUD | |
| palette table entries and parameters | TXT | |
| completion \`CANDIDATE_CAPACITY\` | KEEP | |
| stream capacities | KEEP | |
| \`WIRING_LIST_ROW_LIMIT\`, \`WIRINGS_OF_AN_ASKER_MOST\` | BUD | |

### Network, QUIC and remote (17 rows)

| Row | Target | Note |
|---|---|---|
| remote \`CONNECTION_CAPACITY\` | BUD | |
| \`CLIENT_CAPACITY\`, \`CLIENT_ROWS_OF_ONE_PRINCIPAL\` | BUD | Keys in the store of the principal |
| remote display \`CONNECTION_CAPACITY\` | BUD | |
| \`NETWORK_MASK\`, \`ENDPOINT_CAPACITY\` | POL; BUD | The mask is a policy of the plan or a fact of DHCP. The endpoints are BUD |
| \`ARP_CAPACITY\` | BUD | |
| \`WINDOW_LIMIT\` | TXT | Window scaling, a standard: no number to choose |
| \`ADMITTED_CAPACITY\` | KEEP | |
| \`PAGE_NAME_LIMIT\` | TXT | |
| HTTP client store capacities | BUD | |
| browser page capacities | BUD | |
| browser state capacities | BUD | |
| store sync capacities | BUD | |
| mesh lists and revocations | BUD | A revocation that a bound drops is a fault of security: BUD first |
| role proxy limits | TXT | |
| \`MESH_LINK_CAPACITY\` | BUD | |
| SSH known hosts and grid | BUD; DER | |
| \`SERVICE_CONNECTION_CAPACITY\` | KEEP | |

### Recipes, projects and module files (10 rows)

Each row is BUD, except \`MAX_RECIPE_ARG_BYTES\` and the enum member texts, which are TXT. No row is a setting: the size of a build is the budget of the builder.

### Assistant and agent (8 rows)

| Row | Target | Note |
|---|---|---|
| \`REQUEST_TEXT_BYTES\`, \`REPLY_TEXT_BYTES\`, \`ACT_LINE_BYTES\` | TXT | |
| conversation and act capacities | BUD | |
| act table capacities | TXT | A table that scrolls |
| result lines | BUD | |
| runner caps of the host | TOOL | The host program has dynamic memory: remove the caps |
| lines of one agent step | POL | A budget of time and of calls in the terms of the wide grant, which the principal accepts on the trusted display. The grant is the policy, not a setting |

### Guest (2 rows) and tool (5 rows)

| Row | Target | Note |
|---|---|---|
| guest mounts, paths, entries | BUD | |
| \`REGIONS_MOST\` | BUD | |
| \`MAX_OBJECT_PAYLOAD_BYTES\`, \`MAX_TREE_PAYLOAD_BYTES\` | BUD | |
| \`DATA_DISK_SIZE\`, \`SCRATCH_DISK_SIZE\` | TOOL | |
| \`MACHINE_PROCESSOR_COUNT\` | TOOL | |
| site search bounds | BUD | |

### Count

| Target | Rows |
|---|---|
| BUD | 81 |
| TXT | 25 |
| DER | 10 |
| KEEP | 9 |
| POL | 3 |
| TOOL | 3 |
| SET | 0 |
| Total | 131 |

The 7 D-const rows of AUDIT (\`LARGEST_BUDGET\`, \`budget_exceptions\`, the guest memory and processors) are POL. The 8 D rows stay where they are set, and the grant durations get a default that the principal chooses (section 3.1).

## 5. Prior art

### 5.1 The table

| System | Schema | Where values live | Policy over preference | Dynamic cases | Concrete failure modes |
|---|---|---|---|---|---|
| GSettings and dconf (GSET, GSCH, GKEY, DLOCK) | Compiled XML schema per application: type, default, range, summary. Relocatable schemas for one instance per path | One dconf database per user, a global tree of paths; a binary database read in memory | Keyfiles of the system and \`locks\`: a locked key is not writable; \`is_writable\` tells the reader | Range of a key in the schema only. Choices that the machine gives, and settings that depend on another, are code of the panel. Instances by relocatable path | The tree is global: any process of the user writes any key of any application. The schema says nothing about the view, so GNOME Settings is hand-written code for each panel. A schema that an application removed leaves keys in the database. Locks are by path, so a renamed key escapes its lock |
| Windows Registry and Group Policy (WREG, WGPO, WADMX, WCS) | None in the registry. ADMX and ADML files describe policies apart from the code: each names registry keys and values | One global tree of hives; policy values in \`Policies\` keys | A GPO writes keys; precedence local, site, domain, organisational unit; the Central Store holds the ADMX files | No schema for a dynamic case: the ADMX lists fixed choices | No schema: any program writes any key, readers parse free values. The schema is a separate file that can disagree with the code (WADMX: "each administrative template specifies the registry keys"). Values stay after the program that wrote them is gone. A policy written outside the \`Policies\` keys stays after its GPO leaves ("tattooing", UNVERIFIED in a fetched source; a common report of administrators) |
| macOS CFPreferences and MDM (APREF, AMDM) | None: property lists of free keys | Plists per domain | Eight domains in a fixed search order of user, application and host (APREF, table 1); managed preferences of a profile win | Code of the application | The search order of eight domains: a reader cannot tell from where a value comes. A free key has no type. A daemon caches values, and a direct write to the file is lost |
| NixOS modules (NIXOS) | \`mkOption\` with a type, a default and a description; types merge; \`assertions\` check invariants across options | The evaluated configuration, a value in the store; nothing mutable | Priorities \`mkDefault\` and \`mkForce\` order the definitions of one option | \`mkIf\` makes a definition conditional on another option; freeform submodules for open settings | Changes need a rebuild and a switch: no live preference. An error of a merge or an assertion can be far from its cause. The \`settings\` freeform convention passes text formats of each program through, untyped past the top |
| Fuchsia Structured Configuration (FSC, FSCREF, FCAP) | A typed schema in the manifest of the component; generated client libraries | Values of the package, resolved when the component is created | Precedence: developer override service, then the parent, then the package (FSCREF, "Resolution precedence"). Configuration capabilities route values from a parent (FCAP) | None: a value is fixed at the creation of the instance. Mutation at run time is an opt-in for a parent | Close to what modus needs for policy. It has no live preference of a person and no view. A value fixed at creation needs a restart of the component to change |
| Android (ADS, APS, ASEC, AGLOB) | \`PreferenceScreen\` in XML for the view; DataStore typed with Protocol Buffers | The private file of each application; \`Settings.System\`, \`Secure\`, \`Global\` tables in a system provider | \`Secure\` and \`Global\`: "applications can read but are not allowed to write" (ASEC, AGLOB) | A \`ListPreference\` takes its entries from code at run time; dependency through \`android:dependency\` | \`Settings.System\` began writable by applications and was narrowed in later releases: a global table that each application could write. A global table that each application can read is a fingerprint of the person. Two keys with one name in two tables moved over the years (ASEC: \`ADB_ENABLED\` deprecated in Secure for Global) |
| Plan 9 (P9ENV, P9NS, P9FAC, P9CFG) | None: files of text | \`/env\` per process group; \`#ec\` for the kernel; \`/cfg/$sysname\` scripts | The namespace of a process decides what it sees | Files that a server serves are dynamic by nature | P9ENV: \`#ec\` is "writable only by the host owner. [XXX actually everything is world writable; that's a mistake.]" A shared mutable place got the wrong rights, as property 8 predicts. Values are text that each reader parses (property 19). The lesson that works: factotum holds secrets in one process and answers questions, and never gives the secret |
| Haiku and BeOS (HBM, HPREF) | None: a flattened \`BMessage\` of typed fields per application | Files in the settings folder of the user | None | Each preferences panel is code | HPREF: "a key philosophy of Haiku is to cut down on options and have sensible defaults instead". Few settings, each with its own panel. Typed fields in a message, but no description that a second program can read |

### 5.2 What modus takes and what it leaves

- **From GSettings**: a typed schema with a default and a range, compiled with the program. **Left**: the global tree of paths, and a schema that knows nothing of the view.
- **From the registry and Group Policy**: policy precedence over preference, and a lock. **Left**: a schema apart from the code; values that outlive their writer.
- **From NixOS**: options with types, assertions across options, conditions between options, priorities, and a configuration that is a value with a hash. **Left**: a rebuild for a live preference.
- **From Fuchsia**: the schema in the manifest, the value routed from a parent as a capability, and a precedence of three sources. **Left**: nothing that contradicts a property. It is the model of machine policy in modus.
- **From Android**: the split between a table that only the system writes and the private data of each application; a list of choices that code fills at run time. **Left**: a global table of the system that each application reads.
- **From Plan 9**: factotum, one process that keeps a value and answers questions about it. **Left**: shared text files.
- **From Haiku**: few settings, good defaults. Each number of section 4 that is not a setting follows this rule.

## 6. The dynamic cases

### 6.1 Conditional availability and ranges

Examples: the order of the stripes is useless with the grid fit of a picture; a refresh rate exists only for a display that offers it.

- A static description can state one simple condition: "this setting applies when setting S holds member M". NixOS \`mkIf\` and Android \`android:dependency\` show that most conditions have this form.
- Each other condition is live: the owner gives the state of each of its settings through one export (available, not applicable with the reason, absent device, fixed by policy) and the range in force.
- A setting that is not available keeps its value. A device that comes back gets its value back.

### 6.2 Choice lists that the machine gives

Examples: the fonts of the image, the audio outputs, the displays, the Wi-Fi networks, the keyboard layouts that a pack adds.

- The value is the **identity** of the choice, never its place in a list: the hash of a font file, the identity of an output. A place moves when a list changes.
- The static description names the export that gives the list, and the type of its rows. The export is a table export (property 12, property 19 "State"): it writes rows into memory of the caller (property 14).
- A kept identity that the list no longer holds stays kept and shows as absent. The owner draws with its default.
- A closed set that the code knows stays an enum (\`src/md/infrastructure/choice_constants.md\`). An open set is never an enum: its members are not in the code.

### 6.3 Instances

Examples: the scale and the refresh of each display, the layout of each keyboard, the retention of each store.

- An instance is named by a stable identity that the owner computes from the device (for a display, a hash of its identity data and its connector; for a keyboard, its identity on its bus).
- The description says that the setting is per instance and names the export that lists the instances.
- The setter takes the instance as its first argument. The owner keeps one value per instance in an arena of its budget: no count is fixed.
- A value of an absent instance stays kept, as in 6.2.

### 6.4 Invariants across settings

Example: the hour of light must be before the hour of dark.

- The owner is the one border. Its setter refuses a value that breaks an invariant, with an error record that names the other setting (\`docs/WRITING.md\`).
- Two settings that one invariant binds are parameters of one setter, so a principal changes both in one call. \`settings.set\` already takes each setting as an optional parameter: \`settings.set(light_from = 6:30, dark_from = 20:00)\` changes both at once, or neither.
- A static description can name an invariant for the view (an order of two fields), but the owner checks it. NixOS assertions show the cost of a check far from its cause: the check stays at the owner.

### 6.5 Schema evolution

- The kept values follow \`src/md/features/data_evolution.md\`: the object carries its description, a migration is derived or declared, and an unknown description is refused, never overwritten.
- A setting that a new module removes is a stated loss of the migration.
- A plan that names a setting or a policy that the new holder lacks is refused at the border of the plan, as a role holder that does not fill its contract is refused today. Nothing is ignored in silence (refused: the tolerant reader of Protocol Buffers).
- Before 1.0, a change breaks the old values, as each format does.

### 6.6 A module that does not run

- The description is in the module file. The manual and the console read it with no start, as they read exports today.
- The values are in the store of their keeper (property 9). A setting of a role is kept by the process \`settings\`, which answers at any time. A setting of an application is kept by the application: reading it starts the application as a service (\`on_demand\`), or the window shows it as "not running" with its default. No other process reads the store of the application.

### 6.7 Custom views

Examples: an editor of a keyboard layout, the arrangement of displays.

- The description of a setting may name an act of the owner that opens its own window.
- The settings window shows the setting and a button that raises that window. It never draws a view of another process inside its own surface: a process sees only its own surfaces (property 20, line 6), and a foreign view inside a window of the system is the false dialog of line 8.

### 6.8 Authority and covert channels

- **Write.** A setter serves only a caller that acts for the principal, as \`settings.set\` does today (\`No_Grant\`). A policy changes only through a plan that the principal accepts on the trusted display.
- **Read.** A getter is reached only through a connection that a start grant set lists. The shared look page is a read-only grant, given to the processes with a surface.
- **No channel between two sandboxes.** A sandboxed process can write no value that another sandboxed process reads. A setting of an application is in its own store. A setting of a role is written by the process \`settings\` only.
- **A remaining channel (Inference).** A process that acts for the principal (an agent console with a wide grant) can change the appearance at a rhythm, and each process with a surface sees the page change. That is a one-way channel from a process that reads documents to a sandboxed process that may hold the network. Answers: each change by a caller that is not on the trusted path is an act record of the collector (\`src/md/features/wide_grants.md\`), the change redraws the whole desktop where the principal sees it, and the setter keeps a rate for callers that are not the window of \`settings\`. The intent file lists it as a tension of property 20.
- **Fingerprint.** Each process with a surface reads the font, the scale and the languages. A process with the network can send them. This is the price of one shared look page. A process gets only the values that it draws with: the page holds no other setting.

## 7. Conclusion

The intent file proposes three keepers for three kinds of value: the process \`settings\` for the settings of the roles, each application for its own settings, and the plan for machine policy. One static description in the module file serves the three, and names the exports that give the live parts. Each number of section 4 becomes a budget, a length, or a fact of the machine, and none becomes a setting.

# Module settings: independent adversarial design study

This study audits the configuration problem of `modus` from first principles against the 25 properties in `docs/PROPERTIES.md`. It tests one floated candidate architecture adversarially, compares six real operating systems, and proposes a recommended architecture, its strongest alternative, and the open decisions for the owner.

## 1. The candidate under audit

The floated candidate splits configuration into three parts:

1. **Static schema in binary metadata (property 12):** Each module carries its settings schema in flat tables inside its module file.
2. **Central value storage:** Principal choices live in the `settings` store, and machine policy lives in the Lex plan.
3. **Runtime dynamic lists:** Each owning service answers runtime availability and choice lists when queried.

This design looks small for ten scalar settings. Over five years, it breaks properties 2, 8, 11, 12, 20, 22, 23, and 24.

## 2. Adversarial audit: five structural failure modes

### 2.1 Binary metadata bloat and ABI rigidity (properties 11, 12, 23)

Putting settings schemas into the binary module format freezes a UI and validation language into a permanent ABI.

**The failure is already visible in `modus` today.** `docs/FONTS.md`, "7. The setting", lists nine settings. Two of those nine—`time_zone` and `languages`—already fail to fit `settings.descriptions`. `time_zone` is a constrained numeric offset with city lookup, and `languages` is an ordered list of up to eight `language_tag.Locale` records with deduplication rules. A flat scalar schema fails on 22% of settings before the system has Wi-Fi, multi-monitor displays, audio, a firewall, or keyboard remapping.

**The current type system cannot express real configuration.** `docs/MODULE_CONTRACT.md`, "5. The types", enforces strict binary bounds for clear reasons:

- Records have a 256-byte limit (`RECORD_SIZE_LIMIT`) and hold no nested record, no table, no variant, no flags type, and no float.
- Module metadata validation (`module.validate`) runs in the kernel for the root service.

To handle five years of real modules, a binary settings schema table must grow to express:

| Real configuration case | What a binary schema DSL must add | Why a flat binary table fails |
|---|---|---|
| Per-monitor color profiles and layout | Keyed maps indexed by runtime EDID, 2D coordinates, ICC blob references, conditional HDR toggles | Keys do not exist at compile time; layout needs a spatial canvas, not a form. |
| Per-Wi-Fi network credentials | Variable-size table of SSID records, EAP certificate chains, sealed secrets with `version_erase` | Secrets need zeroing and isolation; authentication modes have conditional nested fields. |
| Firewall rules | Ordered rule lists, IP/CIDR/port ranges, cross-references to grants or interfaces, drag-to-reorder | Semantics depend on rule order and cross-rule overlap detection. |
| Keyboard remapping tables | Layered scancode-to-action maps, dead-key state machines, chords, per-device overrides | The data is a state table, not a set of independent scalar knobs. |
| Plugin and third-party module settings | Dynamic schemas loaded when a plugin or WebAssembly module loads (property 15) | The host module binary does not know its plugins at compile time. |

**Adding a settings schema table breaks content hashing (property 11).** The BLAKE3 hash of a module covers every metadata table (`docs/MODULE_CONTRACT.md`, "1. The module file"). Changing a setting description, regrouping a card, or widening a slider range changes the module hash. That hash change cascades into every importer hash, invalidates signed replacement rows (`src/md/api/module_replacement.md`), and forces new pins in every plan.

**Adding a settings schema table conflicts with replaceable roles (property 23).** A client and a principal depend on a role contract, never on one holder module. If a settings schema lives inside module `compositor`, replacing the `Display` holder with another module changes the schema identity and breaks the principal's stored configuration.

### 2.2 Covert channels, fingerprinting, and ambient authority (properties 2, 8, 20, 21, 24)

**The current `settings_page` already leaks ambient principal fingerprints.** Inspecting `src/library/modus/contract/settings/settings.odin` reveals that every GUI window and terminal maps one shared page at `SETTINGS_PAGE_ADDRESS`. That page exposes fields that most processes have no need to read:

- `pointer_theme` (only the `Display` holder needs it).
- `keyboard_layout` (only the `Input` holder and the desktop shell need it).
- `zone_offset_minutes` (only `date` needs it; `date` already copies it to the date page).
- `languages[8]` (up to eight ordered BCP 47 locales, exposed even to untranslated or untrusted disk processes).

Combining eight ordered locales, UTC offset, keyboard layout, scale factor, font, grid fit, subpixel order, pointer theme, and appearance creates a high-entropy persistent fingerprint. Every sandboxed disk process with a window receives it ambiently, contradicting property 20.

**A central `settings` service becomes a covert channel and a registry.**

1. **Cross-process signaling:** Two sandboxed processes with no ring between them can communicate if process A triggers any observable write to the shared page or central service and process B reads `change_count` or polls the service. Even without write access, contention and response timing on one central `settings` service create a timing channel identical to the shared log lock closed in `src/md/features/log_side_channels.md`.
2. **Global mutable registry (property 8):** Storing values for every module inside one `settings` service recreates the Windows Registry or `dconf`. Property 8 forbids a registry and shared configuration directories. Keying entries by text strings recreates a global text namespace (property 20, row 11). Keying entries by module hash orphans every setting on every module rebuild (property 11).
3. **Confused deputy (property 20, row 12):** If `settings` pushes changes into privileged services, `settings` holds authority over every subsystem. `docs/FONTS.md`, "7. The setting", already refused to make scheduling strategy a setting for this exact reason: `settings` must not hold a right to pass on for a caller.
4. **Multi-principal breakdown (property 21, layer 4):** One machine-wide `settings_page` cannot serve two active principals with different scales, appearances, keyboard layouts, or languages.
5. **Multi-monitor breakdown:** One global `scale` and one global `subpixel_order` on `settings_page` cannot represent a 2x RGB laptop screen beside a 1x BGR external monitor, nor a `remote_display` viewer with a different DPI.
6. **Record-and-replay overhead (property 24):** The kernel tracks shared read-only pages with point copies at each input point. Growing a monolithic shared settings page forces every recorded process to copy unrelated setting updates (such as 07:00/19:00 appearance flips or keyboard layout switches).

### 2.3 One writer vs live reload vs atomic rollback

Splitting schema (module binary), value storage (`settings` store), and runtime validation (owning service) creates three unsolvable failure modes.

**1. Store-first vs service-first deadlock.**
`src/md/features/settings_window.md` enforces "one writer, the store first": `settings` commits to its private store before writing the page. Now consider a setting whose validity depends on an owning service—or on two services at once:

- **Display scale vs window memory budgets vs compositor work area:** Today `settings` commits any scale from 1.0 to 2.0 without asking windows. Windows whose budgets cannot pay the scale decline it and show empty frames, forcing a back-channel counter (`display.windows_that_declined_the_scale`).
- **Time zone vs `date` vs auto appearance:** `settings` writes `zone_offset_minutes`, `date` copies it to the date page, then `date` wakes `settings` to recompute `appearance_in_force`. Two processes form a live feedback cycle.
- **Monitor mode + scale + compositor bar height:** Neither `settings` nor the GPU service alone knows whether a mode preserves the minimum work area (`scale_factor.WORK_AREA_LEAST_HEIGHT`).

If `settings` writes the store first, it persists impossible configurations that the owning service rejects at runtime; durable state and live state diverge permanently. If `settings` asks the owning service before committing, then:

- Changing a setting must cold-start stopped services, violating property 16 ("Services start when a process asks for them").
- A hung or hostile disk module stalls the Settings UI or blocks commits.
- Multi-service invariants require a distributed two-phase commit across untrusted processes.

**2. Conflating desired state with effective state.**
Hardware changes while the machine runs. A principal configures an external monitor profile or a USB audio device, then unplugs it. A language pack is absent from a newer boot image. If a central `settings` store validates against runtime choices and overwrites rejected entries, unplugging a monitor destroys its saved profile. The system must separate *desired configuration* from *effective runtime state*.

**3. Module upgrades and broken rollbacks.**
Suppose module `M` v1 declares `timeout_seconds: 1..60` and `mode: { Fast, Safe }`. Module `M` v2 renames `mode` to `profile` and narrows `timeout_seconds` to `1..30`.

- Static binary schemas contain no migration logic. A central `settings` service can only wipe the record on version mismatch (as `Kept_Settings` does today) or silently drop unknown keys.
- **Rollback breaks:** The principal upgrades to v2 via `plans.apply`, edits settings in `settings`, then runs `plans.rollback()`. The plan rolls back the module hash to v1, while the separate `settings` store still holds v2 values. Version v1 now starts with unreadable or rejected settings.

### 2.4 Principal settings vs Lex plan (property 22)

`src/md/features/declarations.md`, "The plan", already lists "the settings, each a member of `Setting` with its value" as part of a Lex plan. At the same time, `src/modules/system/settings` persists `Kept_Settings` in its own private store.

Keeping both as independent configuration stores violates property 22 and Objective rule 1 ("If two mechanisms do the same work, delete one"). Every system with two independent sources of truth hits the same collision:

- **If the Lex plan wins on apply or boot:** Live clicks in the Settings window silently revert on the next `plans.apply` or reboot. The Settings window becomes a trap.
- **If the `settings` store wins over the Lex plan:** Two machines with identical Lex declarations and pins behave differently (violating property 11). `plans.difference` omits real system changes, and `plans.rollback()` fails to restore prior state.
- **Two schemas and two mental models:** Every new option forces a debate: "Does this go in `settings`, in `plan`, in both, or in a private store?" The lists drift apart within one year.

#### Is the split irreducible?

Reducing the problem to its irreducible constraints reveals that two orthogonal axes are conflated:

1. **Authority boundary (irreducible):**
   - *Authority-changing configuration* (role holders, grants, start lists, budgets, substitution trust, TPM-measured machine policy) changes who can access what. It must pass through the trusted-path difference dialog (`plan_diff_ask`), explicit consent, and TPM measurement for principal 0 (properties 17, 20, 23).
   - *Within-grant behavioral configuration* (dark mode, font, volume, Wi-Fi choice, editor indentation) changes behavior strictly inside grants the process already holds. Requiring a trusted-path consent dialog or process restart to toggle dark mode ruins usability.
2. **Secret boundary (irreducible):**
   - *Secrets* (Wi-Fi passphrases, VPN keys, API tokens) require encrypted storage and `version_erase` block zeroing (property 9). They must never enter hashable, diffable, shareable Lex plans or shared memory pages.
3. **Storage and schema split (not irreducible):**
   - Having two separate type systems, two uncoordinated stores, and conflicting precedence for non-secret behavioral configuration is accidental debt, not a physical law. One typed data model with explicit precedence tiers eliminates the drift.

## 3. Comparison with real operating systems (property 25)

Every major operating system faced this exact design space. Property 25 directs `modus` to take the proven substance and leave the accidental debt.

| System | Mechanism | Gold to take | Debt to leave |
|---|---|---|---|
| **Fuchsia** | Static structured config (`.cml` + `.cvf`) at boot, plus runtime `fuchsia.settings.*` FIDL services | Capability-routed immutable boot config; zero ambient filesystem; assembly-time type checking | Split into two worlds (static assembly config vs runtime FIDL settings); flat scalar schemas that forced JSON blobs for complex data |
| **GSettings / dconf** | Compiled XML schemas + central binary key-value database + system lockdown layer | Fast typed reads; explicit admin lockdown over user values | Global mutable registry (violates P8); ambient read/write sandbox holes; schema-binary desync; complex tools (NetworkManager, monitors, firewall) ignore it anyway |
| **NixOS options** | Pure functional typed module options with merge algebra (`mkDefault`, normal, `mkForce`) and atomic generations | One declarative language; explicit priority algebra; reproducible atomic generations and rollback | Rebuild-on-every-edit UX; painful drift against mutable desktop stores; out-of-band secret hacks (`agenix`/`sops-nix`) |
| **Windows ADMX / Registry** | Central hierarchical registry + XML UI templates + Group Policy precedence | Clear separation of policy layers (Machine > User > Default) and localized UI labels (`.adml`) | Untyped global mutable registry (violates P8); policy "tattooing" when policies are removed; static UI XML that lags real features |
| **macOS plists / MDM** | Per-domain `NSUserDefaults` search list (MDM Managed > User > Default) + Keychain | **Zero-tattooing layered precedence** (removing a managed profile restores the user's choice cleanly); per-app domains; isolated secret store | Untyped plists; central `cfprefsd` daemon; ambient `NSGlobalDomain` fingerprinting |
| **Plan 9** | Per-process private namespaces + owning-service `ctl` files + `factotum` secret agent | Owning service validates live changes directly; per-process visibility; dedicated secret agent that never leaks raw keys | Untyped text parsing on `ctl` files (violates P3, P19); no transactional persistence or atomic rollback |

**The empirical verdict across all six systems:** No operating system has ever succeeded in forcing all configuration into a single static binary key-value schema. Every system that tried ended up carving out secrets, complex hardware/table subsystems, and runtime validators anyway. The systems that aged best combined **explicit non-tattooing precedence layers** (macOS/NixOS), **capability-routed per-consumer delivery** (Fuchsia/Plan 9), and **owner-validated domain contracts** (Plan 9/Fuchsia FIDL).

## 4. Recommended architecture: Owner-Held Config Contracts + Layered Plan/Overlay + Narrow Projections

This architecture adds **zero new binary metadata tables** to `module.VERSION` and **zero global registry**. It composes mechanisms `modus` already owns.

### 4.1 Four strict configuration classes

Every configurable fact belongs to exactly one class:

| Class | Examples | Where it lives | Who validates and applies |
|---|---|---|---|
| **1. Authority and topology** | Role holders, grants, start list, budgets, substitution policy, hard machine locks | Lex plan (`applied_plans`, principal 0 or named principal) | Root service and `plans`, via trusted-path diff dialog; takes effect on start/next boot |
| **2. Cross-cutting desktop preferences** | Scale, appearance, font, subpixel order, grid fit, contrast, motion, pointer theme, keyboard layout, time zone, language list | Layered: Plan `locked` > Principal live overlay (in `settings` private store) > Plan `defaults` | `settings` writes only its overlay; **delivery is capability-narrowed per consumer** (section 4.4) |
| **3. Service and module domain configuration** | Monitor layouts/ICC profiles, firewall rules, keyboard remaps, scheduler strategy, audio routing, editor prefs, plugin config | Layered: Plan `locked`/`defaults` (typed Lex records passed at start or apply) + **owning service's private versioned CoW store** (property 9) | The owning service itself (or its pure `config_check` export in a zero-authority call host) |
| **4. Secrets** | Wi-Fi passphrases, VPN keys, client tokens, recovery material | Owning service's private store with `version_erase` (property 9) or TPM-sealed key store | Never enters Lex plans, shared pages, or any central `settings` service |

### 4.2 Configuration contracts without binary UI bloat (properties 12, 19, 23)

Do not add a `Settings` widget-schema table to the module binary format. Reuse existing module descriptions and role contracts:

1. **Keep scalar settings on existing typed exports (property 19).** Any module or role contract exposes typed `config_get` and `config_set` exports using existing `Enum`, `Integer` (with `Integer_Unit`), `Text`, `Record`, `Optional`, `enum_getters`, `Member_Texts`, and documentation comments. The console, the palette, and a generic inspector UI already generate completion, help, and buttons from those exact tables—with zero new ABI surface.
2. **Model complex settings with typed `Table` exports and owner views.** Firewall rules, monitor arrangements, Wi-Fi networks, and keyboard remapping layers are domain data models. A module exposes typed `Table` exports (`rules_list`, `rule_add`, `rule_remove`, `monitor_modes`) so Lex and the console can inspect and script them without text parsing (property 19), while rich graphical editing lives in the module's own window or panel, never in a frozen binary form DSL.
3. **Bind role-level settings to the role contract (property 23), not the module hash.** For example, the `Display` role contract defines the shared display configuration exports and records (scale, work-area policy, bar edge). Replacing `compositor` with `tiling_compositor` preserves every role-contract setting because both modules fill the same contract hash. Module-specific extras (such as tiling gap width) stay scoped to that module's private store and optional plan record.
4. **Validate Lex plans offline through pure sandboxed evaluation.** To check a module's declarative config block before starting a stopped service (property 16), `plans` invokes the module's optional pure `config_check` export inside a zero-authority call host (the exact pattern already built for `declaration_eval`). `config_check` takes the candidate `Record` or `Table` and returns `Ok` or an `Error_Record`. No service needs to wake, no parser runs in the root service, and complex cross-field invariants (such as CIDR overlap or monitor bounding boxes) stay in normal Odin code.
5. **Keep schema evolution inside the owner.** When module v2 reads its own private store (property 9), it holds all prior CoW versions and owns its own schema upgrade or refusal logic. Because `modus` keeps no backward compatibility before 1.0, each owner validates its stored record at one border and falls back to declared defaults on mismatch, writing a structured log fact.

### 4.3 Non-tattooing layered precedence (unifying Lex plan and live edits)

To satisfy property 22 without breaking live UX or reproducibility, **one precedence algebra** governs every configurable item (desktop preference or module setting):

```
Effective value =
  1. Machine Policy Lock    (Principal 0 plan: `locked`)    [cannot be overridden]
  2. Principal Live Edit    (Owner's private CoW store)     [instant, 1-click, no dialog]
  3. Principal Plan Default (Principal plan: `defaults`)    [reproducible baseline]
  4. Module Built-in Default (ZII zero / contract default)
```

**Why this eliminates both NixOS drift and Windows tattooing:**

- **No tattooing:** Removing a Principal 0 lock immediately reveals the principal's intact live edit or plan default underneath. Removing a live override immediately restores the plan default.
- **No silent overwrites:** Applying a new Lex plan updates tiers 1 and 3. If a live override in tier 2 shadows a changed tier-3 default, `plans.difference` explicitly reports it as shadowed—it never silently clobbers a principal's live tweak, and it never hides drift.
- **Frequent tasks in Lex (property 22):**
  - Change one setting live: `settings.set(appearance = .dark)` or `firewall.rule_add(...)`
  - See every live edit that diverges from the declared plan: `plans.overrides()`
  - Discard live edits back to the declared plan: `plans.reset_overrides()` (or per-service `plans.reset_overrides("settings")`)
  - Export current effective settings as a Lex record literal to paste into a declaration: `plans.export_settings()`
- **Desired vs effective state:** Every owner keeps desired values apart from observed runtime state. An unplugged monitor keeps its desired profile keyed by stable monitor identity; when disconnected, effective state reports `Absent` without erasing the desired entry.

### 4.4 Closing covert channels and fingerprinting: capability-narrowed delivery

Eliminate the monolithic global `settings_page` mapped into every process. Replace it with **narrow per-consumer delivery**:

1. **`Input` holder** receives only `keyboard_layout` (one 64-bit word or a dedicated 1-field ring message from `settings`).
2. **`date` service** receives only `zone_offset_minutes` directly from `settings` (and writes the date page).
3. **`Display` holder (`compositor`)** receives `pointer_theme`, `appearance_in_force`, `font`, `subpixel_order`, `grid_fit`, `contrast`, `motion`, and per-output `scale`.
4. **Every GUI window** receives **no global settings page at all**. Instead, the `Display` holder delivers a narrow **`Surface_Presentation`** record on the window ring (alongside `Work_Area`) whenever the window opens, moves to another monitor, or a visual setting changes. That record carries only what that surface needs to render:
   - `scale` (for *that monitor* and *that window*—fixing multi-monitor and `remote_display` immediately),
   - `appearance_in_force`, `font`, `subpixel_order` (for *that monitor*), `grid_fit`, `contrast`, and `motion`.
5. **Language selection** does not broadcast an 8-element locale list to every process. At process start (or via the session contract), a process receives either no locale (default English) or only the single resolved language tag that matches the language pack actually mapped for that process.

**Security and property 24 payoff:**

- Untrusted disk processes can no longer fingerprint the principal's keyboard layout, time zone, pointer theme, or 8-item locale list.
- Multi-principal sessions (property 21, layer 4) work with zero global page contention: each session's `Display` holder and `settings` instance serve only that session.
- A sandbox or `remote_display` interposition membrane (property 23) can clamp or override `Surface_Presentation` per window without touching global state.
- Record and replay (property 24) no longer pays kernel point-copy deltas for unrelated settings changes: presentation updates arrive deterministically on the already-recorded window ring.

### 4.5 Adversarial self-critique of the recommended architecture

Applying the push-back rule to this proposal exposes four real costs:

1. **Atomic code + live-edit rollback is imperfect for tier 2.** Rolling back a Lex plan rolls back module hashes, tier-1 locks, and tier-3 defaults, but tier-2 live overrides sit in each owner's private CoW store. Mitigating this requires `plans.rollback()` to either coordinate store snapshots across services (adding complexity) or warn when tier-2 overrides remain active.
2. **Distributed live overrides across owners make global backup and sync harder.** In property 21 layer 5 (one principal across several machines), syncing preferences means collecting overrides from each owning service's store rather than copying one file. A uniform `config_export` export on each configurable role mitigates this, at the cost of iterating active roles.
3. **No automatic unified search across all settings without a catalog.** Because schemas live in module exports and role contracts rather than one central table, a unified Settings search box must scan the module metadata of installed roles (via `manual`'s flat-table readers, property 12) or rely on each role registering its settings panel.
4. **Per-window `Surface_Presentation` adds state to the Display contract.** Every window currently reads `SETTINGS_PAGE_ADDRESS` synchronously inside `interface.window_frame_begin` and inside the `drawing` library module. Switching to window-ring delivery requires passing the current presentation state from `display` into `interface` and `drawing` (or giving each window a private read-only page that only its `Display` holder writes).

## 5. Strongest alternative: Unified Plan-as-Single-Truth (Zero Separate Settings Store)

If property 22 ("one general mechanism") and property 11 ("complete reproducibility and atomic rollback") outrank decentralized ownership, one strong alternative exists.

### How it works

1. **Delete the separate `settings` persistent store.** `applied_plans` is the single durable store for both machine/session topology and all non-secret configuration.
2. **Split plan commits into two trust classes:**
   - **Authority commits** (changing role holders, grants, start lists, budgets, or module hashes): require trusted-path `plan_diff_ask` consent, as today.
   - **Config-only commits** (changing only typed configuration values within unchanged grants and hashes): require no security dialog; a click in the Settings window sends a typed patch to `plans`, which validates it against the owning module's pure `config_check` in a call host, commits generation `N+1` atomically, and pushes the updated typed record to the running owner(s) over their config ring.
3. **One history, one diff, one rollback:** `plans.rollback()` rolls back code hashes and every non-secret setting together in one atomic step. Multi-machine sync (property 21, layer 5) copies one applied plan.
4. **Secrets stay out-of-band:** Secrets still live in a dedicated sealed store with `version_erase` (property 9) and appear in plans only as opaque secret IDs, never by value.

### Where this alternative wins and where it breaks

| Criterion | Recommended (Layered Plan + Owner Stores) | Strongest Alternative (Unified Plan-as-Single-Truth) |
|---|---|---|
| **Property 22 (one mechanism)** | Two persistence layers (plan + owner stores) unified by one precedence algebra | Strictly one persistence mechanism for all non-secret config |
| **Atomic code + config rollback** | Partial (plan rolls back; owner stores keep live overrides unless coordinated) | Exact: one generation binds code hashes and config values together |
| **Property 8 & 20 (no central registry / least privilege)** | Strong: no single service holds all module configs | Weak: `plans` holds every module's configuration and becomes a central config broker |
| **High-churn / dynamic hardware config** | Natural: owning service commits directly to its own CoW store | Awkward: dragging a slider, rearranging monitors, or adding a Wi-Fi SSID creates plan generations and bloats `applied_plans` |
| **Live-reload latency & resilience** | Owner applies locally; failure in `plans` does not stop local module config | Every live setting change depends on `plans` + sandboxed validation + push |
| **Coalescing vs audit trail** | Clean separation between system generations and user tweaks | Must either pollute system generations with slider clicks or invent a second "config revision" log inside `plans` |

**Verdict:** The Unified Plan alternative is cleaner if `modus` treats the desktop like a tightly curated, low-churn appliance where almost all config is small and declarative. It bends under stress once rich applications, dynamic multi-monitor/audio/network hardware, and high-frequency UI edits arrive—forcing it to either pollute plan history or silently grow a second mutable store inside `plans`.

## 6. Decisions only the owner can make

Pure engineering analysis narrows the design space to clear trade-offs, but five forks depend on product priorities that only the owner can decide:

1. **Unified single store vs decentralized owner stores:** Does `modus` forbid a separate live-settings store and route all non-secret config edits through `plans` generations (Section 5, maximizing P11/P22 atomic rollback), or does it accept a layered model where each owner keeps its own live CoW overlay beneath Lex plan locks and defaults (Section 4, maximizing P8/P9 isolation and low-churn hardware UX)?
2. **Scope of the Settings window:** Is `settings` solely the window for cross-cutting desktop and system preferences (display, input, region, accessibility, network, sound), while every other application owns its own preferences window—or must `settings` act as a unified host shell that renders settings for third-party modules too?
3. **Fingerprinting strictness for untrusted windows (property 20):** Must untrusted disk processes be blocked from reading `keyboard_layout`, `time_zone`, `pointer_theme`, and the full 8-item `languages` list (requiring the move from global `settings_page` to per-window `Surface_Presentation`), or is the shared settings page accepted as a deliberate usability concession under property 21?
4. **Hard policy locks (Principal 0 over named principals):** Does `modus` need non-overridable machine-level configuration locks (`locked` in Principal 0's plan, for kiosks or managed devices), or does Principal 0 govern only authority/roles/start-policy while each named principal has full control over its own preferences?
5. **Handling of live overrides during `plans.apply`:** If the layered model is chosen and a live UI edit differs from a newly applied Lex plan default, must `plans.apply` keep the live override (reporting it in `plans.difference` until reset), or must `plans.apply` reset conflicting live overrides to match the declared plan?

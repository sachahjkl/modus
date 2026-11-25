# Timed grants, per-grant service budgets, and machine grant policy

This design defines three grant controls that keep policy in principal 0 plans and enforcement inside `root` and owning services without adding kernel operations or data-plane accounting in the kernel: timed ordinary grants, per-grant service budgets, and machine-level grant and signer policy locks.

## Purpose

Ordinary `allow` and powerbox grants previously lasted until revoked by hand, had no uniform per-grant consumption counter across services, and had no machine-wide policy table for locking object-cache signer keys or capping session grant durations. Adding a shared freestanding contract (`modus:contract/grant_policy`) and a root-service expiry tracker (`internal:root/grant_expiry`) gives `root`, `storage`, `network`, `recipes`, and agent services one tested set of rules for temporary access, per-grant quotas, and administrative locks.

## Constraints

- **No new kernel operation and no kernel data-plane accounting.** Expiry checks run on the monotonic system clock in `root` and owning services; byte and operation quotas are charged strictly inside the service that serves each grant.
- **No background timer thread for expiry.** Expiration is decided lazily at grant use and reclaimed by bounded sweeps driven by the service wait loop's earliest deadline.
- **Fail closed with zero mutation on refusal.** Any invalid word, overflow, capacity limit, locked grant class, or disallowed signer key returns an explicit `Grant_Policy_Refusal` without changing policy, quota, or expiry table state.
- **Closed enumerations at every border.** `Grant_Class` and `Grant_Policy_Refusal` carry explicit contract values and convert from transport words only through `enum_word.member_of_word`.
- **Freestanding and bounded.** All data structures have fixed capacities with documented bound kinds and use zero heap allocation.

## The chosen form

### 1. Timed ordinary grants

A timed grant carries `Timed_Grant_Term{granted_at_ms, expires_at_ms}` on the monotonic millisecond clock of the machine:

- `expires_at_ms == 0` marks a permanent grant (never expires).
- Any non-zero `expires_at_ms` expires once `now_ms >= expires_at_ms`.
- `timed_grant_create(now_ms, duration_ms, max_duration_ms)` enforces both the optional per-class duration cap (`max_duration_ms > 0` refuses both `duration_ms == 0` and `duration_ms > max_duration_ms` with `Duration_Past_Cap`) and arithmetic overflow (`now_ms > max(u64) - duration_ms` returns `Bad_Value`).

Inside the root service, `internal:root/grant_expiry` keeps a fixed-capacity `Grant_Expiry_Table` (`GRANT_EXPIRY_CAPACITY` = 256, a plan value covering active timed grants across sessions). `grant_expiry_next_deadline_ms` returns the earliest active non-zero expiry so the root wait loop wakes on time without polling, and `grant_expiry_sweep(table, now_ms, expired_out)` removes and returns expired entries in caller-provided storage without dropping entries when `expired_out` fills (`more_expired = true` signals another pass).

### 2. Per-grant service budgets

`Grant_Quota{limit, used}` tracks optional per-grant consumption inside the owning service (storage bytes per store share, network bytes per endpoint grant, or agent operation counts per wide grant):

- `limit == 0` means no separate per-grant quota cap (the grant remains bounded by its service's normal limits).
- `quota_charge(q, amount)` checks `q.used <= q.limit` and `amount <= q.limit - q.used` without addition overflow; any charge past `limit` returns `Quota_Exceeded` and leaves `q.used` unchanged.
- `quota_remaining(q)` returns `max(u64)` when `limit == 0`, `0` when `used >= limit`, and `limit - used` otherwise.

### 3. Machine-level grant and signer policy locks

Principal 0's plan installs a `Machine_Grant_Policy` with three controls:

- **Signer allowlist (`allowed_signers`, `signer_lock_active`).** Holds up to `ALLOWED_SIGNER_CAPACITY` (32, a plan value) non-zero 32-byte Ed25519 object-cache signer public keys. When `signer_lock_active` is false and the table is empty, no machine signer lock is active (all-zero keys are still refused with `Bad_Value`). Once `signer_lock_active` is true, `policy_signer_allowed` accepts only enrolled keys and returns `Signer_Not_Allowed` for every other key (including when the allowlist is intentionally locked empty).
- **Duration caps (`max_duration_ms[Grant_Class]`).** Caps ordinary grant duration per class (`Store`, `Network`, `Device`, `Wide_Agent`). A non-zero cap forbids permanent grants in that class.
- **Locked grant classes (`locked_classes`).** A `bit_set[Grant_Class; u8]` that blocks session approvals for any locked class with `Grant_Class_Locked`.

See [wide_grants.md](wide_grants.md), [powerbox.md](powerbox.md), [declarations.md](declarations.md), and [several_principals.md](several_principals.md) for the surrounding grant and plan flows.

## Refused forms

- **Wall-clock UTC timestamps for grant expiry.** Wall-clock adjustments or a missing RTC date can extend or prematurely cancel active grants; monotonic milliseconds stay strictly ordered within a boot.
- **Dedicated expiry timer thread per grant or in `root`.** Adds thread-budget pressure and wake synchronization when a single earliest-deadline query on the existing wait loop achieves exact expiry with zero threads.
- **Counting service bytes or operations in the kernel.** Violates the separation between kernel handle transport and service data planes; each owning service already sees every byte or operation on its own ring.
- **Silently truncating expired entries during a sweep.** If `expired_out` is smaller than the number of expired grants, leaving excess expired entries in the table and returning `more_expired = true` guarantees no revocation is lost.

## Subtle points

- **Exact expiry boundary.** `now_ms == expires_at_ms` is expired (`>=`), so a grant of duration `D` granted at `T` is active for `[T, T + D)` and expired at `T + D`.
- **Permanent grants under a duration cap.** Passing `duration_ms == 0` requests a permanent grant; when `max_duration_ms > 0`, `timed_grant_create` refuses it with `Duration_Past_Cap` rather than silently clamping to the cap.
- **Zero signer keys.** A 32-byte all-zero key is never a valid Ed25519 public key and is always refused with `Bad_Value` even when no signer allowlist lock is installed.
- **Renewing an active grant ID.** Registering an existing `grant_id` in `Grant_Expiry_Table` updates its entry in place without consuming a second slot, keeping renewal idempotent even when the table is at capacity.

## State

Built: freestanding contract `modus:contract/grant_policy` (timed grant terms, overflow-safe per-grant quotas, machine grant and signer policy locks, and adversarial host tests), freestanding `internal:root/grant_expiry` (`Grant_Expiry_Table`, earliest-deadline lookup, non-dropping bounded sweep, and adversarial host tests), and the companion state module `src/modules/system/root/grant_expiry.odin` in `root`. Plan schema wiring and live powerbox/`allow` duration options build on these types next.

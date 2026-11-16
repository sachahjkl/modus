title: The TPM refuses an older system and a revoked key
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/TRUSTED_BOOT.md

modus is an operating system whose boot program checks a signed list of the hashes of the whole system before the kernel starts. Until now, each list that the key of the publisher signed stayed valid, an older one with a known flaw too.

The TPM now keeps floors that only rise. Each system description carries a security version, and each boot program a key number. Before it measures a newer system, its boot program raises the floors to its numbers; after the measure, no kernel and no program can raise them. From then on, the boot program of an older system, or of a revoked signing key, stops before the kernel starts, and the screen names the floor.

The publisher raises the security version only for a flaw that an older system would bring back, so a principal can still go back to the release before for any other fault. Six machines of `modustool test trusted_boot` with a software TPM show both refusals, and the repair of an index that another system planted.

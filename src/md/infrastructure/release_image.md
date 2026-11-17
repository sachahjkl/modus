# The release image

A release publishes a disk image of the system that a principal writes to a USB key and starts on a real machine. Beside it are a checksum list and the signature of that list. This file records why the image has its form, why the published files are signed with a key of their own, and why a published image is never a test image.

The guide for a reader is [`docs/INSTALL.md`](../../../docs/INSTALL.md), "1. The files of a release". The keys are in [`docs/TRUSTED_BOOT.md`](../../../docs/TRUSTED_BOOT.md), "5. The signing key".

## Purpose

- A principal gets the system with no build of their own: one file, written to a USB key with `dd`.
- The principal checks, before the write, that the file comes from the publisher of the system and that no byte changed on the way. The host of the files (GitHub) is not trusted for this.
- The image starts with Secure Boot on, after the principal enrolled the certificate of the firmware signing key, and the TPM then seals the machine key to it.

## Constraints

- **A published volume is never a test volume.** A volume that the test signing key signed, the boot image of a measure run, and any boot image that a test changed must never reach a release. A volume of the test signing key starts any system that anyone signs: its private key is published.
- **The production keys come from the environment.** They never enter the repository. The release command refuses to run with no key of the publisher: it never falls back to the test keys, as `build` does.
- **The release ships the bytes that the tests ran.** The modules and the kernel of the image are those of the build that the machine tests boot: the build with the checks of the kernel. No other kind of build exists for a release.
- **A published image holds only what the system may redistribute.** The Posy pointer theme is under CC-BY-NC-4.0: nixpkgs marks it not redistributable, and a NonCommercial license is not the permissive license of the reuse rule of [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md). A release image holds the pointer theme of the system only, under the license of the repository. A build of a developer may keep the Posy theme.
- **The tool uses the Odin standard library only**, with the source library of the system (`AGENTS.md`). The compression runs a program of the development shell, as the signature of the boot program runs `sbsign`.

## The chosen form

### The image: a GPT disk around the release volume

The release volume is the main boot image with its boot program signed for Secure Boot: `build/boot_volume_release.img`, the boot image `build/boot.image`, the kernel module `kernel`, the firmware signature `Signed`. It is the volume of the machine of Secure Boot of the tests (`boot_volume_secure_boot.img`) with the keys of the publisher. The main volume of the tests has an unsigned boot program, and a firmware with Secure Boot on refuses it.

The boot volume of the build is a FAT32 file system with no partition table. The firmware of the test machine starts from such a disk. A USB key for a real machine needs a partition table: the UEFI specification makes a firmware read a GPT disk, and the support of a disk with no partition table varies from one firmware to the next. So the release image is a GPT disk:

- sector 0: a protective MBR, one partition of type `0xEE` over the disk;
- sector 1: the GPT header; sectors 2 to 33: 128 partition entries of 128 bytes;
- one partition, the EFI system partition, from sector 2048 (1 MiB): the release volume, byte for byte;
- 1 MiB after the volume, with the backup entries and the backup header in its last 33 sectors.

The disk GUID and the partition GUID come from the BLAKE3 hash of the volume, with the bits of a version-4 GUID. The same volume gives the same disk, byte for byte: no random value and no time is in the disk. The tool reads the disk back with its own reader before it writes the file.

### The release volume is built by the release command only

The release volume is not in the list of the volumes of the build (`boot_volumes`): no test boots it, and a test build does not pay for a volume that only a release needs. `modustool release image` makes a whole build of the modules and the boot images, then builds the release volume in its own process, with no build record. A kept module could come from another state of the work tree; a whole build cannot.

### The pointer theme of a release: the theme of the system only

The build makes the Posy theme when the variable `POINTER_THEME_SOURCE` names its Xcursor folder ([`docs/POINTERS.md`](../../../docs/POINTERS.md), "5. The two themes"). Three parts keep it out of a release:

- **The release build makes no Posy theme.** `modustool release image` makes the pointer themes with no source folder, whatever the environment holds: its boot image has the resource `pointers_system` and no `pointers_posy`. The compositor then uses the theme of the system, by the path that it already takes when a build has no input.
- **The packaging refuses a pointer theme of others.** With `Publisher_Keys_Only`, each resource of the boot image of the volume that starts with the magic of a pointer theme file must pass `pointer_pictures.validate`, and the license of its header must be the license of the repository, read from `LICENSE`. A resource named `pointers_posy` is refused by its name too. The check reads the bytes, so a theme of others under another name is refused.
- **The Nix environment of a release has no Posy input.** The flake gives `POINTER_THEME_SOURCE` to the default development shell only. The checks of the flake and the shell `release`, which the release workflow uses, do not name the package `posy-cursors`, so the release workflow never fetches it.

So the checks of the flake test the boot image that a release ships: the same modules, the same kernel and the same resources. The pictures of the documents come from the machine test of the check of the flake ([full_check.md](full_check.md)), so they show the theme of the system too. A build in the default development shell, `modustool run` and a film keep the Posy theme.

The machine test runs with one theme or two. The window `pointers` puts the button of the theme of the system first and writes its line at each press, so one press at one place shows the theme of the system in both builds. The test of the setting `pointer_theme` waits for the line of the changed setting, not for the line "the pointer theme in use": with one theme, the compositor changes no theme and writes no such line.

### The files of a release

`modustool release image` writes three files in `dist/`:

| File | What it is |
|---|---|
| `modus-<release number>-x86_64.img.zst` | The disk image, compressed by `zstd -19` |
| `SHA256SUMS.txt` | The checksum list: one line, the SHA-256 of the compressed file in 64 lowercase hexadecimal digits, two spaces, its name, an end of line: the form of `sha256sum` |
| `SHA256SUMS.txt.sig` | The release signature: Ed25519, base64url with no padding, then an end of line |

The release signature covers the bytes of the release signature context `modus release checksums 1` and an end of line, then the bytes of `SHA256SUMS.txt`. The context binds the signature to this one use, as the label of the signed message of a system description does: a signature that the release signing key makes for another use is never a release signature.

The forms of the key and of the signature are those of the package `signing` of gui_toolkit and of the `.sig` files of its package `update`: a private key is the 32-byte seed in base64url with no padding, a public key is its 32 bytes in base64url with no padding, a signature covers its context then the bytes. One form serves every program of the publisher. A host test checks the key form against a vector of that package.

### The release signing key, a third key

The release signing key is an Ed25519 key of its own, beside the signing key and the firmware signing key. Its public key is in the repository (`resources/keys/release_signing_key.public`) and on the site.

- **A new release signing key changes no machine.** A machine holds the public key of the signing key in its boot program and the certificate of the firmware signing key in its firmware. A lost or stolen release signing key is replaced by a commit of a new public key; a lost signing key needs a new boot program on each machine.
- **It answers another question.** The signing key says which system a machine starts. The release signing key says only that the files of a download come from the publisher of the system.
- **Its file is in the key folder.** `modustool key new` writes it beside the signing key, so one variable, `SYSTEM_SIGNING_KEY`, names all the keys of a build, as it already does for the firmware signing key.
- **The release command compares it.** It refuses a release signing key whose public key is not the file of the repository: a signature that no reader can verify is never published.

### The keys in a workflow

The release workflow receives the four values of the key folder as the secrets `SYSTEM_SIGNING_KEY`, `FIRMWARE_SIGNING_KEY`, `FIRMWARE_CERTIFICATE` and `RELEASE_SIGNING_KEY` of the GitHub environment `release`, which only a tag `v*` may use; a tag ruleset limits who creates or moves a tag `v*`. A secret of the repository itself would reach each run of each workflow on any branch. `modustool key write <folder>` writes them into a key folder outside the repository, with the modes of `key new`, from four variables: the same names with `_TEXT` at their end. Each value is checked for its form, and no value is printed. A write that fails part of the way removes the files that it wrote, and the folder if it made it. The publisher keeps the same four values, under the names of the secrets, in `secrets/production.yaml`, encrypted with SOPS (`secrets/README.md`).

The variables end with `_TEXT` because the variable `SYSTEM_SIGNING_KEY` of the tool already names a path: one name keeps one meaning in the tool.

### What the release command refuses

Before any build:

- no `SYSTEM_SIGNING_KEY`;
- the test signing key, found by its public key whatever its path;
- the test firmware signing key: by its path, and a copy of its private key or of its certificate in a key folder by its bytes;
- no release signing key in the key folder, a key file that another user can read, a key folder inside the repository;
- a release signing key whose public key is not `resources/keys/release_signing_key.public`, or no such file;
- a certificate of the firmware signing key that is not `resources/keys/firmware_signing_key.crt`, or no such file. A principal enrols that certificate in the firmware; the site publishes it in PEM and in DER, because the setup of a firmware reads one or the other. A release whose boot program another certificate signed would start with Secure Boot on at no machine.

In the build, the key of the system stops the build when `resources/keys/key_numbers` has no line for the signing key: its boot program would have no key number for the key floor of the TPM ([rollback_floors.md](../features/rollback_floors.md)). In the build, `sbverify` checks the signed boot program with the certificate: a private key that does not belong to its certificate would give a boot program that the enrolled certificate refuses on every machine.

After the build, the packaging checks the files that the build of the volume wrote beside it:

- the file `<volume>.signed_by` must be the text of the key of the publisher; the text of the test signing key is refused, and so is a missing file;
- the boot image of the volume must hold each module and each resource of the boot image of the build (`build/boot.image`), with the same name and the same BLAKE3 hash of its bytes, in the same order, then only the three resources that the build of a volume adds: the replacement list, the system description and its signature. A boot image that holds another build of a module under the same name passes a check of the names; its bytes differ. The boot image of a measure run has one resource more. A module that a test changed has other bytes;
- the system description of the volume must name the BLAKE3 hash of the kernel module of the build for the kernel. The boot program refuses a kernel with another hash at each start, so the kernel of the volume is the kernel of the build;
- with `Publisher_Keys_Only`, the boot image must hold no resource `pointers_posy`, and each pointer theme file in it must be valid and under the license of the repository. The machine test packages a volume with `Test_Keys_Allowed`: a developer runs it in a build that may hold the Posy theme.

The check reads the signed boot image beside the volume, not the volume itself: inside the volume the boot image is in the boot program, and the tool has no reader of a boot program. The release command builds the volume and the files beside it in one call, so they cannot come from two builds there.

The packaging procedure takes one of two values: `Publisher_Keys_Only`, which the command gives, and `Test_Keys_Allowed`, which only the machine test gives. No argument of a command selects the second.

### Verification

`modustool verify <image> <checksum list>` verifies the release signature with the public key of the repository, then reads the checksum list, then compares the SHA-256 of the image with its line. The signature comes first: the tool reads no line of a list that the publisher did not sign.

A principal with no tool verifies with OpenSSL 3 and `sha256sum` ([`docs/INSTALL.md`](../../../docs/INSTALL.md), "2. Verify the files"). OpenSSL verifies a raw Ed25519 signature over a file (`openssl pkeyutl -verify -rawin`): the file to verify is the context then the checksum list, which `printf` and `cat` make. The site publishes the public key in PEM for it. A plain `openssl dgst` or a verification of the checksum list alone fails: the signed message starts with the context.

### The release workflow

The release workflow, `.github/workflows/release.yml`, runs on a tag `v*`. Each step calls the tool, Nix or an action. It has three jobs:

1. `check`: `nix flake check` of the tagged commit, with no secret. The release ships the bytes that the tests ran, so it waits for a green full check. This costs the time of a full check at each release; a release is seldom.
2. `build`: the environment `release`, `contents: read`. Each step runs in the development shell `release` (`nix develop .#release`), which has no Posy input. `release tag-check <tag>` (the tag must be `v` and `RELEASE_NUMBER`), `key write`, `release image`, then an artifact with `dist/` and the notes. `release image` empties `dist/` first, so no file of an older release goes with the new one. It takes the notes from the command `changelog notes`, which it runs, so the section of a release has one writer.
3. `publish`: `contents: write`, no key, no code of the repository: `gh release create <tag> --verify-tag --notes-file build/release_notes.md` with the files of the artifact.

Each action is pinned by the commit of its version, with the version in a comment: a moved tag of an action cannot change the code that runs beside the keys. No cache action runs in the release workflow: its daemon and its post step would run while the keys are on the disk. The runner is a hosted runner, which is discarded after the job with the key folder; a runner that stays would keep the keys.

## Refused forms

- **Import the package `signing` of gui_toolkit, or use `core:crypto/ed25519`.** The tool links the copy of the Ed25519 code of the system (`src/library/support/cryptography/ed25519`) through the system description, the replacement rows and QUIC. Its package name is `ed25519`, as in the standard library, and the compiler refuses two packages of one name in one build ("A package name must be unique"). The tool signs with the copy, which is the code of `core:crypto/ed25519` with only its imports changed, and keeps the forms of gui_toolkit.
- **Publish the boot volume with no partition table.** Some firmware does not start a disk with no partition table.
- **Publish the main volume as the tests build it.** Its boot program is unsigned, so Secure Boot refuses it, and the seal of the machine key needs Secure Boot.
- **Sign the image itself.** One signature over a list covers any count of files, and `sha256sum -c` checks the list with a program that each system has.
- **GPG, minisign or signify.** Each needs a program that a principal installs, and a key form unlike the other programs of the publisher. OpenSSL is on most systems, and the tool verifies with no other program.
- **The release signing key as the signing key.** A key that decides which system a machine starts would sign files on a host for downloads, and its replacement would need a new boot program on each machine.
- **The key values in the workflow file, or a script that writes them.** The repository has no script, and a workflow step calls the tool.
- **A release from the measure build.** Its kernel has no checks and is not the kernel that the tests ran.
- **The Posy theme in a release image.** CC-BY-NC-4.0 allows a share for a non-commercial purpose only, and the publisher of the system cannot control the use of a public download. nixpkgs marks the package not redistributable.
- **A refusal by the name `pointers_posy` alone.** A name is a field of the build: a renamed resource would pass. The license in the header of the theme file is a fact of its bytes.
- **A refusal by the hash of the Posy theme file.** The hash changes with each change of the converter or of the manifest, and the release environment has no Posy theme to hash.
- **The checks of the flake with the Posy theme, and a release without it.** The release would then ship a set of resources that no check of the flake booted.
- **Unset `POINTER_THEME_SOURCE` in the release command.** A change of the environment of the process is a hidden effect. A variable of the build, as `build_whole`, says it in the code.

## Subtle points

- **The seal of the machine key needs Secure Boot.** The TPM service seals only when the firmware verified the boot program (`docs/PRINCIPALS.md`, "The machine key sealed by the TPM"). A principal who starts the image with Secure Boot off has the checks of the boot program, and no seal.
- **The test of the image boots the published form.** The machine test packages the volume of Secure Boot of the tests with a release signing key made in the test, verifies the files, decompresses the image, and starts a machine from the GPT disk. It uses the usual firmware: the machines of Secure Boot already test the signature of the boot program, and their firmware starts slowly.
- **The compressed bytes depend on zstd.** The flake pins zstd. The disk inside is the same for the same volume; the checksum list names the compressed file, because that is the file that a principal downloads.
- **The SHA-256 of the list is computed by the system's copy of SHA-256**, for the reason of the first refused form.

## State

Built: the release volume, the GPT disk, the files of a release, the refusals, the pointer theme of the system only in a release, `verify`, `key write`, the workflow of a release, the check of each push, the download section of the site, the host tests, and a machine of `test trusted_boot` that starts the decompressed image.

Left: the keys of the publisher and the first published image; a start of the image on a real machine with the certificate enrolled (`ROADMAP.md`).

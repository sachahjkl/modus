# Install

This guide says how to get the disk image of a release, how to verify it, how to write it to a USB key, and how to set the firmware of a machine to start it. The terms are in `docs/GLOSSARY.md`, sections "Trusted boot" and "Project".

**For whom.** A principal who starts the system on a real machine, with no build of their own.

**Read before.** `TRUSTED_BOOT.md`, "1. The claims": what the start proves.

**The map of this guide.** "1. The files of a release" names the files. "2. Verify the files" checks them, with the tool or with OpenSSL. "3. Write the USB key" copies the image. "4. Start with Secure Boot" enrols the certificate. "5. Start with Secure Boot off" says what that loses. "6. A new release" says what changes at an update.

The system runs on x86-64 with UEFI firmware. It is tested on QEMU with virtio devices, a UEFI firmware and a TPM, and not on a real machine. Its disk and network services drive virtio devices: a machine with no such device has no data disk and no network in the system.

## 1. The files of a release

Each release from the first one that the release signing key signed publishes three files under its tag `v<release number>`, on the releases of the repository. The site names them in its section "Download", on the home and on the page of the releases.

| File | What it is |
|---|---|
| `modus-<release number>-x86_64.img.zst` | The disk image, compressed with zstd: a GPT disk with one EFI system partition, which holds the boot program and the debug image |
| `SHA256SUMS.txt` | The checksum list: the SHA-256 of the compressed image, in the form of `sha256sum` |
| `SHA256SUMS.txt.sig` | The release signature of the checksum list, by the release signing key |

The site also publishes two public files of the publisher of the system:

| File | What it is |
|---|---|
| `release_signing_key.public`, `release_signing_key.pem` | The public key of the release signing key: base64url, and PEM for OpenSSL. The repository holds it as `resources/keys/release_signing_key.public` |
| `firmware_signing_key.cer`, `firmware_signing_key.crt` | The certificate of the firmware signing key, in DER and in PEM: the certificate to enrol for Secure Boot. The repository holds it as `resources/keys/firmware_signing_key.crt` |

The image is the system that the publisher of the system signed with their keys. It is never a volume of a test: `modustool release image` refuses the test keys and every boot image of a test.

## 2. Verify the files

Verify before you write the USB key. A file that does not verify did not come from the publisher of the system, or changed on the way: do not use it.

### With the tool

In a copy of the repository, with the three files in one folder:

```sh
nix develop -c modustool verify modus-0.93.0-x86_64.img.zst SHA256SUMS.txt
```

The tool verifies the release signature of `SHA256SUMS.txt` with `resources/keys/release_signing_key.public`, then the SHA-256 of the image against its line. It prints `modustool: verify: ... has the SHA-256 that it names` and ends with the status 0.

### With OpenSSL and sha256sum

The release signature is an Ed25519 signature of two parts: the release signature context, the bytes `modus release checksums 1` and an end of line, then the bytes of `SHA256SUMS.txt`. OpenSSL 3 verifies an Ed25519 signature of a whole file, so the first step makes that file. The signature file is base64url with no padding, so the second step adds the padding before the decoder of coreutils reads it.

The steps need OpenSSL 3.0 or later: an older OpenSSL, and the LibreSSL of macOS, have no `pkeyutl -rawin` for Ed25519. On Linux, `basenc` and `sha256sum` are in GNU coreutils 8.31 or later.

With the three files and `release_signing_key.pem` in one folder, on Linux:

```sh
printf 'modus release checksums 1\n' > signed_message
cat SHA256SUMS.txt >> signed_message
printf '%s==' "$(cat SHA256SUMS.txt.sig)" | basenc --base64url -d > signature.bin
openssl pkeyutl -verify -pubin -inkey release_signing_key.pem -rawin -in signed_message -sigfile signature.bin
sha256sum -c SHA256SUMS.txt
```

On macOS, with OpenSSL 3 (for example from Homebrew) first on the path, the decode changes the two characters of base64url to those of base64, and `shasum` checks the hash:

```sh
printf 'modus release checksums 1\n' > signed_message
cat SHA256SUMS.txt >> signed_message
printf '%s==' "$(tr '_-' '/+' < SHA256SUMS.txt.sig)" | base64 -D > signature.bin
openssl pkeyutl -verify -pubin -inkey release_signing_key.pem -rawin -in signed_message -sigfile signature.bin
shasum -a 256 -c SHA256SUMS.txt
```

OpenSSL prints `Signature Verified Successfully`, and `sha256sum` or `shasum` prints the name of the image and `OK`. A verification of `SHA256SUMS.txt` alone, with no context, fails: the signed message starts with the context.

Take `release_signing_key.pem` from a source that you trust apart from the server of the files: the repository, or the site. A key from the same server as a changed image proves nothing.

## 3. Write the USB key

The write replaces all the data of the USB key.

1. Decompress the image:

   ```sh
   zstd -d modus-0.93.0-x86_64.img.zst
   ```

2. Find the device of the USB key. Run `lsblk` before and after you plug it in: the new disk is the key, for example `/dev/sdX`. Do not take a partition (`/dev/sdX1`): take the whole disk.

3. Write the image, and wait for the end of the write:

   ```sh
   sudo dd if=modus-0.93.0-x86_64.img of=/dev/sdX bs=4M conv=fsync status=progress
   sync
   ```

The image is 66 MiB: the volume of 64 MiB and 1 MiB on each side. A larger key keeps its other sectors unused.

## 4. Start with Secure Boot

With Secure Boot on, the firmware verifies the boot program with the certificates of its variable `db` before it runs it. The boot program of a release is signed with the firmware signing key of the publisher of the system. So the firmware starts it only after a principal present at the machine enrolled the certificate of that key.

1. Copy `firmware_signing_key.cer` to a USB key with a FAT file system that the firmware reads. The USB key of the system works too: its partition is FAT32.
2. Open the setup of the firmware, at the start of the machine. Its key and its menus depend on the machine.
3. Find the settings of Secure Boot. Set the mode of the keys to the custom mode, if the firmware asks for it.
4. Add the certificate to `db`: a menu such as "Append key", "Enroll signature" or "Add to db", from the file `firmware_signing_key.cer`. Some firmware reads only PEM: then take `firmware_signing_key.crt`.
5. Turn Secure Boot on, save, and start from the USB key of the system.

The boot display then says "verified by: the firmware (Secure Boot), then the boot program".

**The certificates of the vendor.** Step 4 adds the certificate and keeps the other certificates of `db`. So the firmware also starts each boot program that a certificate of the vendor verifies (`TRUSTED_BOOT.md`, "Layer 3: Secure Boot"). A firmware can take the certificate as its only entry of `db`, with the platform key and the key exchange key, as the test machine does. On some machines a device of the machine, such as a graphics card, has firmware that the certificates of the vendor sign: with them removed from `db`, the firmware does not run it, and the screen can stay dark. Remove them only on a machine whose vendor says that it works with no such certificate.

**The machine key.** With Secure Boot on, `machine_seal()` in the console seals the machine key to the TPM, to this system and to this state of Secure Boot (`PRINCIPALS.md`, "The machine key sealed by the TPM"). Keep the recovery key that the window of `unlock` shows.

## 5. Start with Secure Boot off

The firmware starts the boot program with no check. The boot program still checks the signature of the system description and the hash of each file before the kernel starts (`TRUSTED_BOOT.md`, "Layer 1: the signed system description").

What that loses:

- **The check of the boot program.** Anyone who can write the USB key can replace the boot program, its public key and its checks. The boot display says "verified by the boot program, which the firmware did not verify".
- **The seal of the machine key.** The root service refuses `machine_seal()` with Secure Boot off: a replaced boot program could extend PCR 11 with the hash of a correct system description, and a seal would trust it. The disk grants of principal 0 then last across a restart only with a machine passphrase, typed at each start; with none, they last until the machine stops (`PRINCIPALS.md`, "Principal 0 and its machine passphrase").

## 6. A new release

A new release is another system, with another measure in PCR 11. After a principal writes it to the USB key, the TPM does not release a machine key sealed to the release before it: the window of `unlock` asks for the recovery key once, and with Secure Boot on `unlock` seals the key again to the new system.

The certificate of the firmware signing key stays the same from release to release. The firmware needs a new certificate only when the publisher of the system replaces the firmware signing key (`TRUSTED_BOOT.md`, "Loss").

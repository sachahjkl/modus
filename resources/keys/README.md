# The test keys

`test_signing_key` and `test_signing_key.public` are the key pair of RFC 8032, section 7.1, TEST 1.

`test_firmware_signing_key.pem` and `test_firmware_signing_key.crt` are the test firmware signing key: an RSA-2048 key and its certificate, for Secure Boot. `modustool key test-firmware-new` wrote them once. Its private key is in this repository.

- **These are test keys.** Their private keys are published.
- A system that these keys sign is not trusted. The boot program, the boot display and the root service say so, and the file `<volume>.signed_by` beside each boot volume says so too.
- The build signs with these keys when the environment variable `SYSTEM_SIGNING_KEY` is not set.
- The signing key of a real machine is a file outside the repository: `modustool key new <folder>` writes one (`docs/TRUSTED_BOOT.md`, "The signing key").

The format of the two Ed25519 files: 64 hexadecimal digits, then an end of line. The firmware key files are PEM.

## The key numbers

`key_numbers` gives each signing key its key number: one line for each key, the number from 1 to 64, one space, and the 64 lowercase hexadecimal digits of its public key. The boot program holds the number of its key, and the key floor of the TPM refuses a boot program whose number is below it (`docs/TRUSTED_BOOT.md`, "10. The TPM floors").

- The test signing key has the number 1. The signing key of the publisher of the system has the number 2: its public key is the second line.
- No boot program that the production firmware signing key signed exists from before the TPM floors: none was ever built. So each boot program that the firmware of a machine with the certificate of the publisher starts reads the floors and holds a key number.
- The build refuses a signing key with no line.
- A new key of the publisher after a theft gets the next number. The first start of a system signed with it raises the key floor, and each key with a lower number is then revoked on that machine.
- A line stays after its key is revoked: the file is the list of the keys and of their order.

## The public files of the publisher

Two files here are not test keys. Neither holds a private key. The publisher of the system commits them once, from the key folder (`secrets/README.md`):

- `release_signing_key.public`: the public key of the release signing key, 32 bytes in base64url with no padding. `modustool verify` and a reader verify the files of a release with it.
- `firmware_signing_key.crt`: the certificate of the firmware signing key of the publisher, PEM. A principal enrols it in the firmware for Secure Boot (`docs/INSTALL.md`, "4. Start with Secure Boot").

`modustool release image` refuses a key folder whose release signing key or certificate differs from these files. Until they are committed, no release publishes an image. The release command refuses the test keys of this folder.

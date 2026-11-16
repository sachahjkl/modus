title: A release publishes a disk image for a USB key
date: 2026-11-15
release: next
picture: none
kind: Decided
guide: docs/INSTALL.md

Each release can now publish the system as one file: a disk image that `dd` writes to a USB key. The image is a GPT disk whose one partition holds the boot program of the system, signed for Secure Boot.

Beside it are `SHA256SUMS.txt` and its signature by the release signing key of the publisher. `modustool verify` checks both, and OpenSSL and `sha256sum` do the same check with no tool.

A published image is never a test image. The release command refuses the test keys, whose private keys are in the repository, and every boot image of a test.

With Secure Boot on, the firmware starts the image after a principal enrolled the certificate of the publisher, which the site publishes. The guide says how, and what a start with Secure Boot off loses: the seal of the machine key by the TPM.

The first image comes with the first release that the keys of the publisher sign.

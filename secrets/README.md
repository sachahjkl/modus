# Secrets

This folder holds the keys of the publisher of the system, encrypted with SOPS for the age key of `.sops.yaml`. A file here is committed: its values are encrypted, its names are not. The design is in `src/md/infrastructure/release_image.md`; the keys are in `docs/TRUSTED_BOOT.md`, "5. The signing key".

| File | Use |
|---|---|
| `production.yaml` | The five values of the key folder of the publisher: the source of the secrets of the workflow of a release |

No other file of the repository holds a private key of the publisher. The test keys of `resources/keys` are published on purpose, and a release refuses them.

## The values

Each name is the name of a key of `production.yaml` and the name of a secret of one environment of the repository on GitHub. They are never secrets of the repository itself: each run of each workflow, on any branch, can read those.

| Name | What it is | The file of the key folder | Environment |
|---|---|---|---|
| `SYSTEM_SIGNING_KEY` | The signing key: the 64 hexadecimal digits of its private key | `signing_key` | `release` |
| `FIRMWARE_SIGNING_KEY` | The firmware signing key: the RSA-2048 private key, PEM | `firmware_signing_key.pem` | `release` |
| `FIRMWARE_CERTIFICATE` | The certificate of the firmware signing key, PEM. It is not secret; it is here so that the workflow has the whole key folder | `firmware_signing_key.crt` | `release` |
| `RELEASE_SIGNING_KEY` | The release signing key: its 32-byte seed in base64url with no padding | `release_signing_key` | `release` |
| `CACHE_SIGNING_KEY` | The cache signing key: the 64 hexadecimal digits of its seed | `cache_signing_key` | `cache` |

Two environments keep the keys apart. The job `build` of `.github/workflows/release.yml` names `environment: release` and reads the first four; the job `cache` names `environment: cache` and reads the cache signing key alone. A secret of an environment reaches only a job that names it, so the job that builds never holds the cache signing key, and the job that uploads to the public object cache never holds a key that signs a system or a release (`src/md/infrastructure/cache_publication.md`, "The cache signing key").

The workflow gives each secret to `modustool key write` as the variable of the same name with `_TEXT` at its end: `SYSTEM_SIGNING_KEY` names the path of the signing key in the tool, so a value cannot have that name. The job `cache` gives `CACHE_SIGNING_KEY_TEXT` to `modustool key write cache`.

## Make the keys

Do this once, on a computer of the publisher, outside the repository. Nothing here prints a private value.

1. Make the key folder:

   ```sh
   nix develop -c modustool key new ~/keys/modus
   ```

   The tool writes the signing key, the firmware signing key and its certificate, the release signing key and the cache signing key, each private file readable by its owner only, in a folder that only its owner can open. A folder made before the cache signing key existed gets it alone with `nix develop -c modustool key new cache ~/keys/modus`.

2. Commit the public key of the release signing key, so that a reader can verify a release, and the certificate of the firmware signing key, so that a principal can enrol it for Secure Boot. Neither is secret. `modustool release image` refuses a key folder whose public key or certificate differs from these files.

   ```sh
   cp ~/keys/modus/release_signing_key.public resources/keys/release_signing_key.public
   cp ~/keys/modus/firmware_signing_key.crt resources/keys/firmware_signing_key.crt
   cp ~/keys/modus/cache_signing_key.public resources/keys/cache_signing_key.public
   ```

   The deployment of the public object cache authorises the cache signing key with `--authorized-key resources/keys/cache_signing_key.public`. `modustool key write cache` refuses a key whose public key is not this file.

3. Copy the folder to two media that stay offline, in two places (`docs/TRUSTED_BOOT.md`, "Backup").

## Put the keys in SOPS

The age identity of the publisher is outside every repository: `~/.config/sops/age/keys.txt`.

```sh
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops secrets/production.yaml
```

The editor of `sops` opens a new file. Write the five names of the table, each with the whole text of its file as a value (a PEM file as a block of YAML, `|`), save, and commit `secrets/production.yaml`. `sops` encrypts each value before it writes the file.

## Make the environments `release` and `cache` and protect the tags

Do this before the first secret goes to GitHub. The job `build` of `.github/workflows/release.yml` names `environment: release`, and the job `cache` names `environment: cache`: they are the two jobs that read a key. Each environment gets the same rule of tags.

1. Settings, Environments, New environment: the name `release`, then the name `cache`. Do steps 2 and 3 for each.
2. In the environment, "Deployment branches and tags": choose "Selected branches and tags", and add one rule of the type Tag with the pattern `v*`. A run of any branch, or of another tag, then gets no secret of the environment.
3. Optional: in the environment, "Required reviewers": a run of a tag then waits until a reviewer approves it.
4. Settings, Rules, Rulesets, New ruleset, New tag ruleset: the target pattern `v*`, the rules "Restrict creations", "Restrict updates" and "Restrict deletions", and the publisher of the system as the only bypass. A collaborator with write access then cannot push a tag `v*`, and a tag cannot be moved to another commit.

With `gh`, each environment and its rule of tags:

```sh
for environment in release cache; do
  gh api -X PUT repos/{owner}/{repo}/environments/$environment -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true'
  gh api -X POST repos/{owner}/{repo}/environments/$environment/deployment-branch-policies -f name='v*' -f type=tag
done
```

## Put the keys in the secrets of the environment

Give each value from its file, so that no value goes through the history of a shell:

```sh
gh secret set SYSTEM_SIGNING_KEY --env release < ~/keys/modus/signing_key
gh secret set FIRMWARE_SIGNING_KEY --env release < ~/keys/modus/firmware_signing_key.pem
gh secret set FIRMWARE_CERTIFICATE --env release < ~/keys/modus/firmware_signing_key.crt
gh secret set RELEASE_SIGNING_KEY --env release < ~/keys/modus/release_signing_key
gh secret set CACHE_SIGNING_KEY --env cache < ~/keys/modus/cache_signing_key
```

From SOPS, on another computer, for one value:

```sh
sops --decrypt --extract '["RELEASE_SIGNING_KEY"]' secrets/production.yaml | gh secret set RELEASE_SIGNING_KEY --env release
```

## Build with the keys on a computer

`modustool key write` makes a key folder from the four variables, outside the repository:

```sh
export SYSTEM_SIGNING_KEY_TEXT="$(sops --decrypt --extract '["SYSTEM_SIGNING_KEY"]' secrets/production.yaml)"
# and FIRMWARE_SIGNING_KEY_TEXT, FIRMWARE_CERTIFICATE_TEXT, RELEASE_SIGNING_KEY_TEXT in the same way
nix develop -c modustool key write ~/keys/modus-copy
SYSTEM_SIGNING_KEY=~/keys/modus-copy/signing_key nix develop -c modustool release image
```

Remove the copy of the folder after the build.

## A lost or stolen key

- The release signing key: make a new one, commit its public key in `resources/keys/release_signing_key.public`, and replace the value in SOPS and on GitHub. No machine changes.
- The cache signing key: make a new one (`key new cache` in an empty folder), commit its public key in `resources/keys/cache_signing_key.public`, replace the value in SOPS and in the environment `cache` on GitHub, and give the deployment the new `--authorized-key` in place of the old one. A principal whose substitution policy names the old key removes it. No machine changes, and no system or release signature changes.
- The signing key or the firmware signing key: `docs/TRUSTED_BOOT.md`, "Loss" and "Theft".

# Firmware release manifest format

One signed `release-manifest.json` per GitHub release replaces
per-asset `.fw.sig` signing. The device verifies the manifest
signature, enforces a monotonic counter, then verifies the per-target
`sha256` of the one asset it downloads. Firmware bytes are never
signed directly — the manifest pins them by hash.

This document is the wire contract implemented by
`NervesGithubUpdater.Manifest` and `NervesGithubUpdater.Signature`.

## Assets on each release

| Asset | Content |
|---|---|
| `release-manifest.json` | UTF-8 JSON, schema below |
| `release-manifest.sig` | raw 64-byte Ed25519 signature (binary, not base64) |
| `<app>_<target>.fw` | firmware images referenced by the manifest |

`<app>_<target>.fw` is just a convention — the manifest's `asset`
field is the literal filename the device looks for, so the host
project can name its firmware assets however its release pipeline
already does.

## JSON schema

```json
{
  "version": 1,
  "counter": 1789475200,
  "signed_at": "2026-07-15T12:00:00Z",
  "expires_at": null,
  "targets": {
    "rpi3": {
      "asset": "my_app_rpi3.fw",
      "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
      "size": 47185920
    }
  },
  "deltas": {}
}
```

- **`version`** (required, int) — manifest format version. This
  document describes version `1`. Devices reject unknown versions.
- **`counter`** (required, non-negative int) — strictly increases
  across releases; CI typically uses Unix epoch seconds at signing
  time. The device persists the last-accepted counter
  (`fw_manifest_counter`, via the host's `:kv_get`/`:kv_put` opts —
  typically backed by `Nerves.Runtime.KV`) after a successful flash
  and refuses any manifest with a **lower** counter (equal is allowed,
  so the current release can be reinstalled). A device with no stored
  counter accepts and sets it — first-contact trust, same model as the
  public key baked into the firmware.
- **`signed_at`** (required, ISO 8601 UTC) — informational timestamp.
- **`expires_at`** (optional, ISO 8601 UTC or `null`) — if present and
  the device has expiry enforcement enabled (`enforce_expiry: true`,
  **default off**), manifests past this instant are refused. Off by
  default because a dormant project must not brick its devices'
  update path.
- **`targets`** (required, non-empty map) — keyed by Nerves target
  name (`nerves_fw_platform`). Each entry:
  - `asset` — exact release asset filename to download,
  - `sha256` — lowercase hex SHA-256 of the asset bytes,
  - `size` — asset size in bytes.
- **`deltas`** (reserved) — future delta-update descriptors. Version-1
  devices ignore it.

Unknown top-level keys are ignored (forward compatibility within
version 1).

## Signature construction

The signed message is **`sha512(manifest_bytes)`** — the 64-byte
SHA-512 digest of the manifest file exactly as shipped (byte-for-byte;
no canonicalization, no trailing-newline trimming). Ed25519 is then
applied to that digest as a plain message (PureEdDSA over 64 bytes).

Why the double hash: signing the digest keeps the signed message a
constant 64 bytes regardless of manifest size — inside AWS KMS's
4,096-byte RAW cap and trivial for any HSM.

```sh
# Signer side — always the same first step:
sha512sum release-manifest.json | cut -d' ' -f1 | xxd -r -p > digest.bin
```

```elixir
# Device (verifying) — NervesGithubUpdater.Signature.verify_manifest/3:
digest = :crypto.hash(:sha512, manifest_bytes)
:crypto.verify(:eddsa, :none, digest, signature, [public_key, :ed25519])
```

**The signing and verifying constructions must match exactly**: the
signer performs pure Ed25519 over the digest we provide, so the device
must verify over the same digest, not over the raw manifest bytes. Test
your signing pipeline against real device verification (or the
library's `Signature` test suite) before relying on it in production.

### Signer backends

The scheme is deliberately signer-agnostic: **anything that produces a
raw 64-byte Ed25519 signature over `digest.bin` works.** The device
only ever sees the public key (32 raw bytes baked into the firmware)
and the signature. Known-good recipes:

**AWS KMS** (an Ed25519 asymmetric CMK, e.g. via an OIDC role with
`kms:Sign`):

```sh
aws kms sign --key-id "$KMS_KEY_ID" \
  --message fileb://digest.bin --message-type RAW \
  --signing-algorithm ED25519_SHA_512 \
  --output text --query Signature | base64 -d > release-manifest.sig
```

**GCP Cloud KMS** (`EC_SIGN_ED25519` key, SOFTWARE or HSM protection;
PureEdDSA takes raw input, so omit `--digest-algorithm`):

```sh
gcloud kms asymmetric-sign \
  --location "$LOC" --keyring "$RING" --key "$KEY" --version "$VER" \
  --input-file digest.bin --signature-file sig.b64
base64 -d sig.b64 > release-manifest.sig
```

**Local key / hardware HSM** (offline signing, YubiHSM 2, Nitrokey,
or any PKCS#11 token with Ed25519 — sign on a workstation or
self-hosted runner, then attach with `gh release upload`):

```sh
# Plain openssl with a PEM key:
openssl pkeyutl -sign -rawin -inkey ed25519_private.pem \
  -in digest.bin -out release-manifest.sig
# YubiHSM 2: yubihsm-shell -a sign-eddsa -A ed25519 ... < digest.bin
```

**Local Ed25519 key in CI** (signs in-CI from an Ed25519 PEM stored as
a repo secret; lower security than KMS since the private key touches
the runner, useful for test releases or bootstrapping before KMS is
set up):

```sh
openssl genpkey -algorithm ed25519 -out fw_signing.pem       # private
openssl pkey -in fw_signing.pem -pubout -outform DER \
  | tail -c 32 > firmware_signing.pub                        # commit into firmware
openssl pkeyutl -sign -rawin -inkey fw_signing.pem \
  -in digest.bin -out release-manifest.sig                    # sign
```

Whichever backend signs, sanity-check `release-manifest.sig` is
exactly 64 bytes before uploading it as a release asset. The raw
32-byte public key baked into the firmware (wherever the host project
embeds it — e.g. a file under `rootfs_overlay/`) is what the device
trusts, independent of which backend signs.

## Device-side pipeline

1. Fetch `release-manifest.json` + `release-manifest.sig` from the
   release. Missing manifest ⇒ error (when verification is required).
2. Verify signature (sentinel all-zero public key ⇒ refuse, fails
   closed).
3. Parse + validate schema; reject unknown `version`.
4. Optional expiry check (policy-gated, default off).
5. Counter check against the persisted counter anchor.
6. Look up the device's target in `targets`; download that asset.
7. Verify streamed `sha256` (and `size`) before the atomic rename.
8. Flash via fwup; on success persist the new counter, then reboot.

Any failure broadcasts `{:fw_update_progress, %{phase: :error, ...}}`
and resets the updater to `:idle`.

## Bootstrap / rollout order

Devices running pre-manifest firmware ignore unknown release assets
(they match their expected `.fw` asset by name via `:asset_matcher`
and, with verification off, install it unverified). A typical rollout:

1. Ship manifest-aware firmware via the old unverified path once.
2. Provision the real public key (replaces the all-zero sentinel) in
   the next firmware; flip `verification_required` to `true`.
3. From then on, enforcement is live; the manifest and counter gate
   every install.

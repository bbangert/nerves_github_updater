# Getting started

A task-oriented walkthrough for wiring `nerves_github_updater` into a
Nerves app, cutting your first (unsigned) release, then graduating to
signed releases with rollback protection. For the full opt reference
see the [README](../README.md); for the manifest wire format see
[`guides/manifest-format.md`](manifest-format.md).

## 1. Add + wire the library

```elixir
# mix.exs
def deps do
  [
    {:nerves_github_updater, "~> 0.1"}
  ]
end
```

Child-spec `NervesGithubUpdater.Supervisor` somewhere in your app's
supervision tree. This is the minimal set of opts to get a device
checking and installing:

```elixir
# lib/my_app/application.ex
children = [
  # ...
  {NervesGithubUpdater.Supervisor,
   owner_repo: "myorg/my_app",
   verification_required: false,
   download_dir: "/data/fw_update",
   reboot_fn: fn -> Nerves.Runtime.reboot("0 tryboot") end,
   devpath_fn: fn -> Nerves.Runtime.KV.get("nerves_fw_devpath") end,
   target_fn: fn -> Nerves.Runtime.KV.get_active("nerves_fw_platform") end,
   current_version_fn: fn -> Nerves.Runtime.KV.get_active("nerves_fw_version") end,
   kv_get: &Nerves.Runtime.KV.get/1,
   kv_put: &Nerves.Runtime.KV.put/2,
   asset_matcher: &MyApp.FirmwareUpdate.match_asset/2}
]
```

`asset_matcher` is your own `(tag_name, assets) -> {:ok, fw_asset} |
{:error, reason}` function — see step 2 for what it needs to match.
The README's ["Usage / wiring"](../README.md#usage--wiring) section
has the complete opt list (PubSub, `:channel`, `:allow_downgrade`,
etc.); this guide only calls out what each task needs.

A common pattern (see `NervesGithubUpdater.Updater`'s moduledoc) is to
put all of this behind a small host-owned facade module — one that
owns the child-spec, exposes `check/0` / `install_latest/0` /
`update_config/1`, and translates your app's own config surface
(env vars, a `Nerves.Runtime.KV`-backed store, a LiveView settings
page — whatever it is) into these opts. That facade is also where
`reboot_fn`, `devpath_fn`, `target_fn`, `kv_get`/`kv_put`, and
`asset_matcher` live, since they all reach into `Nerves.Runtime` in
ways the library itself never does.

## 2. Cutting an unsigned release (bootstrap)

`verification_required: false` (the default) is the simplest path:
no manifest, no signature — just a `.fw` asset the device finds by
filename and flashes.

**Name the firmware asset** so your `asset_matcher` can find it. The
convention (also used by the manifest path) is `<app>_<target>.fw`,
e.g. `my_app_rpi3.fw`:

```elixir
def match_asset(_tag_name, assets) do
  target = Nerves.Runtime.KV.get_active("nerves_fw_platform")
  fw_name = "my_app_#{target}.fw"

  case Enum.find(assets, fn a -> a.name == fw_name end) do
    nil -> {:error, :no_fw_asset}
    asset -> {:ok, asset}
  end
end
```

**Cut the release:**

```sh
mix firmware  # or your Nerves build step, producing _build/.../my_app.fw
cp _build/rpi3_dev/nerves/images/my_app.fw my_app_rpi3.fw
gh release create v0.2.0 my_app_rpi3.fw --title "v0.2.0"
```

**The device picks it up** the next time it calls `check/0` — the
`NervesGithubUpdater.Updater` state machine goes
`:idle → :checking → :idle` and caches the release. Call
`install_latest/0` to actually download and flash it
(`:downloading → :flashing → :idle`).

The release's `tag_name` (`v0.2.0` above) must compare as newer than
`:current_version_fn.()`, or the install is refused with
`{:downgrade_refused, ...}` — set `allow_downgrade: true` if you
genuinely need to reinstall an older tag.

**This path has no rollback protection and no authenticity check** —
anyone who can attach an asset named right to *any* release you poll
gets flashed, unverified. It's a deliberate bootstrap convenience for
getting a fleet manifest-aware before you've provisioned a signing
key; every such install fires a `Logger.warning` so the exposure is
auditable in your logs. Move to signed releases (below) before this
matters in production.

## 3. Switching on signed releases

### a. Generate a signing key

```sh
openssl genpkey -algorithm ed25519 -out fw_signing.pem       # keep private!
openssl pkey -in fw_signing.pem -pubout -outform DER \
  | tail -c 32 > firmware_signing.pub                         # 32 raw bytes
```

`firmware_signing.pub` is the raw 32-byte Ed25519 public key every
device trusts. How it gets onto the device is up to you — the
library only takes it as the `:public_key` opt, as binary bytes, and
compares it byte-for-byte against a manifest's signature. A common
approach is baking it into the firmware image itself, e.g. a file
under `rootfs_overlay/` that your host code reads at boot and passes
through:

```elixir
public_key: File.read!("/etc/firmware_signing.pub")
```

Until a real key is provisioned, the device holds the all-zero
sentinel key — `NervesGithubUpdater.Signature.verify_manifest/3`
refuses to validate against it (`{:error, :missing_public_key}`),
so an unprovisioned device fails closed rather than trusting anything.

For production signing you generally don't want the private key
sitting in a file at all — see
[`guides/manifest-format.md`](manifest-format.md#signer-backends) for
signer-agnostic recipes (AWS KMS, GCP Cloud KMS, a local key/HSM in
CI) and the reusable
[`.github/workflows/sign-firmware.yml`](../.github/workflows/sign-firmware.yml)
workflow that wraps all of them.

### b. Cutting a signed release

A signed release adds `release-manifest.json` + `release-manifest.sig`
alongside the `.fw` asset(s). The manifest schema is documented in
full in [`guides/manifest-format.md`](manifest-format.md#json-schema);
a minimal example for one target:

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

Sign `sha512(manifest_bytes)` — not the raw manifest — and write the
raw 64-byte signature to `release-manifest.sig`:

```sh
sha512sum release-manifest.json | cut -d' ' -f1 | xxd -r -p > digest.bin
openssl pkeyutl -sign -rawin -inkey fw_signing.pem \
  -in digest.bin -out release-manifest.sig
```

In CI, call the reusable
[`sign-firmware.yml`](../.github/workflows/sign-firmware.yml) workflow
instead of hand-rolling this — it downloads the release's `.fw`
assets, builds the manifest (including the `counter`), signs it via
whichever `signing-backend` you configure (`aws-kms` / `gcp-kms` /
`local-key` / `manual`), and uploads both files back to the release.

Attach all three files to the release:

```sh
gh release create v0.3.0 my_app_rpi3.fw
gh release upload v0.3.0 release-manifest.json release-manifest.sig
```

### c. Flip the device to signed verification

Once a real public key has replaced the sentinel on-device, turn on
enforcement — through whatever config surface your host facade
exposes (see step 4), which under the hood calls:

```elixir
NervesGithubUpdater.Updater.update_config(verification_required: true)
```

From then on, `check/0` + `install_latest/0` take the manifest path
(`:verifying → :downloading → :flashing`): signature, schema, expiry
(if enabled), and rollback counter are all checked before a single
byte of firmware is downloaded.

### d. The monotonic counter

Every manifest carries a `counter`. After a successful flash, the
device persists it via your `:kv_put` opt (key
`fw_manifest_counter`, typically backed by `Nerves.Runtime.KV`) —
**only after the flash succeeds**, so a failed install never moves
the rollback floor. A future manifest with a **lower** counter is
refused (`{:manifest_rollback, manifest_counter, stored_counter}`);
an **equal** counter is allowed (reinstalling the current release);
a device with no stored counter yet accepts and sets it
(first-contact trust, same model as the public key). CI's
`sign-firmware.yml` uses Unix epoch seconds at signing time, which is
monotonic by construction as long as you don't sign two releases with
manually-forced counters out of order.

## 4. Operator runtime controls

Everything below maps directly onto
`NervesGithubUpdater.Updater.update_config/2`'s mutable opts — the
library itself only exposes that one call; **it's up to your host app
to expose a corresponding control** (an IEx/SSH helper, a LiveView
settings page, a config file reload, etc.) that persists the change
somewhere durable and forwards it. A common pattern is the single
`update_config/1` entry point on the host's facade module: it writes
to the app's own config store first, then best-effort propagates the
same sanitized values to the live `Updater` process so an in-flight
device picks them up without a restart.

Runtime-mutable opts, and what to expose for each:

  * **Turn signed validation off/on** —
    `verification_required: false` / `true`. Turning it off drops
    back to the unverified legacy path (step 2) — no signature, no
    rollback counter, only the semver downgrade gate. Treat this as
    an emergency/bootstrap switch, not a steady state; flip it back
    to `true` as soon as whatever forced it off is resolved.
  * **Change the repo** — `owner_repo: "neworg/new_repo"`.
  * **Switch channel** — `channel: :stable` or `:prerelease`.
  * **Toggle downgrade** — `allow_downgrade: true` / `false`.
  * **Toggle expiry enforcement** — `enforce_expiry: true` / `false`.
  * **Point at a different target** — this one is a function opt, not
    a simple value: `target_fn: fn -> "rpi4" end`. Since `target_fn`
    is itself an opt, your host facade decides whether "switch
    target" is even a runtime-exposed control or a compile-time
    constant.

`update_config/2` returns `{:error, :immutable}` for opts that are
fixed at supervisor start (`:pubsub`, `:pubsub_topic`,
`:download_dir`, `:fwup_devpath`, `:fwup_task`) and `{:error,
:unknown}` for anything it doesn't recognize. Changes take effect on
the **next** `check/1`/`install_latest/1` — an install already in
flight keeps running with the opts it started with.

## 5. Observing progress

Subscribe to your configured `:pubsub_topic` (requires `:pubsub` +
`:pubsub_topic` both set, and `:phoenix_pubsub` as a dependency):

```elixir
Phoenix.PubSub.subscribe(MyApp.PubSub, "firmware_update:progress")
```

Every phase transition broadcasts:

```elixir
{:fw_update_progress, %{phase: phase, pct: pct, message: message}}
```

`phase` is one of `:checking`, `:verifying`, `:downloading`,
`:flashing`, `:idle`, or `:error`. Which phases you see depends on
the install path:

  * **Unsigned (legacy)** — `:downloading → :flashing` (no
    `:verifying`).
  * **Signed (manifest)** — `:verifying → :downloading → :flashing`.

`pct` updates on phase transitions and via intermediate download/flash
progress callbacks; a `state/1` snapshot taken mid-download or
mid-flash can lag briefly behind the most recent PubSub event (see
`NervesGithubUpdater.Updater`'s moduledoc "Progress snapshot caveat").

## 6. Troubleshooting

  * **`{:error, :missing_public_key}`** — `:public_key` is `nil`,
    not 32 bytes, or still the all-zero sentinel. Provision a real
    key (step 3a) before enabling `verification_required: true`.
  * **`{:error, :invalid_signature}`** — the signature doesn't verify
    against the manifest bytes with the configured public key. Check
    you signed `sha512(manifest_bytes)`, not the raw manifest, and
    that the public key on-device matches the private key that
    signed it.
  * **`{:error, {:manifest_rollback, manifest_counter,
    stored_counter}}`** — the release's `counter` is lower than what
    the device already persisted. You're trying to install an older
    signed release than one it's already run; this is the rollback
    guard doing its job.
  * **`{:error, {:sha256_mismatch, expected: _, actual: _}}`** — the
    downloaded asset's hash doesn't match the manifest's `sha256` for
    that target. Usually a stale/wrong asset attached to the release,
    or a manifest built against different bytes than what's uploaded.
  * **`{:error, :no_fw_asset}`** (legacy path) / `{:error,
    {:target_asset_missing, asset_name}}` (manifest path) — no asset
    on the release matched what `:asset_matcher` (legacy) or the
    manifest's `targets` entry (signed) expected. Check the asset
    filename against your `target_fn`'s value and the release.
  * **`{:error, :rate_limited}`** — GitHub's anonymous API quota
    (60/hr/IP) is exhausted. Set `:github_token` to lift it to
    5,000/hr, and make sure you're reusing the ETag `check/1` already
    tracks — a matching `If-None-Match` returns `304`/`:not_modified`
    without counting against quota.

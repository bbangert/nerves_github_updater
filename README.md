# NervesGithubUpdater

[![Hex.pm](https://img.shields.io/hexpm/v/nerves_github_updater.svg)](https://hex.pm/packages/nerves_github_updater)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/nerves_github_updater)
[![License](https://img.shields.io/hexpm/l/nerves_github_updater.svg)](https://github.com/bbangert/nerves_github_updater/blob/main/LICENSE)

GitHub Releases OTA firmware updater for Nerves devices, with signed
release manifests, per-target SHA-256 pinning, and rollback
protection.

## What it is

`NervesGithubUpdater` polls a GitHub repo's Releases for new firmware
and flashes it with `fwup`. There is no server component and no
device-management plane: you `gh release create` (or push a tag and
let CI do it), and devices that are online pick it up on their next
check.

Contrast with [NervesHub](https://nervescloud.com): NervesHub gives
you a fleet dashboard, staged/canary rollouts, device grouping, and a
control plane you (or Nerves Cloud) run. This library gives you none
of that — what you get instead is zero infrastructure. If your
"fleet" is a handful of devices, a single-vendor appliance, or a
hobby project, cutting a signed GitHub Release is a much smaller
operational surface than standing up (or paying for) a device
management service. If you need staged rollouts, per-device targeting,
or a dashboard, use NervesHub instead — this library doesn't grow into
that.

## Security model

A device trusts a 32-byte Ed25519 public key baked into its firmware.
The all-zero key is a "not provisioned yet" sentinel —
`NervesGithubUpdater.Signature.verify_manifest/3` refuses to validate
against it, so an unprovisioned device fails closed rather than
silently accepting any signature.

Each release carries a `release-manifest.json` + `release-manifest.sig`
pair. The signed message is `sha512(manifest_bytes)`, not the raw
bytes (so signature size stays constant regardless of manifest size —
notably, inside AWS KMS's 4,096-byte RAW cap). The manifest lists, per
Nerves target, the exact asset filename, its `sha256`, and its size;
the device downloads only the asset for its own target and verifies
the streamed hash before flashing. A monotonic `counter` in the
manifest is persisted (via the host's `:kv_get`/`:kv_put` opts) after
every successful flash and rejected if a future manifest's counter is
lower — this is the rollback guard.

`verification_required: false` is a deliberate bootstrap mode: no
manifest, no signature, just an `:asset_matcher`-selected `.fw` asset
downloaded and flashed. It's meant for getting a device fleet
manifest-aware before you've provisioned real signing keys — every
such install logs a `Logger.warning` so the unverified state is
auditable. Flip to `verification_required: true` once a real public
key replaces the sentinel.

See [`guides/manifest-format.md`](guides/manifest-format.md) for the
full wire contract, JSON schema, and signer recipes (AWS KMS, GCP
Cloud KMS, local Ed25519 key / HSM).

## Public-repos-only (v0.1)

Asset downloads use each asset's `browser_download_url` with no
auth — a direct, unauthenticated redirect that works for public
repos. Private-repo asset downloads (the GitHub API's asset-by-ID
route with an `accept: application/octet-stream` + Bearer token) are
not implemented in v0.1. `:github_token`, if set, is used only for the
release-metadata API call, to lift the anonymous rate limit
(60/hr/IP → 5,000/hr).

## Installation

```elixir
def deps do
  [
    {:nerves_github_updater, "~> 0.1"}
  ]
end
```

Not yet published to Hex — until then, pull it from GitHub:

```elixir
{:nerves_github_updater, github: "bbangert/nerves_github_updater"}
```

## Usage / wiring

The host app child-specs `NervesGithubUpdater.Supervisor` somewhere in
its own supervision tree and supplies all the host-specific glue as
opts — the library itself has no Nerves dependency and no idea what
"the current device" means until you tell it.

```elixir
# lib/my_app/application.ex (or a dedicated wiring module)
children = [
  # ...
  {NervesGithubUpdater.Supervisor,
   owner_repo: "myorg/my_app",
   github_token: Application.get_env(:my_app, :github_token),
   public_key: Application.get_env(:my_app, :fw_public_key),
   verification_required: true,
   channel: :stable,
   allow_downgrade: false,
   download_dir: "/data/fw_update",
   pubsub: MyApp.PubSub,
   pubsub_topic: "firmware_update:progress",
   reboot_fn: fn -> Nerves.Runtime.reboot("0 tryboot") end,
   devpath_fn: fn -> Nerves.Runtime.KV.get("nerves_fw_devpath") end,
   target_fn: fn -> Nerves.Runtime.KV.get_active("nerves_fw_platform") end,
   current_version_fn: fn -> Nerves.Runtime.KV.get_active("nerves_fw_version") end,
   kv_get: &Nerves.Runtime.KV.get/1,
   kv_put: &Nerves.Runtime.KV.put/2,
   asset_matcher: &MyApp.FirmwareUpdate.match_asset/2}
]
```

Opts, from `NervesGithubUpdater.Updater`:

  * `:owner_repo` — `"owner/repo"` GitHub slug to poll.
  * `:github_token` — optional bearer token; lifts the API rate limit
    (see above). Never sent on asset downloads.
  * `:public_key` — the device's 32-byte raw Ed25519 public key.
    Required for the manifest path.
  * `:verification_required` (default `false`) — selects the signed
    manifest path vs. the legacy unverified path. See "Security
    model" above.
  * `:channel` (default `:stable`) — `:stable` hits
    `/releases/latest`; `:prerelease` considers all non-draft releases
    and picks the highest semver tag.
  * `:allow_downgrade` (default `false`) — belt-and-braces semver
    check on top of the manifest counter; see "Channels & downgrade"
    below.
  * `:enforce_expiry` (default `false`) — honor a manifest's
    `expires_at`. Off by default so a dormant project's devices don't
    brick their update path.
  * `:kv_get` / `:kv_put` — read/write the rollback counter anchor:
    `kv_get.(key)` returns a `String.t()` or `nil`; `kv_put.(key,
    value)` returns `:ok` or an error tuple. Typically
    `&Nerves.Runtime.KV.get/1` and `&Nerves.Runtime.KV.put/2`. Omit
    either and it no-ops gracefully (no anchor persisted) rather than
    crashing — handy on host/test targets without `Nerves.Runtime.KV`.
  * `:target_fn` — `(-> String.t())` resolving the device's Nerves
    target (e.g. `"rpi3"`), used to look up the right entry in the
    manifest. Required for the manifest path.
  * `:current_version_fn` — `(-> String.t() | nil)` returning the
    running firmware version, used by the downgrade gate.
  * `:asset_matcher` — legacy-path only. Contract: `(tag_name,
    assets) -> {:ok, fw_asset} | {:error, reason}`, where `assets` is
    the release's asset list. Resolves which `.fw` asset to install
    when there's no manifest to do it for you.
  * `:reboot_fn` — `(-> any())`, called after a successful flash. The
    library never reboots on its own otherwise.
  * `:devpath_fn` — `(-> String.t() | nil)`, resolves the block device
    `fwup` should write to.
  * `:pubsub` / `:pubsub_topic` — a `Phoenix.PubSub` name/module and
    topic to broadcast progress on. Both must be set (and
    `:phoenix_pubsub` must be a dependency) for broadcasts to fire;
    omit either to run without PubSub.
  * `:download_dir` — where the pending firmware/manifest files are
    staged before flashing.

Subscribers get `{:fw_update_progress, %{phase: phase, pct: pct,
message: message}}` on `:pubsub_topic`, where `phase` is one of
`:checking`, `:verifying`, `:downloading`, `:flashing`, `:idle`, or
`:error`.

Kick off checks and installs from wherever your app's UI or scheduler
lives:

```elixir
NervesGithubUpdater.Updater.check()
NervesGithubUpdater.Updater.install_latest()
NervesGithubUpdater.Updater.state()
```

(Pass a `:name` opt to `Supervisor`/`Updater` if you're not using the
default `NervesGithubUpdater.Updater` process name.)

## The fwup serialize contract

`NervesGithubUpdater.Fwup.apply/2` streams a `.fw` file into `fwup
--apply --framing` over an Erlang Port and blocks until it exits.
**Callers must serialize calls to it** — concurrent `apply/2` calls
against the same device are undefined. The `Updater` GenServer gets
this for free: the whole install (download → verify → flash) runs
inside one `handle_info/2`, so only one flash can ever be in flight.

Two accepted risks, documented in `NervesGithubUpdater.Fwup`'s
moduledoc: no `--exit-handshake` (it deadlocks under a Port in framing
mode), so a failure's error text can occasionally race behind the
exit status; and stderr is merged into the framed stdout stream, which
is fine because `fwup` stays quiet on stderr in framing mode in
practice.

## tryboot / reboot_fn + validation

The library reboots the device **only** by calling your `:reboot_fn`,
and only after a successful flash. It has no opinion on *how* you
reboot.

On A/B (tryboot) systems, the newly-flashed firmware must validate
itself after booting — typically `Nerves.Runtime.validate_firmware/0`
— or the bootloader considers the boot failed and rolls back to the
previous partition. `Nerves.Runtime.reboot("0 tryboot")` is the usual
way to request that the next boot only be given one chance before
falling back. If your host has its own startup-guard/heart/watchdog
gate on validation, make sure the path that runs after a firmware
update can still reach and call `validate_firmware/0` — a half-wired
guard can leave a perfectly good update stuck rolling back forever.

## Channels & downgrade

`:channel` selects `:stable` (GitHub's `/releases/latest`, which
already excludes prereleases/drafts) or `:prerelease` (considers all
non-draft releases, picks the highest semver tag — so a prerelease can
outrank an older stable tag).

Before any install, the release's `tag_name` is compared against
`:current_version_fn.()`. An older release is refused unless
`:allow_downgrade` is `true`. This is deliberately belt-and-braces: on
the manifest path the counter is the real rollback control (and the
only one that matters); this semver check is what also guards the
legacy unverified path, which has no counter at all.

## Status

Extracted from a production Nerves application
([universal_proxy](https://github.com/bbangert/universal_proxy)).
v0.1 is host-verified (full test suite passing on `MIX_TARGET=host`);
hardware validation on real Nerves targets is in progress.

Licensed under Apache-2.0 — see
[LICENSE](https://github.com/bbangert/nerves_github_updater/blob/main/LICENSE).

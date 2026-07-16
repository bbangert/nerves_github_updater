# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [0.1.1] - 2026-07-16

### Fixed

- Isolate the `fwup` port in a monitored worker process so an fwup
  process that dies mid-stream (broken pipe / `:epipe`) surfaces as
  `{:error, {:fwup_port_exit, reason}}` instead of propagating an exit
  signal that crashes the caller. Adds host-safe unit coverage for the
  port-streaming path via a fake fwup executable.
- `Updater.state/1` and `update_config/2` no longer crash a caller that
  polls during a long check/install (the loop blocks by design): they
  return a busy snapshot / `{:error, :busy}` on call timeout.
- Bound the manifest (4 MiB) and signature (64 KiB) downloads so an
  oversized pre-verification asset can't exhaust device memory.

### Changed

- `Signature.verify_manifest/3` returns `:invalid_public_key_size`
  (distinct from `:missing_public_key`) for a wrong-length key.
- Drop the unused `nerves_runtime` dependency — KV/reboot/target are all
  opts-injected — which also removes the `libmnl` build requirement in CI.
- Bump `aws-actions/configure-aws-credentials` and `actions/cache` to v6.

## [0.1.0] - 2026-07-16

### Added

- Signed release-manifest verification: Ed25519 signature over a
  `sha512` digest of the manifest, per-target asset/`sha256`/size
  pinning, and a monotonic rollback counter persisted via host-supplied
  `:kv_get`/`:kv_put`. See `NervesGithubUpdater.Manifest` and
  `NervesGithubUpdater.Signature`, and `guides/manifest-format.md` for
  the wire contract.
- Legacy unverified install path (`verification_required: false`) for
  bootstrapping fleets before a signing key is provisioned, gated by an
  audit-trail `Logger.warning` on every unverified install.
- `:channel` support (`:stable` / `:prerelease`) and a downgrade gate
  (`:allow_downgrade`, default `false`) comparing release tags against
  the running firmware version.
- Streamed, incrementally-hashed asset downloads
  (`NervesGithubUpdater.GithubClient`) with atomic `.part` → rename,
  a hard size ceiling against runaway/malicious responses, and
  `If-None-Match`/ETag support to avoid burning GitHub API rate limit.
- `NervesGithubUpdater.Fwup`: a length-framed `fwup --apply --framing`
  wrapper over an Erlang Port, with progress callbacks and a documented
  caller-must-serialize contract.
- `NervesGithubUpdater.Updater` GenServer state machine
  (`:idle`/`:checking`/`:verifying`/`:downloading`/`:flashing`/`:error`)
  with PubSub progress broadcasts and runtime `update_config/2` for
  mutable opts.
- `NervesGithubUpdater.VersionCompare` for semver-aware
  "update available" / "up to date" comparisons independent of the
  install flow.
- `NervesGithubUpdater.Supervisor` as the library's single public
  entry point for host supervision trees.

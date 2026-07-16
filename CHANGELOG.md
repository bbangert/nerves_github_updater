# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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

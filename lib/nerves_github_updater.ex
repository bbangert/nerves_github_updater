defmodule NervesGithubUpdater do
  @moduledoc """
  GitHub Releases OTA firmware updater for Nerves devices.

  The host application child-specs `NervesGithubUpdater.Supervisor` and
  wires it up through opts: a `Phoenix.PubSub` module + topic for progress
  broadcasts, `:kv_get`/`:kv_put` functions for persisting the rollback
  counter (typically backed by `Nerves.Runtime.KV`), a `:reboot_fn`, and a
  `:devpath_fn` resolving the fwup destination device.

  Firmware is verified via a signed release manifest (Ed25519 signature
  over a `sha512` digest of the manifest bytes) that maps each supported
  Nerves target to its expected asset name, `sha256`, and size — see
  `NervesGithubUpdater.Manifest` and `NervesGithubUpdater.Signature`. A
  legacy, unverified install path is also available for hosts that have
  not yet adopted manifests.

  See `NervesGithubUpdater.Supervisor` and `NervesGithubUpdater.Updater`
  for the full opts contract and state machine.
  """
end

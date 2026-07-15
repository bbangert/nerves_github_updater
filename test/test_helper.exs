# Broadcast-asserting Updater tests need a running PubSub (the lib default
# is nil = no-op); phoenix_pubsub is an optional dep present in the test env.
{:ok, _} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: NervesGithubUpdater.TestPubSub}],
    strategy: :one_for_one
  )

# The fwup integration tests are :hardware-tagged and spawn the real fwup
# binary — excluded by default; run with `mix test --include hardware` on a
# host that has fwup on PATH.
ExUnit.start(exclude: [:hardware])

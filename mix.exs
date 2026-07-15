defmodule NervesGithubUpdater.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/bbangert/nerves_github_updater"

  def project do
    [
      app: :nerves_github_updater,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_options: [warnings_as_errors: true],
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:nerves_runtime, :phoenix_pubsub]
      ],
      description:
        "GitHub Releases OTA firmware updater for Nerves devices with signed release manifests.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:nerves_runtime, "~> 0.13.9", optional: true, runtime: false},
      # Optional: the Updater only broadcasts through it when both
      # :pubsub opts are set AND the dep is present (Code.ensure_loaded?
      # guard) — hosts without Phoenix.PubSub still compile and run fine.
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:plug, "~> 1.0", only: :test},
      # req itself depends on jason (non-`only`-restricted) as its default
      # JSON codec, so an `only: :test` constraint here conflicts with
      # req's requirement; leave it unrestricted like req does.
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp package do
    [
      files: [
        "lib",
        "test",
        "guides",
        "LICENSE",
        "mix.exs",
        "mix.lock",
        "README.md",
        "CHANGELOG.md"
      ],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "guides/manifest-format.md", "CHANGELOG.md"],
      groups_for_modules: [
        "Entry point": [
          NervesGithubUpdater,
          NervesGithubUpdater.Supervisor
        ],
        "Update pipeline": [
          NervesGithubUpdater.Updater,
          NervesGithubUpdater.GithubClient,
          NervesGithubUpdater.Fwup,
          NervesGithubUpdater.Signature,
          NervesGithubUpdater.Manifest
        ],
        Support: [
          NervesGithubUpdater.VersionCompare
        ]
      ]
    ]
  end
end

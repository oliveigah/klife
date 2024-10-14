defmodule Klife.MixProject do
  use Mix.Project

  def project do
    [
      app: :klife,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      # docs
      name: "Klife",
      source_url: "https://github.com/oliveigah/klife",
      extras: [],
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "guides/examples/client_configuration.md"
        ],
        groups_for_extras: [
          Examples: Path.wildcard("guides/examples/*.md")
        ],
        groups_for_docs: [
          groups_for_docs("Producer API"),
          groups_for_docs("Transaction API")
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Klife.Application, []}
    ]
  end

  defp groups_for_docs(group), do: {String.to_atom(group), &(&1[:group] == group)}

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:klife_protocol, "~> 0.7.0"},
      {:nimble_options, "~> 1.0"},
      {:nimble_pool, "~> 1.1"},
      # docs
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      # Benchmarks and tests
      {:benchee, "~> 1.0", only: :dev, runtime: false},
      {:kafka_ex, "~> 0.13", only: :dev},
      {:brod, "~> 3.16", only: :dev},
      {:observer_cli, "~> 1.7", only: :dev}
    ]
  end
end

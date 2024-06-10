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
      docs: [
        main: "readme",
        extras: ["README.md"]
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:klife_protocol, "~> 0.5.0"},
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

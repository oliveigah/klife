defmodule Klife.MixProject do
  use Mix.Project

  def project do
    [
      app: :klife,
      version: "0.5.1",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: [
        # Remove no_opaque when https://github.com/elixir-lang/elixir/issues/14837 get solved
        flags: [:no_opaque]
      ],
      # docs
      name: "Klife",
      description: "Kafka client focused on performance",
      source_url: "https://github.com/oliveigah/klife",
      extras: [],
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/oliveigah/klife"}
      ],
      docs: [
        main: "readme",
        assets: "assets",
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
        ],
        groups_for_modules: [
          Client: [Klife.Client, Klife.Topic, Klife.Record],
          Producer: [
            Klife.Producer,
            Klife.Producer.DefaultPartitioner,
            Klife.TxnProducerPool
          ],
          Testing: [Klife.Testing],
          Behaviours: [Klife.Behaviours.Partitioner],
          Example: [MyClient]
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
      {:klife_protocol, "~> 0.10.0"},
      {:nimble_options, "~> 1.0"},
      {:nimble_pool, "~> 1.1"},
      {:uuid, "~> 1.1"},
      # docs
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      # Benchmarks and tests
      {:benchee, "~> 1.0", only: :dev, runtime: false},
      # {:kafka_ex, "~> 0.13", only: :dev},
      # {:brod, "~> 4.4", only: :dev},
      # {:erlkaf, "~> 2.2", only: :dev},
      # {:observer_cli, "~> 1.7", only: :dev},
      # dev
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end

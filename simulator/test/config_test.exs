defmodule Simulator.ConfigTest do
  use ExUnit.Case, async: false

  setup do
    env = %{
      "SIM_CONTAINER" => "true",
      "SIM_CPUS" => "1.5",
      "SIM_MEMORY" => "2g",
      "BROKER_CPUS" => "1",
      "BROKER_MEMORY" => "1g",
      "BROKER_HEAP" => "512m",
      "CONTROLLER_CPUS" => "0.5",
      "CONTROLLER_MEMORY" => "512m",
      "CONTROLLER_HEAP" => "256m",
      "KAFKA_VERSION" => "4.4.0",
      "SIM_IMAGE" => "klife-simulator:test",
      "SIM_CONFIG" => "",
      "RUN_SECONDS" => "45",
      "FORCE_STABLE" => "",
      "SASL_MECHANISM" => "",
      "OAUTH_TOKEN_LIFETIME_S" => ""
    }

    previous = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)
    previous_rerun = :persistent_term.get(:rerun_timestamp, nil)
    :persistent_term.erase(:rerun_timestamp)
    System.put_env(env)

    on_exit(fn ->
      :persistent_term.erase(:rerun_timestamp)
      if previous_rerun, do: :persistent_term.put(:rerun_timestamp, previous_rerun)

      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "every saved simulation config includes all worker Docker settings" do
    config = Simulator.EngineConfig.generate_config()
    {saved, _} = config |> inspect(limit: :infinity) |> Code.eval_string()

    assert saved.resources == %{
             simulator: %{cpus: "1.5", memory: "2g"},
             broker: %{cpus: "1", memory: "1g", heap: "512m"},
             controller: %{cpus: "0.5", memory: "512m", heap: "256m"},
             kafka_version: "4.4.0",
             image: "klife-simulator:test"
           }

    assert config.clients != []
    assert config.oauth_token_lifetime_s in [75, 90, 120]
    assert config.run_seconds == 45
    refute config.force_stable
    refute Map.has_key?(saved.resources, :parallel)
  end

  test "replay keeps the workload and records the current worker's resources" do
    original = Simulator.EngineConfig.generate_config()
    directory = "_config_test_#{System.unique_integer([:positive])}"
    path = Path.join("simulations_data", directory)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "config.exs"), inspect(original, limit: :infinity))
    on_exit(fn -> File.rm_rf!(path) end)

    :persistent_term.put(:rerun_timestamp, directory)
    System.put_env("BROKER_MEMORY", "2g")
    replay = Simulator.EngineConfig.generate_config()

    assert replay.resources.broker.memory == "2g"
    assert replay.random_seeds_map == original.random_seeds_map
    assert replay.consumer_groups == original.consumer_groups
    assert replay.producer_concurrency == original.producer_concurrency
    assert Enum.map(replay.topics, & &1.partitions) == Enum.map(original.topics, & &1.partitions)
    refute Enum.any?(replay.topics, &(&1 in original.topics))
    topics = MapSet.new(replay.topics, & &1.topic)

    for group <- replay.consumer_group_configs, topic <- group[:topics] do
      assert topic[:name] in topics
    end

    # Container replay loads the mounted file and ignores generation overrides.
    :persistent_term.erase(:rerun_timestamp)

    System.put_env(%{
      "SIM_CONFIG" => Path.join(path, "config.exs"),
      "RUN_SECONDS" => "30",
      "FORCE_STABLE" => "true",
      "SASL_MECHANISM" => "unknown",
      "OAUTH_TOKEN_LIFETIME_S" => "invalid"
    })

    mounted_replay = Simulator.EngineConfig.generate_config()
    assert mounted_replay.random_seeds_map == original.random_seeds_map
    assert mounted_replay.clients == original.clients
    assert mounted_replay.force_stable == original.force_stable
    assert mounted_replay.oauth_token_lifetime_s == original.oauth_token_lifetime_s
    assert mounted_replay.run_seconds == 30
  end
end

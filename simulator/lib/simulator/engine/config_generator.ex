defmodule Simulator.Engine.ConfigGenerator do
  alias Simulator.Engine
  alias Klife.Consumer.ConsumerGroup

  def generate_client() do
    Enum.random(Engine.get_clients())
  end

  def generate_config(:consumer_group) do
    opts = ConsumerGroup.get_opts()

    base_args = [
      client: generate_client(),
      topics: generate_config(:cg_topics),
      group_name: Base.encode16(:rand.bytes(10))
    ]

    base_config = NimbleOptions.validate!(base_args, opts)

    Enum.map(base_config, fn {key, base_val} ->
      {key, get_fuzzy_value(:consumer_group, key, base_val)}
    end)
  end

  def generate_config(:cg_topics) do
    opts = ConsumerGroup.TopicConfig.get_opts()
    possible_keys = Keyword.keys(opts) |> Enum.map(fn pk -> {pk, :to_remove} end)

    base_configs =
      Enum.map(Engine.get_simulation_topics_data(), fn %{topic: t} ->
        base_args = [name: t]
        NimbleOptions.validate!(base_args, opts)
      end)
      |> Enum.map(fn tc ->
        tcmap =
          Map.new(tc)
          # Needs to delete fetch strategy because we are calling validate
          # directly on the topic config and not through consumer group.
          #
          # Since nimble options does not resolve the values recursivelly,
          # in production clients will pass this empty and not with the
          # default value
          #
          # This line does not have fetch strategy set on topic configurations
          # base_validated_args = NimbleOptions.validate!(args, @consumer_group_opts)
          #
          # But if validate is called with ConsumerGroup.TopicConfig.get_opts()
          # the default value for fetch_strategy is present
          #
          # In production we just call like NimbleOptions.validate!(args, @consumer_group_opts)
          # and relie on custom logic to make the appropriate defaults.
          # see from_map/2 on Klife.Consumer.ConsumerGroup.TopicConfig
          |> Map.delete(:fetch_strategy)

        pkmap = Map.new(possible_keys)

        Map.merge(pkmap, tcmap)
        |> Map.to_list()
      end)

    Enum.map(base_configs, fn tc ->
      Enum.map(tc, fn {key, base_val} ->
        {key, get_fuzzy_value(:cg_topics, key, base_val)}
      end)
      |> Enum.reject(fn {k, v} -> v == :to_remove end)
    end)
  end

  def generate_config(:exclusive_fetch) do
    opts = ConsumerGroup.get_exclusive_fetch_opts()
    base_config = NimbleOptions.validate!([], opts)

    Enum.map(base_config, fn {key, base_val} ->
      {key, get_fuzzy_value(:exclusive_fetch, key, base_val)}
    end)
  end

  def get_fuzzy_value(:cg_topics, :handler_max_unacked_commits, base_val) do
    weighted_random_opt([{5, base_val}, 0, 5, 10])
  end

  def get_fuzzy_value(:cg_topics, :handler_max_batch_size, base_val) do
    weighted_random_opt([base_val, :dynamic, 1, 10, 100])
  end

  def get_fuzzy_value(:cg_topics, :offset_reset_policy, base_val) do
    weighted_random_opt([{5, base_val}, :latest, :earliest])
  end

  def get_fuzzy_value(:cg_topics, :fetch_max_bytes, base_val) do
    weighted_random_opt([
      {5, base_val},
      100_000,
      500_000,
      1_000_000,
      2_000_000,
      5_000_000
    ])
  end

  def get_fuzzy_value(:cg_topics, :max_queue_size, base_val) do
    weighted_random_opt([
      {5, base_val},
      2,
      5,
      10,
      20,
      50
    ])
  end

  def get_fuzzy_value(:cg_topics, :fetch_interval_ms, base_val) do
    weighted_random_opt([
      {5, base_val},
      1000,
      2500,
      5000,
      10_000,
      30_000
    ])
  end

  def get_fuzzy_value(:cg_topics, :handler_cooldown_ms, base_val) do
    weighted_random_opt([
      {5, base_val},
      0,
      100,
      500,
      1000,
      5000
    ])
  end

  def get_fuzzy_value(:cg_topics, :isolation_level, base_val) do
    weighted_random_opt([{5, base_val}, :read_committed, :read_uncommitted])
  end

  def get_fuzzy_value(:cg_topics, :fetch_strategy, base_val) do
    weighted_random_opt([
      {5, base_val},
      {1, {:shared, :klife_default_fetcher}},
      {1, {:exclusive, generate_config(:exclusive_fetch)}}
    ])
  end

  def get_fuzzy_value(:consumer_group, :fetch_strategy, base_val) do
    weighted_random_opt([
      {5, base_val},
      {1, {:shared, :klife_default_fetcher}},
      {1, {:exclusive, generate_config(:exclusive_fetch)}}
    ])
  end

  def get_fuzzy_value(:consumer_group, :rebalance_timeout_ms, base_val) do
    weighted_random_opt([
      {5, base_val},
      10_000,
      20_000,
      30_000,
      60_000,
      120_000
    ])
  end

  def get_fuzzy_value(:consumer_group, :committers_count, base_val) do
    weighted_random_opt([
      {5, base_val},
      1,
      2,
      3,
      5,
      10
    ])
  end

  def get_fuzzy_value(:consumer_group, :isolation_level, base_val) do
    weighted_random_opt([{5, base_val}, :read_committed, :read_uncommitted])
  end

  def get_fuzzy_value(:exclusive_fetch, :max_wait_ms, base_val) do
    weighted_random_opt([
      {5, base_val},
      0,
      100,
      500,
      1000,
      5000
    ])
  end

  def get_fuzzy_value(:exclusive_fetch, :min_bytes, base_val) do
    weighted_random_opt([
      {5, base_val},
      100,
      1000,
      10_000,
      100_000
    ])
  end

  def get_fuzzy_value(:exclusive_fetch, :max_bytes, base_val) do
    weighted_random_opt([
      {5, base_val},
      100_000,
      250_000,
      500_000,
      1_000_000,
      5_000_000
    ])
  end

  def get_fuzzy_value(:exclusive_fetch, :request_timeout_ms, base_val) do
    weighted_random_opt([
      # {5, base_val},
      # 3000,
      # 5000,
      10_000,
      30_000
    ])
  end

  def get_fuzzy_value(:exclusive_fetch, :isolation_level, base_val) do
    weighted_random_opt([{5, base_val}, :read_committed, :read_uncommitted])
  end

  def get_fuzzy_value(_config_name, _key, base_val), do: base_val

  def weighted_random_opt(base_opts) do
    weighted_list =
      Enum.map(base_opts, fn
        {w, opt} -> {w, opt}
        opt -> {1, opt}
      end)

    total_weight = Enum.sum_by(weighted_list, fn {weight, _} -> weight end)
    random_value = :rand.uniform(total_weight)

    return =
      weighted_list
      |> Enum.reduce_while({0, nil}, fn {weight, value}, {acc_weight, _} ->
        new_acc = acc_weight + weight

        if new_acc >= random_value,
          do: {:halt, {new_acc, value}},
          else: {:cont, {new_acc, value}}
      end)
      |> elem(1)

    case return do
      {m, f, a} -> apply(m, f, a)
      v -> v
    end
  end
end

defmodule Simulator.EngineConfig do
  alias Klife.Consumer.ConsumerGroup

  # TODO: Add random seeds in the config file as well!
  defstruct [
    :clients,
    :topics,
    :topics_replication_factor,
    :consumer_groups,
    :consumer_group_configs,
    :producer_max_rps,
    :producer_concurrency,
    :producer_loop_interval_ms,
    :record_value_bytes,
    :record_key_bytes,
    :invariants_check_interval_ms,
    :lag_warning_multiplier
  ]

  def generate_config do
    case :persistent_term.get(:rerun_timestamp, nil) do
      nil -> generate_random()
      rerun_ts -> generate_from_file(rerun_ts)
    end
  end

  defp generate_random do
    # Order is imporant here because some configs depends on others
    config_keys = [
      :clients,
      :topics,
      :topics_replication_factor,
      :consumer_groups,
      :consumer_group_configs,
      :producer_max_rps,
      :producer_concurrency,
      :producer_loop_interval_ms,
      :record_value_bytes,
      :record_key_bytes,
      :invariants_check_interval_ms
    ]

    Enum.reduce(config_keys, %__MODULE__{}, fn key, acc_config ->
      Map.put(acc_config, key, random_value(key, acc_config))
    end)
  end

  defp generate_from_file(rerun_ts) do
    {%__MODULE__{}, _binding} =
      {base_config, _binding} =
      Code.eval_file(Path.relative("simulations_data/#{rerun_ts}/config.exs"))

    # Must update the topics in order to resimulate from a new topic
    # instead of reuse the old one that may have old data that may
    # interfere on the tests
    old_to_new_topics =
      Map.new(base_config.topics, fn %{topic: old_name} ->
        {old_name, old_name <> "_" <> Base.encode16(:rand.bytes(5))}
      end)

    new_topics =
      Enum.map(base_config.topics, fn tdata ->
        Map.put(tdata, :topic, old_to_new_topics[tdata.topic])
      end)

    new_consumer_group_configs =
      Enum.map(base_config.consumer_group_configs, fn cg_config ->
        new_topics_config =
          Enum.map(cg_config[:topics], fn topic_config ->
            Keyword.put(topic_config, :name, old_to_new_topics[topic_config[:name]])
          end)

        Keyword.put(cg_config, :topics, new_topics_config)
      end)

    %{base_config | topics: new_topics, consumer_group_configs: new_consumer_group_configs}
  end

  defp random_value(:clients, _config) do
    [Simulator.NormalClient, Simulator.TLSClient]
  end

  defp random_value(:topics, _config) do
    topic_count = weighted_random_opt([3, 5, 10, 15, 20])

    Enum.map(1..topic_count, fn _ ->
      %{
        topic: Base.encode16(:rand.bytes(30)),
        partitions: weighted_random_opt([1, 5, 10, 15, 20, 25, 30])
      }
    end)
  end

  defp random_value(:topics_replication_factor, _config) do
    weighted_random_opt([1, 2, 3])
  end

  defp random_value(:consumer_groups, _config) do
    cg_count = weighted_random_opt([3, 5, 10])

    Enum.map(1..cg_count, fn i ->
      # TODO: Fix the problem with multiple consumers that start producing before everyone is ready
      %{name: "SimulatorGroup#{i}", max_consumers: weighted_random_opt([1])}
    end)
  end

  defp random_value(:consumer_group_configs, config) do
    for %{name: cg_name, max_consumers: mc} <- config.consumer_groups,
        idx <- 1..mc do
      opts = random_value(:single_consumer_group, config)

      cg_mod =
        case opts[:client] do
          Simulator.NormalClient -> :"#{Simulator.Engine.Consumer.NormalClient}#{idx}"
          Simulator.TLSClient -> :"#{Simulator.Engine.Consumer.TLSClient}#{idx}"
        end

      opts
      |> Keyword.replace(:group_name, cg_name)
      |> Keyword.put(:cg_mod, cg_mod)
    end
  end

  defp random_value(:single_consumer_group, config) do
    opts = ConsumerGroup.get_opts()

    base_args = [
      client: Enum.random(config.clients),
      topics: random_value(:cg_topics, config),
      group_name: Base.encode16(:rand.bytes(10)),
      # Fetch strategy needs to be defined here because
      # we need a runtime defined default value, otherwise
      # it raises!
      fetch_strategy: random_value(:fetch_strategy, config)
    ]

    base_config = NimbleOptions.validate!(base_args, opts)

    Enum.map(base_config, fn {key, base_val} ->
      {key, random_value({:consumer_group, key}, base_val)}
    end)
  end

  defp random_value(:cg_topics, config) do
    opts = ConsumerGroup.TopicConfig.get_opts()
    possible_keys = Keyword.keys(opts) |> Enum.map(fn pk -> {pk, :to_remove} end)

    base_configs =
      Enum.map(config.topics, fn %{topic: t} ->
        base_args = [name: t]
        NimbleOptions.validate!(base_args, opts)
      end)
      |> Enum.map(fn tc ->
        tcmap =
          Map.new(tc)
          |> Map.delete(:fetch_strategy)

        pkmap = Map.new(possible_keys)

        Map.merge(pkmap, tcmap)
        |> Map.to_list()
      end)

    Enum.map(base_configs, fn tc ->
      Enum.map(tc, fn {key, base_val} ->
        {key, random_value({:cg_topics, key}, base_val)}
      end)
      |> Enum.reject(fn {_k, v} -> v == :to_remove end)
    end)
  end

  defp random_value(:exclusive_fetch, _config) do
    opts = ConsumerGroup.get_exclusive_fetch_opts()
    base_config = NimbleOptions.validate!([], opts)

    Enum.map(base_config, fn {key, base_val} ->
      {key, random_value({:exclusive_fetch, key}, base_val)}
    end)
  end

  defp random_value(:fetch_strategy, _config) do
    weighted_random_opt([
      {1, {:exclusive, random_value(:exclusive_fetch, nil)}},
      {5, {:shared, :klife_default_fetcher}}
    ])
  end

  defp random_value(:producer_max_rps, _config) do
    weighted_random_opt([50, 80, 100])
  end

  defp random_value(:producer_concurrency, _config) do
    weighted_random_opt([5, 7, 10])
  end

  defp random_value(:producer_loop_interval_ms, _config) do
    weighted_random_opt([1000])
  end

  defp random_value(:record_value_bytes, _config) do
    weighted_random_opt([10, 100, 1000, 10_000])
  end

  defp random_value(:record_key_bytes, _config) do
    weighted_random_opt([64, 128])
  end

  defp random_value(:invariants_check_interval_ms, _config) do
    weighted_random_opt([5_000])
  end

  defp random_value({:cg_topics, :handler_max_unacked_commits}, _base_val) do
    # TODO: Think how to keep invariants even when not 0
    weighted_random_opt([0])
  end

  defp random_value({:cg_topics, :handler_max_batch_size}, base_val) do
    weighted_random_opt([base_val, :dynamic, 100, 200, 1000])
  end

  defp random_value({:cg_topics, :offset_reset_policy}, _base_val) do
    # TODO: Think how to keep invariants even when not latest
    weighted_random_opt([:latest])
  end

  defp random_value({:cg_topics, :fetch_max_bytes}, base_val) do
    weighted_random_opt([base_val, 100_000, 500_000, 2_000_000, 4_000_000])
  end

  defp random_value({:cg_topics, :max_queue_size}, base_val) do
    weighted_random_opt([{5, base_val}, 10, 20, 50])
  end

  defp random_value({:cg_topics, :fetch_interval_ms}, base_val) do
    weighted_random_opt([{5, base_val}, 1000, 2500, 5000, 10_000, 30_000])
  end

  defp random_value({:cg_topics, :handler_cooldown_ms}, base_val) do
    weighted_random_opt([{5, base_val}, 0])
  end

  defp random_value({:cg_topics, :isolation_level}, base_val) do
    weighted_random_opt([{5, base_val}, :read_committed, :read_uncommitted])
  end

  defp random_value({:cg_topics, :fetch_strategy}, base_val) do
    weighted_random_opt([
      {5, base_val},
      {1, {:exclusive, random_value(:exclusive_fetch, nil)}},
      {1, {:shared, :klife_default_fetcher}}
    ])
  end

  defp random_value({:consumer_group, :fetch_strategy}, base_val) do
    weighted_random_opt([
      {5, base_val},
      {1, {:exclusive, random_value(:exclusive_fetch, nil)}},
      {1, {:shared, :klife_default_fetcher}}
    ])
  end

  defp random_value({:consumer_group, :rebalance_timeout_ms}, base_val) do
    weighted_random_opt([{5, base_val}, 10_000, 20_000, 60_000, 120_000])
  end

  defp random_value({:consumer_group, :committers_count}, base_val) do
    weighted_random_opt([{5, base_val}, 1, 2, 4, 8])
  end

  defp random_value({:consumer_group, :isolation_level}, base_val) do
    weighted_random_opt([{5, base_val}, :read_committed, :read_uncommitted])
  end

  defp random_value({:exclusive_fetch, :max_wait_ms}, base_val) do
    weighted_random_opt([{5, base_val}, 0, 100, 500, 1000, 5000])
  end

  defp random_value({:exclusive_fetch, :min_bytes}, base_val) do
    weighted_random_opt([{5, base_val}, 10_000, 20_000, 50_000, 100_000])
  end

  defp random_value({:exclusive_fetch, :max_bytes}, base_val) do
    weighted_random_opt([{5, base_val}, 100_000, 250_000, 500_000, 1_000_000, 5_000_000])
  end

  defp random_value({:exclusive_fetch, :request_timeout_ms}, base_val) do
    weighted_random_opt([{5, base_val}, 3_000, 5_000, 10_000, 30_000])
  end

  defp random_value({:exclusive_fetch, :isolation_level}, base_val) do
    weighted_random_opt([{5, base_val}, :read_committed, :read_uncommitted])
  end

  defp random_value({_context, _key}, base_val), do: base_val

  defp weighted_random_opt(base_opts) do
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

  def lag_warning_threshold(%__MODULE__{} = config) do
    20 * config.producer_max_rps * config.producer_concurrency
  end
end

defmodule Simulator.EngineConfig do
  alias Klife.Consumer.ConsumerGroup
  alias Klife.Consumer.Fetcher

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
    :root_seed,
    :random_seeds_map
  ]

  def generate_config do
    case :persistent_term.get(:rerun_timestamp, nil) do
      nil -> generate_random()
      rerun_ts -> generate_from_file(rerun_ts)
    end
  end

  def parse_topic(tname) do
    String.split(tname, "_") |> List.first()
  end

  defp generate_random do
    # Order is imporant here because some configs depends on others
    config_keys = [
      :root_seed,
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
      :random_seeds_map
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

  defp random_value(:root_seed, _config) do
    <<a::32, b::32, c::32>> = :crypto.strong_rand_bytes(12)
    {a, b, c}
  end

  defp random_value(:random_seeds_map, %__MODULE__{} = config) do
    with_producer =
      for %{topic: tname} <- config.topics,
          producer_idx <- 0..(config.producer_concurrency - 1),
          into: %{} do
        {{:producer, tname, producer_idx}, random_value(:root_seed, config)}
      end

    with_consumer =
      for %{topic: tname} <- config.topics,
          # Pre alocate random seeds for partitions that may be created dynamically
          pidx <- 0..49,
          %{name: cgname, max_consumers: cgcount} <- config.consumer_groups,
          cgidx <- 0..(cgcount - 1),
          into: with_producer do
        {{:consumer, tname, pidx, cgname, cgidx}, random_value(:root_seed, config)}
      end

    Map.put(with_consumer, :event_executor, random_value(:root_seed, config))
  end

  defp random_value(:topics, _config) do
    topic_count = Enum.random(1..10)

    Enum.map(1..topic_count, fn _ ->
      %{
        topic: Base.encode16(:rand.bytes(30)),
        partitions: Enum.random(1..12)
      }
    end)
  end

  defp random_value(:topics_replication_factor, _config) do
    2
  end

  defp random_value(:consumer_groups, _config) do
    cg_count = Enum.random(1..5)

    Enum.map(1..cg_count, fn i ->
      %{name: "SimulatorGroup#{i}", max_consumers: Enum.random(3..6)}
    end)
  end

  defp random_value(:consumer_group_configs, config) do
    for %{name: cg_name, max_consumers: mc} <- config.consumer_groups,
        idx <- 0..(mc - 1) do
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

  defp random_value(:exclusive_fetcher, _config) do
    opts = Fetcher.get_opts()
    # Filter only the opts relevant for exclusive fetch (exclude name, client_id, etc.)
    exclusive_opts =
      Keyword.take(opts, [
        :max_wait_ms,
        :max_bytes_per_request,
        :request_timeout_ms,
        :isolation_level
      ])

    base_config = NimbleOptions.validate!([], exclusive_opts)

    Enum.map(base_config, fn {key, base_val} ->
      {key, random_value({:exclusive_fetcher, key}, base_val)}
    end)
  end

  defp random_value(:fetch_strategy, _config) do
    weighted_random_opt([
      {1, {:exclusive, random_value(:exclusive_fetcher, nil)}},
      {5, {:shared, :klife_default_fetcher}}
    ])
  end

  defp random_value(:producer_max_rps, _config) do
    Enum.random(10..100)
  end

  defp random_value(:producer_concurrency, _config) do
    Enum.random(5..20)
  end

  defp random_value(:producer_loop_interval_ms, _config) do
    1000
  end

  defp random_value(:record_value_bytes, _config) do
    Enum.random(10..1_500)
  end

  defp random_value(:record_key_bytes, _config) do
    Enum.random(32..64)
  end

  defp random_value(:invariants_check_interval_ms, _config) do
    5000
  end

  defp random_value({:cg_topics, :handler_max_unacked_commits}, _base_val) do
    # Can not ensure invariants if not 0
    0
  end

  defp random_value({:cg_topics, :handler_max_batch_size}, base_val) do
    weighted_random_opt([{5, base_val}, :dynamic, 200, 1000])
  end

  defp random_value({:cg_topics, :offset_reset_policy}, _base_val) do
    # TODO: Think how to keep invariants even when not earliest
    # the problem is that we need to figure out how to wait for
    # consumer group stabilization before start producing, otherwise
    # a new consumer may be assigned to a partition after
    # records production has started and before a previous commit
    # by other consumer. This will lead to the new consumer reset
    # the start offset using latest policy effectively skipping
    # some records.
    #
    # Idea: We can have a single record be produced, consumed and committed
    # and them delete it from the engine tables (so it does not count
    # towards invariants validations) and start counting from it, this probaly
    # solves the problem!
    :earliest
  end

  defp random_value({:cg_topics, :fetch_max_bytes}, base_val) do
    weighted_random_opt([{5, base_val}, 500_000, 1_000_000])
  end

  defp random_value({:cg_topics, :max_queue_size}, base_val) do
    weighted_random_opt([{5, base_val}, 10, 20, 50])
  end

  defp random_value({:cg_topics, :fetch_interval_ms}, base_val) do
    weighted_random_opt([{5, base_val}, 100, 200, 500, 1000, 2000])
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
      {1, {:exclusive, random_value(:exclusive_fetcher, nil)}},
      {1, {:shared, :klife_default_fetcher}}
    ])
  end

  defp random_value({:consumer_group, :fetch_strategy}, base_val) do
    weighted_random_opt([
      {5, base_val},
      {1, {:exclusive, random_value(:exclusive_fetcher, nil)}},
      {1, {:shared, :klife_default_fetcher}}
    ])
  end

  defp random_value({:consumer_group, :rebalance_timeout_ms}, base_val) do
    weighted_random_opt([{5, base_val}, 20_000, 30_000])
  end

  defp random_value({:consumer_group, :committers_count}, base_val) do
    weighted_random_opt([{5, base_val}, 1, 2, 4, 8])
  end

  defp random_value({:consumer_group, :isolation_level}, base_val) do
    weighted_random_opt([{5, base_val}, :read_committed, :read_uncommitted])
  end

  defp random_value({:exclusive_fetcher, :max_wait_ms}, base_val) do
    weighted_random_opt([{5, base_val}, 0, 100, 500, 1000, 5000])
  end

  defp random_value({:exclusive_fetcher, :max_bytes_per_request}, base_val) do
    weighted_random_opt([{5, base_val}, 500_000, 1_000_000, 5_000_000])
  end

  defp random_value({:exclusive_fetcher, :request_timeout_ms}, base_val) do
    weighted_random_opt([{5, base_val}, 10_000, 20_000, 30_000])
  end

  defp random_value({:exclusive_fetcher, :isolation_level}, base_val) do
    weighted_random_opt([{5, base_val}, :read_committed, :read_uncommitted])
  end

  defp random_value({:exclusive_fetcher, :linger_ms}, base_val) do
    weighted_random_opt([{5, base_val}, 500, 1000])
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
end

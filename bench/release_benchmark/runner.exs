defmodule Klife.ReleaseBenchmark.Runner do
  alias Klife.ReleaseBenchmark.{Client, Config, Report, Workload}
  alias Klife.Connection
  alias KlifeProtocol.Messages, as: M

  @timeout 120_000
  @producer_partitions 12

  def run(config) do
    Process.flag(:trap_exit, true)
    Logger.configure(level: :error)
    {:ok, _} = Application.ensure_all_started(:klife)
    :rand.seed(:exsss, {17, 29, 43})
    filler = :rand.bytes(config.record_bytes - 24)
    prefix = "klife-release-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
    producer_topics = for n <- 1..3, do: {"#{prefix}-produce-#{n}", @producer_partitions}

    cases = Config.cases(config)

    consumer_topics =
      for %{kind: :consumer, level: level, partitions: partitions} <-
            Enum.uniq_by(cases, &{&1.kind, &1.level}),
          n <- 1..3,
          do: {"#{prefix}-consume-#{level}-#{n}", partitions}

    latency_topics = for n <- 1..3, do: {"#{prefix}-urgent-#{n}", 1}
    topics = producer_topics ++ consumer_topics ++ latency_topics
    path = Path.join(config.output, "sample-#{config.version}-#{config.sample}.etf")

    metadata = %{
      version: config.version,
      sample: config.sample,
      options: config,
      commit: git(["rev-parse", "HEAD"]),
      dirty: git(["status", "--porcelain"]) != "",
      lock_sha256: Base.encode16(:crypto.hash(:sha256, File.read!("mix.lock"))),
      elixir: System.version(),
      otp: System.otp_release(),
      os: :os.type(),
      schedulers: System.schedulers_online(),
      build_env:
        Map.take(System.get_env(), [
          "CFLAGS",
          "CXXFLAGS",
          "ERL_FLAGS",
          "ELIXIR_ERL_OPTIONS",
          "MIX_ENV"
        ]),
      dependencies:
        for(
          {app, _, version} <- Application.loaded_applications(),
          do: {app, List.to_string(version)}
        ),
      complete: false,
      started_at: timestamp(),
      finished_at: nil,
      error: nil,
      results: []
    }

    Report.save_sample(path, metadata)

    try do
      admin = admin_connection(hd(config.brokers))

      try do
        create_topics(admin, topics)

        Enum.reduce(cases, metadata, fn c, saved ->
          started_at = timestamp()

          IO.puts(
            "#{config.version} sample=#{config.sample} #{c.title}/#{c.variant} #{c.profile} #{c.scale}"
          )

          selected =
            case c.kind do
              :consumer ->
                Enum.filter(consumer_topics, fn {name, _} ->
                  String.contains?(name, "-consume-#{c.level}-")
                end)

              :latency ->
                latency_topics

              :producer ->
                producer_topics
            end

          overrides = c.module.settings(c)
          settings = Map.merge(%{producer: [], fetcher: [], topic: [], socket: []}, overrides)

          client_config = [
            connection: [bootstrap_servers: config.brokers, socket_opts: settings.socket],
            producers: [Keyword.put(settings.producer, :name, :klife_default_producer)],
            fetchers: [Keyword.put(settings.fetcher, :name, :klife_default_fetcher)],
            disabled_features: [:txn_producer],
            topics: Enum.map(topics, fn {name, _} -> [name: name] end)
          ]

          Application.put_env(:klife_release_benchmark, Client, client_config)
          {:ok, client} = Client.start_link([])

          result =
            try do
              unless c.kind == :consumer,
                do: Workload.warmup_partitions(selected, filler)

              result =
                c.module.run(c, %{
                  config: config,
                  topics: selected,
                  filler: filler,
                  settings: settings
                })

              Map.merge(
                c,
                Map.merge(result, %{
                  overrides: overrides,
                  settings: effective_settings(settings, c),
                  client_config: client_config,
                  workload_topics: selected,
                  started_at: started_at,
                  finished_at: timestamp()
                })
              )
            after
              Supervisor.stop(client, :normal, @timeout)
            end

          details =
            case c.kind do
              :consumer ->
                "catch-up=#{Float.round(result.catchup_ms, 3)} ms, remaining committed lag=#{result.remaining_lag_records}"

              :latency ->
                "ack p99=#{result.ack_p99_ms} ms, delivery p99=#{result.e2e_p99_ms} ms"

              :producer ->
                "ack p99=#{result.ack_p99_ms} ms"
            end

          IO.puts("  #{round(result.records_s)} records/s; #{details}; #{result.status}")

          saved = %{saved | results: saved.results ++ [result]}
          Report.save_sample(path, saved)
          Report.write(config, console: false)

          saved
        end)
        |> Map.put(:complete, true)
        |> Map.put(:finished_at, timestamp())
        |> then(&Report.save_sample(path, &1))
      after
        try do
          delete_topics(admin, Enum.map(topics, &elem(&1, 0)))
        after
          Connection.close(admin)
        end
      end
    rescue
      error ->
        File.write!(
          Path.join(config.output, "failure-#{config.version}-#{config.sample}.txt"),
          Exception.format(:error, error, __STACKTRACE__)
        )

        failed =
          Config.read(path)
          |> Map.merge(%{
            complete: false,
            finished_at: timestamp(),
            error: Exception.format(:error, error, __STACKTRACE__)
          })

        Report.save_sample(path, failed)
        reraise error, __STACKTRACE__
    end
  end

  defp effective_settings(settings, c) do
    producer =
      NimbleOptions.validate!(
        Keyword.put(settings.producer, :name, :klife_default_producer),
        Klife.Producer.get_opts()
      )

    fetcher =
      NimbleOptions.validate!(
        Keyword.put(settings.fetcher, :name, :klife_default_fetcher),
        Klife.Consumer.Fetcher.get_opts()
      )

    brokers = length(Klife.Connection.Controller.get_known_brokers(Client))

    fetcher =
      Keyword.put_new(fetcher, :batchers_count, ceil(System.schedulers_online() / brokers))

    topic =
      NimbleOptions.validate!(
        settings.topic
        |> Keyword.put(:name, "benchmark")
        |> Keyword.put(
          :offset_reset_policy,
          if(c.kind == :consumer, do: :earliest, else: :latest)
        ),
        Klife.Consumer.ConsumerGroup.TopicConfig.get_opts()
      )

    %{
      producer: producer,
      fetcher: fetcher,
      topic: Keyword.put_new(topic, :max_queue_size, 5),
      socket: Keyword.merge([keepalive: true], settings.socket),
      brokers: brokers
    }
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp git(args) do
    {output, 0} = System.cmd("git", args)
    String.trim(output)
  end

  defp admin_connection(endpoint) do
    {:ok, bootstrap} = Connection.new(endpoint, false, [active: false], [], [])

    try do
      {:ok, %{brokers: brokers, controller: controller}} =
        Klife.Connection.Controller.get_cluster_info(bootstrap)

      {_, address} = Enum.find(brokers, fn {id, _} -> id == controller end)
      {:ok, conn} = Connection.new(address, false, [active: false], [], [])
      conn
    after
      Connection.close(bootstrap)
    end
  end

  defp create_topics(conn, topics) do
    response =
      admin_request(conn, M.CreateTopics, 2, %{
        topics:
          Enum.map(topics, fn {name, partitions} ->
            %{
              name: name,
              num_partitions: partitions,
              replication_factor: 2,
              assignments: [],
              configs: []
            }
          end),
        timeout_ms: 30_000,
        validate_only: false
      })

    unless Enum.all?(response.topics, &(&1.error_code == 0)),
      do: raise("Topic creation failed: #{inspect(response)}")
  end

  defp delete_topics(conn, topics) do
    response = admin_request(conn, M.DeleteTopics, 1, %{topic_names: topics, timeout_ms: 30_000})

    unless Enum.all?(response.responses, &(&1.error_code in [0, 3])),
      do: raise("Topic cleanup failed: #{inspect(response)}")
  end

  defp admin_request(conn, module, version, content) do
    data = module.serialize_request(%{headers: %{correlation_id: 1}, content: content}, version)
    :ok = Connection.write(data, conn)
    {:ok, data} = Connection.read(conn)
    {:ok, %{content: response}} = module.deserialize_response(data, version)
    response
  end
end

defmodule Klife.Consumer.Fetcher do
  @fetcher_opts [
    name: [
      type: {:or, [:atom, :string]},
      required: true,
      doc: "Fetcher name. Must be unique per client. Can be passed as an option for consumers"
    ],
    client_id: [
      type: :string,
      required: false,
      doc:
        "String used on all requests. If not provided the following string is used: \"klife_fetcher.{client_name}.{fetcher_name}\""
    ],
    linger_ms: [
      type: :non_neg_integer,
      default: 0,
      doc:
        "The maximum time to wait for additional record requests from consumers before sending a batch to the broker."
    ],
    max_bytes_per_request: [
      type: :non_neg_integer,
      default: 5_000_000,
      doc: "The maximum amount of bytes to be returned in a single fetch request."
    ],
    max_in_flight_requests: [
      type: :non_neg_integer,
      default: 3,
      doc:
        "The maximum number of fetch requests per batcher the fetcher will send before waiting for responses."
    ],
    # We must have more batchers here than for the producer
    # because the message deserialization happens inside
    # the batcher, and if the response is large (very likely for fetch)
    # it may become a bottleneck!
    batchers_count: [
      type: :pos_integer,
      doc:
        "The number of batchers per broker the fetcher will start. Defaults to `ceil(schedulers_online / known_brokers_count)`"
    ],
    request_timeout_ms: [
      type: :non_neg_integer,
      default: :timer.seconds(30),
      doc:
        "The maximum amount of time the fetcher will wait for a broker response to a request before considering it as failed."
    ],
    max_wait_ms: [
      type: :non_neg_integer,
      default: 0,
      doc:
        "Define for how long the broker may wait (for more records) before send a response to the client"
    ]
  ]

  @moduledoc """
  Defines a fetcher.

  A fetcher is responsible for batching and sending fetch requests to Kafka brokers. Klife groups
  all topic-partitions that share the same broker leader into the same fetcher batcher,
  so most requests are sent as a single batched TCP call per broker, maximizing network efficiency.

  Fetchers are configured as part of `Klife.Client` setup. Most users interact with fetchers
  indirectly through a `Klife.Consumer.ConsumerGroup`, which manages offset tracking, rebalancing,
  and dispatching under the hood. The consumer group creates or shares fetchers according to its
  `:fetch_strategy` configuration, see the `Klife.Consumer.ConsumerGroup` docs for details.

  For advanced use cases that require full control over offset management and partition assignment
  (i.e. standalone consumers), fetchers can also be used directly through the `Klife.Client` fetch API.
  This gives you the same building blocks that the consumer group uses internally.

  ## Client configurations

  #{NimbleOptions.docs(@fetcher_opts)}

  ## How many fetchers?

  By default, all fetch requests use a single default fetcher configured with standard settings,
  maximizing batch efficiency.

  There are two main reasons to consider using multiple fetchers:

  - Different configurations for specific topics: Some topics may benefit from unique settings. You can assign topics with similar needs
  to the same fetcher.

  - Fault isolation: Each fetcher has an independent request pipeline. Using multiple fetchers
  can prevent issues in one topic from affecting fetch latency of others.

  Consider this scenario:

  ```md
  - A fetcher batches fetch requests for topics A and B into a single request to the broker leader.
  - For some reason, topic B is temporarily unavailable and the broker responds slowly.
  - Because both topics share the same batcher pipeline, fetch responses for topic A are delayed
    waiting on topic B's slow response.
  ```

  If this presents a potential issue for your use case, consider creating multiple fetchers
  and dedicating some of them to critical topics. However, note that this may slightly reduce
  batch efficiency in normal operation.

  ## Batchers count

  Each fetcher starts a configurable number of batchers for each broker in the Kafka cluster.
  Topic-partitions with the same leader are managed by the same batcher.

  Unlike producers, fetchers default `batchers_count` to `ceil(schedulers_online / known_brokers_count)`
  rather than 1. This is because fetch responses are typically large and deserialization happens inside
  the batcher, a single batcher per broker can easily become a CPU bottleneck.

  You may still want to tune this value:

  - Lower values improve batch efficiency at the cost of parallelism.
  - Higher values improve parallelism but may reduce batch efficiency.

  ## Dynamic batching

  Like the producer, the fetcher uses dynamic batching. Fetch requests that arrive while the
  batcher is waiting for in-flight responses are automatically accumulated into the next batch.
  As a result, it is rarely necessary to set `linger_ms` to a value greater than zero.

  Increasing `linger_ms` may be helpful only if you set a high value for `max_in_flight_requests`
  or if you need to limit request rates to the broker for specific reasons.

  ## Isolation level

  The `isolation_level` is a per-request option passed through the `Klife.Client` fetch API
  (defaulting to `:read_committed`). It controls whether fetch responses include uncommitted
  transactional records:

  - `:read_committed`: only returns records from committed transactions. Recommended for most use cases.
  - `:read_uncommitted`: returns all records, including those from transactions that may later
  be aborted. Use this only when you need the lowest possible latency and can tolerate
  reading uncommitted data.

  Each fetcher maintains batchers for both isolation levels, so a single fetcher can serve
  requests with different isolation levels without any additional configuration.

  ## Filtering fetched records

  Fetch responses may include records you want to skip. For example, records before your
  starting offset, Kafka control records (transaction markers), or records from aborted
  transactions. Use `Klife.Record.filter_records/2` to remove them:

  ```elixir
  {:ok, records} = MyClient.fetch("my_topic", 0, 42)

  filtered =
    Klife.Record.filter_records(records,
      base_offset: 42,
      exclude_control: true,
      exclude_aborted: true
    )
  ```

  See the `Klife.Record` docs for further detail.

  ## Client default fetcher

  If a fetch call is made without specifying a fetcher, the client default fetcher is used.
  The client default fetcher can be configured as part of the overall `Klife.Client` setup.
  Refer to `Klife.Client` documentation for more details.
  """

  @doc false
  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  alias Klife.Connection.Controller, as: ConnController
  alias Klife.Consumer.Fetcher.Batcher

  alias Klife.MetadataCache

  alias Klife.PubSub

  defstruct Keyword.keys(@fetcher_opts) ++
              [:client_name, :batcher_supervisor, :latest_metadata_sync_ts]

  @doc false
  def get_opts, do: @fetcher_opts

  @doc false
  def default_fetcher_config, do: NimbleOptions.validate!([], @fetcher_opts)

  @doc false
  def start_link(args) do
    client_name = args.client_name
    fetcher_name = args.name
    GenServer.start_link(__MODULE__, args, name: get_process_name(client_name, fetcher_name))
  end

  defp get_process_name(client, fetcher_name),
    do: via_tuple({__MODULE__, client, fetcher_name})

  @doc false
  def fetch(tpo_or_list, client, opts \\ [])

  @doc false
  def fetch({_t, _p, _o} = key, client, opts) do
    [key]
    |> fetch(client, opts)
    |> Map.fetch!(key)
  end

  @doc false
  def fetch(tpo_list, client, opts) when is_list(tpo_list) do
    fetcher = opts[:fetcher] || client.get_default_fetcher()
    iso_level = opts[:isolation_level] || :read_committed
    max_bytes = opts[:max_bytes] || 100_000

    timeout =
      Enum.map(tpo_list, fn {t, p, o} ->
        tpo_to_batch_item(t, p, o, client, max_bytes, fetcher)
      end)
      |> Enum.group_by(fn {key, _item} -> key end, fn {_, val} -> val end)
      |> Enum.reduce(0, fn {{broker, batcher_id}, items}, acc ->
        fetch_resp =
          try do
            Batcher.request_data(items, client, fetcher, broker, batcher_id, iso_level)
          catch
            kind, reason ->
              {:error, {kind, reason}}
          end

        case fetch_resp do
          {:ok, timeout, _pid} ->
            if timeout > acc, do: timeout, else: acc

          # This is a hack to simplify error handling
          # instead of hanlding possible errors on this step
          # we send to self errors as messages, exactly
          # the same way the Dispatcher would do in case of
          # a normal error.
          {:error, reason} ->
            Enum.each(items, fn %Batcher.BatchItem{} = item ->
              send(
                self(),
                {:klife_fetch_response, {item.topic_name, item.partition, item.offset_to_fetch},
                 {:error, inspect(reason)}}
              )
            end)

            acc
        end
      end)

    wait_fetch_response(timeout, length(tpo_list))
  end

  @doc false
  def fetch_async({t, p, o}, client, opts \\ []) do
    fetcher = opts[:fetcher] || client.get_default_fetcher()
    iso_level = opts[:isolation_level] || :read_committed
    max_bytes = opts[:max_bytes] || 500_000

    {{broker, batcher_id}, item} = tpo_to_batch_item(t, p, o, client, max_bytes, fetcher)

    # This try/catch is important to prevent raise surges during cluster
    # changes. This raise surges may cause unecessary consumer restarts
    fetch_resp =
      try do
        Batcher.request_data([item], client, fetcher, broker, batcher_id, iso_level)
      catch
        kind, reason ->
          {:error, {kind, reason}}
      end

    case fetch_resp do
      {:ok, _timeout, pid} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp tpo_to_batch_item(t, p, o, client, max_bytes, fetcher) do
    {:ok,
     %{
       topic_id: t_id,
       leader_id: broker
     }} = MetadataCache.get_metadata(client, t, p)

    batcher_id = get_batcher_id(client, fetcher, t, p)

    {{broker, batcher_id},
     %Batcher.BatchItem{
       topic_id: t_id,
       topic_name: t,
       partition: p,
       offset_to_fetch: o,
       __callback: self(),
       max_bytes: max_bytes
     }}
  end

  defp wait_fetch_response(timeout_ms, max_resps) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms + 2_000
    do_wait_fetch_response(deadline, max_resps, 0, %{})
  end

  defp do_wait_fetch_response(_deadline, max_resps, max_resps, resp_acc), do: resp_acc

  defp do_wait_fetch_response(deadline, max_resps, counter, resp_acc) do
    now = System.monotonic_time(:millisecond)

    receive do
      {:klife_fetch_response, {t, p, o}, resp} ->
        resp =
          case resp do
            {:ok, list_recs} ->
              {:ok, Klife.Record.filter_records(list_recs, base_offset: o)}

            other ->
              other
          end

        new_resp_acc = Map.put(resp_acc, {t, p, o}, resp)
        new_counter = counter + 1
        do_wait_fetch_response(deadline, max_resps, new_counter, new_resp_acc)
    after
      # This should never happen, because the Dispacher already
      # tracks requests timeouts and send it as response
      deadline - now ->
        raise "Unexpected timeout while waiting for fetch response (received=#{counter}/#{max_resps})"
    end
  end

  @doc false
  @impl true
  def init(validated_args) do
    args_map = Map.take(validated_args, Map.keys(%__MODULE__{}))

    {:ok, batcher_sup_pid} = DynamicSupervisor.start_link([])

    state =
      Map.merge(
        %__MODULE__{
          client_id: "klife_fetcher.#{args_map.client_name}.#{args_map.name}",
          batcher_supervisor: batcher_sup_pid
        },
        args_map
      )
      |> Map.update!(:batchers_count, fn bc ->
        if bc == nil do
          known_brokers_count =
            validated_args.client_name
            |> ConnController.get_known_brokers()
            |> length()

          ceil(System.schedulers_online() / known_brokers_count)
        else
          bc
        end
      end)

    :ok = PubSub.subscribe({:metadata_updated, args_map.client_name})
    # Although tecnicaly we could just listen to metadata changes
    # cluster changes happens faster than metadata ones and in
    # order to be able to react faster we must also subscribe to
    # cluster change events.
    :ok = PubSub.subscribe({:cluster_change, args_map.client_name})

    :ok = handle_batchers(state)
    {:ok, state}
  end

  defp sync_metadata_cache(client, fetcher) do
    client
    |> get_process_name(fetcher)
    |> GenServer.call({:sync_metadata_cache, System.monotonic_time()})
  end

  @doc false
  @impl true
  def handle_call({:sync_metadata_cache, ts}, _from, %__MODULE__{} = state) do
    if ts < state.latest_metadata_sync_ts do
      {:reply, :ok, state}
    else
      {:noreply, state} = handle_cluster_or_metadata_changes(state)
      {:reply, :ok, state}
    end
  end

  @doc false
  @impl true
  def handle_info(
        {{:metadata_updated, client_name}, _event_data, _callback_data},
        %__MODULE__{client_name: client_name} = state
      ) do
    handle_cluster_or_metadata_changes(state)
  end

  @doc false
  def handle_info(
        {{:cluster_change, client_name}, _event_data, _callback_data},
        %__MODULE__{client_name: client_name} = state
      ) do
    handle_cluster_or_metadata_changes(state)
  end

  defp handle_cluster_or_metadata_changes(state) do
    :ok = handle_batchers(state)
    {:noreply, %{state | latest_metadata_sync_ts: System.monotonic_time()}}
  end

  @doc false
  def handle_batchers(%__MODULE__{} = state) do
    known_brokers = ConnController.get_known_brokers(state.client_name)
    :ok = init_batchers(state, known_brokers)
    :ok = setup_batcher_ids(state)
  end

  defp init_batchers(%__MODULE__{} = state, known_brokers) do
    for broker_id <- known_brokers,
        batcher_id <- 0..(state.batchers_count - 1),
        iso_level <- [:read_committed, :read_uncommitted] do
      args = [
        {:broker_id, broker_id},
        {:batcher_id, batcher_id},
        {:fetcher_config, state},
        {:batcher_config, build_batcher_config(state)},
        {:iso_level, iso_level}
      ]

      spec = %{
        id: {__MODULE__, Batcher, state.client_name, state.name, broker_id, batcher_id},
        start: {Batcher, :start_link, [args]},
        restart: :transient,
        type: :worker
      }

      case DynamicSupervisor.start_child(state.batcher_supervisor, spec) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  defp setup_batcher_ids(%__MODULE__{} = state) do
    %__MODULE__{
      client_name: client_name,
      name: fetcher_name
    } = state

    batchers_data_map =
      client_name
      |> MetadataCache.get_all_metadata()
      |> Enum.group_by(& &1.leader_id)
      |> Enum.map(fn {_broker_id, topics_list} ->
        topics_list
        |> Enum.with_index()
        |> Enum.map(fn {val, idx} ->
          batcher_id =
            if state.batchers_count > 1, do: rem(idx, state.batchers_count), else: 0

          Map.put(val, :batcher_id, batcher_id)
        end)
      end)
      |> List.flatten()
      |> Enum.map(fn %{topic_name: t_name, partition_idx: partition, batcher_id: b_id} ->
        {{t_name, partition}, b_id}
      end)
      |> Map.new()

    save_batcher_id_map(client_name, fetcher_name, batchers_data_map)
  end

  defp save_batcher_id_map(client_name, fetcher_name, batcher_map) do
    :persistent_term.put(
      {__MODULE__, client_name, fetcher_name},
      batcher_map
    )
  end

  @doc false
  def get_batcher_id(client_name, fetcher_name, topic, partition) do
    {__MODULE__, client_name, fetcher_name}
    |> :persistent_term.get()
    |> Map.get({topic, partition})
    |> case do
      nil ->
        :ok = sync_metadata_cache(client_name, fetcher_name)

        {__MODULE__, client_name, fetcher_name}
        |> :persistent_term.get()
        |> Map.fetch!({topic, partition})

      data ->
        data
    end
  end

  defp build_batcher_config(%__MODULE__{} = state) do
    [
      {:batch_wait_time_ms, state.linger_ms},
      {:max_in_flight, state.max_in_flight_requests},
      {:max_batch_size, state.max_bytes_per_request}
    ]
  end
end

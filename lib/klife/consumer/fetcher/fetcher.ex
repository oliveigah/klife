defmodule Klife.Consumer.Fetcher do
  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  alias Klife.Connection.Controller, as: ConnController
  alias Klife.Consumer.Fetcher.Batcher

  alias Klife.MetadataCache

  alias Klife.PubSub

  alias Klife.Connection.Broker

  alias KlifeProtocol.Messages, as: M

  @fetcher_opts [
    name: [
      type: {:or, [:atom, :string]},
      required: true,
      doc: "Fetcher name. Must be unique per client. Can be passed as an option for consumers"
    ],
    client_id: [
      type: :string,
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
      default: 5,
      doc:
        "The maximum number of fetch requests per broker the fetcher will send before waiting for responses."
    ],
    batchers_count: [
      type: :pos_integer,
      doc:
        "The number of batchers per broker the fetcher will start. Defaults to `ceil(schedulers_online / known_brokers_count)`"
    ],
    request_timeout_ms: [
      type: :non_neg_integer,
      default: :timer.seconds(5),
      doc:
        "The maximum amount of time the fetcher will wait for a broker response to a request before considering it as failed."
    ],
    isolation_level: [
      type: {:in, [:read_committed, :read_uncommitted]},
      default: :read_committed,
      doc:
        "Define if the consumers of the consumer group will receive uncommitted transactional records"
    ],
    max_wait_ms: [
      type: :non_neg_integer,
      default: 0,
      doc:
        "Define for how long the broker may wait (for more records) before send a response to the client"
    ]
  ]

  defstruct Keyword.keys(@fetcher_opts) ++ [:client_name, :batcher_supervisor]

  def get_opts, do: @fetcher_opts

  def default_fetcher_config, do: NimbleOptions.validate!([], @fetcher_opts)

  def start_link(args) do
    client_name = args.client_name
    fetcher_name = args.name
    GenServer.start_link(__MODULE__, args, name: get_process_name(client_name, fetcher_name))
  end

  defp get_process_name(client, fetcher_name),
    do: via_tuple({__MODULE__, client, fetcher_name})

  def fetch(tpo_or_list, client, opts \\ [])

  def fetch({_t, _p, _o} = key, client, opts) do
    [key]
    |> fetch(client, opts)
    |> Map.fetch!(key)
  end

  def fetch(tpo_list, client, opts) when is_list(tpo_list) do
    fetcher = opts[:fetcher] || client.get_default_fetcher()
    iso_level = opts[:isolation_level] || :read_committed
    max_bytes = opts[:max_bytes] || 100_000

    timeout =
      Enum.map(tpo_list, fn {t, p, o} ->
        tpo_to_batch_item(t, p, o, client, max_bytes, fetcher)
      end)
      |> Enum.group_by(fn {key, _item} -> key end, fn {_, val} -> val end)
      |> Enum.reduce(0, fn {{broker, batcher_id}, items}, _acc ->
        {:ok, timeout} =
          Batcher.request_data(items, client, fetcher, broker, batcher_id, iso_level)

        timeout
      end)

    wait_fetch_response(timeout, length(tpo_list))
  end

  def fetch_async({t, p, o}, client, opts \\ []) do
    fetcher = opts[:fetcher] || client.get_default_fetcher()
    iso_level = opts[:isolation_level] || :read_committed
    max_bytes = opts[:max_bytes] || 100_000

    {{broker, batcher_id}, item} = tpo_to_batch_item(t, p, o, client, max_bytes, fetcher)
    {:ok, timeout} = Batcher.request_data([item], client, fetcher, broker, batcher_id, iso_level)
    {:ok, timeout}
  end

  def fetch_raw_async({t, p, o}, client, opts \\ []) do
    {:ok,
     %{
       topic_id: t_id,
       leader_id: broker
     }} = MetadataCache.get_metadata(client, t, p)

    data = %{
      max_wait_ms: opts[:max_wait_ms] || 0,
      min_bytes: opts[:min_bytes] || 1,
      max_bytes: opts[:max_bytes] || 500_000,
      isolation_level:
        case Keyword.get(opts, :isolation_level, :read_committed) do
          :read_committed -> 1
          :read_uncommitted -> 0
        end,
      session_id: opts[:session_id] || 0,
      session_epoch: opts[:session_epoch] || 0,
      topics: [
        %{
          topic_id: t_id,
          partitions: [
            %{
              partition: p,
              current_leader_epoch: opts[:current_leader_epoch] || -1,
              fetch_offset: o,
              last_fetched_epoch: opts[:last_fetched_epoch] || -1,
              log_start_offset: opts[:log_start_offset] || -1,
              partition_max_bytes: opts[:max_bytes] || 500_000
            }
          ]
        }
      ],
      forgotten_topics_data: [],
      rack_id: opts[:rack_id] || ""
    }

    req_opts = [
      async: true,
      callback_pid: self(),
      callback_ref: opts[:callback_ref] || make_ref()
    ]

    headers = %{
      client_id: opts[:client_id] || nil
    }

    Broker.send_message(
      M.Fetch,
      client,
      broker,
      data,
      headers,
      req_opts
    )
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
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_fetch_response(deadline, max_resps, 0, %{})
  end

  defp do_wait_fetch_response(_deadline, max_resps, max_resps, resp_acc), do: resp_acc

  defp do_wait_fetch_response(deadline, max_resps, counter, resp_acc) do
    now = System.monotonic_time(:millisecond)

    receive do
      {:klife_fetch_response, {t, p, o}, resp} ->
        new_resp_acc = Map.put(resp_acc, {t, p, o}, resp)
        new_counter = counter + 1
        do_wait_fetch_response(deadline, max_resps, new_counter, new_resp_acc)
    after
      # This should never happen, because the Dispacher already
      # tracks requests timeouts and send it as response
      deadline - now ->
        raise "Unexpected timeout while waiting for fetch response"
    end
  end

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

  @impl true
  def handle_info(
        {{:metadata_updated, client_name}, _event_data, _callback_data},
        %__MODULE__{client_name: client_name} = state
      ) do
    handle_cluster_or_metadata_changes(state)
  end

  def handle_info(
        {{:cluster_change, client_name}, _event_data, _callback_data},
        %__MODULE__{client_name: client_name} = state
      ) do
    handle_cluster_or_metadata_changes(state)
  end

  defp handle_cluster_or_metadata_changes(state) do
    :ok = handle_batchers(state)
    {:noreply, state}
  end

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

  def get_batcher_id(client_name, fetcher_name, topic, partition) do
    {__MODULE__, client_name, fetcher_name}
    |> :persistent_term.get()
    |> Map.fetch!({topic, partition})
  end

  defp build_batcher_config(%__MODULE__{} = state) do
    [
      {:batch_wait_time_ms, state.linger_ms},
      {:max_in_flight, state.max_in_flight_requests},
      {:max_batch_size, state.max_bytes_per_request}
    ]
  end
end

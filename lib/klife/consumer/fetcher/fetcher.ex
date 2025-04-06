defmodule Klife.Consumer.Fetcher do
  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  alias Klife.Connection.Controller, as: ConnController
  alias Klife.Consumer.Fetcher.Batcher

  alias Klife.MetadataCache

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
      default: 1,
      doc: "The number of batchers per broker the fetcher will start."
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
      type_doc: "`:read_committed` or `:read_uncommitted`",
      doc:
        "Define if the consumers of the consumer group will receive uncommitted transactional records"
    ]
  ]

  defstruct Keyword.keys(@fetcher_opts) ++ [:client_name]

  def get_opts, do: @fetcher_opts

  def default_fetcher_config, do: NimbleOptions.validate!([], @fetcher_opts)

  def start_link(args) do
    client_name = args.client_name
    fetcher_name = args.name
    GenServer.start_link(__MODULE__, args, name: get_process_name(client_name, fetcher_name))
  end

  defp get_process_name(client, fetcher_name),
    do: via_tuple({__MODULE__, client, fetcher_name})

  def fetch(tpo_list, client, opts \\ []) do
    fetcher = opts[:fetcher] || client.get_default_fetcher()
    iso_level = opts[:isolation_level] || :read_committed
    max_bytes = opts[:max_bytes] || 100_000

    timeout =
      Enum.map(tpo_list, fn {t, p, o} ->
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
      end)
      |> Enum.group_by(fn {key, _item} -> key end, fn {_, val} -> val end)
      |> Enum.reduce(0, fn {{broker, batcher_id}, items}, acc ->
        {:ok, timeout} =
          Batcher.request_data(items, client, fetcher, broker, batcher_id, iso_level)

        timeout
      end)

    wait_fetch_response(timeout, length(tpo_list))
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

  def group_by_batcher(meta_and_batch_items, client_name, fetcher) do
    meta_and_batch_items
    |> Enum.group_by(fn {meta, %Batcher.BatchItem{} = item} ->
      nil
    end)
  end

  @impl true
  def init(validated_args) do
    args_map = Map.take(validated_args, Map.keys(%__MODULE__{}))

    state =
      Map.merge(
        %__MODULE__{
          client_id: "klife_fetcher.{args_map.client_name}.{args_map.name}"
        },
        args_map
      )

    :ok = handle_batchers(state)
    {:ok, state}
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
      result =
        Batcher.start_link([
          {:broker_id, broker_id},
          {:batcher_id, batcher_id},
          {:fetcher_config, state},
          {:batcher_config, build_batcher_config(state)},
          {:iso_level, iso_level}
        ])

      case result do
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
    |> Enum.each(fn %{topic_name: t_name, partition_idx: partition, batcher_id: b_id} ->
      put_batcher_id(client_name, fetcher_name, t_name, partition, b_id)
    end)
  end

  defp put_batcher_id(client_name, fetcher_name, topic, partition, batcher_id) do
    :persistent_term.put(
      {__MODULE__, client_name, fetcher_name, topic, partition},
      batcher_id
    )
  end

  def get_batcher_id(client_name, fetcher_name, topic, partition) do
    :persistent_term.get({__MODULE__, client_name, fetcher_name, topic, partition})
  end

  defp build_batcher_config(%__MODULE__{} = state) do
    [
      {:batch_wait_time_ms, state.linger_ms},
      {:max_in_flight, state.max_in_flight_requests},
      {:batch_max_size, state.max_bytes_per_request}
    ]
  end
end

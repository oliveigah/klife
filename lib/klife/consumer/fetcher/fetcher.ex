defmodule Klife.Consumer.Fetcher do
  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  alias Klife.Connection.Controller, as: ConnController
  alias Klife.Consumer.Fetcher.Batcher

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
    _fetcher = opts[:fetcher] || client.default_fetcher()
    _iso_level = opts[:isolation_level] || :read_committed
    max_bytes = opts[:max_bytes] || 100_000

    _reqs =
      Enum.map(tpo_list, fn {t, p, o} ->
        %Batcher.BatchItem{
          # TODO: Handle topic id conversion
          topic_id: t,
          topic_name: t,
          partition: p,
          offset_to_fetch: o,
          __callback: self(),
          max_bytes: max_bytes
        }
      end)

    # Batcher.request_data(reqs, client, fetcher, )
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

  defp build_batcher_config(%__MODULE__{} = state) do
    [
      {:batch_wait_time_ms, state.linger_ms},
      {:max_in_flight, state.max_in_flight_requests},
      {:batch_max_size, state.max_bytes_per_request}
    ]
  end
end

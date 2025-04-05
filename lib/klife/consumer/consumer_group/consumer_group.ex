defmodule Klife.Consumer.ConsumerGroup do
  import Klife.ProcessRegistry, only: [via_tuple: 1]

  require Logger

  alias Klife.Connection.Broker

  alias Klife.Helpers

  alias KlifeProtocol.Messages, as: M

  alias Klife.Consumer.ConsumerGroup.TopicConfig

  @consumer_group_opts [
    # TODO: Implement regex based topic subscription
    topics: [
      type: {:list, {:keyword_list, TopicConfig.get_opts()}},
      required: true,
      doc:
        "The maximum time to wait for additional record requests from consumers before sending a batch to the broker."
    ],
    group_name: [
      type: :string,
      required: true,
      doc: "Name of the consumer group"
    ],
    instance_id: [
      type: :string,
      doc: "Value to identify the consumer across restarts (static membership). See KIP-345"
    ],
    rebalance_timeout_ms: [
      type: :non_neg_integer,
      default: 30_000,
      doc:
        "The maximum time in milliseconds that the coordinator will wait on the member to revoke its partitions"
    ],
    fetcher_name: [
      type: {:or, [:atom, :string]},
      doc: "Fetcher name to be used by the consumers of the group."
    ]
  ]

  defstruct Keyword.keys(@consumer_group_opts) ++
              [
                :client_name,
                :coordinator_id,
                :member_id,
                :epoch
              ]

  def start_link(mod, args) do
    base_validated_args =
      args
      |> NimbleOptions.validate!(@consumer_group_opts)
      |> Helpers.keyword_list_to_map()

    validated_args =
      %__MODULE__{}
      |> Map.from_struct()
      |> Map.merge(base_validated_args)

    GenServer.start_link(mod, validated_args,
      name: via_tuple({__MODULE__, mod.klife_client(), validated_args.group_name})
    )
  end

  def init(mod, args_map) do
    state =
      %__MODULE__{
        topics: args_map.topics,
        group_name: args_map.group_name,
        instance_id: args_map.instance_id,
        rebalance_timeout_ms: args_map.rebalance_timeout_ms,
        client_name: mod.klife_client(),
        member_id: UUID.uuid4(),
        epoch: 0
      }

    coordinatior_id = find_coordinator!(state)
    state = %__MODULE__{state | coordinator_id: coordinatior_id}

    {:ok, state}
  end

  def find_coordinator!(%__MODULE__{} = state) do
    content = %{
      key_type: 0,
      coordinator_keys: [state.group_name]
    }

    fun = fn ->
      case Broker.send_message(M.FindCoordinator, state.client_name, :any, content) do
        {:ok, %{content: %{coordinators: [%{error_code: 0, node_id: broker_id}]}}} ->
          broker_id

        {:ok, %{content: %{coordinators: [%{error_code: ec}]}}} ->
          Logger.error(
            "Error code #{ec} returned from broker for client #{inspect(state.client_name)} on #{inspect(M.FindCoordinator)} call"
          )

          :retry

        _data ->
          :retry
      end
    end

    Helpers.with_timeout!(fun, :timer.seconds(30))
  end

  def send_heartbeat(%__MODULE__{} = state) do
    content =
      %{
        group_id: state.group_name,
        member_id: state.member_id,
        member_epoch: state.epoch || 0,
        instance_id: state.instance_id,
        rebalance_timeout_ms: state.rebalance_timeout_ms,
        subscribed_topic_names: Enum.map(state.topics, fn t -> t.name end),
        # TODO: Implement later
        rack_id: nil,
        subscribed_topic_regex: nil,
        server_assignor: nil,
        topic_partitions: []
      }

    Broker.send_message(
      M.ConsumerGroupHeartbeat,
      state.client_name,
      state.coordinator_id,
      content
    )
  end

  defmacro __using__(opts) do
    if !Keyword.has_key?(opts, :client) do
      raise ArgumentError, """
      client option is required when using Klife.Consumer.ConsumerGroup.

      use Klife.Consumer.ConsumerGroup, client: MyKlifeClient
      """
    end

    quote bind_quoted: [opts: opts] do
      use GenServer

      def klife_client(), do: unquote(opts[:client])

      def start_link(args), do: Klife.Consumer.ConsumerGroup.start_link(__MODULE__, args)

      def init(args), do: Klife.Consumer.ConsumerGroup.init(__MODULE__, args)
    end
  end
end

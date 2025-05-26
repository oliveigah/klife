defmodule Klife.Consumer.ConsumerGroup do
  import Klife.ProcessRegistry, only: [via_tuple: 1]

  require Logger

  alias Klife.Connection.Broker

  alias Klife.Helpers

  alias KlifeProtocol.Messages, as: M

  alias Klife.Consumer.ConsumerGroup.TopicConfig

  alias Klife.Consumer.ConsumerGroup.Consumer

  alias Klife.PubSub

  @consumer_group_opts [
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
                :mod,
                :client_name,
                :coordinator_id,
                :member_id,
                :epoch,
                :heartbeat_interval_ms,
                :assigned_topic_partitions,
                :consumer_supervisor,
                :consumers_monitor_map
              ]

  def start_link(cg_mod, args) do
    base_validated_args =
      args
      |> NimbleOptions.validate!(@consumer_group_opts)
      |> Helpers.keyword_list_to_map()

    validated_args =
      %__MODULE__{}
      |> Map.from_struct()
      |> Map.merge(base_validated_args)
      |> Map.put(:mod, cg_mod)

    GenServer.start_link(cg_mod, validated_args, name: get_process_name(cg_mod))
  end

  defp get_process_name(cg_mod) do
    via_tuple({__MODULE__, cg_mod})
  end

  def send_consumer_up(cg_mod, topic_id, partition) do
    cg = get_process_name(cg_mod)
    GenServer.cast(cg, {:consumer_up, {topic_id, partition, self()}})
  end

  def init(mod, args_map) do
    {:ok, consumer_sup_pid} = DynamicSupervisor.start_link([])

    :ets.new(get_acked_topic_partitions_table(mod), [
      :set,
      :public,
      :named_table
    ])

    PubSub.subscribe({:metadata_updated, mod.klife_client()})

    init_state =
      %__MODULE__{
        mod: mod,
        topics:
          args_map.topics
          |> Enum.map(fn tc -> {tc.name, tc} end)
          |> Map.new(),
        group_name: args_map.group_name,
        instance_id: args_map.instance_id,
        rebalance_timeout_ms: args_map.rebalance_timeout_ms,
        client_name: mod.klife_client(),
        member_id: UUID.uuid4(),
        epoch: 0,
        heartbeat_interval_ms: 1000,
        assigned_topic_partitions: [],
        consumer_supervisor: consumer_sup_pid,
        consumers_monitor_map: %{}
      }
      |> get_coordinator!()

    send(self(), :heartbeat)

    {:ok, init_state}
  end

  defp get_acked_topic_partitions_table(cg_mod), do: :"acked_topic_partitions.#{cg_mod}"

  defp ack_topic_partition(cg_mod, topic_id, partition_idx) do
    cg_mod
    |> get_acked_topic_partitions_table()
    |> :ets.insert({{topic_id, partition_idx}})
  end

  defp unack_topic_partition(cg_mod, topic_id, partition_idx) do
    cg_mod
    |> get_acked_topic_partitions_table()
    |> :ets.delete({{topic_id, partition_idx}})
  end

  def get_coordinator!(%__MODULE__{} = state) do
    content = %{
      key_type: 0,
      coordinator_keys: [state.group_name]
    }

    fun = fn ->
      case Broker.send_message(M.FindCoordinator, state.client_name, :any, content) do
        {:ok, %{content: %{coordinators: [%{error_code: 0, node_id: broker_id}]}}} ->
          %__MODULE__{state | coordinator_id: broker_id}

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

  def polling_allowed?(cg_mod, topic_id, partition) do
    cg_mod
    |> get_acked_topic_partitions_table()
    |> :ets.lookup({topic_id, partition})
    |> case do
      [] -> false
      [_] -> true
    end
  end

  def handle_heartbeat(%__MODULE__{} = state) do
    new_state =
      state
      |> do_heartbeat()
      |> handle_assignment()

    Process.send_after(self(), :heartbeat, new_state.heartbeat_interval_ms)

    {:noreply, new_state}
  end

  defp do_heartbeat(%__MODULE__{} = state) do
    tp_list = Map.values(state.consumers_monitor_map)

    content =
      %{
        group_id: state.group_name,
        member_id: state.member_id,
        member_epoch: state.epoch,
        instance_id: state.instance_id,
        rebalance_timeout_ms: state.rebalance_timeout_ms,
        subscribed_topic_names: Map.keys(state.topics),
        topic_partitions:
          tp_list
          |> Enum.group_by(fn {t_id, _p} -> t_id end, fn {_t_id, p} -> p end)
          |> Enum.map(fn {t_id, partitions} -> %{partitions: partitions, topic_id: t_id} end),
        # TODO: Implement later
        rack_id: nil,
        subscribed_topic_regex: nil,
        server_assignor: nil
      }

    case Broker.send_message(
           M.ConsumerGroupHeartbeat,
           state.client_name,
           state.coordinator_id,
           content
         ) do
      {:error, _} ->
        %__MODULE__{state | heartbeat_interval_ms: 5}

      {:ok, %{content: %{error_code: 0} = resp}} ->
        new_state = %__MODULE__{
          state
          | assigned_topic_partitions: resp.assignment.topic_partitions,
            heartbeat_interval_ms: resp.heartbeat_interval_ms,
            epoch: resp.member_epoch
        }

        Enum.each(tp_list, fn {t_id, p} ->
          true = ack_topic_partition(new_state.mod, t_id, p)
        end)

        new_state

      {:ok, %{content: %{error_code: ec, error_message: em}}} ->
        # TODO: How to react to specific errors?
        Logger.error(
          "Heartbeat error for client #{state.client_name} on consumer group #{state.group_name}. Error Code: #{ec} Error Message: #{em}"
        )

        # Ensure the coordinator still the same
        get_coordinator!(state)
    end
  end

  defp handle_assignment(%__MODULE__{consumers_monitor_map: cm_map} = state) do
    assignment_keys =
      for %{partitions: p_data, topic_id: t_id} <- state.assigned_topic_partitions,
          partition <- p_data do
        {t_id, partition}
      end

    assigment_mapset = MapSet.new(assignment_keys)

    current_mapset =
      cm_map
      |> Map.values()
      |> MapSet.new()

    to_stop = MapSet.difference(current_mapset, assigment_mapset)
    to_start = MapSet.difference(assigment_mapset, current_mapset)

    Enum.each(to_start, fn {topic_id, partition} ->
      consumer_args = [
        consumer_group_config: state,
        topic_id: topic_id,
        partition_idx: partition
      ]

      case DynamicSupervisor.start_child(state.consumer_supervisor, {Consumer, consumer_args}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    end)

    Enum.each(to_stop, fn {topic_id, partition} ->
      true = unack_topic_partition(state.mod, topic_id, partition)
      :ok = Consumer.revoke_assignment(state.mod, topic_id, partition)
    end)

    state
  end

  def handle_consumer_up(
        %__MODULE__{consumers_monitor_map: c_map} = state,
        topic_id,
        partition,
        consumer_pid
      ) do
    ref = Process.monitor(consumer_pid)

    {
      :noreply,
      %__MODULE__{state | consumers_monitor_map: Map.put(c_map, ref, {topic_id, partition})}
    }
  end

  def handle_consumer_down(%__MODULE__{consumers_monitor_map: cmap} = state, monitor_ref, reason) do
    case Map.get(cmap, monitor_ref) do
      nil ->
        {:stop, reason, state}

      {_topic_id, _partition} ->
        new_cmap = Map.delete(cmap, monitor_ref)
        {:noreply, %__MODULE__{state | consumers_monitor_map: new_cmap}}
    end
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

      def handle_info(:heartbeat, state) do
        Klife.Consumer.ConsumerGroup.handle_heartbeat(state)
      end

      def handle_cast({:consumer_up, {topic_id, partition, consumer_pid}}, state) do
        Klife.Consumer.ConsumerGroup.handle_consumer_up(
          state,
          topic_id,
          partition,
          consumer_pid
        )
      end

      def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
        Klife.Consumer.ConsumerGroup.handle_consumer_down(state, ref, reason)
      end
    end
  end
end

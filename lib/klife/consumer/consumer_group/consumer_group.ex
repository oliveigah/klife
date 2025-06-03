defmodule Klife.Consumer.ConsumerGroup do
  import Klife.ProcessRegistry, only: [via_tuple: 1]

  require Logger

  alias Klife.Connection.Broker

  alias Klife.Helpers

  alias KlifeProtocol.Messages, as: M

  alias Klife.Consumer.ConsumerGroup.TopicConfig

  alias Klife.Consumer.ConsumerGroup.Consumer

  alias Klife.PubSub

  alias Klife.Consumer.Committer

  alias Klife.MetadataCache

  @consumer_group_opts [
    client: [
      type: :atom,
      required: true,
      doc: "The name of the klife client to be used by the consumer group"
    ],
    topics: [
      type: {:list, {:keyword_list, TopicConfig.get_opts()}},
      required: true,
      doc: "List of topic configurations that will be handled by the consumer group"
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
        "The maximum time in milliseconds that the kafka broker coordinator will wait on the member to revoke it's partitions"
    ],
    fetcher_name: [
      type: {:or, [:atom, :string]},
      doc:
        "Fetcher name to be used by the consumers of the group. Defaults to client's default fetcher"
    ],
    committers_count: [
      type: :pos_integer,
      default: 1,
      doc: "How many committer processes will be started for the consumer group"
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
                :consumers_monitor_map,
                :committers_distribution
              ]

  defmacro __using__(opts) do
    if !Keyword.has_key?(opts, :client) do
      raise ArgumentError, """
      client option is required when using Klife.Consumer.ConsumerGroup.

      use Klife.Consumer.ConsumerGroup, client: MyKlifeClient
      """
    end

    quote bind_quoted: [opts: opts] do
      use GenServer

      @behaviour Klife.Behaviours.ConsumerGroup

      def klife_client(), do: unquote(opts[:client])

      def start_link(args) do
        cg_opts = unquote(opts)
        input_map_args = Map.new(args)
        cg_opts_map_args = Map.new(cg_opts)
        final_map_args = Map.merge(cg_opts_map_args, input_map_args)
        final_args = Map.to_list(final_map_args)

        Klife.Consumer.ConsumerGroup.start_link(__MODULE__, final_args)
      end

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

      def terminate(reason, state) do
        Klife.Consumer.ConsumerGroup.handle_terminate(state, reason)
      end
    end
  end

  def start_link(cg_mod, args) do
    base_validated_args = NimbleOptions.validate!(args, @consumer_group_opts)

    map_args = Helpers.keyword_list_to_map(base_validated_args)

    validated_args =
      %__MODULE__{}
      |> Map.from_struct()
      |> Map.merge(map_args)
      |> Map.put(:mod, cg_mod)
      |> Map.put(:member_id, UUID.uuid4())

    GenServer.start_link(cg_mod, validated_args,
      name: get_process_name(cg_mod.klife_client(), cg_mod)
    )
  end

  defp get_process_name(client_name, cg_mod) do
    via_tuple({__MODULE__, client_name, cg_mod})
  end

  def send_consumer_up(cg_mod, topic_id, partition) do
    cg = get_process_name(cg_mod.klife_client(), cg_mod)
    GenServer.cast(cg, {:consumer_up, {topic_id, partition, self()}})
  end

  def init(mod, args_map) do
    Process.flag(:trap_exit, true)
    {:ok, consumer_sup_pid} = DynamicSupervisor.start_link([])

    :ets.new(get_acked_topic_partitions_table(mod.klife_client(), mod), [
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
          |> Enum.map(fn tc -> {tc.name, TopicConfig.from_map(tc)} end)
          |> Map.new(),
        group_name: args_map.group_name,
        instance_id: args_map.instance_id,
        rebalance_timeout_ms: args_map.rebalance_timeout_ms,
        client_name: mod.klife_client(),
        member_id: args_map.member_id,
        epoch: 0,
        heartbeat_interval_ms: 1000,
        assigned_topic_partitions: [],
        consumer_supervisor: consumer_sup_pid,
        consumers_monitor_map: %{},
        fetcher_name: args_map[:fetcher_name] || mod.klife_client().get_default_fetcher(),
        committers_count: args_map.committers_count,
        committers_distribution: %{}
      }
      |> get_coordinator!()

    send(self(), :heartbeat)

    {:ok, init_state}
  end

  defp get_acked_topic_partitions_table(client_name, cg_mod),
    do: :"acked_topic_partitions.#{client_name}.#{cg_mod}"

  defp ack_topic_partition(client_name, cg_mod, topic_id, partition_idx) do
    client_name
    |> get_acked_topic_partitions_table(cg_mod)
    |> :ets.insert({{topic_id, partition_idx}})
  end

  defp unack_topic_partition(client_name, cg_mod, topic_id, partition_idx) do
    client_name
    |> get_acked_topic_partitions_table(cg_mod)
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

  def polling_allowed?(client_name, cg_mod, topic_id, partition) do
    client_name
    |> get_acked_topic_partitions_table(cg_mod)
    |> :ets.member({topic_id, partition})
  end

  def handle_heartbeat(%__MODULE__{} = state) do
    new_state =
      state
      |> do_heartbeat()
      |> maybe_start_committer()
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
        new_state =
          %__MODULE__{
            state
            | assigned_topic_partitions: get_in(resp, [:assignment, :topic_partitions]) || [],
              heartbeat_interval_ms: resp.heartbeat_interval_ms,
              epoch: resp.member_epoch
          }

        Enum.each(tp_list, fn {t_id, p} ->
          true = ack_topic_partition(new_state.client_name, new_state.mod, t_id, p)
        end)

        new_state

      {:ok, %{content: %{error_code: ec, error_message: em}}} ->
        Logger.error(
          "Heartbeat error on consumer group #{state.group_name} for module #{state.mod}. Error Code: #{ec} Error Message: #{em}"
        )

        coordinator_error? = ec in [14, 15, 16]
        fence_error? = ec in [25, 110]
        static_membership_error? = ec in [111]

        cond do
          coordinator_error? ->
            get_coordinator!(state)

          fence_error? ->
            # The easiest thing to do is restart the consumer group, because it guarantees
            # that all consumers will be forcefully stopped
            raise "Fence error on heartbeat. Error Code: #{ec} Error Message: #{em}"

          # This should happen only when the previous instance is leaving the group
          static_membership_error? ->
            state

          true ->
            raise "Unrecoverable error on heartbeat. Error Code: #{ec} Error Message: #{em}"
        end
    end
  end

  defp maybe_start_committer(%__MODULE__{} = state)
       when map_size(state.committers_distribution) == 0 do
    new_dist =
      1..state.committers_count
      |> Enum.map(fn committer_id ->
        committer_args = [
          broker_id: state.coordinator_id,
          batcher_id: committer_id,
          member_id: state.member_id,
          client_name: state.client_name,
          consumer_group_mod: state.mod,
          batcher_config: [
            # TODO: Make config
            {:batch_wait_time_ms, 5},
            {:max_in_flight, 5}
          ]
        ]

        {:ok, _pid} =
          DynamicSupervisor.start_child(state.consumer_supervisor, {Committer, committer_args})

        {committer_id, MapSet.new()}
      end)
      |> Map.new()

    %__MODULE__{state | committers_distribution: new_dist}
  end

  defp maybe_start_committer(%__MODULE__{} = state) do
    state
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

    new_state =
      Enum.reduce(to_stop, state, fn {topic_id, partition}, acc_state ->
        stop_consumer(acc_state, topic_id, partition)
      end)

    new_state =
      Enum.reduce(to_start, new_state, fn {topic_id, partition}, acc_state ->
        start_consumer(acc_state, topic_id, partition)
      end)

    if MapSet.size(to_stop) != 0 or MapSet.size(to_start) != 0 do
      %__MODULE__{new_state | heartbeat_interval_ms: 5}
    else
      new_state
    end
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

  def handle_terminate(%__MODULE__{} = state, _reason) do
    # TODO: Maybe we should also use the termination reason to deefine leaving epoch
    leaving_epoch = if state.instance_id != nil, do: -2, else: -1

    exit_state = %__MODULE__{state | consumers_monitor_map: %{}, epoch: leaving_epoch}

    do_heartbeat(exit_state)
  end

  defp stop_consumer(%__MODULE__{} = state, topic_id, partition) do
    true = unack_topic_partition(state.client_name, state.mod, topic_id, partition)
    :ok = Consumer.revoke_assignment_async(state.client_name, state.mod, topic_id, partition)

    committer_id =
      find_committer_id_by_topic_partition(state.committers_distribution, topic_id, partition)

    new_dist =
      Map.update!(state.committers_distribution, committer_id, fn curr_ms ->
        MapSet.delete(curr_ms, {topic_id, partition})
      end)

    %__MODULE__{state | committers_distribution: new_dist}
  end

  defp start_consumer(%__MODULE__{} = state, topic_id, partition) do
    committer_id = get_next_committer_id(state.committers_distribution)
    topic_name = MetadataCache.get_topic_name_by_id(state.client_name, topic_id)

    consumer_args = [
      consumer_group_mod: state.mod,
      topic_id: topic_id,
      partition_idx: partition,
      committer_id: committer_id,
      topic_config: state.topics[topic_name],
      client_name: state.client_name
    ]

    case DynamicSupervisor.start_child(state.consumer_supervisor, {Consumer, consumer_args}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end

    new_dist =
      Map.update!(state.committers_distribution, committer_id, fn curr_ms ->
        MapSet.put(curr_ms, {topic_id, partition})
      end)

    %__MODULE__{state | committers_distribution: new_dist}
  end

  defp get_next_committer_id(committer_distribution_map) do
    committer_distribution_map
    |> Enum.sort_by(fn {_committer_id, tp_ms} -> MapSet.size(tp_ms) end)
    |> List.first()
    |> elem(0)
  end

  defp find_committer_id_by_topic_partition(committer_distribution_map, topic, partition) do
    committer_distribution_map
    |> Enum.find(fn {_committer_id, tp_ms} -> MapSet.member?(tp_ms, {topic, partition}) end)
    |> elem(0)
  end
end

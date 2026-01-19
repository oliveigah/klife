defmodule Klife.Consumer.ConsumerGroup do
  import Klife.ProcessRegistry, only: [via_tuple: 1]

  require Logger

  alias Klife.Consumer.Fetcher
  alias Klife.Connection.Broker

  alias Klife.Helpers

  alias KlifeProtocol.Messages, as: M

  alias Klife.Consumer.ConsumerGroup.TopicConfig

  alias Klife.Consumer.ConsumerGroup.Consumer

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
    fetch_strategy: [
      type: {:custom, __MODULE__, :validate_fetch_strategy, []},
      default: {:exclusive, []},
      doc: """
      Fetch strategy for this topic. Can be either:
      - `{:exclusive, fetcher_options}` - Will create an exclusive fetcher to be used for this consumer group
      - `{:shared, fetcher_name}` - Will use a pre existing fetcher that will batch requests from different sources

      Defaults to `{:shared, Client.default_fetcher}`
      """
    ],
    committers_count: [
      type: :pos_integer,
      default: 1,
      doc: "How many committer processes will be started for the consumer group"
    ],
    isolation_level: [
      type: {:in, [:read_committed, :read_uncommitted]},
      default: :read_committed,
      doc:
        "Define if the consumers of the consumer group will receive uncommitted transactional records"
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

      def handle_info({:EXIT, _from, reason}, state) do
        exit(reason)
      end

      def handle_call(:member_epoch, _from, state) do
        Klife.Consumer.ConsumerGroup.handle_member_epoch(state)
      end

      def terminate(reason, state) do
        Klife.Consumer.ConsumerGroup.handle_terminate(state, reason)
      end
    end
  end

  def get_opts(), do: @consumer_group_opts

  def validate_fetch_strategy({:shared, fetcher_name}) when is_atom(fetcher_name) do
    {:ok, {:shared, fetcher_name}}
  end

  def validate_fetch_strategy({:exclusive, options}) when is_list(options) do
    # Name will be replaced on the maybe_start_group_fetcher function
    with_tmp_name = Keyword.put(options, :name, :tbd)

    case NimbleOptions.validate(with_tmp_name, Fetcher.get_opts()) do
      {:ok, validated_opts} -> {:ok, {:exclusive, validated_opts}}
      {:error, error} -> {:error, error}
    end
  end

  def validate_fetch_strategy(value) do
    {:error,
     "expected :fetch_strategy to be either {:shared, atom} or {:exclusive, keyword_list}, got: #{inspect(value)}"}
  end

  def start_link(cg_mod, args) do
    args =
      Keyword.put_new(
        args,
        :fetch_strategy,
        {:shared, cg_mod.klife_client().get_default_fetcher()}
      )

    base_validated_args =
      NimbleOptions.validate!(args, @consumer_group_opts)

    map_args = Helpers.keyword_list_to_map(base_validated_args)

    validated_args =
      %__MODULE__{}
      |> Map.from_struct()
      |> Map.merge(map_args)
      |> Map.put(:mod, cg_mod)
      |> Map.put(:member_id, UUID.uuid4())

    GenServer.start_link(cg_mod, validated_args,
      name: get_process_name(cg_mod.klife_client(), cg_mod, validated_args.group_name)
    )
  end

  defp get_process_name(client_name, cg_mod, group_name) do
    via_tuple({__MODULE__, client_name, cg_mod, group_name})
  end

  def send_consumer_up(cg_pid, topic_id, partition) do
    GenServer.cast(cg_pid, {:consumer_up, {topic_id, partition, self()}})
  end

  def get_member_epoch(cg_pid) do
    GenServer.call(cg_pid, :member_epoch)
  end

  def init(mod, args_map) do
    Process.flag(:trap_exit, true)

    {:ok, consumer_sup_pid} = DynamicSupervisor.start_link([])

    :ets.new(get_acked_topic_partitions_table(mod.klife_client(), mod, args_map.group_name), [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    init_state =
      %__MODULE__{
        mod: mod,
        group_name: args_map.group_name,
        instance_id: args_map.instance_id,
        rebalance_timeout_ms: args_map.rebalance_timeout_ms,
        client_name: mod.klife_client(),
        member_id: args_map.member_id,
        epoch: 0,
        heartbeat_interval_ms: 1_000,
        assigned_topic_partitions: [],
        consumer_supervisor: consumer_sup_pid,
        consumers_monitor_map: %{},
        fetch_strategy: args_map.fetch_strategy,
        committers_count: args_map.committers_count,
        committers_distribution: %{}
      }
      |> get_coordinator!()
      |> maybe_start_group_fetcher()

    init_state = %{
      init_state
      | topics:
          args_map.topics
          |> Enum.map(fn tc ->
            final_tc =
              tc
              |> TopicConfig.from_map(init_state)
              |> maybe_start_topic_fetcher(init_state)

            {tc.name, final_tc}
          end)
          |> Map.new()
    }

    send(self(), :heartbeat)

    {:ok, init_state}
  end

  defp get_acked_topic_partitions_table(client_name, cg_mod, cg_name),
    do: :"acked_topic_partitions.#{client_name}.#{cg_mod}.#{cg_name}"

  defp ack_topic_partition(client_name, cg_mod, topic_id, partition_idx, cg_name) do
    client_name
    |> get_acked_topic_partitions_table(cg_mod, cg_name)
    |> :ets.insert({{topic_id, partition_idx}})
  end

  defp unack_topic_partition(client_name, cg_mod, topic_id, partition_idx, cg_name) do
    client_name
    |> get_acked_topic_partitions_table(cg_mod, cg_name)
    |> :ets.delete({{topic_id, partition_idx}})
  end

  defp unack_all_topic_partitions(client_name, cg_mod, cg_name) do
    client_name
    |> get_acked_topic_partitions_table(cg_mod, cg_name)
    |> :ets.delete_all_objects()
  end

  def get_coordinator!(%__MODULE__{} = state) do
    content = %{
      key_type: 0,
      coordinator_keys: [state.group_name]
    }

    fun = fn ->
      case Broker.send_message(M.FindCoordinator, state.client_name, :any, content, %{},
             timeout_ms: 15_000
           ) do
        {:ok, %{content: %{coordinators: [%{error_code: 0, node_id: broker_id}]}}} ->
          if state.coordinator_id != nil and state.coordinator_id != broker_id do
            Enum.each(state.committers_distribution, fn {commiter_id, _list} ->
              :ok =
                Committer.update_coordinator(
                  broker_id,
                  state.client_name,
                  state.mod,
                  state.group_name,
                  commiter_id
                )
            end)
          end

          %__MODULE__{state | coordinator_id: broker_id}

        {:ok, %{content: %{coordinators: [%{error_code: ec}]}}} ->
          Logger.error(
            "Error code #{ec} returned from broker for group #{state.group_name} on #{inspect(M.FindCoordinator)} call"
          )

          :retry

        {:error, reason} ->
          Logger.error(
            "Unexpected error #{reason} on #{inspect(M.FindCoordinator)} call for group #{state.group_name}"
          )

          :retry
      end
    end

    Helpers.with_timeout!(fun, :timer.seconds(30))
  end

  def processing_allowed?(client_name, cg_mod, topic_id, partition, cg_name) do
    client_name
    |> get_acked_topic_partitions_table(cg_mod, cg_name)
    |> :ets.member({topic_id, partition})
  end

  def handle_member_epoch(%__MODULE__{} = state) do
    {:reply, state.epoch, state}
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
           content,
           %{},
           timeout_ms: state.rebalance_timeout_ms
         ) do
      {:error, :timeout} ->
        raise "Timeout on heartbeat for client #{state.client_name} group #{state.group_name}. It is not safe to keep consuming records because consumers may be fenced!"

      # Needs to unack all because this loop may cause problems when a consumer can not properly
      # send/receive heartbeats. Because the consumer group will be stuck on
      # this heartbeat -> coordinator -> heartbeat loop, and wont stop consumers.
      #
      # The comsumption will be re enabled after the next successfull heartbeat
      #
      # TODO: Should we raise after some timeout here?
      {:error, error} ->
        true = unack_all_topic_partitions(state.client_name, state.mod, state.group_name)

        Logger.error("Error on heartbeat for #{state.group_name} error: #{error}")

        state
        |> get_coordinator!()
        |> do_heartbeat()

      {:ok, %{content: %{error_code: 0} = resp}} ->
        new_state =
          %__MODULE__{
            state
            | assigned_topic_partitions: get_in(resp, [:assignment, :topic_partitions]) || [],
              heartbeat_interval_ms: resp.heartbeat_interval_ms,
              epoch: resp.member_epoch
          }

        Enum.each(tp_list, fn {t_id, p} ->
          true =
            ack_topic_partition(
              new_state.client_name,
              new_state.mod,
              t_id,
              p,
              new_state.group_name
            )
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
            state
            |> get_coordinator!()
            |> do_heartbeat()

          fence_error? ->
            # The easiest thing to do is restart the consumer group, because it guarantees
            # that all consumers/committers will be forcefully stopped
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
    # TODO: Handle coordinator changes on committer
    new_dist =
      1..state.committers_count
      |> Enum.map(fn committer_id ->
        committer_args = [
          group_id: state.group_name,
          broker_id: state.coordinator_id,
          batcher_id: committer_id,
          member_id: state.member_id,
          member_epoch: state.epoch,
          client_name: state.client_name,
          consumer_group_mod: state.mod,
          group_intance_id: state.instance_id,
          cg_pid: self(),
          # TODO: Make config
          batcher_config: [
            {:batch_wait_time_ms, 0},
            # To have max_in_flight greater than 1, must think about
            # how to prevent lower offset values to override
            # higher ones on retries.
            #
            # Eg:
            # req 1 commit 10 (fail)
            # req 2 commit 20 (success)
            # req 1 retry, commit 10 (success)
            #
            # With max_in_flight 1 this is not a problem
            # because failed commits will be merged on
            # the waiting batch using the higher value
            {:max_in_flight, 1}
          ]
        ]

        {:ok, _pid} = Committer.start_link(committer_args)

        {committer_id, MapSet.new()}
      end)
      |> Map.new()

    %__MODULE__{state | committers_distribution: new_dist}
  end

  defp maybe_start_committer(%__MODULE__{} = state) do
    state
  end

  defp maybe_start_group_fetcher(%__MODULE__{fetch_strategy: {:exclusive, opts}} = state)
       when is_list(opts) do
    name = Module.concat([__MODULE__, state.mod, state.group_name])

    args =
      opts
      |> Keyword.put(:client_name, state.client_name)
      |> Keyword.put(:name, name)
      |> Map.new()

    {:ok, _pid} = Fetcher.start_link(args)

    %{state | fetch_strategy: {:exclusive, name}}
  end

  defp maybe_start_group_fetcher(%__MODULE__{} = state) do
    state
  end

  defp maybe_start_topic_fetcher(
         %TopicConfig{fetch_strategy: {:exclusive, opts}} = tc,
         %__MODULE__{} = state
       )
       when is_list(opts) do
    name = Module.concat([__MODULE__, state.mod, state.group_name, tc.name])

    args =
      opts
      |> Keyword.put(:client_name, state.client_name)
      |> Keyword.put(:name, name)
      |> Map.new()

    {:ok, _pid} = Fetcher.start_link(args)

    %{tc | fetch_strategy: {:exclusive, name}}
  end

  defp maybe_start_topic_fetcher(%TopicConfig{} = tc, %__MODULE__{} = _state) do
    tc
  end

  defp get_init_offsets(%__MODULE__{} = state, tid_p_list) do
    # TODO: Think how to handle errors on specific topics/partitions
    tname_map =
      tid_p_list
      |> Enum.map(fn {tid, _p} -> tid end)
      |> Enum.uniq()
      |> Enum.map(fn tid ->
        tname = MetadataCache.get_topic_name_by_id(state.client_name, tid)
        {tid, tname}
      end)
      |> Map.new()

    parsed_list =
      tid_p_list
      |> Enum.map(fn {tid, p} -> {tname_map[tid], p} end)
      |> Enum.group_by(fn {tname, _p} -> tname end, fn {_tname, p} -> p end)

    content = %{
      groups: [
        %{
          group_id: state.group_name,
          member_id: state.member_id,
          member_epoch: state.epoch,
          topics:
            Enum.map(parsed_list, fn {tname, p_list} ->
              %{
                name: tname,
                partition_indexes: p_list
              }
            end)
        }
      ],
      require_stable: true
    }

    offset_fetch_result =
      case Broker.send_message(M.OffsetFetch, state.client_name, state.coordinator_id, content) do
        {:ok, %{content: %{groups: [%{error_code: 0, topics: tdata}]}}} ->
          for topic_resp <- tdata, %{error_code: 0} = pdata <- topic_resp.partitions, into: %{} do
            {{topic_resp.name, pdata.partition_index}, pdata.committed_offset}
          end

        {:ok, %{content: %{groups: [%{error_code: ec}]}}} ->
          raise "Error code #{ec} returned from broker for client #{inspect(state.client_name)} on #{inspect(M.OffsetFetch)} call"
      end

    missing_resp_tp =
      offset_fetch_result
      |> Enum.filter(fn {{_tname, _p}, offset} -> offset == -1 end)
      |> Enum.map(fn {{t, p}, -1} -> {t, p} end)

    reset_offset_map = get_reset_offset(missing_resp_tp, state.client_name, state.topics)

    tid_map = tname_map |> Enum.map(fn {tname, tid} -> {tid, tname} end) |> Map.new()

    Map.merge(offset_fetch_result, reset_offset_map)
    |> Enum.map(fn {{tname, p}, offset} -> {{tid_map[tname], p}, offset} end)
    |> Map.new()
  end

  def get_reset_offset(tname_p_list, client, tconfig_map) do
    # TODO: Think how to handle errors on specific topics/partitions
    grouped_by_broker =
      Enum.group_by(
        tname_p_list,
        fn {tname, p} -> MetadataCache.get_metadata_attribute(client, tname, p, :leader_id) end
      )

    contents =
      Enum.map(grouped_by_broker, fn {broker, tp_list} ->
        grouped_tp_list =
          Enum.group_by(tp_list, fn {tname, _p} -> tname end, fn {_tname, p} -> p end)

        content = %{
          replica_id: -1,
          isolation_level: 1,
          topics:
            Enum.map(grouped_tp_list, fn {tname, plist} ->
              %{
                name: tname,
                partitions:
                  Enum.map(plist, fn p ->
                    %{
                      partition_index: p,
                      timestamp:
                        case tconfig_map[tname].offset_reset_policy do
                          :earliest -> -2
                          :latest -> -1
                        end
                    }
                  end)
              }
            end)
        }

        {broker, content}
      end)

    Task.async_stream(contents, fn {broker, content} ->
      {:ok, %{content: %{topics: tdata}}} =
        Broker.send_message(M.ListOffsets, client, broker, content)

      for topic_resp <- tdata, %{error_code: 0} = pdata <- topic_resp.partitions do
        # Need the -1 so we do not skip the first record
        {{topic_resp.name, pdata.partition_index}, pdata.offset - 1}
      end
    end)
    |> Enum.flat_map(fn {:ok, resp} -> resp end)
    |> Map.new()
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
      if MapSet.size(to_start) != 0 do
        init_offsets_map = get_init_offsets(state, to_start)

        Enum.reduce(to_start, new_state, fn {topic_id, partition}, acc_state ->
          start_consumer(acc_state, topic_id, partition, init_offsets_map[{topic_id, partition}])
        end)
      else
        new_state
      end

    if MapSet.size(to_stop) != 0 or MapSet.size(to_start) != 0 do
      %{new_state | heartbeat_interval_ms: 5}
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
        Logger.error("Unexpected consumer down message received!")
        {:stop, reason, state}

      {_topic_id, _partition} ->
        new_cmap = Map.delete(cmap, monitor_ref)
        {:noreply, %__MODULE__{state | consumers_monitor_map: new_cmap}}
    end
  end

  def handle_terminate(%__MODULE__{} = state, _reason) do
    true = unack_all_topic_partitions(state.client_name, state.mod, state.group_name)

    # TODO: Maybe we should also use the termination reason to define leaving epoch
    leaving_epoch = if state.instance_id != nil, do: -2, else: -1

    # TODO: make timeout a config
    state.consumers_monitor_map
    |> Task.async_stream(
      fn {_k, {tid, p}} ->
        :ok = Consumer.revoke_assignment(state.client_name, state.mod, tid, p, state.group_name)
      end,
      timeout: 15_000
    )
    |> Enum.to_list()

    exit_state = %__MODULE__{state | consumers_monitor_map: %{}, epoch: leaving_epoch}

    do_heartbeat(exit_state)
  end

  defp stop_consumer(%__MODULE__{} = state, topic_id, partition) do
    true =
      unack_topic_partition(state.client_name, state.mod, topic_id, partition, state.group_name)

    :ok =
      Consumer.revoke_assignment_async(
        state.client_name,
        state.mod,
        topic_id,
        partition,
        state.group_name
      )

    committer_id =
      find_committer_id_by_topic_partition(state.committers_distribution, topic_id, partition)

    new_dist =
      Map.update!(state.committers_distribution, committer_id, fn curr_ms ->
        MapSet.delete(curr_ms, {topic_id, partition})
      end)

    %__MODULE__{state | committers_distribution: new_dist}
  end

  defp start_consumer(%__MODULE__{} = state, topic_id, partition, init_offset) do
    committer_id = get_next_committer_id(state.committers_distribution)
    topic_name = MetadataCache.get_topic_name_by_id(state.client_name, topic_id)

    consumer_args = [
      consumer_group_mod: state.mod,
      topic_id: topic_id,
      partition_idx: partition,
      committer_id: committer_id,
      topic_config: state.topics[topic_name],
      client_name: state.client_name,
      consumer_group_name: state.group_name,
      consumer_group_member_id: state.member_id,
      consumer_group_epoch: state.epoch,
      consumer_group_coordinator_id: state.coordinator_id,
      consumer_group_pid: self(),
      init_offset: init_offset
    ]

    spec = %{
      id: {topic_id, partition},
      start: {Consumer, :start_link, [consumer_args]},
      restart: :transient,
      type: :worker
    }

    case DynamicSupervisor.start_child(state.consumer_supervisor, spec) do
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

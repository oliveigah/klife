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
                :internal_supervisor,
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
        internal_supervisor: nil,
        consumers_monitor_map: %{},
        fetch_strategy: args_map.fetch_strategy,
        committers_count: args_map.committers_count,
        committers_distribution: %{}
      }
      |> get_coordinator!()

    {init_state, group_fetcher_specs} = build_group_fetcher_specs(init_state)

    {topics, topic_fetcher_specs} =
      args_map.topics
      |> Enum.map_reduce([], fn tc, acc_specs ->
        final_tc = TopicConfig.from_map(tc, init_state)
        {final_tc, specs} = build_topic_fetcher_specs(final_tc, init_state)
        {{tc.name, final_tc}, acc_specs ++ specs}
      end)

    init_state = %{init_state | topics: Map.new(topics)}

    {committers_distribution, committer_specs} = build_committer_specs(init_state)
    init_state = %{init_state | committers_distribution: committers_distribution}

    internal_children = group_fetcher_specs ++ topic_fetcher_specs ++ committer_specs

    {:ok, internal_sup_pid} =
      Supervisor.start_link(internal_children, strategy: :one_for_one)

    init_state = %{init_state | internal_supervisor: internal_sup_pid}

    send(self(), :heartbeat)

    Logger.info(
      "Starting consumer group #{init_state.group_name}: (client=#{inspect(init_state.client_name)}, mod=#{init_state.mod})",
      client: init_state.client_name,
      group: init_state.group_name
    )

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
      case Broker.send_message(M.FindCoordinator, state.client_name, :any, content) do
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
            "#{inspect(M.FindCoordinator)} failed with error code #{ec} (client=#{inspect(state.client_name)}, group=#{state.group_name})",
            client: state.client_name,
            group: state.group_name,
            error_code: ec
          )

          :retry

        {:error, reason} ->
          Logger.error(
            "#{inspect(M.FindCoordinator)} failed unexpectedly: #{inspect(reason)} (client=#{inspect(state.client_name)}, group=#{state.group_name})",
            client: state.client_name,
            group: state.group_name,
            reason: inspect(reason)
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
    case do_heartbeat(state) do
      {:ok, new_state} ->
        new_state = handle_assignment(new_state)

        Process.send_after(self(), :heartbeat, new_state.heartbeat_interval_ms)

        {:noreply, new_state}

      {:error, reason} ->
        {:stop, reason, state}
    end
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
        Logger.error(
          "Heartbeat timeout for group #{state.group_name}. Consumers may be fenced, stopping consumption (client=#{inspect(state.client_name)})",
          client: state.client_name,
          group: state.group_name,
          coordinator_id: state.coordinator_id
        )

        {:error, :timeout}

      # Needs to unack all because this loop may cause problems when a consumer can not properly
      # send/receive heartbeats. Because the consumer group will be stuck on
      # this heartbeat -> coordinator -> heartbeat loop, and wont stop consumers.
      #
      # The comsumption will be re enabled after the next successfull heartbeat
      #
      # TODO: Should we raise after some timeout here?
      {:error, error} ->
        true = unack_all_topic_partitions(state.client_name, state.mod, state.group_name)

        Logger.error(
          "Heartbeat error for group #{state.group_name}: #{inspect(error)} (client=#{inspect(state.client_name)})",
          client: state.client_name,
          group: state.group_name,
          reason: inspect(error)
        )

        state
        |> get_coordinator!()
        |> do_heartbeat()

      {:ok, %{content: %{error_code: 0} = resp}} ->
        if state.coordinator_id != nil and resp.member_epoch != state.epoch do
          Enum.each(state.committers_distribution, fn {commiter_id, _list} ->
            :ok =
              Committer.update_epoch(
                resp.member_epoch,
                state.client_name,
                state.mod,
                state.group_name,
                commiter_id
              )
          end)
        end

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

        {:ok, new_state}

      {:ok, %{content: %{error_code: ec, error_message: em}}} ->
        Logger.error(
          "Heartbeat error for group #{state.group_name}: error_code=#{ec} error_message=#{em} (client=#{inspect(state.client_name)})",
          client: state.client_name,
          group: state.group_name,
          consumer_group_mod: state.mod,
          error_code: ec,
          error_message: em
        )

        coordinator_error? = ec in [14, 15, 16]
        static_membership_error? = ec in [111]

        cond do
          coordinator_error? ->
            state
            |> get_coordinator!()
            |> do_heartbeat()

          # This should happen only when the previous instance is leaving the group
          # so we can keep going and this should resolve eventually!
          static_membership_error? ->
            state

          true ->
            Logger.error(
              "Unrecoverable heartbeat error for group #{state.group_name}, restarting: error_code=#{ec} error_message=#{em} (client=#{inspect(state.client_name)})",
              client: state.client_name,
              group: state.group_name,
              error_code: ec,
              error_message: em
            )

            {:error, ec}
        end
    end
  end

  defp build_committer_specs(%__MODULE__{} = state) do
    # TODO: Handle coordinator changes on committer
    1..state.committers_count
    |> Enum.map_reduce([], fn committer_id, acc_specs ->
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

      spec = %{
        id: {Committer, committer_id},
        start: {Committer, :start_link, [committer_args]},
        restart: :permanent,
        type: :worker
      }

      {{committer_id, MapSet.new()}, acc_specs ++ [spec]}
    end)
    |> then(fn {dist_list, specs} -> {Map.new(dist_list), specs} end)
  end

  defp build_group_fetcher_specs(%__MODULE__{fetch_strategy: {:exclusive, opts}} = state)
       when is_list(opts) do
    name = Module.concat([__MODULE__, state.mod, state.group_name])

    args =
      opts
      |> Keyword.put(:client_name, state.client_name)
      |> Keyword.put(:name, name)
      |> Map.new()

    spec = %{
      id: {Fetcher, :group, name},
      start: {Fetcher, :start_link, [args]},
      restart: :permanent,
      type: :worker
    }

    {%{state | fetch_strategy: {:exclusive, name}}, [spec]}
  end

  defp build_group_fetcher_specs(%__MODULE__{} = state) do
    {state, []}
  end

  defp build_topic_fetcher_specs(
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

    spec = %{
      id: {Fetcher, :topic, name},
      start: {Fetcher, :start_link, [args]},
      restart: :permanent,
      type: :worker
    }

    {%{tc | fetch_strategy: {:exclusive, name}}, [spec]}
  end

  defp build_topic_fetcher_specs(%TopicConfig{} = tc, %__MODULE__{} = _state) do
    {tc, []}
  end

  defp get_init_offsets(%__MODULE__{} = state, tid_p_list) do
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
      # TODO: should this always be true?
      require_stable: true
    }

    offset_fetch_result =
      case Broker.send_message(M.OffsetFetch, state.client_name, state.coordinator_id, content) do
        {:ok, %{content: %{groups: [%{error_code: 0, topics: tdata}]}}} ->
          # TODO: Think how to handle errors on specific topics/partitions
          for topic_resp <- tdata, %{error_code: 0} = pdata <- topic_resp.partitions, into: %{} do
            {{topic_resp.name, pdata.partition_index}, pdata.committed_offset}
          end

        {:ok, %{content: %{groups: [%{error_code: ec}]}}} ->
          raise "#{inspect(M.OffsetFetch)} failed with error code #{ec} (client=#{inspect(state.client_name)}, group=#{state.group_name})"
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

    Task.async_stream(
      contents,
      fn {broker, content} ->
        {:ok, %{content: %{topics: tdata}}} =
          Broker.send_message(M.ListOffsets, client, broker, content)

        for topic_resp <- tdata, %{error_code: 0} = pdata <- topic_resp.partitions do
          # Need the -1 so we do not skip the first record
          {{topic_resp.name, pdata.partition_index}, pdata.offset - 1}
        end
      end,
      timeout: 30_000
    )
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

  def handle_consumer_down(%__MODULE__{consumers_monitor_map: cmap} = state, monitor_ref, reason) do
    case Map.get(cmap, monitor_ref) do
      nil ->
        Logger.error(
          "Unexpected consumer DOWN message received (client=#{inspect(state.client_name)}, group=#{state.group_name})",
          client: state.client_name,
          group: state.group_name,
          reason: inspect(reason)
        )

        {:stop, reason, state}

      {_topic_id, _partition} ->
        new_cmap = Map.delete(cmap, monitor_ref)
        {:noreply, %__MODULE__{state | consumers_monitor_map: new_cmap}}
    end
  end

  def handle_terminate(%__MODULE__{} = state, reason) do
    Logger.info(
      "Terminating consumer group #{state.group_name}: #{inspect(reason)} (client=#{inspect(state.client_name)})",
      client: state.client_name,
      group: state.group_name,
      reason: inspect(reason)
    )

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

    {:ok, exit_state} = do_heartbeat(exit_state)
    exit_state
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

    remove_entry_from_committers_map(state, topic_id, partition)
  end

  defp start_consumer(
         %__MODULE__{consumers_monitor_map: cm_map} = state,
         topic_id,
         partition,
         init_offset
       ) do
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
      # I think temporary behaviour is the best approach here
      # because the consumer group process is in charge of restarts
      # and the dynamic supervisor may not have proper state to
      # automatically restart the consumer (ie. init_offset may
      # have been moved forward and auto restart might lead to double consume)
      restart: :temporary,
      type: :worker
    }

    {:ok, pid} =
      case DynamicSupervisor.start_child(state.consumer_supervisor, spec) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end

    new_committer_dist =
      Map.update!(state.committers_distribution, committer_id, fn curr_ms ->
        MapSet.put(curr_ms, {topic_id, partition})
      end)

    ref = Process.monitor(pid)

    %__MODULE__{
      state
      | committers_distribution: new_committer_dist,
        consumers_monitor_map: Map.put(cm_map, ref, {topic_id, partition})
    }
  end

  defp get_next_committer_id(committer_distribution_map) do
    committer_distribution_map
    |> Enum.sort_by(fn {_committer_id, tp_ms} -> MapSet.size(tp_ms) end)
    |> List.first()
    |> elem(0)
  end

  defp remove_entry_from_committers_map(%__MODULE__{} = state, topic, partition) do
    state.committers_distribution
    |> Enum.find(fn {_committer_id, tp_ms} -> MapSet.member?(tp_ms, {topic, partition}) end)
    |> case do
      nil ->
        state

      {committer_id, ms} ->
        new_ms = MapSet.delete(ms, {topic, partition})
        new_commiter_map = Map.replace!(state.committers_distribution, committer_id, new_ms)

        %{state | committers_distribution: new_commiter_map}
    end
  end
end

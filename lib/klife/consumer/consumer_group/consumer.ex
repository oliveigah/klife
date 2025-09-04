defmodule Klife.Consumer.ConsumerGroup.Consumer do
  use GenServer, restart: :transient

  import Klife.ProcessRegistry

  alias Klife.MetadataCache

  alias Klife.Consumer.ConsumerGroup

  alias Klife.Consumer.ConsumerGroup.TopicConfig

  alias Klife.Record

  alias Klife.Consumer.Committer

  alias Klife.Connection.Broker

  alias KlifeProtocol.Messages, as: M

  alias Klife.Consumer.Fetcher

  require Logger

  defstruct [
    :cg_mod,
    :topic_config,
    :topic_id,
    :partition_idx,
    :topic_name,
    :committer_id,
    :client_name,
    :cg_name,
    :cg_member_id,
    :cg_member_epoch,
    :cg_coordinator_id,
    :cg_pid,
    :latest_committed_offset,
    :latest_processed_offset,
    :records_queue,
    :records_queue_size,
    :unconfirmed_commits_count,
    :empty_fetch_results_count,
    :next_fetch_ref,
    :leader_epoch
  ]

  def start_link(args) do
    cg_mod = Keyword.fetch!(args, :consumer_group_mod)
    client_name = Keyword.fetch!(args, :client_name)
    topic_id = Keyword.fetch!(args, :topic_id)
    partition_idx = Keyword.fetch!(args, :partition_idx)

    GenServer.start_link(__MODULE__, Map.new(args),
      name: get_process_name(client_name, cg_mod, topic_id, partition_idx)
    )
  end

  def get_process_name(client_name, cg_mod, topic_id, partition_idx) do
    via_tuple({__MODULE__, client_name, cg_mod, topic_id, partition_idx})
  end

  @impl true
  def init(args_map) do
    client_name = args_map.client_name
    topic_name = MetadataCache.get_topic_name_by_id(client_name, args_map.topic_id)

    state =
      %__MODULE__{
        topic_id: args_map.topic_id,
        partition_idx: args_map.partition_idx,
        topic_name: topic_name,
        topic_config: args_map.topic_config,
        committer_id: args_map.committer_id,
        client_name: client_name,
        cg_mod: args_map.consumer_group_mod,
        cg_name: args_map.consumer_group_name,
        cg_member_id: args_map.consumer_group_member_id,
        cg_member_epoch: args_map.consumer_group_epoch,
        cg_coordinator_id: args_map.consumer_group_coordinator_id,
        unconfirmed_commits_count: 0,
        empty_fetch_results_count: 0,
        next_fetch_ref: nil,
        records_queue: :queue.new(),
        records_queue_size: 0,
        cg_pid: args_map.consumer_group_pid,
        leader_epoch:
          Klife.MetadataCache.get_metadata_attribute(
            client_name,
            topic_name,
            args_map.partition_idx,
            :leader_epoch
          )
      }

    state = get_latest_committed_offset(state)

    :ok =
      ConsumerGroup.send_consumer_up(
        state.cg_pid,
        state.topic_id,
        state.partition_idx
      )

    send(self(), :poll_records)

    if function_exported?(state.cg_mod, :handle_consumer_start, 2) do
      :ok = state.cg_mod.handle_consumer_start(state.topic_name, state.partition_idx)
    end

    {:ok, state}
  end

  defp get_latest_committed_offset(%__MODULE__{} = state) do
    content = %{
      groups: [
        %{
          group_id: state.cg_name,
          member_id: state.cg_member_id,
          member_epoch: state.cg_member_epoch,
          topics: [
            %{name: state.topic_name, partition_indexes: [state.partition_idx]}
          ]
        }
      ],
      require_stable: true
    }

    %TopicConfig{} = tc = state.topic_config

    case Broker.send_message(M.OffsetFetch, state.client_name, state.cg_coordinator_id, content) do
      {:ok,
       %{
         content: %{
           groups: [%{error_code: 0, topics: [%{partitions: [%{committed_offset: -1}]}]}]
         }
       }} ->
        latest_offset =
          get_start_offset(
            state.client_name,
            state.topic_name,
            state.partition_idx,
            tc.offset_reset_policy
          )

        %__MODULE__{
          state
          | latest_committed_offset: latest_offset - 1,
            latest_processed_offset: latest_offset - 1
        }

      {:ok,
       %{
         content: %{
           groups: [%{error_code: 0, topics: [%{partitions: [%{committed_offset: co}]}]}]
         }
       }} ->
        %__MODULE__{state | latest_committed_offset: co, latest_processed_offset: co}

      {:ok, %{content: %{groups: [%{error_code: ec}]}}} ->
        Logger.error(
          "Error code #{ec} returned from broker for client #{inspect(state.client_name)} on #{inspect(M.OffsetFetch)} call"
        )

        raise "Unexpected"
    end
  end

  defp get_start_offset(client, topic, partition, latest_or_earliest) do
    broker = Klife.MetadataCache.get_metadata_attribute(client, topic, partition, :leader_id)

    content = %{
      replica_id: -1,
      isolation_level: 1,
      topics: [
        %{
          name: topic,
          partitions: [
            %{
              partition_index: partition,
              timestamp: if(latest_or_earliest == :earliest, do: -2, else: -1)
            }
          ]
        }
      ]
    }

    case Broker.send_message(M.ListOffsets, client, broker, content) do
      {:ok, %{content: %{topics: [%{partitions: [%{error_code: 0, offset: offset}]}]}}} ->
        offset

      {:ok, %{content: %{topics: [%{partitions: [%{error_code: ec}]}]}}} ->
        Logger.error(
          "Error code #{ec} returned from broker for client #{inspect(client)} on #{inspect(M.ListOffsets)} call"
        )
    end
  end

  def revoke_assignment(client_name, cg_mod, topic_id, partition) do
    client_name
    |> get_process_name(cg_mod, topic_id, partition)
    |> GenServer.call(:assignment_revoked)
  end

  def revoke_assignment_async(client_name, cg_mod, topic_id, partition) do
    client_name
    |> get_process_name(cg_mod, topic_id, partition)
    |> GenServer.cast(:assignment_revoked)
  end

  @impl true
  def handle_info(:poll_records, %__MODULE__{} = state) do
    offset_to_fetch =
      case :queue.out_r(state.records_queue) do
        {{:value, %Record{offset: offset}}, _queue} -> offset + 1
        {:empty, _queue} -> state.latest_processed_offset + 1
      end

    %TopicConfig{} = topic_config = state.topic_config

    opts = [
      fetcher: topic_config.fetcher_name,
      isolation_level: topic_config.isolation_level,
      max_bytes: topic_config.fetch_max_bytes
    ]

    {:ok, _} =
      Fetcher.fetch_async(
        {state.topic_name, state.partition_idx, offset_to_fetch},
        state.client_name,
        opts
      )

    {:noreply, state}
  end

  @impl true
  def handle_info({:klife_fetch_response, {_t, _p, _o}, {:ok, []}}, %__MODULE__{} = state) do
    backoff_ratio = min((state.empty_fetch_results_count + 1) / 100, 1)
    next_fetch_wait_time = ceil(backoff_ratio * state.topic_config.fetch_interval_ms)
    ref = Process.send_after(self(), :poll_records, next_fetch_wait_time)

    new_state = %__MODULE__{
      state
      | empty_fetch_results_count: state.empty_fetch_results_count + 1,
        next_fetch_ref: ref
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:klife_fetch_response, {_t, _p, _o}, {:ok, recs}}, %__MODULE__{} = state) do
    new_queue =
      Enum.reduce(recs, state.records_queue, fn rec, acc_queue -> :queue.in(rec, acc_queue) end)

    new_state = %__MODULE__{
      state
      | records_queue: new_queue,
        records_queue_size: state.records_queue_size + length(recs),
        next_fetch_ref: nil
    }

    send(self(), :handle_records)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:klife_fetch_response, {_t, _p, _o}, {:error, reason}}, %__MODULE__{} = state) do
    Logger.error("Unexpected fetch error on consumer: #{reason}")
    Process.send_after(self(), :poll_records, 5000)
    {:noreply, state}
  end

  @impl true
  def handle_info({:offset_committed, committed_offset}, %__MODULE__{} = state) do
    send(self(), :handle_records)
    {:noreply, %__MODULE__{state | latest_committed_offset: committed_offset}}
  end

  @impl true
  def handle_info(:handle_records, %__MODULE__{} = state) do
    %__MODULE__{
      cg_mod: cg_mod,
      client_name: client_name,
      topic_id: topic_id,
      topic_name: topic_name,
      partition_idx: partition_idx,
      records_queue: rec_queue,
      records_queue_size: records_queue_size,
      topic_config: %TopicConfig{
        handler_max_batch_size: max_batch_size,
        handler_max_commit_lag: max_commit_lag
      },
      latest_committed_offset: latest_committed_offset,
      latest_processed_offset: latest_processed_offset
    } = state

    processing_allowed? =
      ConsumerGroup.processing_allowed?(client_name, cg_mod, topic_id, partition_idx)

    has_records_to_process? = records_queue_size > 0
    curr_commit_lag = latest_processed_offset - latest_committed_offset

    cond do
      not processing_allowed? ->
        Process.send_after(self(), :handle_records, 500)
        {:noreply, state}

      not has_records_to_process? ->
        ref =
          if state.next_fetch_ref == nil do
            Process.send_after(self(), :poll_records, 0)
          else
            state.next_fetch_ref
          end

        {:noreply, %{state | next_fetch_ref: ref}}

      curr_commit_lag > max_commit_lag ->
        {:noreply, state}

      true ->
        max_recs = min(max_batch_size, records_queue_size)

        {recs, new_queue} =
          Enum.reduce(1..max_recs, {[], rec_queue}, fn _i, {acc_recs, acc_queue} ->
            {{:value, rec}, new_queue} = :queue.out(acc_queue)
            {[rec | acc_recs], new_queue}
          end)

        recs = Enum.reverse(recs)

        {parsed_user_result, opts} =
          case cg_mod.handle_record_batch(topic_name, partition_idx, recs) do
            [_ | _] = result -> {result, []}
            {[_ | _] = result, opts} -> {result, opts}
            {action, opts} -> {Enum.map(recs, fn rec -> {action, rec} end), opts}
            action -> {Enum.map(recs, fn rec -> {action, rec} end), []}
          end

        to_move =
          Enum.filter(parsed_user_result, fn {action, _rec} ->
            match?({:move_to, _topic}, action)
          end)
          |> Enum.map(fn {{:move_to, topic_to_move}, rec} ->
            rec
            |> Map.put(:topic, topic_to_move)
            |> Map.put(:partition, nil)
          end)

        if to_move != [] do
          produce_resp = state.client_name.produce_batch(to_move)

          Enum.zip(to_move, produce_resp)
          |> Enum.each(fn {original_rec, {status, produced_rec}} ->
            case status do
              :ok ->
                :noop

              :error ->
                Logger.error("""
                Failed to move record offset #{original_rec.offset} from topic #{original_rec.topic} partition #{original_rec.partition} to topic #{produced_rec.topic} partition #{produced_rec.partition}. Record will be skipped! Error code: #{produced_rec.error_code}
                """)
            end
          end)
        end

        # TODO: Validate result list inconsistencies

        groupped_recs =
          Enum.group_by(
            parsed_user_result,
            fn {action, _rec} -> user_action_to_commit_group(action) end
          )

        to_commit_recs = groupped_recs[:commit] || []

        to_retry_recs = groupped_recs[:retry] || []

        new_queue =
          to_retry_recs
          |> Enum.reverse()
          |> Enum.reduce(new_queue, fn {_action, rec}, acc_queue ->
            new_rec = Map.update(rec, :consumer_attempts, 1, fn att -> att + 1 end)
            :queue.in_r(new_rec, acc_queue)
          end)

        latest_processed_offset =
          case List.last(to_commit_recs) do
            {_, %Record{} = rec} ->
              commit_data = %Committer.BatchItem{
                callback_pid: self(),
                leader_epoch: state.leader_epoch,
                offset_to_commit: rec.offset,
                partition: state.partition_idx,
                topic_name: state.topic_name
              }

              Committer.commit(commit_data, state.client_name, state.cg_mod, state.committer_id)

              rec.offset

            nil ->
              state.latest_processed_offset
          end

        new_queue_size = records_queue_size - length(to_commit_recs)

        ref =
          if new_queue_size <= 2 * max_batch_size and state.next_fetch_ref == nil do
            Process.send_after(self(), :poll_records, 0)
          else
            state.next_fetch_ref
          end

        new_state =
          %__MODULE__{
            state
            | records_queue: new_queue,
              records_queue_size: new_queue_size,
              latest_processed_offset: latest_processed_offset,
              next_fetch_ref: ref
          }

        next_handle_delay = Keyword.get(opts, :handler_cooldown_ms, 0)
        Process.send_after(self(), :handle_records, next_handle_delay)

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:assignment_revoked, waiting_pid}, %__MODULE__{} = state) do
    do_handle_revoke(state, waiting_pid)
  end

  @impl true
  def handle_call(:assignment_revoked, from, %__MODULE__{} = state) do
    do_handle_revoke(state, from)
  end

  @impl true
  def handle_cast(:assignment_revoked, %__MODULE__{} = state) do
    do_handle_revoke(state, nil)
  end

  defp do_handle_revoke(%__MODULE__{} = state, waiting_pid) do
    if state.latest_committed_offset == state.latest_processed_offset do
      if waiting_pid, do: GenServer.reply(waiting_pid, :ok)

      {:stop, {:shutdown, {:assignment_revoked, state.topic_id, state.partition_idx}}, state}
    else
      Process.send_after(self(), {:assignment_revoked, waiting_pid}, 50)
      {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, %__MODULE__{} = state) do
    if function_exported?(state.cg_mod, :handle_consumer_stop, 3) do
      :ok = state.cg_mod.handle_consumer_stop(state.topic_name, state.partition_idx, reason)
    end
  end

  def user_action_to_commit_group(:retry), do: :retry
  def user_action_to_commit_group(:commit), do: :commit
  def user_action_to_commit_group(:skip), do: :commit
  def user_action_to_commit_group({:commit, _str}), do: :commit
  def user_action_to_commit_group({:skip, _str}), do: :commit
  def user_action_to_commit_group({:move_to, _str}), do: :commit
end

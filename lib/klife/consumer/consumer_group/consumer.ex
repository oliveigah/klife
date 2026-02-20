defmodule Klife.Consumer.ConsumerGroup.Consumer do
  @moduledoc false

  use GenServer

  import Klife.ProcessRegistry

  alias Klife.MetadataCache

  alias Klife.Consumer.ConsumerGroup

  alias Klife.Consumer.ConsumerGroup.TopicConfig

  alias Klife.Record

  alias Klife.Consumer.Committer

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
    :latest_fetched_offset,
    :records_batch_queue,
    :records_batch_queue_count,
    :empty_fetch_results_count,
    :fetch_ref,
    :fetch_batcher_monitor_ref,
    :leader_epoch,
    :idle_timeout
  ]

  def start_link(args) do
    cg_mod = Keyword.fetch!(args, :consumer_group_mod)
    client_name = Keyword.fetch!(args, :client_name)
    topic_id = Keyword.fetch!(args, :topic_id)
    partition_idx = Keyword.fetch!(args, :partition_idx)
    cg_name = Keyword.fetch!(args, :consumer_group_name)

    GenServer.start_link(__MODULE__, Map.new(args),
      name: get_process_name(client_name, cg_mod, topic_id, partition_idx, cg_name)
    )
  end

  def get_process_name(client_name, cg_mod, topic_id, partition_idx, cg_name) do
    via_tuple({__MODULE__, client_name, cg_mod, topic_id, partition_idx, cg_name})
  end

  @impl true
  def init(args_map) do
    client_name = args_map.client_name
    topic_name = MetadataCache.get_topic_name_by_id!(client_name, args_map.topic_id)

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
        latest_fetched_offset: -1,
        latest_processed_offset: args_map.init_offset,
        latest_committed_offset: args_map.init_offset,
        empty_fetch_results_count: 0,
        fetch_ref: nil,
        records_batch_queue: :queue.new(),
        records_batch_queue_count: 0,
        cg_pid: args_map.consumer_group_pid,
        leader_epoch:
          Klife.MetadataCache.get_metadata_attribute(
            client_name,
            topic_name,
            args_map.partition_idx,
            :leader_epoch
          )
      }

    send(self(), :poll_records)

    if function_exported?(state.cg_mod, :handle_consumer_start, 3) do
      :ok =
        state.cg_mod.handle_consumer_start(state.topic_name, state.partition_idx, state.cg_name)
    end

    {:ok, %{state | idle_timeout: get_idle_timeout(state)}}
  end

  def revoke_assignment(client_name, cg_mod, topic_id, partition, cg_name) do
    client_name
    |> get_process_name(cg_mod, topic_id, partition, cg_name)
    |> GenServer.call(:assignment_revoked, 15_000)
  end

  def revoke_assignment_async(client_name, cg_mod, topic_id, partition, cg_name) do
    client_name
    |> get_process_name(cg_mod, topic_id, partition, cg_name)
    |> GenServer.cast(:assignment_revoked)
  end

  # This timeout is used as a sanity check of the consumer loop liveness
  # if no message is received by the consumer during the timeout period
  # it will shutdown automatically triggering a restart! This should never
  # be triggered, but is a safety mechanism to ensure that no consumer will
  # become stale.
  #
  # This is especially important because the consumer main loop depends on
  # multiple other process colaborate properly (fetcher, batcher, dispatcher, commiter)
  # any unexpected error on them may cause the consumer be forever waiting
  # for a message that may never arrive!
  defp get_idle_timeout(%__MODULE__{} = state) do
    # TODO: Use fetcher and commiter request timeout here instead of the client default
    3 *
      (state.topic_config.fetch_interval_ms + state.client_name.get_default_request_timeout_ms())
  end

  @impl true
  def handle_info(:timeout, %__MODULE__{} = state) do
    Logger.error(
      "Consumer liveness timeout for #{state.topic_name}:#{state.partition_idx} on group #{state.cg_name}, restarting (client=#{inspect(state.client_name)})",
      client: state.client_name,
      group: state.cg_name,
      topic: state.topic_name,
      partition: state.partition_idx
    )

    {:stop, {:shutdown, :liveness_timeout}, state}
  end

  def handle_info(:poll_records, %__MODULE__{fetch_ref: nil} = state) do
    offset_to_fetch =
      case :queue.out_r(state.records_batch_queue) do
        {{:value, rec_batch}, _queue} ->
          max(List.last(rec_batch).offset + 1, state.latest_fetched_offset + 1)

        {:empty, _queue} ->
          max(state.latest_processed_offset + 1, state.latest_fetched_offset + 1)
      end

    %TopicConfig{} = topic_config = state.topic_config

    tpo = {state.topic_name, state.partition_idx, offset_to_fetch}
    ref = {make_ref(), tpo}

    {_shared_or_exclusive, fetcher_name} = topic_config.fetch_strategy

    opts = [
      fetcher: fetcher_name,
      isolation_level: topic_config.isolation_level,
      max_bytes: topic_config.fetch_max_bytes
    ]

    case Fetcher.fetch_async(tpo, state.client_name, opts) do
      {:ok, batcher_pid} ->
        batcher_monitor = Process.monitor(batcher_pid)

        {:noreply,
         %__MODULE__{state | fetch_ref: ref, fetch_batcher_monitor_ref: batcher_monitor},
         state.idle_timeout}

      {:error, reason} ->
        Logger.warning(
          "Fetch error for #{state.topic_name}:#{state.partition_idx} on group #{state.cg_name} reason #{reason} (client=#{inspect(state.client_name)})",
          client: state.client_name,
          group: state.cg_name,
          topic: state.topic_name,
          partition: state.partition_idx
        )

        Process.send_after(self(), :poll_records, Enum.random(100..1000))
        {:noreply, state, state.idle_timeout}
    end
  end

  def handle_info(:poll_records, %__MODULE__{} = state) do
    {:noreply, state, state.idle_timeout}
  end

  @impl true
  def handle_info({:klife_fetch_response, {_t, _p, _o} = tpo, {:ok, recs}}, %__MODULE__{} = state) do
    state = demonitor_batcher(state)
    {:noreply, handle_fetch_response(state, recs, tpo), state.idle_timeout}
  end

  @impl true
  def handle_info(
        {:klife_fetch_response, {_t, _p, _o} = tpo, {:error, reason}},
        %__MODULE__{} = state
      ) do
    state = demonitor_batcher(state)
    {:noreply, handle_fetch_error!(state, reason, tpo), state.idle_timeout}
  end

  @impl true
  def handle_info({:offset_committed, committed_offset}, %__MODULE__{} = state) do
    send(self(), :handle_records)

    {:noreply,
     %__MODULE__{
       state
       | latest_committed_offset: max(state.latest_committed_offset, committed_offset)
     }, state.idle_timeout}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %__MODULE__{fetch_batcher_monitor_ref: ref, fetch_ref: {_ref, tpo}} = state
      )
      when ref != nil do
    state = %__MODULE__{state | fetch_batcher_monitor_ref: nil}
    {:noreply, handle_fetch_error!(state, :batcher_down, tpo), state.idle_timeout}
  end

  @impl true
  def handle_info(:handle_records, %__MODULE__{} = state) do
    %__MODULE__{
      cg_mod: cg_mod,
      client_name: client_name,
      topic_id: topic_id,
      topic_name: topic_name,
      partition_idx: partition_idx,
      records_batch_queue: rec_queue,
      records_batch_queue_count: records_batch_queue_count,
      topic_config: %TopicConfig{
        handler_max_unacked_commits: max_unacked
      },
      latest_committed_offset: latest_committed_offset,
      latest_processed_offset: latest_processed_offset,
      cg_name: cg_name
    } = state

    processing_allowed? =
      ConsumerGroup.processing_allowed?(
        client_name,
        cg_mod,
        topic_id,
        partition_idx,
        cg_name
      )

    has_records_to_process? = records_batch_queue_count > 0
    curr_unacked = latest_processed_offset - latest_committed_offset

    cond do
      not processing_allowed? ->
        Process.send_after(self(), :handle_records, 100)
        {:noreply, state, state.idle_timeout}

      not has_records_to_process? ->
        if state.fetch_ref == nil do
          Process.send_after(self(), :poll_records, 0)
        end

        {:noreply, state, state.idle_timeout}

      curr_unacked > max_unacked ->
        {:noreply, state, state.idle_timeout}

      true ->
        {{:value, rec_batch}, new_queue} = :queue.out(rec_queue)

        # TODO: There is a bug when user's callback raises, because
        # it is not guarantee that the new consumer will be started
        # only after the commit happens.
        # Ideally we should wait for the commits before fully removing
        # this consumer from the consumer group, but it is not clear
        # how to proper implement it right now
        {parsed_user_result, usr_opts} =
          case cg_mod.handle_record_batch(topic_name, partition_idx, cg_name, rec_batch) do
            [_ | _] = result -> {result, []}
            {[_ | _] = result, opts} -> {result, opts}
            {action, opts} -> {Enum.map(rec_batch, fn rec -> {action, rec} end), opts}
            action -> {Enum.map(rec_batch, fn rec -> {action, rec} end), []}
          end

        groupped_recs =
          Enum.group_by(
            parsed_user_result,
            fn {action, _rec} -> action end,
            fn {_action, rec} -> rec end
          )

        to_commit_recs = groupped_recs[:commit] || []
        to_retry_recs = groupped_recs[:retry] || []

        new_queue =
          to_retry_recs
          |> Enum.map(fn rec ->
            Map.update(rec, :consumer_attempts, 1, fn att -> att + 1 end)
          end)
          |> case do
            [] -> new_queue
            list -> :queue.in_r(list, new_queue)
          end

        latest_processed_offset =
          case List.last(to_commit_recs) do
            %Record{} = rec ->
              commit_data = %Committer.BatchItem{
                callback_pid: self(),
                leader_epoch: state.leader_epoch,
                offset_to_commit: rec.offset,
                partition: state.partition_idx,
                topic_name: state.topic_name
              }

              :ok =
                Committer.commit(
                  commit_data,
                  state.client_name,
                  state.cg_mod,
                  state.cg_name,
                  state.committer_id
                )

              rec.offset

            nil ->
              state.latest_processed_offset
          end

        new_queue_size =
          if to_retry_recs == [],
            do: records_batch_queue_count - 1,
            else: records_batch_queue_count

        if new_queue_size <= 3 do
          Process.send_after(self(), :poll_records, 0)
        end

        new_state =
          %__MODULE__{
            state
            | records_batch_queue: new_queue,
              records_batch_queue_count: new_queue_size,
              latest_processed_offset: latest_processed_offset
          }

        next_handle_delay = Keyword.get(usr_opts, :handler_cooldown_ms, 0)
        # TODO: Proper implement cooldown! The send_after approach does not guarantee
        # that no record will be consumed because :handle_records may be received
        # from the commit or poll message handling
        Process.send_after(self(), :handle_records, next_handle_delay)

        {:noreply, new_state, state.idle_timeout}
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
      Process.send_after(self(), {:assignment_revoked, waiting_pid}, 100)
      {:noreply, state, state.idle_timeout}
    end
  end

  @impl true
  def terminate(reason, %__MODULE__{} = state) do
    if state.latest_committed_offset < state.latest_processed_offset do
      Logger.warning(
        "Consumer for #{state.topic_name}:#{state.partition_idx} on group #{state.cg_name} terminated with unacked commits (client=#{inspect(state.client_name)})",
        client: state.client_name,
        group: state.cg_name,
        topic: state.topic_name,
        partition: state.partition_idx
      )
    end

    if function_exported?(state.cg_mod, :handle_consumer_stop, 4) do
      :ok =
        state.cg_mod.handle_consumer_stop(
          state.topic_name,
          state.partition_idx,
          state.cg_name,
          reason
        )
    end
  end

  defp demonitor_batcher(%__MODULE__{fetch_batcher_monitor_ref: nil} = state), do: state

  defp demonitor_batcher(%__MODULE__{fetch_batcher_monitor_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    %__MODULE__{state | fetch_batcher_monitor_ref: nil}
  end

  def handle_fetch_error!(%__MODULE__{} = state, 1, {t, p, o}) do
    reset_offset_map =
      ConsumerGroup.get_reset_offset(
        [{state.topic_name, state.partition_idx}],
        state.client_name,
        %{
          state.topic_name => state.topic_config
        }
      )

    reset_offset = Map.fetch!(reset_offset_map, {state.topic_name, state.partition_idx})

    Logger.warning(
      "Offset out of range for #{t}:#{p} at offset #{o}, resetting to #{reset_offset} (client=#{inspect(state.client_name)}, group=#{state.cg_name})",
      client: state.client_name,
      group: state.cg_name,
      topic: t,
      partition: p
    )

    send(self(), :poll_records)

    %__MODULE__{state | latest_fetched_offset: reset_offset, fetch_ref: nil}
  end

  @retryable_errors [
    :timeout,
    :batcher_down,
    :broker_removed,
    -1,
    3,
    5,
    6,
    7,
    9,
    56,
    74,
    75,
    78,
    100,
    103
  ]
  def handle_fetch_error!(%__MODULE__{} = state, error, {t, p, o})
      when error in @retryable_errors do
    Logger.warning(
      "Fetch error on #{t}:#{p} at offset #{o}, retrying: #{inspect(error)} (client=#{inspect(state.client_name)}, group=#{state.cg_name})",
      client: state.client_name,
      group: state.cg_name,
      topic: t,
      partition: p
    )

    Process.send_after(
      self(),
      :poll_records,
      Enum.random(0..state.topic_config.fetch_interval_ms)
    )

    %__MODULE__{state | fetch_ref: nil}
  end

  # TODO: Should handle more error codes?
  def handle_fetch_error!(%__MODULE__{} = state, error_code, {t, p, _o}) do
    raise "Unexpected fetch error on #{t}:#{p} (error_code=#{inspect(error_code)}, client=#{inspect(state.client_name)}, group=#{state.cg_name})"
  end

  def handle_fetch_response(%__MODULE__{} = state, [], {_t, _p, _o}) do
    backoff_ratio = min((state.empty_fetch_results_count + 1) / 10, 1)
    next_fetch_wait_time = ceil(backoff_ratio * state.topic_config.fetch_interval_ms)
    Process.send_after(self(), :poll_records, next_fetch_wait_time)

    %__MODULE__{
      state
      | empty_fetch_results_count: state.empty_fetch_results_count + 1,
        fetch_ref: nil
    }
  end

  def handle_fetch_response(
        %__MODULE__{records_batch_queue: curr_queue, records_batch_queue_count: curr_q_size} =
          state,
        base_recs,
        {_t, _p, base_offset}
      ) do
    filter_rec_opts =
      [
        base_offset: base_offset,
        exclude_control: true,
        exclude_aborted: state.topic_config.isolation_level == :read_committed
      ]

    base_last_fetched_offset = List.last(base_recs).offset

    {new_queue, new_queue_size, last_fetched_offset} =
      case Record.filter_records(base_recs, filter_rec_opts) do
        [] ->
          {
            state.records_batch_queue,
            state.records_batch_queue_count,
            base_last_fetched_offset
          }

        recs ->
          case state.topic_config.handler_max_batch_size do
            :dynamic ->
              new_queue = :queue.in(recs, state.records_batch_queue)
              new_queue_size = state.records_batch_queue_count + 1
              {new_queue, new_queue_size, List.last(recs).offset}

            batch_size ->
              {new_queue, new_size} =
                recs
                |> Enum.chunk_every(batch_size)
                |> Enum.reduce_while({curr_queue, curr_q_size}, fn rec_batch,
                                                                   {acc_queue, acc_size} ->
                  new_size = acc_size + 1

                  if new_size > state.topic_config.max_queue_size,
                    do: {:halt, {acc_queue, acc_size}},
                    else: {:cont, {:queue.in(rec_batch, acc_queue), new_size}}
                end)

              {:value, last_batch} = :queue.peek_r(new_queue)
              {new_queue, new_size, List.last(last_batch).offset}
          end
      end

    send(self(), :handle_records)

    %__MODULE__{
      state
      | records_batch_queue: new_queue,
        records_batch_queue_count: new_queue_size,
        latest_fetched_offset: min(base_last_fetched_offset, last_fetched_offset),
        empty_fetch_results_count: 0,
        fetch_ref: nil
    }
  end
end

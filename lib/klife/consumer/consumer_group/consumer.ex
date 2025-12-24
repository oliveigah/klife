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
    :latest_fetched_offset,
    :records_batch_queue,
    :records_batch_queue_count,
    :empty_fetch_results_count,
    :fetch_ref,
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
        latest_fetched_offset: -1,
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
              timestamp:
                case latest_or_earliest do
                  :earliest -> -2
                  :latest -> -1
                end
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

    {:ok, timeout} =
      case topic_config.fetch_strategy do
        {:shared, fetcher_name} ->
          opts = [
            fetcher: fetcher_name,
            isolation_level: topic_config.isolation_level,
            max_bytes: topic_config.fetch_max_bytes
          ]

          Fetcher.fetch_async(
            tpo,
            state.client_name,
            opts
          )

        {:exclusive, fetch_opts} ->
          final_opts =
            Keyword.merge(
              fetch_opts,
              isolation_level: topic_config.isolation_level,
              max_bytes: topic_config.fetch_max_bytes,
              callback_ref: ref
            )

          :ok =
            Fetcher.fetch_raw_async(
              tpo,
              state.client_name,
              final_opts
            )

          {:ok, fetch_opts[:request_timeout_ms]}
      end

    Process.send_after(self(), {:check_poll_timeout, ref}, timeout + 1000)

    {:noreply, %__MODULE__{state | fetch_ref: ref}}
  end

  def handle_info(:poll_records, %__MODULE__{} = state) do
    {:noreply, state}
  end

  def handle_info({:check_poll_timeout, ref}, %__MODULE__{} = state) do
    if ref == state.fetch_ref do
      Logger.warning(
        "Fetch request timeout for #{state.topic_name} #{state.partition_idx} on client #{state.client_name} group name #{state.cg_name} module #{state.cg_mod}, retrying..."
      )

      Process.send_after(self(), :poll_records, Enum.random(1000..5000))

      {:noreply, %__MODULE__{state | fetch_ref: nil}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:klife_fetch_response, {_t, _p, _o} = tpo, {:ok, recs}}, %__MODULE__{} = state) do
    {:noreply, handle_fetch_response(state, recs, tpo)}
  end

  @impl true
  def handle_info(
        {:klife_fetch_response, {_t, _p, _o} = tpo, {:error, reason}},
        %__MODULE__{} = state
      ) do
    {:noreply, handle_fetch_error!(state, reason, tpo)}
  end

  @impl true
  def handle_info(
        {:async_broker_response, {req_ref, {t, p, o} = tpo}, binary_resp, M.Fetch = msg_mod,
         msg_version},
        %__MODULE__{fetch_ref: {req_ref, {t, p, o}}, topic_id: t_id} = state
      ) do
    with {:ok, %{content: content}} <- msg_mod.deserialize_response(binary_resp, msg_version),
         %{error_code: 0, responses: [%{topic_id: ^t_id, partitions: [resp_data]}]} <- content,
         %{error_code: 0} <- resp_data do
      first_aborted_offset =
        if state.topic_config.isolation_level == :read_committed do
          Enum.map(resp_data.aborted_transactions, fn %{first_offset: fo} -> fo end)
          |> Enum.min(fn -> :infinity end)
        else
          :infinity
        end

      recs =
        Enum.flat_map(resp_data.records, fn rec_batch ->
          Record.parse_from_protocol(t, p, rec_batch, first_aborted_offset: first_aborted_offset)
        end)

      {:noreply, handle_fetch_response(state, recs, tpo)}
    else
      %{error_code: ec} ->
        {:noreply, handle_fetch_error!(state, ec, tpo)}

      {:error, reason} ->
        raise "Unexpected error on consumer fetch. reason: #{inspect(reason)}"

      _err ->
        raise "unexpected error on consumer fetch"
    end
  end

  @impl true
  def handle_info(
        {:async_broker_response, ref, _binary_resp, M.Fetch, _msg_version},
        %__MODULE__{} = state
      ) do
    if state.fetch_ref != ref do
      Logger.warning(
        "Unexpected async broker response received for #{state.topic_name} #{state.partition_idx} on client #{state.client_name}"
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:offset_committed, committed_offset}, %__MODULE__{} = state) do
    send(self(), :handle_records)

    {:noreply,
     %__MODULE__{
       state
       | latest_committed_offset: max(state.latest_committed_offset, committed_offset)
     }}
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
        Process.send_after(self(), :handle_records, 5)
        {:noreply, state}

      not has_records_to_process? ->
        if state.fetch_ref == nil do
          Process.send_after(self(), :poll_records, 0)
        end

        {:noreply, state}

      curr_unacked > max_unacked ->
        {:noreply, state}

      true ->
        {{:value, rec_batch}, new_queue} = :queue.out(rec_queue)

        {parsed_user_result, usr_opts} =
          case cg_mod.handle_record_batch(topic_name, partition_idx, rec_batch) do
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

        if new_queue_size <= 1 do
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

  def handle_fetch_error!(%__MODULE__{} = state, 1, {t, p, o}) do
    Logger.warning(
      "Tried to fetch from offset #{o} for topic #{t} partition #{p} but offset was out of range (error code 1). Reseting offset..."
    )

    start_offset =
      get_start_offset(
        state.client_name,
        state.topic_name,
        state.partition_idx,
        # Should this be always earliest??
        state.topic_config.offset_reset_policy
      )

    send(self(), :poll_records)
    %__MODULE__{latest_fetched_offset: start_offset - 1, fetch_ref: nil}
  end

  # TODO: Should handle more error codes?
  def handle_fetch_error!(%__MODULE__{} = _state, error_code, {t, _p, _o}) do
    raise "Unexpected error on consumer fetch for topic #{t}. error code: #{inspect(error_code)}"
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
        include_control: false,
        include_aborted: state.topic_config.isolation_level == :read_uncommitted
      ]

    {new_queue, new_queue_size} =
      case Record.filter_records(base_recs, filter_rec_opts) do
        [] ->
          {state.records_batch_queue, state.records_batch_queue_count}

        recs ->
          case state.topic_config.handler_max_batch_size do
            :dynamic ->
              new_queue = :queue.in(recs, state.records_batch_queue)
              new_queue_size = state.records_batch_queue_count + 1
              {new_queue, new_queue_size}

            batch_size ->
              chunk_size = min(length(recs), batch_size)

              recs
              |> Enum.chunk_every(chunk_size, chunk_size, :discard)
              |> Enum.reduce_while({curr_queue, curr_q_size}, fn rec_batch,
                                                                 {acc_queue, acc_size} ->
                new_size = acc_size + 1

                if new_size > state.topic_config.max_queue_size,
                  do: {:halt, {acc_queue, acc_size}},
                  else: {:cont, {:queue.in(rec_batch, acc_queue), new_size}}
              end)
          end
      end

    send(self(), :handle_records)

    %__MODULE__{
      state
      | records_batch_queue: new_queue,
        records_batch_queue_count: new_queue_size,
        latest_fetched_offset: List.last(base_recs).offset,
        empty_fetch_results_count: 0,
        fetch_ref: nil
    }
  end
end

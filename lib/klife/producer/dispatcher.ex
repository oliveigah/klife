defmodule Klife.Producer.Dispatcher do
  use GenServer
  import Klife.ProcessRegistry

  require Logger
  alias Klife.Producer
  alias Klife.Connection.Broker
  alias KlifeProtocol.Messages

  defstruct [
    :producer_config,
    :broker_id,
    :current_batch,
    :current_waiting_pids,
    :current_base_time,
    :current_estimated_size,
    :last_batch_sent_at,
    :in_flight_pool,
    :next_send_msg_ref,
    :batch_queue
  ]

  def start_link(args) do
    pconfig = Keyword.fetch!(args, :producer_config)
    cluster_name = pconfig.cluster_name
    broker_id = Keyword.fetch!(args, :broker_id)
    dispatcher_id = Keyword.fetch!(args, :id)

    GenServer.start_link(__MODULE__, args,
      name:
        get_process_name(
          cluster_name,
          broker_id,
          pconfig.producer_name,
          dispatcher_id
        )
    )
  end

  def init(args) do
    args_map = Map.new(args)
    max_in_flight = args_map.producer_config.max_in_flight_requests
    linger_ms = args_map.producer_config.linger_ms

    next_send_msg_ref =
      if linger_ms > 0,
        do: Process.send_after(self(), :send_to_broker, linger_ms),
        else: nil

    base = %__MODULE__{
      current_batch: %{},
      current_waiting_pids: %{},
      current_base_time: nil,
      current_estimated_size: 0,
      batch_queue: :queue.new(),
      last_batch_sent_at: System.monotonic_time(:millisecond),
      in_flight_pool: Enum.map(1..max_in_flight, fn _ -> nil end),
      next_send_msg_ref: next_send_msg_ref
    }

    state = %__MODULE__{} = Map.merge(base, args_map)

    {:ok, state}
  end

  def produce_sync(
        record,
        topic,
        partition,
        cluster_name,
        broker_id,
        producer_name,
        dispatcher_id
      ) do
    cluster_name
    |> get_process_name(broker_id, producer_name, dispatcher_id)
    |> GenServer.call({:produce_sync, record, topic, partition, estimate_record_size(record)})
  end

  def handle_call(
        {:produce_sync, record, topic, partition, rec_size},
        {pid, _tag},
        %__MODULE__{} = state
      ) do
    %{
      producer_config: %{linger_ms: linger_ms, delivery_timeout_ms: delivery_timeout},
      last_batch_sent_at: last_batch_sent_at,
      in_flight_pool: in_flight_pool,
      batch_queue: batch_queue
    } = state

    now = System.monotonic_time(:millisecond)
    pool_idx = Enum.find_index(in_flight_pool, &is_nil/1)

    on_time? = now - last_batch_sent_at >= linger_ms
    request_in_flight_available? = is_number(pool_idx)
    batch_queue_is_empty? = :queue.is_empty(batch_queue)

    cond do
      not on_time? ->
        new_state = add_record(state, record, topic, partition, pid, rec_size)
        {:reply, {:ok, delivery_timeout}, new_state}

      not request_in_flight_available? ->
        new_state =
          state
          |> add_record(record, topic, partition, pid, rec_size)
          |> schedule_dispatch(10)

        {:reply, {:ok, delivery_timeout}, new_state}

      batch_queue_is_empty? ->
        new_sate =
          state
          |> add_record(record, topic, partition, pid, rec_size)
          |> dispatch_to_broker(pool_idx)

        {:reply, {:ok, delivery_timeout}, new_sate}

      not batch_queue_is_empty? ->
        new_sate =
          state
          |> add_record(record, topic, partition, pid, rec_size)
          |> dispatch_to_broker(pool_idx)
          |> schedule_dispatch(10)

        {:reply, {:ok, delivery_timeout}, new_sate}
    end
  end

  def handle_info(:send_to_broker, %__MODULE__{} = state) do
    %{
      producer_config: %{linger_ms: linger_ms},
      last_batch_sent_at: last_batch_sent_at,
      in_flight_pool: in_flight_pool,
      batch_queue: batch_queue
    } = state

    now = System.monotonic_time(:millisecond)
    pool_idx = Enum.find_index(in_flight_pool, &is_nil/1)

    on_time? = now - last_batch_sent_at >= linger_ms
    in_flight_available? = is_number(pool_idx)
    has_batch_on_queue? = not :queue.is_empty(batch_queue)
    should_reschedule? = linger_ms > 0 or has_batch_on_queue?

    new_state = %{state | next_send_msg_ref: nil}

    cond do
      not on_time? ->
        {:noreply, schedule_dispatch(new_state, linger_ms - (now - last_batch_sent_at))}

      not in_flight_available? ->
        {:noreply, schedule_dispatch(new_state, 10)}

      should_reschedule? ->
        new_state =
          new_state
          |> dispatch_to_broker(pool_idx)
          |> schedule_dispatch(if has_batch_on_queue?, do: 0, else: linger_ms)

        {:noreply, new_state}

      not should_reschedule? ->
        {:noreply, dispatch_to_broker(new_state, pool_idx)}
    end
  end

  def handle_info({:broker_delivery_success, pool_idx}, %__MODULE__{} = state) do
    %__MODULE__{
      in_flight_pool: in_flight_pool
    } = state

    {:noreply, %{state | in_flight_pool: List.replace_at(in_flight_pool, pool_idx, nil)}}
  end

  def handle_info({:broker_delivery_error, pool_idx, :timeout}, %__MODULE__{} = state) do
    %__MODULE__{
      in_flight_pool: in_flight_pool
    } = state

    Logger.error("""
    Timeout error while produce to broker.

    cluster: #{state.producer_config.cluster_name}
    broker_id: #{state.broker_id}
    producer_name: #{state.producer_config.name}
    """)

    {:noreply, %{state | in_flight_pool: List.replace_at(in_flight_pool, pool_idx, nil)}}
  end

  ## State Operations

  def reset_current_data(%__MODULE__{} = state) do
    %{
      state
      | current_batch: %{},
        current_waiting_pids: %{},
        current_base_time: nil,
        current_estimated_size: 0
    }
  end

  def move_current_data_to_batch_queue(%__MODULE__{batch_queue: batch_queue} = state) do
    data_to_queue =
      Map.take(state, [
        :current_batch,
        :current_waiting_pids,
        :current_base_time,
        :current_estimated_size
      ])

    %{state | batch_queue: :queue.in(data_to_queue, batch_queue)}
    |> reset_current_data()
  end

  def add_record_to_current_data(
        %__MODULE__{
          current_estimated_size: curr_size,
          producer_config: pconfig,
          current_batch: curr_batch,
          current_waiting_pids: curr_pids,
          current_base_time: curr_base_time
        } = state,
        record,
        topic,
        partition,
        pid,
        estimated_size
      ) do
    %{
      state
      | current_batch: add_record_to_batch(curr_batch, record, topic, partition, pconfig),
        current_waiting_pids: add_waiting_pid(curr_pids, pid, topic, partition),
        current_base_time: curr_base_time || System.monotonic_time(:millisecond),
        current_estimated_size: curr_size + estimated_size
    }
  end

  def add_record(
        %__MODULE__{
          producer_config: %{batch_size_bytes: batch_size_bytes},
          current_estimated_size: current_estimated_size
        } = state,
        record,
        topic,
        partition,
        pid,
        rec_estimated_size
      ) do
    if current_estimated_size + rec_estimated_size > batch_size_bytes,
      do:
        state
        |> move_current_data_to_batch_queue()
        |> add_record_to_current_data(record, topic, partition, pid, rec_estimated_size),
      else:
        state
        |> add_record_to_current_data(record, topic, partition, pid, rec_estimated_size)
  end

  def dispatch_to_broker(
        %__MODULE__{
          producer_config: %{cluster_name: cluster_name} = pconfig,
          broker_id: broker_id,
          in_flight_pool: in_flight_pool,
          batch_queue: batch_queue
        } = state,
        pool_idx
      ) do
    case :queue.out(batch_queue) do
      {{:value, queued_data}, new_queue} ->
        {queued_data, new_queue, false}

      {:empty, new_queue} ->
        if state.current_estimated_size == 0,
          do: :noop,
          else: {state, new_queue, true}
    end
    |> case do
      :noop ->
        state

      {data_to_send, new_batch_queue, sending_from_current?} ->
        %{
          current_batch: batch_to_send,
          current_waiting_pids: waiting_pids,
          current_base_time: batch_base_time
        } = data_to_send

        {:ok, task_pid} =
          Task.Supervisor.start_child(
            via_tuple({Klife.Producer.DispatcherTaskSupervisor, cluster_name}),
            __MODULE__,
            :do_dispatch_to_broker,
            [
              pconfig,
              batch_to_send,
              broker_id,
              self(),
              waiting_pids,
              pool_idx,
              batch_base_time
            ],
            restart: :transient
          )

        new_state = %{
          state
          | batch_queue: new_batch_queue,
            in_flight_pool: List.replace_at(in_flight_pool, pool_idx, task_pid),
            last_batch_sent_at: System.monotonic_time(:millisecond)
        }

        if sending_from_current?,
          do: reset_current_data(new_state),
          else: new_state
    end
  end

  def schedule_dispatch(%__MODULE__{next_send_msg_ref: nil} = state, time),
    do: %{
      state
      | next_send_msg_ref: Process.send_after(self(), :send_to_broker, time)
    }

  def schedule_dispatch(%__MODULE__{} = state, _), do: state

  ## PRIVATE FUNCTIONS

  defp add_record_to_batch(current_batch, record, topic, partition, pconfig) do
    case Map.get(current_batch, {topic, partition}) do
      nil ->
        new_batch =
          pconfig
          |> init_partition_data(topic, partition)
          |> add_record_to_batch(record)

        Map.put(current_batch, {topic, partition}, new_batch)

      partition_data ->
        new_partition_data = add_record_to_batch(partition_data, record)
        Map.replace!(current_batch, {topic, partition}, new_partition_data)
    end
  end

  defp init_partition_data(%Producer{} = _pconfig, _topic, _partition) do
    # TODO: Use proper values here
    %{
      base_offset: 0,
      partition_leader_epoch: -1,
      magic: 2,
      attributes: 0,
      last_offset_delta: -1,
      base_timestamp: nil,
      max_timestamp: nil,
      producer_id: -1,
      producer_epoch: -1,
      base_sequence: -1,
      records: [],
      records_length: 0
    }
  end

  defp add_record_to_batch(batch, record) do
    now = DateTime.to_unix(DateTime.utc_now())

    new_offset_delta = batch.last_offset_delta + 1
    timestamp_delta = if batch.base_timestamp == nil, do: 0, else: now - batch.base_timestamp

    new_rec = %{
      attributes: 0,
      timestamp_delta: timestamp_delta,
      offset_delta: new_offset_delta,
      key: record[:key],
      value: record.value,
      headers: record[:headers]
    }

    %{
      batch
      | records: [new_rec | batch.records],
        records_length: batch.records_length + 1,
        last_offset_delta: batch.last_offset_delta + 1,
        max_timestamp: now,
        base_timestamp: min(batch.base_timestamp, now)
    }
  end

  defp add_waiting_pid(waiting_pids, new_pid, topic, partition) do
    case Map.get(waiting_pids, {topic, partition}) do
      nil ->
        Map.put(waiting_pids, {topic, partition}, [{new_pid, 0}])

      [{_last_pid, last_offset} | _rest] = current_pids ->
        Map.replace!(waiting_pids, {topic, partition}, [{new_pid, last_offset + 1} | current_pids])
    end
  end

  def do_dispatch_to_broker(
        pconfig,
        batch_to_send,
        broker_id,
        callback_pid,
        delivery_confirmation_pids,
        pool_idx,
        base_time
      ) do
    %Producer{
      request_timeout_ms: req_timeout,
      delivery_timeout_ms: delivery_timeout,
      cluster_name: cluster_name,
      retry_backoff_ms: retry_ms,
      client_id: client_id,
      acks: acks
    } = pconfig

    now = System.monotonic_time(:millisecond)

    headers = %{client_id: client_id}

    content = %{
      transactional_id: nil,
      acks: if(acks == :all, do: -1, else: acks),
      timeout_ms: req_timeout,
      topic_data: parse_batch_before_send(batch_to_send)
    }

    # Check if it is safe to send the batch
    if now + req_timeout - base_time < delivery_timeout - :timer.seconds(5) do
      {:ok, resp} =
        Broker.send_message(Messages.Produce, cluster_name, broker_id, content, headers)

      grouped_results =
        for %{name: topic_name, partition_responses: partition_resps} <- resp.content.responses,
            %{error_code: error_code, index: p_index} = p <- partition_resps do
          {topic_name, p_index, error_code, p[:base_offset]}
        end
        |> Enum.group_by(&(elem(&1, 2) == 0))

      success_list = grouped_results[true] || []
      failure_list = grouped_results[false] || []

      success_list
      |> Enum.each(fn {topic, partition, 0, base_offset} ->
        delivery_confirmation_pids
        |> Map.get({topic, partition}, [])
        |> Enum.each(fn {pid, batch_offset} ->
          send(pid, {:klife_produce_sync, :ok, base_offset + batch_offset})
        end)
      end)

      case failure_list do
        [] ->
          send(callback_pid, {:broker_delivery_success, pool_idx})

        _list ->
          # TODO: Handle specific errors by code, not just retry all not success
          new_batch_to_send =
            batch_to_send
            |> Map.drop(Enum.map(success_list, fn {t, p, _, _} -> {t, p} end))

          Process.sleep(retry_ms)

          do_dispatch_to_broker(
            pconfig,
            new_batch_to_send,
            broker_id,
            callback_pid,
            delivery_confirmation_pids,
            pool_idx,
            base_time
          )
      end
    else
      send(callback_pid, {:broker_delivery_error, pool_idx, :timeout})
    end
  end

  defp parse_batch_before_send(current_batch) do
    current_batch
    |> Enum.group_by(fn {k, _} -> elem(k, 0) end, fn {k, v} -> {elem(k, 1), v} end)
    |> Enum.map(fn {topic, partitions_list} ->
      %{
        name: topic,
        partition_data:
          Enum.map(partitions_list, fn {partition, batch} ->
            %{
              index: partition,
              records: Map.replace(batch, :records, Enum.reverse(batch.records))
            }
          end)
      }
    end)
  end

  defp get_process_name(
         cluster_name,
         broker_id,
         producer_name,
         dispatcher_id
       ) do
    via_tuple({__MODULE__, cluster_name, broker_id, producer_name, dispatcher_id})
  end

  defp estimate_record_size(record) do
    # add 80 extra bytes to account for other fields
    Enum.reduce(record, 80, fn {k, v}, acc ->
      acc + do_estimate_size(k, v)
    end)
  end

  defp do_estimate_size(_k, nil), do: 0

  defp do_estimate_size(_k, v) when is_list(v),
    do: Enum.reduce(v, 0, fn i, acc -> acc + estimate_record_size(i) end)

  defp do_estimate_size(_k, v) when is_binary(v), do: byte_size(v)
end

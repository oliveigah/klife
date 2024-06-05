defmodule Klife.Producer.Batcher do
  use GenServer
  import Klife.ProcessRegistry

  require Logger

  alias Klife.Record

  alias Klife.Producer
  alias Klife.Producer.Dispatcher

  defstruct [
    :producer_config,
    :producer_epochs,
    :base_sequences,
    :broker_id,
    :current_batch,
    :current_waiting_pids,
    :current_base_time,
    :current_estimated_size,
    :last_batch_sent_at,
    :in_flight_pool,
    :next_send_msg_ref,
    :batch_queue,
    :batcher_id,
    :dispatcher_pid
  ]

  def start_link(args) do
    pconfig = Keyword.fetch!(args, :producer_config)
    cluster_name = pconfig.cluster_name
    broker_id = Keyword.fetch!(args, :broker_id)
    batcher_id = Keyword.fetch!(args, :id)

    GenServer.start_link(__MODULE__, args,
      name:
        get_process_name(
          cluster_name,
          broker_id,
          pconfig.producer_name,
          batcher_id
        )
    )
  end

  def init(args) do
    args_map = Map.new(args)
    max_in_flight = args_map.producer_config.max_in_flight_requests
    linger_ms = args_map.producer_config.linger_ms
    broker_id = args_map.broker_id
    batcher_id = args_map.id
    producer_config = args_map.producer_config

    next_send_msg_ref =
      if linger_ms > 0,
        do: Process.send_after(self(), :send_to_broker, linger_ms),
        else: nil

    state = %__MODULE__{
      current_batch: %{},
      current_waiting_pids: %{},
      current_base_time: nil,
      current_estimated_size: 0,
      batch_queue: :queue.new(),
      last_batch_sent_at: System.monotonic_time(:millisecond),
      in_flight_pool: Enum.map(1..max_in_flight, fn _ -> nil end),
      next_send_msg_ref: next_send_msg_ref,
      base_sequences: %{},
      producer_epochs: %{},
      broker_id: broker_id,
      batcher_id: batcher_id,
      producer_config: producer_config
    }

    {:ok, dispatcher_pid} = start_dispatcher(state)

    {:ok, %{state | dispatcher_pid: dispatcher_pid}}
  end

  defp start_dispatcher(%__MODULE__{} = state) do
    args = [
      producer_config: state.producer_config,
      broker_id: state.broker_id,
      batcher_id: state.batcher_id,
      batcher_pid: self()
    ]

    case Dispatcher.start_link(args) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  def produce(
        [%Record{} | _] = records,
        cluster_name,
        broker_id,
        producer_name,
        batcher_id,
        callback_pid
      ) do
    cluster_name
    |> get_process_name(broker_id, producer_name, batcher_id)
    |> GenServer.call({:produce, records, callback_pid})
  end

  def handle_call(
        {:produce, [%Record{} | _] = recs, callback_pid},
        _from,
        %__MODULE__{} = state
      ) do
    %{
      producer_config: %{linger_ms: linger_ms, delivery_timeout_ms: delivery_timeout},
      last_batch_sent_at: last_batch_sent_at,
      next_send_msg_ref: next_ref
    } = state

    now = System.monotonic_time(:millisecond)

    on_time? = now - last_batch_sent_at >= linger_ms

    new_state =
      Enum.reduce(recs, state, fn rec, acc_state ->
        add_record(acc_state, rec, callback_pid)
      end)

    if on_time? and next_ref == nil,
      do: {:reply, {:ok, delivery_timeout}, maybe_schedule_send(new_state, 0)},
      else: {:reply, {:ok, delivery_timeout}, new_state}
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
    is_periodic? = linger_ms > 0
    new_state = %{state | next_send_msg_ref: nil}

    cond do
      not in_flight_available? ->
        {:noreply, maybe_schedule_send(new_state, 1)}

      has_batch_on_queue? ->
        new_state =
          new_state
          |> dispatch_to_broker(pool_idx)
          |> maybe_schedule_send(1)

        {:noreply, new_state}

      not on_time? ->
        new_state =
          maybe_schedule_send(new_state, linger_ms - (now - last_batch_sent_at))

        {:noreply, new_state}

      is_periodic? ->
        new_state =
          new_state
          |> dispatch_to_broker(pool_idx)
          |> maybe_schedule_send(linger_ms)

        {:noreply, new_state}

      true ->
        {:noreply, dispatch_to_broker(new_state, pool_idx)}
    end
  end

  def handle_info({:bump_epoch, topics_partitions_list}, %__MODULE__{} = state) do
    %{producer_epochs: pe, base_sequences: bs} = state

    {new_pe, new_bs} =
      Enum.reduce(topics_partitions_list, {pe, bs}, fn key, {acc_pe, acc_bs} ->
        new_pe = Map.put(acc_pe, key, Map.get(acc_pe, key, 0) + 1)
        new_bs = Map.replace!(acc_bs, key, 0)
        {new_pe, new_bs}
      end)

    {:noreply, %{state | producer_epochs: new_pe, base_sequences: new_bs}}
  end

  def handle_info({:request_completed, pool_idx}, %__MODULE__{} = state) do
    %__MODULE__{
      in_flight_pool: in_flight_pool
    } = state

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
          current_waiting_pids: curr_pids,
          current_base_time: curr_base_time,
          base_sequences: base_sequences
        } = state,
        %Record{topic: topic, partition: partition} = record,
        pid,
        estimated_size
      ) do
    new_batch = add_record_to_current_batch(state, record)

    %{
      state
      | current_batch: new_batch,
        current_waiting_pids: add_waiting_pid(curr_pids, new_batch, pid, record),
        base_sequences: update_base_sequence(base_sequences, new_batch, topic, partition),
        current_base_time: curr_base_time || System.monotonic_time(:millisecond),
        current_estimated_size: curr_size + estimated_size
    }
  end

  def add_record(
        %__MODULE__{
          producer_config: %{batch_size_bytes: batch_size_bytes},
          current_estimated_size: current_estimated_size
        } = state,
        %Record{__estimated_size: estimated_size} = record,
        pid
      ) do
    if current_estimated_size + estimated_size > batch_size_bytes,
      do:
        state
        |> move_current_data_to_batch_queue()
        |> add_record_to_current_data(record, pid, estimated_size)
        |> maybe_schedule_send(5),
      else:
        state
        |> add_record_to_current_data(record, pid, estimated_size)
  end

  def dispatch_to_broker(
        %__MODULE__{
          producer_config: pconfig,
          in_flight_pool: in_flight_pool,
          batch_queue: batch_queue,
          dispatcher_pid: dispatcher_pid
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

        req_ref = make_ref()

        dispatcher_req = %Dispatcher.Request{
          base_time: batch_base_time,
          batch_to_send: batch_to_send,
          delivery_confirmation_pids: waiting_pids,
          pool_idx: pool_idx,
          producer_config: pconfig,
          request_ref: req_ref
        }

        :ok = Dispatcher.dispatch(dispatcher_pid, dispatcher_req)

        new_state = %{
          state
          | batch_queue: new_batch_queue,
            in_flight_pool: List.replace_at(in_flight_pool, pool_idx, req_ref),
            last_batch_sent_at: System.monotonic_time(:millisecond)
        }

        if sending_from_current?,
          do: reset_current_data(new_state),
          else: new_state
    end
  end

  def maybe_schedule_send(%__MODULE__{next_send_msg_ref: nil} = state, time),
    do: %{
      state
      | next_send_msg_ref: Process.send_after(self(), :send_to_broker, time)
    }

  def maybe_schedule_send(%__MODULE__{next_send_msg_ref: ref} = state, time)
      when is_reference(ref) do
    if Process.read_timer(ref) > time do
      Process.cancel_timer(ref)

      %{
        state
        | next_send_msg_ref: Process.send_after(self(), :send_to_broker, time)
      }
    else
      state
    end
  end

  ## PRIVATE FUNCTIONS

  defp add_record_to_current_batch(
         %__MODULE__{current_batch: batch} = state,
         %Record{topic: topic, partition: partition} = record
       ) do
    case Map.get(batch, {topic, partition}) do
      nil ->
        new_batch =
          state
          |> init_partition_data(topic, partition)
          |> add_record_to_partition_data(record)

        Map.put(batch, {topic, partition}, new_batch)

      partition_data ->
        new_partition_data = add_record_to_partition_data(partition_data, record)
        Map.replace!(batch, {topic, partition}, new_partition_data)
    end
  end

  defp init_partition_data(
         %__MODULE__{
           base_sequences: bs,
           producer_config: %{producer_id: p_id} = pconfig,
           producer_epochs: p_epochs
         } = _state,
         topic,
         partition
       ) do
    {p_epoch, base_seq} =
      if p_id do
        key = {topic, partition}
        {Map.get(p_epochs, key, 0), Map.get(bs, key, 0)}
      else
        {-1, -1}
      end

    %{
      base_offset: 0,
      partition_leader_epoch: -1,
      magic: 2,
      attributes: get_attributes_byte(pconfig, []),
      last_offset_delta: -1,
      base_timestamp: nil,
      max_timestamp: nil,
      producer_id: p_id,
      producer_epoch: p_epoch,
      base_sequence: base_seq,
      records: [],
      records_length: 0
    }
  end

  defp get_attributes_byte(%Producer{} = pconfig, _opts) do
    # TODO: Handle different attributes opts
    [
      compression: pconfig.compression_type,
      is_transactional: pconfig.txn_id != nil
    ]
    |> KlifeProtocol.RecordBatch.encode_attributes()
  end

  defp add_record_to_partition_data(batch, %Record{} = record) do
    now = DateTime.to_unix(DateTime.utc_now())

    new_offset_delta = batch.last_offset_delta + 1
    timestamp_delta = if batch.base_timestamp == nil, do: 0, else: now - batch.base_timestamp

    new_rec = %{
      attributes: 0,
      timestamp_delta: timestamp_delta,
      offset_delta: new_offset_delta,
      key: record.key,
      value: record.value,
      headers: record.headers
    }

    %{
      batch
      | records: [new_rec | batch.records],
        records_length: batch.records_length + 1,
        last_offset_delta: new_offset_delta,
        max_timestamp: now,
        base_timestamp: min(batch.base_timestamp, now)
    }
  end

  defp update_base_sequence(curr_base_sequences, new_batch, topic, partition) do
    case Map.get(curr_base_sequences, {topic, partition}) do
      nil ->
        new_base_sequence =
          new_batch
          |> Map.fetch!({topic, partition})
          |> Map.fetch!(:base_sequence)

        if new_base_sequence != -1,
          do: Map.put(curr_base_sequences, {topic, partition}, new_base_sequence + 1),
          else: curr_base_sequences

      curr_base_seq ->
        Map.replace!(curr_base_sequences, {topic, partition}, curr_base_seq + 1)
    end
  end

  defp add_waiting_pid(waiting_pids, _new_batch, nil, _record), do: waiting_pids

  defp add_waiting_pid(
         waiting_pids,
         new_batch,
         new_pid,
         %Record{topic: topic, partition: partition} = rec
       )
       when is_pid(new_pid) do
    offset =
      new_batch
      |> Map.fetch!({topic, partition})
      |> Map.fetch!(:last_offset_delta)

    case Map.get(waiting_pids, {topic, partition}) do
      nil ->
        Map.put(waiting_pids, {topic, partition}, [{new_pid, offset, rec.__batch_index}])

      current_pids ->
        Map.replace!(waiting_pids, {topic, partition}, [
          {new_pid, offset, rec.__batch_index} | current_pids
        ])
    end
  end

  defp get_process_name(
         cluster_name,
         broker_id,
         producer_name,
         batcher_id
       ) do
    via_tuple({__MODULE__, cluster_name, broker_id, producer_name, batcher_id})
  end
end

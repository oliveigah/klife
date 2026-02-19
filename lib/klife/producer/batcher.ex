defmodule Klife.Producer.Batcher do
  @moduledoc false

  use Klife.GenBatcher

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  require Logger

  alias Klife.Record

  alias Klife.Producer
  alias Klife.Producer.Dispatcher

  alias Klife.GenBatcher

  alias Klife.PubSub

  defstruct [
    :producer_config,
    :producer_epochs,
    :base_sequences,
    :broker_id,
    :batcher_id,
    :dispatcher_pid
  ]

  defmodule Batch do
    defstruct [
      :data,
      :waiting_pids,
      :base_time
    ]
  end

  def start_link(args) do
    pconfig = Keyword.fetch!(args, :producer_config)
    client_name = pconfig.client_name
    broker_id = Keyword.fetch!(args, :broker_id)
    batcher_id = Keyword.fetch!(args, :id)

    GenBatcher.start_link(__MODULE__, args,
      name:
        get_process_name(
          client_name,
          broker_id,
          pconfig.name,
          batcher_id
        )
    )
  end

  def produce(
        [%Record{} | _] = records,
        client_name,
        broker_id,
        producer_name,
        batcher_id
      ) do
    client_name
    |> get_process_name(broker_id, producer_name, batcher_id)
    |> GenBatcher.insert_call(records)
  end

  def produce_async(
        [%Record{} | _] = records,
        client_name,
        broker_id,
        producer_name,
        batcher_id
      ) do
    client_name
    |> get_process_name(broker_id, producer_name, batcher_id)
    |> GenBatcher.insert_cast(records)
  end

  @impl true
  def init_state(args) do
    broker_id = Keyword.fetch!(args, :broker_id)
    batcher_id = Keyword.fetch!(args, :id)
    producer_config = Keyword.fetch!(args, :producer_config)

    :ok = PubSub.subscribe({:cluster_change, producer_config.client_name})

    state = %__MODULE__{
      base_sequences: %{},
      producer_epochs: %{},
      broker_id: broker_id,
      batcher_id: batcher_id,
      producer_config: producer_config
    }

    {:ok, dispatcher_pid} = start_dispatcher(state)

    {:ok, %{state | dispatcher_pid: dispatcher_pid}}
  end

  @impl true
  def init_batch(%__MODULE__{} = state) do
    {:ok,
     %__MODULE__.Batch{
       data: %{},
       waiting_pids: %{},
       base_time: nil
     }, state}
  end

  @impl true
  def handle_insert_item(
        %Record{topic: topic, partition: partition} = record,
        %__MODULE__.Batch{} = batch,
        %__MODULE__{} = state
      ) do
    new_data = add_record_to_data(batch.data, state, record)

    new_batch = %__MODULE__.Batch{
      batch
      | data: new_data,
        waiting_pids: add_waiting_pid(batch.waiting_pids, new_data, record.__callback, record),
        base_time: batch.base_time || System.monotonic_time(:millisecond)
    }

    new_state = %__MODULE__{
      state
      | base_sequences: update_base_sequence(state.base_sequences, new_data, topic, partition),
        producer_epochs: maybe_update_epoch(state.producer_epochs, new_data, topic, partition)
    }

    {:ok, record, new_batch, new_state}
  end

  @impl true
  def handle_insert_response(_records, %__MODULE__{} = state) do
    {:ok, state.producer_config.delivery_timeout_ms}
  end

  @impl true
  def get_size(%Record{} = rec) do
    rec.__estimated_size
  end

  @impl true
  def fit_on_batch?(%Record{} = _rec, %__MODULE__.Batch{} = _batch) do
    true
  end

  @impl true
  def handle_dispatch(%__MODULE__.Batch{} = batch, %__MODULE__{} = state, ref) do
    dispatcher_req = %Dispatcher.Request{
      base_time: batch.base_time,
      data_to_send: batch.data,
      records_map: build_records_map(batch.data),
      delivery_confirmation_pids: batch.waiting_pids,
      producer_config: state.producer_config,
      request_ref: ref
    }

    :ok = Dispatcher.dispatch(state.dispatcher_pid, dispatcher_req)

    {:ok, state}
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

  def handle_info(
        {:bump_epoch, topics_partitions_list},
        %GenBatcher{
          user_state: %__MODULE__{} = state
        } = batcher_state
      ) do
    %__MODULE__{
      producer_epochs: pe,
      base_sequences: bs,
      producer_config: %Producer{
        client_name: client_name,
        name: producer_name
      }
    } = state

    {new_pe, new_bs} =
      Enum.reduce(topics_partitions_list, {pe, bs}, fn {topic, partition}, {acc_pe, acc_bs} ->
        key = {topic, partition}
        new_pe_val = Producer.new_epoch(client_name, producer_name, topic, partition)
        new_pe = Map.put(acc_pe, key, new_pe_val)
        new_bs = Map.replace(acc_bs, key, 0)
        {new_pe, new_bs}
      end)

    new_state = %{state | producer_epochs: new_pe, base_sequences: new_bs}

    {:noreply, %{batcher_state | user_state: new_state}}
  end

  def handle_info(
        {:remove_topic_partition, topic, partition},
        %GenBatcher{
          user_state: %__MODULE__{} = state
        } = batcher_state
      ) do
    key = {topic, partition}
    new_pe = Map.delete(state.producer_epochs, key)
    new_bs = Map.delete(state.base_sequences, key)
    new_state = %{state | producer_epochs: new_pe, base_sequences: new_bs}
    {:noreply, %{batcher_state | user_state: new_state}}
  end

  def handle_info(
        {{:cluster_change, client_name}, event_data, _callback_data},
        %GenBatcher{
          user_state: %__MODULE__{producer_config: %{client_name: client_name}} = state
        } = batcher_state
      ) do
    case event_data do
      %{removed_brokers: []} ->
        {:noreply, batcher_state}

      %{removed_brokers: removed_list} ->
        ids_list = Enum.map(removed_list, fn {removed_broker_id, _host} -> removed_broker_id end)

        if state.broker_id in ids_list do
          {:stop, {:shutdown, {:cluster_change, {:removed_broker, state.broker_id}}},
           batcher_state}
        else
          {:noreply, batcher_state}
        end
    end
  end

  @impl true
  def terminate(reason, %GenBatcher{
        user_state: %__MODULE__{dispatcher_pid: dispatcher_pid},
        current_batch: current_batch,
        current_batch_item_count: current_batch_item_count,
        batch_queue: batch_queue
      }) do
    error_reason =
      case reason do
        {:shutdown, {:cluster_change, {:removed_broker, _broker_id}}} -> :broker_removed
        reason -> reason
      end

    queued_batches = :queue.to_list(batch_queue)

    batches_to_drain =
      if current_batch_item_count > 0,
        do: queued_batches ++ [current_batch],
        else: queued_batches

    Enum.each(batches_to_drain, fn %__MODULE__.Batch{data: data, waiting_pids: waiting_pids} ->
      records_map = build_records_map(data)
      Dispatcher.notify_broker_error(waiting_pids, records_map, error_reason)
    end)

    if dispatcher_pid && Process.alive?(dispatcher_pid) do
      Dispatcher.flush_and_stop(dispatcher_pid, error_reason)
    end
  end

  ## PRIVATE FUNCTIONS

  defp add_record_to_data(
         data,
         %__MODULE__{} = state,
         %Record{topic: topic, partition: partition} = record
       ) do
    case Map.get(data, {topic, partition}) do
      nil ->
        new_tp_data =
          state
          |> init_partition_data(topic, partition)
          |> add_record_to_partition_data(record)

        Map.put(data, {topic, partition}, new_tp_data)

      partition_data ->
        new_partition_data = add_record_to_partition_data(partition_data, record)
        Map.replace!(data, {topic, partition}, new_partition_data)
    end
  end

  defp init_partition_data(
         %__MODULE__{
           base_sequences: bs,
           producer_config:
             %{client_name: client_name, name: producer_name, producer_id: p_id} =
               pconfig,
           producer_epochs: p_epochs
         } = _state,
         topic,
         partition
       ) do
    {p_epoch, base_seq} =
      if p_id do
        key = {topic, partition}

        epoch =
          case Map.get(p_epochs, key) do
            nil ->
              Producer.new_epoch(client_name, producer_name, topic, partition)

            val ->
              val
          end

        {epoch, Map.get(bs, key, 0)}
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
    [
      compression: pconfig.compression_type,
      is_transactional: pconfig.txn_id != nil
    ]
    |> KlifeProtocol.RecordBatch.encode_attributes()
  end

  defp add_record_to_partition_data(batch, %Record{} = record) do
    now = DateTime.to_unix(DateTime.utc_now(), :millisecond)

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

  defp update_base_sequence(curr_base_sequences, new_data, topic, partition) do
    case Map.get(curr_base_sequences, {topic, partition}) do
      nil ->
        new_base_sequence =
          new_data
          |> Map.fetch!({topic, partition})
          |> Map.fetch!(:base_sequence)

        if new_base_sequence != -1,
          do: Map.put(curr_base_sequences, {topic, partition}, new_base_sequence + 1),
          else: curr_base_sequences

      curr_base_seq ->
        Map.replace!(curr_base_sequences, {topic, partition}, curr_base_seq + 1)
    end
  end

  defp maybe_update_epoch(curr_epochs, new_data, topic, partition) do
    case Map.get(curr_epochs, {topic, partition}) do
      nil ->
        epoch =
          new_data
          |> Map.fetch!({topic, partition})
          |> Map.fetch!(:producer_epoch)

        if epoch != -1,
          do: Map.put(curr_epochs, {topic, partition}, epoch),
          else: curr_epochs

      _ ->
        curr_epochs
    end
  end

  defp add_waiting_pid(waiting_pids, _new_batch, nil, _record), do: waiting_pids

  defp add_waiting_pid(
         waiting_pids,
         new_data,
         new_pid,
         %Record{topic: t, partition: p} = rec
       )
       when is_pid(new_pid) do
    offset =
      new_data
      |> Map.fetch!({t, p})
      |> Map.fetch!(:last_offset_delta)

    new_entry = {new_pid, offset, rec.__batch_index}

    Map.update(waiting_pids, {t, p}, [new_entry], fn curr_pids -> [new_entry | curr_pids] end)
  end

  defp add_waiting_pid(
         waiting_pids,
         new_data,
         {_m, _f, _a} = mfa,
         %Record{topic: t, partition: p}
       ) do
    offset =
      new_data
      |> Map.fetch!({t, p})
      |> Map.fetch!(:last_offset_delta)

    new_entry = {mfa, offset}

    Map.update(waiting_pids, {t, p}, [new_entry], fn curr_pids -> [new_entry | curr_pids] end)
  end

  defp add_waiting_pid(
         waiting_pids,
         new_data,
         fun,
         %Record{topic: t, partition: p}
       )
       when is_function(fun, 1) do
    offset =
      new_data
      |> Map.fetch!({t, p})
      |> Map.fetch!(:last_offset_delta)

    new_entry = {fun, offset}

    Map.update(waiting_pids, {t, p}, [new_entry], fn curr_pids -> [new_entry | curr_pids] end)
  end

  defp build_records_map(batch_data_to_send) do
    batch_data_to_send
    |> Enum.map(fn {{t, p}, batch} ->
      rec_map =
        Record.parse_from_protocol(t, p, batch)
        |> Enum.with_index(fn rec, offset_delta -> {offset_delta, rec} end)
        |> Map.new()

      {{t, p}, rec_map}
    end)
    |> Map.new()
  end

  defp get_process_name(
         client_name,
         broker_id,
         producer_name,
         batcher_id
       ) do
    via_tuple({__MODULE__, client_name, broker_id, producer_name, batcher_id})
  end
end

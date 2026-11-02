defmodule Klife.Producer.Batcher do
  @moduledoc false

  use Klife.GenBatcher

  import Klife.ProcessRegistry, only: [via_tuple: 1]

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
    :dispatcher_pid,
    # Version of the producer leader map in which this batcher last handed
    # partitions off. Requests read from older maps may carry their records.
    last_handoff_version: 0,
    # Partitions being handed off to this batcher: %{tp => {handoff_ref, records}}.
    # Their records wait here, raw and unsequenced, until the handoff ends.
    to_hold: %{}
  ]

  defmodule Batch do
    @moduledoc false

    defstruct [
      :data,
      :waiting_pids,
      :base_time,
      # Partitions sent under an epoch that has been bumped since: a broker
      # error discards them instead of retrying
      bumped_tp_set: MapSet.new()
    ]
  end

  defmodule HandoffData do
    @moduledoc false

    # One partition's record batch, taken out of a batch or a dispatcher
    # request to be handed off, with what it takes to finish it elsewhere
    defstruct [
      :tp,
      :record_batch,
      :base_time,
      waiting_pids: [],
      bumped?: false
    ]

    # A partition's record batches keep their exact sequence ranges, which the
    # broker may already have, so they are never merged: the k-th record batch
    # of each partition goes in the k-th batch.
    def to_batches(handoff_data) do
      handoff_data
      |> Enum.group_by(& &1.tp)
      |> Enum.flat_map(fn {_tp, tp_data} -> Enum.with_index(tp_data) end)
      |> Enum.group_by(fn {_data, idx} -> idx end, fn {data, _idx} -> data end)
      |> Enum.sort()
      |> Enum.map(fn {_idx, layer} ->
        Enum.reduce(layer, %Batch{data: %{}, waiting_pids: %{}}, fn %__MODULE__{tp: tp} = data,
                                                                    %Batch{} = batch ->
          %Batch{
            batch
            | data: Map.put(batch.data, tp, data.record_batch),
              waiting_pids: Map.put(batch.waiting_pids, tp, data.waiting_pids),
              base_time: min(batch.base_time, data.base_time),
              bumped_tp_set:
                if(data.bumped?,
                  do: MapSet.put(batch.bumped_tp_set, tp),
                  else: batch.bumped_tp_set
                )
          }
        end)
      end)
    end
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
        batcher_id,
        map_version
      ) do
    client_name
    |> get_process_name(broker_id, producer_name, batcher_id)
    |> GenBatcher.insert_call(records, map_version)
  end

  def produce_async(
        [%Record{} | _] = records,
        client_name,
        broker_id,
        producer_name,
        batcher_id,
        map_version
      ) do
    client_name
    |> get_process_name(broker_id, producer_name, batcher_id)
    |> GenBatcher.insert_cast(records, map_version)
  end

  # Partition handoff steps, see the handlers below
  def prepare_to_receive_handoff(batcher_pid, ref, tps) do
    send(batcher_pid, {:prepare_to_receive_handoff, ref, tps})
    :ok
  end

  def execute_handoff_to_new_leader(batcher_pid, ref, tps, map_version, dest_pid) do
    send(batcher_pid, {:execute_handoff_to_new_leader, ref, tps, map_version, dest_pid})
    :ok
  end

  def receive_handoff_data(batcher_pid, ref, sequences, handoff_data) do
    send(batcher_pid, {:receive_handoff_data, ref, sequences, handoff_data})
    :ok
  end

  def abort_handoff(batcher_pid, ref) do
    send(batcher_pid, {:abort_handoff, ref})
    :ok
  end

  @impl true
  def init_state(args) do
    broker_id = Keyword.fetch!(args, :broker_id)
    batcher_id = Keyword.fetch!(args, :id)
    producer_config = Keyword.fetch!(args, :producer_config)

    :ok = PubSub.subscribe({:cluster_change, producer_config.client_name})

    # A restarted batcher may get requests read from maps where it owned
    # partitions it no longer has
    {map_version, _map} =
      Producer.get_producer_leader_map(producer_config.client_name, producer_config.name)

    state = %__MODULE__{
      base_sequences: %{},
      producer_epochs: %{},
      broker_id: broker_id,
      batcher_id: batcher_id,
      producer_config: producer_config,
      last_handoff_version: map_version
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
        base_time: min(batch.base_time, record.__arrival_ms)
    }

    new_state = %__MODULE__{
      state
      | base_sequences: update_base_sequence(state.base_sequences, new_data, topic, partition),
        producer_epochs: maybe_update_epoch(state.producer_epochs, new_data, topic, partition)
    }

    {:ok, record, new_batch, new_state}
  end

  # The common case: the request was read from a producer leader map no older
  # than this batcher's last handoff, and no partition is being handed off to
  # it.
  @impl true
  def handle_insert_batch(
        records,
        map_version,
        %__MODULE__{to_hold: to_hold, last_handoff_version: last_handoff_version} = state
      )
      when map_size(to_hold) == 0 and map_version >= last_handoff_version do
    {:ok, records, state}
  end

  def handle_insert_batch(records, map_version, %__MODULE__{} = state) do
    me = {state.broker_id, state.batcher_id}
    %Producer{client_name: client_name, name: producer_name} = state.producer_config

    # Only a request read from an older map can hold records for partitions
    # this batcher has handed off. Those go to their current producer leader.
    {latest_version, leader_map} =
      if map_version < state.last_handoff_version,
        do: Producer.get_producer_leader_map(client_name, producer_name),
        else: {map_version, nil}

    {to_insert, new_to_hold, to_forward} =
      Enum.reduce(records, {[], state.to_hold, %{}}, fn %Record{} = rec, {ins, to_hold, fwd} ->
        tp = {rec.topic, rec.partition}
        producer_leader = if leader_map, do: Map.get(leader_map, tp, me), else: me

        cond do
          producer_leader != me ->
            {ins, to_hold, Map.update(fwd, producer_leader, [rec], &[rec | &1])}

          is_map_key(to_hold, tp) ->
            {ins, Map.update!(to_hold, tp, fn {ref, recs} -> {ref, [rec | recs]} end), fwd}

          true ->
            {[rec | ins], to_hold, fwd}
        end
      end)

    Enum.each(to_forward, fn {{broker_id, batcher_id}, recs} ->
      produce_async(
        Enum.reverse(recs),
        client_name,
        broker_id,
        producer_name,
        batcher_id,
        latest_version
      )
    end)

    {:ok, Enum.reverse(to_insert), %__MODULE__{state | to_hold: new_to_hold}}
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
      request_ref: ref,
      bumped_tp_set: batch.bumped_tp_set
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

  def handle_info({:bump_epoch, topics_partitions_list}, %GenBatcher{} = batcher_state) do
    {batcher_state, _bumped_tps} = bump_epochs(batcher_state, topics_partitions_list)
    {:noreply, batcher_state}
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

  # Partition handoff, between the batcher losing the partitions (source) and
  # the one getting them (destination), coordinated by the Producer:
  #
  # 1. The destination holds the partitions' incoming records and acks.
  # 2. The Producer publishes the new producer leaders and asks the source to
  #    execute.
  # 3. The source takes the partitions' work out of its dispatcher and its
  #    batches and sends it, with their epoch and next sequence, to the
  #    destination. Records it gets for them later go to their new producer
  #    leader.
  # 4. The destination claims the partitions from the Producer, puts the work
  #    ahead of its queue and inserts the held records after it.
  #
  # If the Producer aborts the handoff first, the destination inserts its held
  # records as for any new partition, and fails the work if it ever arrives.
  def handle_info(
        {:prepare_to_receive_handoff, ref, tps},
        %GenBatcher{user_state: %__MODULE__{} = state} = batcher_state
      ) do
    %Producer{client_name: client_name, name: producer_name} = state.producer_config
    to_hold = Enum.reduce(tps, state.to_hold, &Map.put(&2, &1, {ref, []}))
    :ok = Producer.handoff_prepared(client_name, producer_name, ref)
    {:noreply, %{batcher_state | user_state: %{state | to_hold: to_hold}}}
  end

  def handle_info(
        {:execute_handoff_to_new_leader, ref, tps, map_version, dest_pid},
        %GenBatcher{user_state: %__MODULE__{dispatcher_pid: dispatcher_pid}} = batcher_state
      ) do
    popped = Dispatcher.pop_partitions(dispatcher_pid, MapSet.new(tps))

    # Bumps the dispatcher asked for before the pop are already in the mailbox.
    # Done here, as on any bump, the batched work is rewritten under the new
    # epoch and the sent work goes once more under the old one.
    {batcher_state, bumped_tps} = bump_epochs(batcher_state, drain_bumps())

    # The dispatcher got its requests before anything still batched here, and
    # in the order of their sequences
    sent =
      popped
      |> Enum.map(fn %HandoffData{} = data ->
        %HandoffData{data | bumped?: data.bumped? or data.tp in bumped_tps}
      end)
      |> Enum.sort_by(&{&1.record_batch.producer_epoch, &1.record_batch.base_sequence})

    {batcher_state, batched} =
      GenBatcher.update_batch_queue(batcher_state, __MODULE__, fn batches ->
        taken =
          for %Batch{} = batch <- batches, {tp, record_batch} <- Map.take(batch.data, tps) do
            %HandoffData{
              tp: tp,
              record_batch: record_batch,
              waiting_pids: Map.get(batch.waiting_pids, tp, []),
              base_time: batch.base_time,
              bumped?: tp in batch.bumped_tp_set
            }
          end

        kept =
          for %Batch{} = batch <- batches, data = Map.drop(batch.data, tps), data != %{} do
            %Batch{batch | data: data, waiting_pids: Map.drop(batch.waiting_pids, tps)}
          end

        {kept, taken}
      end)

    %GenBatcher{user_state: %__MODULE__{} = state} = batcher_state
    sequences = Map.new(tps, &{&1, {state.producer_epochs[&1], state.base_sequences[&1]}})
    :ok = receive_handoff_data(dest_pid, ref, sequences, sent ++ batched)

    new_state = %__MODULE__{
      state
      | producer_epochs: Map.drop(state.producer_epochs, tps),
        base_sequences: Map.drop(state.base_sequences, tps),
        last_handoff_version: map_version
    }

    {:noreply, %{batcher_state | user_state: new_state}}
  end

  def handle_info(
        {:receive_handoff_data, ref, sequences, handoff_data},
        %GenBatcher{user_state: %__MODULE__{} = state} = batcher_state
      ) do
    %Producer{client_name: client_name, name: producer_name} = state.producer_config
    claims = Map.new(sequences, fn {tp, {epoch, _next_seq}} -> {tp, epoch} end)
    claimed_tps = Producer.claim_handoff(client_name, producer_name, ref, claims)

    {claimed, expired} = Enum.split_with(handoff_data, &MapSet.member?(claimed_tps, &1.tp))

    Enum.each(expired, fn %HandoffData{tp: tp} = data ->
      records_map = build_records_map(%{tp => data.record_batch})
      Dispatcher.notify_delivery_error(%{tp => data.waiting_pids}, records_map, :handoff_expired)
    end)

    # Claimed partitions go on with the source's epoch and sequence
    {epochs, base_sequences} =
      for {tp, {epoch, next_seq}} <- sequences,
          epoch != nil,
          MapSet.member?(claimed_tps, tp),
          reduce: {state.producer_epochs, state.base_sequences} do
        {acc_epochs, acc_seqs} ->
          {Map.put(acc_epochs, tp, epoch), Map.put(acc_seqs, tp, next_seq)}
      end

    batches = HandoffData.to_batches(claimed)
    new_state = %{state | producer_epochs: epochs, base_sequences: base_sequences}

    {batcher_state, _} =
      %{batcher_state | user_state: new_state}
      |> GenBatcher.update_batch_queue(__MODULE__, &{batches ++ &1, nil})

    {:noreply, release_held(batcher_state, ref)}
  end

  def handle_info({:abort_handoff, ref}, %GenBatcher{} = batcher_state) do
    {:noreply, release_held(batcher_state, ref)}
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
        user_state: %__MODULE__{dispatcher_pid: dispatcher_pid, to_hold: to_hold},
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
      Dispatcher.notify_delivery_error(waiting_pids, records_map, error_reason)
    end)

    for {_tp, {_ref, recs}} <- to_hold, %Record{} = rec <- recs do
      case rec.__callback do
        nil ->
          :noop

        {pid, produce_ref} when is_pid(pid) ->
          send(pid, {:klife_produce, produce_ref, {:error, error_reason}, rec.__batch_index})

        {m, f, a} ->
          Task.start(m, f, [{:error, %{rec | error_code: error_reason}} | a])

        fun when is_function(fun, 1) ->
          Task.start(fn -> fun.({:error, %{rec | error_code: error_reason}}) end)
      end
    end

    if dispatcher_pid && Process.alive?(dispatcher_pid) do
      Dispatcher.flush_and_stop(dispatcher_pid, error_reason)
    end
  end

  ## PRIVATE FUNCTIONS

  defp drain_bumps(acc \\ []) do
    receive do
      {:bump_epoch, tps} -> drain_bumps(tps ++ acc)
    after
      0 -> Enum.uniq(acc)
    end
  end

  defp release_held(%GenBatcher{user_state: %__MODULE__{} = state} = batcher_state, ref) do
    {released, to_hold} = Map.split_with(state.to_hold, &match?({_tp, {^ref, _recs}}, &1))
    records = Enum.flat_map(released, fn {_tp, {_ref, recs}} -> Enum.reverse(recs) end)
    batcher_state = %{batcher_state | user_state: %{state | to_hold: to_hold}}
    {batcher_state, _resp} = GenBatcher.insert_items(batcher_state, records, nil, __MODULE__)
    batcher_state
  end

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
      producer_id: p_id || -1,
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

  defp bump_epochs(
         %GenBatcher{user_state: %__MODULE__{producer_config: %Producer{producer_id: nil}}} =
           batcher_state,
         _topics_partitions_list
       ),
       do: {batcher_state, []}

  defp bump_epochs(%GenBatcher{} = batcher_state, topics_partitions_list) do
    %GenBatcher{
      batch_queue: batch_queue,
      current_batch: current_batch,
      current_batch_item_count: current_batch_item_count,
      user_state: %__MODULE__{} = state
    } = batcher_state

    %__MODULE__{
      producer_epochs: pe,
      base_sequences: bs,
      producer_config: %Producer{
        client_name: client_name,
        name: producer_name
      }
    } = state

    {new_pe, bump_map} =
      Enum.reduce(topics_partitions_list, {pe, %{}}, fn {topic, partition}, {acc_pe, acc_bump} ->
        key = {topic, partition}

        case Producer.bump_epoch(client_name, producer_name, topic, partition) do
          {:ok, new_pe_val} ->
            {Map.put(acc_pe, key, new_pe_val), Map.put(acc_bump, key, {new_pe_val, 0})}

          # The partition moved to another batcher. Forget it, so if it comes
          # back here it is claimed with a new epoch.
          {:error, :stale} ->
            {Map.delete(acc_pe, key), acc_bump}
        end
      end)

    stale_keys = Enum.reject(topics_partitions_list, &Map.has_key?(bump_map, &1))

    {new_queue, new_current_batch, rewritten_bs} =
      rewrite_batches_on_epoch_bump(
        batch_queue,
        current_batch,
        current_batch_item_count,
        bump_map
      )

    new_bs = bs |> Map.drop(stale_keys) |> Map.merge(rewritten_bs)
    new_state = %{state | producer_epochs: new_pe, base_sequences: new_bs}

    tp_set = MapSet.new(topics_partitions_list)
    send(state.dispatcher_pid, {:flush_partitions, tp_set})

    new_batcher_state = %{
      batcher_state
      | batch_queue: new_queue,
        current_batch: new_current_batch,
        user_state: new_state
    }

    {new_batcher_state, Map.keys(bump_map)}
  end

  defp rewrite_batches_on_epoch_bump(
         batch_queue,
         current_batch,
         current_batch_item_count,
         bump_map
       ) do
    batches = :queue.to_list(batch_queue)

    {rewritten_batches, seq_acc} =
      Enum.map_reduce(batches, bump_map, &rewrite_single_batch/2)

    {rewritten_current, final_seq_acc} =
      if current_batch_item_count > 0 do
        rewrite_single_batch(current_batch, seq_acc)
      else
        {current_batch, seq_acc}
      end

    new_queue = :queue.from_list(rewritten_batches)
    final_bs = Map.new(final_seq_acc, fn {key, {_epoch, next_seq}} -> {key, next_seq} end)

    {new_queue, rewritten_current, final_bs}
  end

  defp rewrite_single_batch(%Batch{data: data} = batch, seq_acc) do
    {new_data, new_seq_acc} =
      Enum.reduce(data, {data, seq_acc}, fn {key, partition_data}, {acc_data, acc_seq} ->
        case Map.get(acc_seq, key) do
          {new_epoch, next_seq} ->
            updated_partition_data = %{
              partition_data
              | base_sequence: next_seq,
                producer_epoch: new_epoch
            }

            new_acc_seq =
              Map.put(acc_seq, key, {new_epoch, next_seq + partition_data.records_length})

            {Map.put(acc_data, key, updated_partition_data), new_acc_seq}

          nil ->
            {acc_data, acc_seq}
        end
      end)

    {%Batch{batch | data: new_data}, new_seq_acc}
  end

  defp add_waiting_pid(waiting_pids, _new_batch, nil, _record), do: waiting_pids

  defp add_waiting_pid(
         waiting_pids,
         new_data,
         {new_pid, produce_ref},
         %Record{topic: t, partition: p} = rec
       )
       when is_pid(new_pid) do
    offset =
      new_data
      |> Map.fetch!({t, p})
      |> Map.fetch!(:last_offset_delta)

    new_entry = {new_pid, produce_ref, offset, rec.__batch_index}

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
      # batch.records holds records newest-first (they are prepended on insert
      # and only reversed at serialization time), so they must be reversed here
      # as well for the index to match each record's offset_delta.
      rec_map =
        Record.parse_from_protocol(t, p, %{batch | records: Enum.reverse(batch.records)})
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

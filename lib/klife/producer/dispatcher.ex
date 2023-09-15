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
    :topic_name,
    :topic_partition,
    :current_batch,
    :current_waiting_pids,
    :current_base_time,
    :last_batch_sent_at,
    :in_flight_queue
  ]

  def start_link(args) do
    pconfig = Keyword.fetch!(args, :producer_config)
    cluster_name = pconfig.cluster_name
    broker_id = Keyword.fetch!(args, :broker_id)
    topic_name = Keyword.get(args, :topic_name)
    topic_partition = Keyword.get(args, :topic_partition)

    GenServer.start_link(__MODULE__, args,
      name: get_process_name(pconfig, broker_id, topic_name, topic_partition, cluster_name)
    )
  end

  def init(args) do
    args_map = Map.new(args)
    max_in_flight = args_map.producer_config.max_inflight_requests
    linger_ms = args_map.producer_config.linger_ms

    base = %__MODULE__{
      current_batch: %{},
      current_waiting_pids: %{},
      current_base_time: nil,
      last_batch_sent_at: System.monotonic_time(:millisecond),
      in_flight_queue: Enum.map(1..max_in_flight, fn _ -> nil end)
    }

    state = %__MODULE__{} = Map.merge(base, args_map)

    if linger_ms > 0 do
      Process.send_after(self(), :send_to_broker, linger_ms)
    end

    {:ok, state}
  end

  def produce_sync(record, topic, partition, %Producer{} = pconfig, broker_id, cluster_name) do
    pconfig
    |> get_process_name(broker_id, topic, partition, cluster_name)
    |> GenServer.call({:produce_sync, record, topic, partition}, pconfig.delivery_timeout_ms)
  end

  def handle_call({:produce_sync, record, topic, partition}, from, %__MODULE__{} = state) do
    %{
      producer_config: %{linger_ms: linger_ms} = pconfig,
      current_batch: current_batch,
      last_batch_sent_at: last_batch_sent_at,
      in_flight_queue: in_flight_queue,
      current_waiting_pids: current_waiting_pids
    } = state

    now = System.monotonic_time(:millisecond)
    queue_position = Enum.find_index(in_flight_queue, &is_nil/1)

    new_state =
      %{
        state
        | current_batch: add_record_to_batch(current_batch, record, topic, partition, pconfig),
          current_waiting_pids: add_waiting_pid(current_waiting_pids, from, topic, partition)
      }
      |> case do
        %{current_base_time: nil} = state ->
          %{state | current_base_time: now}

        state ->
          state
      end

    on_time = now - last_batch_sent_at >= linger_ms
    queue_available = is_number(queue_position)

    cond do
      on_time and queue_available ->
        {:noreply, send_batch_to_broker(new_state, queue_position)}

      true ->
        Process.send_after(self(), :send_to_broker, :timer.seconds(1))
        {:noreply, new_state}
    end
  end

  def handle_info(:send_to_broker, %__MODULE__{} = state) do
    %{
      producer_config: %{linger_ms: linger_ms},
      last_batch_sent_at: last_batch_sent_at,
      in_flight_queue: in_flight_queue
    } = state

    now = System.monotonic_time(:millisecond)
    queue_position = Enum.find_index(in_flight_queue, &is_nil/1)

    on_time = now - last_batch_sent_at >= linger_ms
    queue_available = is_number(queue_position)
    batch_is_empty = state.current_batch == %{}

    cond do
      batch_is_empty ->
        Process.send_after(self(), :send_to_broker, linger_ms)
        {:noreply, state}

      not on_time ->
        Process.send_after(self(), :send_to_broker, linger_ms - (now - last_batch_sent_at))
        {:noreply, state}

      on_time and queue_available ->
        new_state = send_batch_to_broker(state, queue_position)
        Process.send_after(self(), :send_to_broker, linger_ms)
        {:noreply, new_state}

      not queue_available ->
        # TODO: Add warning log here
        Process.send_after(self(), :send_to_broker, :timer.seconds(1))
        {:noreply, state}
    end
  end

  def handle_info({:broker_delivery_success, queue_position, resp}, %__MODULE__{} = state) do
    %__MODULE__{
      in_flight_queue: in_flight_queue
    } = state

    %{waiting_pids: waiting_pids} = Enum.at(in_flight_queue, queue_position)

    topic_resps = resp.content.responses

    for %{name: topic_name, partition_responses: partition_resps} <- topic_resps,
        %{base_offset: base_offset, error_code: 0, index: p_index} <- partition_resps do
      waiting_pids
      |> Map.get({topic_name, p_index}, [])
      |> Enum.each(fn {pid, batch_offset} ->
        GenServer.reply(pid, {:ok, base_offset + batch_offset})
      end)
    end

    {:noreply, %{state | in_flight_queue: List.replace_at(in_flight_queue, queue_position, nil)}}
  end

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
        max_timestamp: now
    }
    |> case do
      %{base_timestamp: nil} = new_batch ->
        %{new_batch | base_timestamp: now}

      new_batch ->
        new_batch
    end
  end

  defp add_waiting_pid(waiting_pids, new_pid, topic, partition) do
    case Map.get(waiting_pids, {topic, partition}) do
      nil ->
        Map.put(waiting_pids, {topic, partition}, [{new_pid, 0}])

      [{_last_pid, last_offset} | _rest] = current_pids ->
        Map.replace!(waiting_pids, {topic, partition}, [{new_pid, last_offset + 1} | current_pids])
    end
  end

  def send_batch_to_broker(%__MODULE__{} = state, queue_position) do
    %__MODULE__{
      producer_config:
        %{
          cluster_name: cluster_name,
          client_id: client_id,
          acks: acks,
          request_timeout_ms: request_timeout
        } = pconfig,
      current_batch: current_batch,
      broker_id: broker_id,
      in_flight_queue: in_flight_queue,
      current_waiting_pids: current_waiting_pids
    } = state

    headers = %{client_id: client_id}

    content = %{
      transactional_id: nil,
      acks: if(acks == :all, do: -1, else: acks),
      timeout_ms: request_timeout,
      topic_data: parse_batch_before_send(current_batch)
    }

    {:ok, task_pid} =
      Task.Supervisor.start_child(
        via_tuple({Klife.Producer.DispatcherTaskSupervisor, cluster_name}),
        __MODULE__,
        :do_send_to_broker,
        [pconfig, content, headers, broker_id, self(), queue_position, state.current_base_time]
      )

    new_in_flight_queue =
      List.replace_at(in_flight_queue, queue_position, %{
        batch: current_batch,
        waiting_pids: current_waiting_pids,
        task_pid: task_pid
      })

    %{
      state
      | in_flight_queue: new_in_flight_queue,
        current_batch: %{},
        current_waiting_pids: %{},
        current_base_time: nil,
        last_batch_sent_at: System.monotonic_time(:millisecond)
    }
  end

  def do_send_to_broker(
        pconfig,
        content,
        headers,
        broker_id,
        callback_pid,
        queue_position,
        base_time
      ) do
    now = System.monotonic_time(:millisecond)

    %Producer{
      request_timeout_ms: req_timeout,
      delivery_timeout_ms: delivery_timeout,
      retry_backoff_ms: retry_ms,
      cluster_name: cluster_name
    } = pconfig

    # Check if it is safe to retry one more time
    if now + req_timeout - base_time < delivery_timeout - :timer.seconds(5) do
      case Broker.send_sync(Messages.Produce, cluster_name, broker_id, content, headers) do
        {:ok, resp} ->
          # TODO: check non retryable errors and partial errors
          send(callback_pid, {:broker_delivery_success, queue_position, resp})

        _err ->
          Process.sleep(retry_ms)

          do_send_to_broker(
            pconfig,
            content,
            headers,
            broker_id,
            callback_pid,
            queue_position,
            base_time
          )
      end
    else
      IO.inspect("ERROR")
      send(callback_pid, {:broker_delivery_error, queue_position, :timeout})
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
         %Producer{producer_name: pname, linger_ms: 0},
         broker_id,
         topic,
         partition,
         cluster_name
       ) do
    via_tuple({__MODULE__, cluster_name, broker_id, pname, topic, partition})
  end

  defp get_process_name(
         %Producer{producer_name: pname},
         broker_id,
         _topic,
         _partition,
         cluster_name
       ) do
    via_tuple({__MODULE__, cluster_name, broker_id, pname})
  end
end

defmodule Klife.Producer.Dispatcher do
  use GenServer
  import Klife.ProcessRegistry

  alias Klife.Producer
  alias Klife.Connection.Broker
  alias KlifeProtocol.Messages

  defstruct [:producer_config, :broker_id, :topic_name, :topic_partition, :current_batch]

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
    base = %__MODULE__{current_batch: %{}}
    state = %__MODULE__{} = Map.merge(base, args_map)

    {:ok, state}
  end

  def produce(record, topic, partition, producer_name, broker_id, cluster_name) do
    cluster_name
    |> Producer.get_producer_config(producer_name)
    |> get_process_name(broker_id, topic, partition, cluster_name)
    |> GenServer.call({:produce, record, topic, partition})
  end

  def handle_call(
        {:produce, record, topic, partition},
        _from,
        %__MODULE__{
          producer_config: %{linger_ms: 0} = pconfig,
          current_batch: current_batch,
          broker_id: broker_id
        } = state
      ) do
    new_batch = add_record_to_partition_data(current_batch, record, topic, partition, pconfig)

    {:ok, resp} = send_to_broker(new_batch, broker_id, pconfig)

    {:reply, {:ok, resp}, state}
  end

  def handle_call(
        {:produce, record, topic, partition},
        _from,
        %__MODULE__{
          producer_config: pconfig,
          current_batch: current_batch
        } = state
      ) do
    new_batch = add_record_to_partition_data(current_batch, record, topic, partition, pconfig)
    {:reply, :ok, Map.replace!(state, :current_batch, new_batch)}
  end

  ## PRIVATE FUNCTIONS

  defp add_record_to_partition_data(current_batch, record, topic, partition, pconfig) do
    case Map.get(current_batch, {topic, partition}) do
      nil ->
        new_batch =
          pconfig
          |> init_partition_data(topic, partition)
          |> add_record_to_partition_data(record)

        Map.put(current_batch, {topic, partition}, new_batch)

      partition_data ->
        new_partition_data = add_record_to_partition_data(partition_data, record)
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

  defp add_record_to_partition_data(batch, record) do
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

  def send_to_broker(current_batch, broker_id, %Producer{} = pconfig) do
    headers = %{client_id: pconfig.client_id}

    content = %{
      transactional_id: nil,
      acks: if(pconfig.acks == :all, do: -1, else: pconfig.acks),
      timeout_ms: pconfig.request_timeout_ms,
      topic_data: handle_current_batch_before_send(current_batch)
    }

    Broker.send_sync(
      Messages.Produce,
      pconfig.cluster_name,
      broker_id,
      content,
      headers
    )
  end

  defp handle_current_batch_before_send(current_batch) do
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
         %Producer{linger_ms: 0} = pconfig,
         broker_id,
         topic,
         partition,
         cluster_name
       ) do
    via_tuple({
      __MODULE__,
      cluster_name,
      broker_id,
      pconfig.producer_name,
      topic,
      partition
    })
  end

  defp get_process_name(%Producer{} = pconfig, broker_id, _topic, _partition, cluster_name) do
    via_tuple({
      __MODULE__,
      cluster_name,
      broker_id,
      pconfig.producer_name
    })
  end
end

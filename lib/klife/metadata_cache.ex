defmodule Klife.MetadataCache do
  use GenServer
  import Klife.ProcessRegistry, only: [via_tuple: 1]

  alias KlifeProtocol.Messages, as: M

  alias Klife.Connection.Controller, as: ConnController

  alias Klife.Connection.Broker

  alias Klife.PubSub

  defstruct [
    :client_name,
    :next_check_ref
  ]

  @check_interval_ms :timer.seconds(30)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: process_name(args.client_name))
  end

  defp process_name(client) do
    via_tuple({__MODULE__, client})
  end

  @impl true
  def init(args) do
    state = %__MODULE__{client_name: args.client_name}

    :ets.new(metadata_table(state.client_name), [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    :ok = do_check_metadata(state)

    new_ref = Process.send_after(self(), :check_metadata, @check_interval_ms)

    {:ok, %__MODULE__{state | next_check_ref: new_ref}}
  end

  @impl true
  def handle_info(:check_metadata, %__MODULE__{} = state) do
    case do_check_metadata(state) do
      :ok ->
        new_ref = Process.send_after(self(), :check_metadata, @check_interval_ms)
        {:noreply, %__MODULE__{state | next_check_ref: new_ref}}

      {:error, _} ->
        :ok = ConnController.trigger_brokers_verification(state.client_name)
        new_ref = Process.send_after(self(), :check_metadata, :timer.seconds(1))
        {:noreply, %__MODULE__{state | next_check_ref: new_ref}}
    end
  end

  defp do_check_metadata(%__MODULE__{client_name: client_name} = _state) do
    content = %{
      topics: nil,
      allow_auto_topic_creation: false,
      include_topic_authorized_operations: false
    }

    case Broker.send_message(M.Metadata, client_name, :controller, content) do
      {:ok, %{content: resp}} ->
        table_name = metadata_table(client_name)

        any_new? =
          for topic <- resp.topics,
              partition <- topic.partitions,
              topic.error_code == 0,
              reduce: false do
            acc ->
              key = {topic.name, partition.partition_index}

              case :ets.lookup(table_name, key) do
                [] ->
                  :ok = upsert_metadata(client_name, topic, partition)
                  true

                [tuple_data] ->
                  data = metadata_tuple_to_map(tuple_data)

                  max_partition =
                    topic.partitions
                    |> Enum.map(fn p_data -> p_data.partition_index end)
                    |> Enum.max()

                  new_data? = [
                    data.leader_id != partition.leader_id,
                    data.topic_id != topic.topic_id,
                    data.max_partition != max_partition
                  ]

                  if Enum.any?(new_data?) do
                    :ok = upsert_metadata(client_name, topic, partition)
                    true
                  else
                    acc
                  end
              end
          end

        if any_new? do
          :ok = PubSub.publish({:metadata_updated, client_name}, %{})
        end

      {:error, _} = err ->
        err
    end

    :ok
  end

  defp upsert_metadata(client_name, topic_data, partition_data) do
    max_partition =
      topic_data.partitions
      |> Enum.map(fn p_data -> p_data.partition_index end)
      |> Enum.max()

    to_insert =
      %{
        key: {topic_data.name, partition_data.partition_index},
        topic_name: topic_data.name,
        partition_idx: partition_data.partition_index,
        leader_id: partition_data.leader_id,
        topic_id: topic_data[:topic_id],
        max_partition: max_partition,
        # default producer/partitioner values will be defined on producer
        default_producer: nil,
        default_partitioner: nil
      }

    true = insert_on_metadata_table(client_name, to_insert)

    :ok
  end

  @metadata_table_name_to_idxs %{
    key: 0,
    topic_name: 1,
    partition_idx: 2,
    leader_id: 3,
    topic_id: 4,
    max_partition: 5,
    default_producer: 6,
    default_partitioner: 7
  }

  defp metadata_table(client_name),
    do: :"metadata_cache.#{client_name}"

  def insert_on_metadata_table(client_name, vals) do
    table = metadata_table(client_name)
    to_insert = metadata_map_to_tuple(vals)
    :ets.insert(table, to_insert)
  end

  def update_metadata(client_name, topic, partition, attr, val) do
    table = metadata_table(client_name)
    idx = @metadata_table_name_to_idxs[attr] + 1
    :ets.update_element(table, {topic, partition}, {idx, val})
  end

  def get_metadata(client_name, topic, partition) do
    table = metadata_table(client_name)

    case :ets.lookup(table, {topic, partition}) do
      [] ->
        {:error, :not_found}

      [item] ->
        {:ok, metadata_tuple_to_map(item)}
    end
  end

  def get_all_metadata(client_name) do
    client_name
    |> metadata_table()
    |> :ets.tab2list()
    |> Enum.map(fn item -> metadata_tuple_to_map(item) end)
  end

  def get_metadata_attribute(client_name, topic, partition, attr) do
    client_name
    |> metadata_table()
    |> :ets.lookup_element({topic, partition}, @metadata_table_name_to_idxs[attr] + 1)
  end

  defp metadata_map_to_tuple(val) do
    @metadata_table_name_to_idxs
    |> Enum.map(fn {attr, idx} -> {idx, Map.fetch!(val, attr)} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {_k, v} -> v end)
    |> List.to_tuple()
  end

  defp metadata_tuple_to_map(val) do
    @metadata_table_name_to_idxs
    |> Enum.map(fn {attr, idx} -> {attr, elem(val, idx)} end)
    |> Map.new()
  end
end

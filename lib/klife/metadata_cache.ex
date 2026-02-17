defmodule Klife.MetadataCache do
  use GenServer
  import Klife.ProcessRegistry, only: [via_tuple: 1]

  alias KlifeProtocol.Messages, as: M

  alias Klife.Connection.Controller, as: ConnController

  alias Klife.Connection.Broker

  alias Klife.PubSub

  defstruct [
    :client_name,
    :next_check_ref,
    :topics,
    :enable_unkown_topics
  ]

  @check_interval_ms Application.compile_env(:klife, :metadata_check_interval_ms, 30_000)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: process_name(args.client_name))
  end

  defp process_name(client) do
    via_tuple({__MODULE__, client})
  end

  @impl true
  def init(args) do
    state = %__MODULE__{
      client_name: args.client_name,
      topics: Enum.map(args.topics, fn t -> {t.name, t} end) |> Map.new(),
      enable_unkown_topics: args.enable_unkown_topics
    }

    :ets.new(metadata_table(state.client_name), [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    :ok = do_check_metadata(state)

    :ok = PubSub.subscribe({:cluster_change, args.client_name})

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

        # Prevent subtle edge case when check metadata
        # messages may accumullate idefinitely
        Process.cancel_timer(state.next_check_ref)

        new_ref = Process.send_after(self(), :check_metadata, :timer.seconds(1))
        {:noreply, %__MODULE__{state | next_check_ref: new_ref}}
    end
  end

  def handle_info(
        {{:cluster_change, client_name}, _event_data, _callback_data},
        %__MODULE__{client_name: client_name} = state
      ) do
    Process.send_after(self(), :check_metadata, 0)
    {:noreply, state}
  end

  defp do_check_metadata(%__MODULE__{client_name: client_name} = state) do
    content = %{
      topics: if(state.enable_unkown_topics, do: nil, else: Map.keys(state.topics)),
      allow_auto_topic_creation: false,
      include_topic_authorized_operations: false
    }

    case Broker.send_message(M.Metadata, client_name, :controller, content) do
      {:ok, %{content: resp}} ->
        table_name = metadata_table(client_name)

        {tp_ids, any_new?} =
          for topic <- resp.topics,
              partition <- topic.partitions,
              topic.error_code == 0,
              reduce: {[], false} do
            {acc_tp_ids, acc_any_new} ->
              new_acc_tp_ids = [{topic.topic_id, topic.name} | acc_tp_ids]

              key = {topic.name, partition.partition_index}

              case :ets.lookup(table_name, key) do
                [] ->
                  :ok = upsert_metadata(state, topic, partition)
                  {new_acc_tp_ids, true}

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
                    :ok = upsert_metadata(state, topic, partition)
                    {new_acc_tp_ids, true}
                  else
                    {new_acc_tp_ids, acc_any_new}
                  end
              end
          end

        :ok = set_topic_name_for_id(client_name, Map.new(tp_ids))

        if any_new? do
          :ok = PubSub.publish({:metadata_updated, client_name}, %{})
        end

        :ok

      {:error, _} = err ->
        err
    end
  end

  def get_topic_name_by_id!(client_name, topic_id) do
    {__MODULE__, :topic_id_name_map, client_name}
    |> :persistent_term.get()
    |> Map.fetch!(topic_id)
  end

  def get_topic_name_by_id(client_name, topic_id) do
    {__MODULE__, :topic_id_name_map, client_name}
    |> :persistent_term.get()
    |> Map.get(topic_id)
  end

  defp set_topic_name_for_id(client_name, data) do
    :persistent_term.put({__MODULE__, :topic_id_name_map, client_name}, data)
  end

  defp upsert_metadata(%__MODULE__{} = state, topic_data, partition_data) do
    max_partition =
      topic_data.partitions
      |> Enum.map(fn p_data -> p_data.partition_index end)
      |> Enum.max()

    topic_conf = state.topics[topic_data.name]
    client = state.client_name

    to_insert_topic_name_key =
      %{
        key: {topic_data.name, partition_data.partition_index},
        topic_name: topic_data.name,
        partition_idx: partition_data.partition_index,
        leader_id: partition_data.leader_id,
        leader_epoch: partition_data.leader_epoch,
        topic_id: topic_data.topic_id,
        max_partition: max_partition,
        default_producer: topic_conf[:default_producer] || client.get_default_producer(),
        default_partitioner: topic_conf[:default_partitioner] || client.get_default_partitioner()
      }

    true = insert_on_metadata_table(client, to_insert_topic_name_key)

    :ok
  end

  @metadata_table_name_to_idxs %{
    key: 0,
    topic_name: 1,
    partition_idx: 2,
    leader_id: 3,
    leader_epoch: 4,
    topic_id: 5,
    max_partition: 6,
    default_producer: 7,
    default_partitioner: 8
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

  def metadata_exists?(client_name, topic, partition) do
    table = metadata_table(client_name)
    :ets.member(table, {topic, partition})
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

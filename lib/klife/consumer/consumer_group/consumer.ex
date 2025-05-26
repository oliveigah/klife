defmodule Klife.Consumer.ConsumerGroup.Consumer do
  use GenServer, restart: :transient

  import Klife.ProcessRegistry

  alias Klife.MetadataCache

  alias Klife.Consumer.ConsumerGroup

  defstruct [
    :consumer_group_config,
    :topic_config,
    :topic_id,
    :partition_idx,
    :topic_name
  ]

  def start_link(args) do
    consumer_group_config = Keyword.fetch!(args, :consumer_group_config)
    cg_mod = consumer_group_config.mod
    topic_id = Keyword.fetch!(args, :topic_id)
    partition_idx = Keyword.fetch!(args, :partition_idx)

    GenServer.start_link(__MODULE__, Map.new(args),
      name: get_process_name(cg_mod, topic_id, partition_idx)
    )
  end

  def get_process_name(cg_mod, topic_id, partition_idx) do
    via_tuple({__MODULE__, cg_mod, topic_id, partition_idx})
  end

  @impl true
  def init(args_map) do
    cg_conf = %ConsumerGroup{client_name: client_name} = args_map.consumer_group_config
    topic_name = MetadataCache.get_topic_name_by_id(client_name, args_map.topic_id)

    state = %__MODULE__{
      consumer_group_config: cg_conf,
      topic_id: args_map.topic_id,
      partition_idx: args_map.partition_idx,
      topic_name: topic_name,
      topic_config: cg_conf.topics[topic_name]
    }

    :ok =
      ConsumerGroup.send_consumer_up(
        state.consumer_group_config.mod,
        state.topic_id,
        state.partition_idx
      )

    send(self(), :poll_records)

    {:ok, state}
  end

  def revoke_assignment(cg_mod, topic_id, partition) do
    cg_mod
    |> get_process_name(topic_id, partition)
    |> GenServer.cast(:assignment_revoked)
  end

  @impl true
  def handle_info(:poll_records, %__MODULE__{} = state) do
    polling_allowed? =
      ConsumerGroup.polling_allowed?(
        state.consumer_group_config.mod,
        state.topic_id,
        state.partition_idx
      )

    new_state =
      if polling_allowed? do
        IO.inspect("Pooling from topic #{state.topic_name} partition #{state.partition_idx}...")
        state
      else
        IO.inspect(
          "Skip polling from topic #{state.topic_name} partition #{state.partition_idx} because it is not acked..."
        )

        state
      end

    Process.send_after(self(), :poll_records, state.topic_config.poll_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:assignment_revoked, %__MODULE__{} = state) do
    {:stop, {:shutdown, {:assignment_revoked, state.topic_id, state.partition_idx}}, state}
  end
end

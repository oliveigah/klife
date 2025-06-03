defmodule Klife.Consumer.ConsumerGroup.Consumer do
  use GenServer, restart: :transient

  import Klife.ProcessRegistry

  alias Klife.MetadataCache

  alias Klife.Consumer.ConsumerGroup

  alias Klife.Consumer.ConsumerGroup.TopicConfig

  alias Klife.Record

  alias Klife.Consumer.Committer

  defstruct [
    :cg_mod,
    :topic_config,
    :topic_id,
    :partition_idx,
    :topic_name,
    :committer_id,
    :client_name
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
    IO.inspect("INITING CONSUMER FOR #{args_map.topic_id} #{args_map.partition_idx}")
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
        cg_mod: args_map.consumer_group_mod
      }

    :ok =
      ConsumerGroup.send_consumer_up(
        state.cg_mod,
        state.topic_id,
        state.partition_idx
      )

    send(self(), :poll_records)

    {:ok, state}
  end

  def revoke_assignment_async(client_name, cg_mod, topic_id, partition) do
    client_name
    |> get_process_name(cg_mod, topic_id, partition)
    |> GenServer.cast(:assignment_revoked)
  end

  @impl true
  def handle_info(:poll_records, %__MODULE__{} = state) do
    cg_mod = state.cg_mod
    %TopicConfig{} = tc = state.topic_config

    polling_allowed? =
      ConsumerGroup.polling_allowed?(
        state.client_name,
        cg_mod,
        state.topic_id,
        state.partition_idx
      )

    new_state =
      if polling_allowed? do
        mock_list = Enum.map(1..tc.handler_max_batch_size, fn i -> %Record{offset: i} end)
        cg_mod.handle_record_batch(state.topic_name, state.partition_idx, mock_list)

        commit_data = %Committer.BatchItem{
          callback_pid: self(),
          offset_to_commit: 10,
          partition: state.partition_idx,
          topic_name: state.topic_name
        }

        :ok = Committer.commit(commit_data, state.client_name, state.cg_mod, state.committer_id)

        state
      else
        IO.inspect(
          "Skip polling from topic #{state.topic_name} partition #{state.partition_idx} because it is not acked..."
        )

        state
      end

    Process.send_after(self(), :poll_records, state.topic_config.fetch_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:assignment_revoked, %__MODULE__{} = state) do
    {:stop, {:shutdown, {:assignment_revoked, state.topic_id, state.partition_idx}}, state}
  end
end

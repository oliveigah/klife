defmodule Klife.Consumer.Committer do
  use Klife.GenBatcher

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  alias Klife.GenBatcher

  alias Klife.PubSub

  defstruct [
    :broker_id,
    :batcher_id,
    :member_id,
    :client_name,
    :cg_mod,
    :dispatcher_pid
  ]

  defmodule Batch do
    defstruct [
      :data,
      :dispatch_ref
    ]
  end

  defmodule BatchItem do
    defstruct [
      :topic_name,
      :partition,
      :offset_to_commit,
      :metadata,
      :callback_pid
    ]
  end

  def start_link(args) do
    client = Keyword.fetch!(args, :client_name)
    batcher_id = Keyword.fetch!(args, :batcher_id)
    cg_mod = Keyword.fetch!(args, :consumer_group_mod)

    GenBatcher.start_link(__MODULE__, args, name: get_process_name(client, cg_mod, batcher_id))
  end

  def commit(%BatchItem{} = batch_item, client, cg_mod, batcher_id) do
    client
    |> get_process_name(cg_mod, batcher_id)
    |> GenBatcher.insert_call([batch_item])
  end

  defp get_process_name(client, cg_mod, batcher_id) do
    via_tuple({__MODULE__, client, cg_mod, batcher_id})
  end

  @impl true
  def init_state(init_arg) do
    client_name = Keyword.fetch!(init_arg, :client_name)

    :ok = PubSub.subscribe({:cluster_change, client_name})

    state =
      %__MODULE__{
        broker_id: Keyword.fetch!(init_arg, :broker_id),
        batcher_id: Keyword.fetch!(init_arg, :batcher_id),
        cg_mod: Keyword.fetch!(init_arg, :consumer_group_mod),
        client_name: client_name,
        member_id: Keyword.fetch!(init_arg, :member_id)
      }

    {:ok, state}
  end

  @impl true
  def init_batch(%__MODULE__{} = state) do
    batch = %Batch{data: %{}}
    {:ok, batch, state}
  end

  @impl true
  def handle_insert_item(
        %BatchItem{} = item,
        %Batch{} = batch,
        %__MODULE__{} = state
      ) do
    new_batch = %Batch{
      batch
      | data: add_item_to_batch_data(item, batch.data)
    }

    {:ok, item, new_batch, state}
  end

  defp add_item_to_batch_data(%BatchItem{} = item, data_map) do
    key = {item.topic_name, item.partition}
    Map.put(data_map, key, item)
  end

  @impl true
  def handle_insert_response(_items, %__MODULE__{} = _state) do
    :ok
  end

  @impl true
  def get_size(%BatchItem{} = _item) do
    0
  end

  @impl true
  def fit_on_batch?(%BatchItem{} = _item, %Batch{} = _current_batch) do
    true
  end

  @impl true
  def handle_dispatch(%Batch{} = batch, %__MODULE__{} = state, ref) do
    to_dispatch = %Batch{batch | dispatch_ref: ref}
    batcher_pid = self()

    Task.start(fn ->
      Process.sleep(2000)

      to_print =
        Enum.map(to_dispatch.data, fn {{t, p}, batch_item} ->
          {{t, p}, batch_item.offset_to_commit}
        end)

      IO.inspect(to_print, label: "COMMITTED")
      GenBatcher.complete_dispatch(batcher_pid, ref)
    end)

    {:ok, state}
  end
end

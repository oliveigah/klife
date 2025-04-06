defmodule Klife.Consumer.Fetcher.Batcher do
  use Klife.GenBatcher

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  alias Klife.GenBatcher

  alias Klife.Consumer.Fetcher.Dispatcher

  defstruct [
    :broker_id,
    :batcher_id,
    :fetcher_config,
    :dispatcher_pid,
    :rack_id,
    :isolation_level
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
      :topic_id,
      :partition,
      :offset_to_fetch,
      :max_bytes,
      :__callback
    ]
  end

  def request_data(
        reqs,
        client,
        fetcher_name,
        broker_id,
        batcher_id,
        iso_level
      ) do
    client
    |> get_process_name(fetcher_name, broker_id, batcher_id, iso_level)
    |> GenBatcher.insert_call(__MODULE__, reqs)
  end

  def start_link(args) do
    fetcher_config = Keyword.fetch!(args, :fetcher_config)
    fetcher_name = fetcher_config.name
    client = fetcher_config.client_name
    broker_id = Keyword.fetch!(args, :broker_id)
    batcher_id = Keyword.fetch!(args, :batcher_id)
    iso_level = Keyword.fetch!(args, :iso_level)

    Klife.GenBatcher.start_link(__MODULE__, args,
      name: get_process_name(client, fetcher_name, broker_id, batcher_id, iso_level)
    )
  end

  defp get_process_name(client, fetcher_name, broker_id, batcher_id, iso_level) do
    via_tuple({__MODULE__, client, fetcher_name, broker_id, batcher_id, iso_level})
  end

  @impl true
  def init_state(init_arg) do
    broker_id = Keyword.fetch!(init_arg, :broker_id)
    batcher_id = Keyword.fetch!(init_arg, :batcher_id)
    fetcher_config = Keyword.fetch!(init_arg, :fetcher_config)
    iso_level = Keyword.fetch!(init_arg, :iso_level)

    state = %__MODULE__{
      broker_id: broker_id,
      batcher_id: batcher_id,
      fetcher_config: fetcher_config,
      isolation_level: iso_level,
      # TODO: Implement later
      rack_id: ""
    }

    {:ok, dispatcher_pid} = start_dispatcher(state)

    {:ok, %__MODULE__{state | dispatcher_pid: dispatcher_pid}}
  end

  defp start_dispatcher(%__MODULE__{} = state) do
    args = [
      fetcher_config: state.fetcher_config,
      broker_id: state.broker_id,
      batcher_id: state.batcher_id,
      batcher_pid: self(),
      rack_id: state.rack_id
    ]

    case Dispatcher.start_link(args) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
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
  def get_size(%BatchItem{} = item) do
    item.max_bytes
  end

  @impl true
  def fit_on_batch?(%BatchItem{} = item, %Batch{} = current_batch) do
    not Map.has_key?(current_batch.data, {item.topic_name, item.partition})
  end

  @impl true
  def handle_dispatch(%Batch{} = batch, %__MODULE__{} = state, ref) do
    to_dispatch = %Batch{batch | dispatch_ref: ref}
    :ok = Dispatcher.dispatch(state.dispatcher_pid, to_dispatch)
    {:ok, state}
  end
end

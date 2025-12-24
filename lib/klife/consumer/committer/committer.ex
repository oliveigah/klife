defmodule Klife.Consumer.Committer do
  use Klife.GenBatcher

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  alias Klife.GenBatcher

  alias Klife.Connection.Broker

  alias KlifeProtocol.Messages, as: M

  defstruct [
    :group_id,
    :broker_id,
    :batcher_id,
    :member_id,
    :member_epoch,
    :client_name,
    :cg_mod,
    :dispatcher_pid,
    :group_intance_id,
    :requests,
    :cg_pid
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
      :callback_pid,
      :leader_epoch
    ]
  end

  def start_link(args) do
    client = Keyword.fetch!(args, :client_name)
    batcher_id = Keyword.fetch!(args, :batcher_id)
    cg_mod = Keyword.fetch!(args, :consumer_group_mod)
    cg_name = Keyword.fetch!(args, :group_id)

    GenBatcher.start_link(__MODULE__, args,
      name: get_process_name(client, cg_mod, cg_name, batcher_id)
    )
  end

  def commit(%BatchItem{} = batch_item, client, cg_mod, cg_name, batcher_id) do
    client
    |> get_process_name(cg_mod, cg_name, batcher_id)
    |> GenBatcher.insert_call([batch_item])
  end

  def update_coordinator(new_coordinator, client, cg_mod, cg_name, batcher_id) do
    client
    |> get_process_name(cg_mod, cg_name, batcher_id)
    |> GenServer.call({:update_coordinator, new_coordinator})
  end

  defp get_process_name(client, cg_mod, cg_name, batcher_id) do
    via_tuple({__MODULE__, client, cg_mod, cg_name, batcher_id})
  end

  @impl true
  def init_state(init_arg) do
    client_name = Keyword.fetch!(init_arg, :client_name)

    state =
      %__MODULE__{
        broker_id: Keyword.fetch!(init_arg, :broker_id),
        batcher_id: Keyword.fetch!(init_arg, :batcher_id),
        cg_mod: Keyword.fetch!(init_arg, :consumer_group_mod),
        client_name: client_name,
        member_id: Keyword.fetch!(init_arg, :member_id),
        group_id: Keyword.fetch!(init_arg, :group_id),
        member_epoch: Keyword.fetch!(init_arg, :member_epoch),
        group_intance_id: Keyword.fetch!(init_arg, :group_intance_id),
        requests: %{},
        cg_pid: Keyword.fetch!(init_arg, :cg_pid)
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

    Map.update(data_map, key, item, fn %BatchItem{} = curr_item ->
      # Need this comparison because of retries
      if item.offset_to_commit > curr_item.offset_to_commit,
        do: item,
        else: curr_item
    end)
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

    content =
      %{
        group_id: state.group_id,
        generation_id_or_member_epoch: state.member_epoch,
        member_id: state.member_id,
        group_instance_id: state.group_intance_id,
        topics:
          to_dispatch.data
          |> Enum.group_by(fn {{t, _p}, _batch_item} -> t end, fn {{_t, p}, item} -> {p, item} end)
          |> Enum.map(fn {t, partition_list} ->
            %{
              name: t,
              partitions:
                Enum.map(partition_list, fn {p, %BatchItem{} = batch_item} ->
                  %{
                    partition_index: p,
                    committed_offset: batch_item.offset_to_commit,
                    committed_leader_epoch: batch_item.leader_epoch,
                    # TODO: Implement user defined metadata
                    committed_metadata: nil
                  }
                end)
            }
          end)
      }

    opts = [
      async: true,
      callback_pid: batcher_pid,
      callback_ref: to_dispatch.dispatch_ref
    ]

    Broker.send_message(M.OffsetCommit, state.client_name, state.broker_id, content, %{}, opts)

    {:ok, %__MODULE__{state | requests: Map.put(state.requests, ref, to_dispatch)}}
  end

  def handle_info(
        {:async_broker_response, req_ref, binary_resp, M.OffsetCommit = msg_mod, msg_version},
        %GenBatcher{user_state: %__MODULE__{} = state} =
          batcher_state
      ) do
    {:ok, %{content: %{topics: resp_list}}} =
      msg_mod.deserialize_response(binary_resp, msg_version)

    req_data = state.requests[req_ref].data

    result =
      for %{name: t, partitions: p_list} <- resp_list,
          %{partition_index: p, error_code: ec} <- p_list do
        key = {t, p}

        %BatchItem{} = batch_item = req_data[key]

        case ec do
          0 ->
            send(batch_item.callback_pid, {:offset_committed, batch_item.offset_to_commit})

          113 ->
            send(self(), :update_member_epoch)
            {:retry, batch_item}

          # TODO: Handle specific errors
          _err ->
            {:retry, batch_item}
        end
      end

    to_retry =
      Enum.filter(result, fn e -> match?({:retry, _}, e) end)
      |> Enum.map(fn {:retry, batch_item} -> batch_item end)

    {new_state, _user_resp} =
      Klife.GenBatcher.insert_items(batcher_state, to_retry, self(), __MODULE__)

    new_state = Klife.GenBatcher.dispatch_completed(new_state, req_ref)

    new_user_state = %__MODULE__{state | requests: Map.delete(state.requests, req_ref)}

    {:noreply, %GenBatcher{new_state | user_state: new_user_state}}
  end

  @impl true
  def handle_info(
        :update_member_epoch,
        %GenBatcher{user_state: %__MODULE__{} = state} = batcher_state
      ) do
    new_epoch = Klife.Consumer.ConsumerGroup.get_member_epoch(state.cg_pid)

    {:noreply,
     %GenBatcher{batcher_state | user_state: %__MODULE__{state | member_epoch: new_epoch}}}
  end

  @impl true
  def handle_call(
        {:update_coordinator, new_coordinator},
        _from,
        %GenBatcher{user_state: %__MODULE__{} = state} = batcher_state
      ) do
    {:reply, :ok,
     %GenBatcher{batcher_state | user_state: %__MODULE__{state | broker_id: new_coordinator}}}
  end
end

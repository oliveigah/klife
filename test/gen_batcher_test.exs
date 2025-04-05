defmodule Klife.GenBatcherTest do
  use ExUnit.Case

  defmodule TestBatcher do
    use Klife.GenBatcher

    defstruct [
      :parent_pid,
      :ref,
      :items_count,
      :dispatch_count,
      :batch_count
    ]

    defmodule Batch do
      defstruct [:items, :global_order, :hash]
    end

    defmodule BatchItem do
      defstruct [:value, :global_order, :size]
    end

    def start_link(args) do
      Klife.GenBatcher.start_link(__MODULE__, args)
    end

    def insert_values(pid, items) do
      Klife.GenBatcher.insert_call(pid, __MODULE__, items)
    end

    @impl true
    def init_state(init_arg) do
      state = %__MODULE__{
        parent_pid: init_arg[:parent_pid],
        ref: init_arg[:ref],
        dispatch_count: 0,
        items_count: 0,
        batch_count: 0
      }

      send(state.parent_pid, {:init_state, init_arg})

      {:ok, state}
    end

    @impl true
    def init_batch(%__MODULE__{} = state) do
      send(state.parent_pid, {:init_batch, state})

      new_batch_count = state.batch_count + 1

      {
        :ok,
        %Batch{items: [], global_order: new_batch_count},
        %__MODULE__{state | batch_count: new_batch_count}
      }
    end

    @impl true
    def handle_insert_response(items, %__MODULE__{} = state) do
      send(state.parent_pid, {:handle_insert_response, items, state})
      :erlang.phash2(items)
    end

    @impl true
    def handle_insert_item(
          %BatchItem{} = item,
          %Batch{} = batch,
          %__MODULE__{} = state
        ) do
      send(state.parent_pid, {:handle_insert_item, item, batch, state})

      items_count = state.items_count + 1
      new_item = %BatchItem{item | global_order: items_count}
      new_items = batch.items ++ [new_item]
      new_batch = %Batch{batch | items: new_items, hash: :erlang.phash2(new_items)}
      new_state = %__MODULE__{state | items_count: items_count}

      {:ok, new_item, new_batch, new_state}
    end

    @impl true
    def handle_dispatch(%Batch{} = batch, %__MODULE__{} = state, ref) do
      send(state.parent_pid, {:handle_dispatch, batch, state, ref})
      {:ok, %__MODULE__{state | dispatch_count: state.dispatch_count + 1}}
    end

    @impl true
    def get_size(%BatchItem{} = item) do
      item.size || 0
    end

    @impl true
    def fit_on_batch?(%BatchItem{} = _item, %Batch{} = _batch) do
      true
    end
  end

  test "test basic genbatcher behaviour" do
    init_ref = make_ref()

    init_args = [
      parent_pid: self(),
      ref: init_ref,
      batcher_config: [
        batch_wait_time_ms: 0,
        max_in_flight: 1,
        max_batch_size: 10,
        max_batch_count: 3
      ]
    ]

    batcher_pid = start_supervised!({TestBatcher, init_args})

    expected_args = Keyword.delete(init_args, :batcher_config)
    assert_receive {:init_state, ^expected_args}

    assert_receive {:init_batch,
                    %TestBatcher{
                      ref: ^init_ref,
                      items_count: 0,
                      batch_count: 0,
                      dispatch_count: 0
                    }}

    item1 = %TestBatcher.BatchItem{value: 1, size: 1}
    item2 = %TestBatcher.BatchItem{value: 2, size: 2}
    item3 = %TestBatcher.BatchItem{value: 3, size: 3}
    to_insert = [item1, item2, item3]

    insert_response = TestBatcher.insert_values(batcher_pid, to_insert)

    assert_receive {:handle_insert_item, ^item1, %TestBatcher.Batch{global_order: 1},
                    %TestBatcher{
                      ref: ^init_ref,
                      items_count: 0,
                      batch_count: 1,
                      dispatch_count: 0
                    }}

    assert_receive {:handle_insert_item, ^item2, %TestBatcher.Batch{global_order: 1},
                    %TestBatcher{
                      ref: ^init_ref,
                      items_count: 1,
                      batch_count: 1,
                      dispatch_count: 0
                    }}

    assert_receive {:handle_insert_item, ^item3, %TestBatcher.Batch{global_order: 1},
                    %TestBatcher{
                      ref: ^init_ref,
                      items_count: 2,
                      batch_count: 1,
                      dispatch_count: 0
                    }}

    assert_receive {:handle_insert_response, received_items,
                    %TestBatcher{
                      ref: ^init_ref,
                      items_count: 3,
                      batch_count: 1,
                      dispatch_count: 0
                    }}

    assert [
             %TestBatcher.BatchItem{value: 1, size: 1, global_order: 1},
             %TestBatcher.BatchItem{value: 2, size: 2, global_order: 2},
             %TestBatcher.BatchItem{value: 3, size: 3, global_order: 3}
           ] = received_items

    assert insert_response == :erlang.phash2(received_items)

    assert_receive {
      :handle_dispatch,
      %TestBatcher.Batch{items: ^received_items, hash: batch_hash, global_order: 1},
      %TestBatcher{items_count: 3, batch_count: 1, dispatch_count: 0},
      dispatch_ref
    }

    assert batch_hash == :erlang.phash2(received_items)

    assert_receive {:init_batch,
                    %TestBatcher{
                      ref: ^init_ref,
                      items_count: 3,
                      batch_count: 1,
                      dispatch_count: 1
                    }}

    :ok = Klife.GenBatcher.complete_dispatch(batcher_pid, dispatch_ref)
  end

  test "batch items while in flight pool not available" do
    init_ref = make_ref()

    init_args = [
      parent_pid: self(),
      ref: init_ref,
      batcher_config: [
        batch_wait_time_ms: 0,
        max_in_flight: 1,
        max_batch_size: 10,
        max_batch_count: 3
      ]
    ]

    batcher_pid = start_supervised!({TestBatcher, init_args})

    expected_args = Keyword.delete(init_args, :batcher_config)
    assert_receive {:init_state, ^expected_args}

    assert_receive {:init_batch,
                    %TestBatcher{
                      ref: ^init_ref,
                      items_count: 0,
                      batch_count: 0,
                      dispatch_count: 0
                    }}

    item1 = %TestBatcher.BatchItem{value: 1, size: 1}
    item2 = %TestBatcher.BatchItem{value: 2, size: 2}
    item3 = %TestBatcher.BatchItem{value: 3, size: 3}
    to_insert = [item1, item2, item3]

    _insert_response = TestBatcher.insert_values(batcher_pid, to_insert)

    assert_receive {
      :handle_dispatch,
      %TestBatcher.Batch{global_order: 1},
      %TestBatcher{items_count: 3, batch_count: 1, dispatch_count: 0},
      dispatch_ref
    }

    item4 = %TestBatcher.BatchItem{value: 4, size: 0}
    item5 = %TestBatcher.BatchItem{value: 5, size: 0}
    item6 = %TestBatcher.BatchItem{value: 6, size: 0}
    item7 = %TestBatcher.BatchItem{value: 7, size: 0}

    _insert_response = TestBatcher.insert_values(batcher_pid, [item4])
    _insert_response = TestBatcher.insert_values(batcher_pid, [item5])
    _insert_response = TestBatcher.insert_values(batcher_pid, [item6])
    _insert_response = TestBatcher.insert_values(batcher_pid, [item7])

    :ok = Klife.GenBatcher.complete_dispatch(batcher_pid, dispatch_ref)

    assert_receive {
      :handle_dispatch,
      %TestBatcher.Batch{items: dispatched_items, global_order: 2},
      %TestBatcher{items_count: 7, batch_count: 3, dispatch_count: 1},
      dispatch_ref
    }

    assert [
             %TestBatcher.BatchItem{value: 4, size: 0, global_order: 4},
             %TestBatcher.BatchItem{value: 5, size: 0, global_order: 5},
             %TestBatcher.BatchItem{value: 6, size: 0, global_order: 6}
           ] = dispatched_items

    :ok = Klife.GenBatcher.complete_dispatch(batcher_pid, dispatch_ref)

    assert_receive {
      :handle_dispatch,
      %TestBatcher.Batch{items: dispatched_items, global_order: 3},
      %TestBatcher{items_count: 7, batch_count: 3, dispatch_count: 2},
      _dispatch_ref
    }

    assert [
             %TestBatcher.BatchItem{value: 7, size: 0, global_order: 7}
           ] = dispatched_items
  end

  test "batch items while wait time" do
    init_ref = make_ref()

    init_args = [
      parent_pid: self(),
      ref: init_ref,
      batcher_config: [
        batch_wait_time_ms: 1000,
        max_in_flight: 1,
        max_batch_size: 6,
        max_batch_count: 10
      ]
    ]

    batcher_pid = start_supervised!({TestBatcher, init_args})

    expected_args = Keyword.delete(init_args, :batcher_config)
    assert_receive {:init_state, ^expected_args}

    assert_receive {:init_batch,
                    %TestBatcher{
                      ref: ^init_ref,
                      items_count: 0,
                      batch_count: 0,
                      dispatch_count: 0
                    }}

    item1 = %TestBatcher.BatchItem{value: 1, size: 1}
    item2 = %TestBatcher.BatchItem{value: 2, size: 2}
    item3 = %TestBatcher.BatchItem{value: 3, size: 3}
    item4 = %TestBatcher.BatchItem{value: 4, size: 4}
    item5 = %TestBatcher.BatchItem{value: 5, size: 10}

    _insert_response = TestBatcher.insert_values(batcher_pid, [item1])
    _insert_response = TestBatcher.insert_values(batcher_pid, [item2])
    _insert_response = TestBatcher.insert_values(batcher_pid, [item3])
    _insert_response = TestBatcher.insert_values(batcher_pid, [item4])
    _insert_response = TestBatcher.insert_values(batcher_pid, [item5])

    assert_receive {
      :handle_dispatch,
      %TestBatcher.Batch{items: dispatched_items, global_order: 1},
      %TestBatcher{items_count: 5, batch_count: 3, dispatch_count: 0},
      dispatch_ref
    }

    assert [
             %TestBatcher.BatchItem{value: 1, size: 1, global_order: 1},
             %TestBatcher.BatchItem{value: 2, size: 2, global_order: 2},
             %TestBatcher.BatchItem{value: 3, size: 3, global_order: 3}
           ] = dispatched_items

    :ok = Klife.GenBatcher.complete_dispatch(batcher_pid, dispatch_ref)

    assert_receive {
      :handle_dispatch,
      %TestBatcher.Batch{items: dispatched_items, global_order: 2},
      %TestBatcher{items_count: 5, batch_count: 3, dispatch_count: 1},
      dispatch_ref
    }

    assert [
             %TestBatcher.BatchItem{value: 4, size: 4, global_order: 4}
           ] = dispatched_items

    # artificial delay to complete
    Process.sleep(2000)

    :ok = Klife.GenBatcher.complete_dispatch(batcher_pid, dispatch_ref)

    assert_receive {
      :handle_dispatch,
      %TestBatcher.Batch{items: dispatched_items, global_order: 3},
      %TestBatcher{items_count: 5, batch_count: 3, dispatch_count: 2},
      dispatch_ref
    }

    assert [
             %TestBatcher.BatchItem{value: 5, size: 10, global_order: 5}
           ] = dispatched_items

    :ok = Klife.GenBatcher.complete_dispatch(batcher_pid, dispatch_ref)

    item6 = %TestBatcher.BatchItem{value: 6, size: 0}

    _insert_response = TestBatcher.insert_values(batcher_pid, [item6])

    assert_receive {
                     :handle_dispatch,
                     %TestBatcher.Batch{items: dispatched_items, global_order: 4},
                     %TestBatcher{items_count: 6, batch_count: 4, dispatch_count: 3},
                     dispatch_ref
                   },
                   1500

    assert [
             %TestBatcher.BatchItem{value: 6, size: 0, global_order: 6}
           ] = dispatched_items

    :ok = Klife.GenBatcher.complete_dispatch(batcher_pid, dispatch_ref)

    item7 = %TestBatcher.BatchItem{value: 7, size: 0}

    _insert_response = TestBatcher.insert_values(batcher_pid, [item7])

    assert_receive {
                     :handle_dispatch,
                     %TestBatcher.Batch{items: dispatched_items, global_order: 5},
                     %TestBatcher{items_count: 7, batch_count: 5, dispatch_count: 4},
                     _dispatch_ref
                   },
                   1500

    assert [
             %TestBatcher.BatchItem{value: 7, size: 0, global_order: 7}
           ] = dispatched_items
  end
end

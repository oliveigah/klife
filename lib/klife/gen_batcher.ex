defmodule Klife.GenBatcher do
  defstruct [
    :current_batch,
    :current_batch_size,
    :current_batch_item_count,
    :last_batch_sent_at,
    :in_flight_pool,
    :next_dispatch_msg_ref,
    :batch_max_size,
    :batch_max_count,
    :batch_queue,
    :user_state,
    :batch_wait_time_ms
  ]

  require Logger

  @type batch_insert_item :: term()
  @type batch :: term()
  @type dispatch_response :: {:ok, user_state}

  @type init_arg :: term()
  @type user_state :: term()

  @callback init_state(init_arg) :: {:ok, user_state} | {:error, reason :: term}
  @callback init_batch(user_state) :: {:ok, batch, user_state}
  @callback get_size(batch_insert_item) :: size :: non_neg_integer()
  @callback handle_insert_item(batch_insert_item, batch, user_state) ::
              {
                :ok,
                updated_item :: batch_insert_item,
                updated_batch :: batch,
                updated_state :: user_state
              }

  @callback handle_insert_response(list(batch_insert_item), user_state) :: term
  @callback handle_dispatch(batch, user_state, reference) :: dispatch_response

  def start_link(mod, args, opts \\ []) do
    GenServer.start_link(mod, args, opts)
  end

  def insert_call(batcher_pid, mod, items) when is_list(items) do
    sizes =
      Enum.map(items, fn item ->
        if function_exported?(mod, :get_size, 1),
          do: apply(mod, :get_size, [item]),
          else: 0
      end)

    GenServer.call(batcher_pid, {:insert_on_batch, items, sizes})
  end

  def insert_cast(batcher_pid, mod, items) when is_list(items) do
    sizes =
      Enum.map(items, fn item ->
        if function_exported?(mod, :get_size, 1),
          do: apply(mod, :get_size, [item]),
          else: 0
      end)

    GenServer.cast(batcher_pid, {:insert_on_batch, items, sizes})
  end

  def complete_dispatch(batcher_pid, dispatch_ref) do
    send(batcher_pid, {:complete_dispatch, dispatch_ref})
    :ok
  end

  # State functions

  def init(mod, args) do
    {batcher_config, args} = Keyword.pop!(args, :batcher_config)
    batch_wait_time_ms = Keyword.get(batcher_config, :batch_wait_time_ms, 0)
    max_in_flight = Keyword.get(batcher_config, :max_in_flight, 1)
    batch_max_size = Keyword.get(batcher_config, :max_batch_size, :infinity)
    batch_max_count = Keyword.get(batcher_config, :max_batch_count, :infinity)

    next_dispatch_msg_ref =
      if batch_wait_time_ms > 0 do
        Process.send_after(self(), :maybe_dispatch, batch_wait_time_ms)
      end

    base_state = %__MODULE__{
      user_state: nil,
      current_batch: nil,
      current_batch_size: 0,
      current_batch_item_count: 0,
      next_dispatch_msg_ref: next_dispatch_msg_ref,
      last_batch_sent_at: System.monotonic_time(:millisecond),
      in_flight_pool: List.duplicate(nil, max_in_flight),
      batch_queue: :queue.new(),
      batch_wait_time_ms: batch_wait_time_ms,
      batch_max_size: batch_max_size,
      batch_max_count: batch_max_count
    }

    with {:ok, user_state} <- mod.init_state(args),
         {:ok, batch, user_state} <- mod.init_batch(user_state) do
      new_state = %__MODULE__{
        base_state
        | user_state: user_state,
          current_batch: batch
      }

      {:ok, new_state}
    end
  end

  def insert_items(%__MODULE__{} = state, items, sizes, _from, mod) do
    zipped_items = Enum.zip(items, sizes)

    {updated_items, new_state} =
      Enum.map_reduce(zipped_items, state, fn {item, size}, acc_state ->
        %__MODULE__{
          current_batch: current_batch,
          current_batch_size: current_batch_size,
          batch_max_size: batch_max_size,
          batch_max_count: batch_max_count,
          user_state: user_state,
          current_batch_item_count: current_batch_item_count
        } = acc_state

        new_size = current_batch_size + size
        new_count = current_batch_item_count + 1

        size_overflow? = new_size > batch_max_size
        count_overflow? = new_count > batch_max_count
        empty_current? = current_batch_item_count == 0

        cond do
          (size_overflow? or count_overflow?) and not empty_current? ->
            new_state =
              acc_state
              |> move_batch_to_queue(mod)
              |> schedule_dispatch_if_earlier(5)

            {:ok, new_item, new_batch, new_user_state} =
              mod.handle_insert_item(item, new_state.current_batch, new_state.user_state)

            new_state = %__MODULE__{
              new_state
              | current_batch_size: size,
                current_batch: new_batch,
                user_state: new_user_state,
                current_batch_item_count: 1
            }

            {new_item, new_state}

          true ->
            {:ok, new_item, new_batch, new_user_state} =
              mod.handle_insert_item(item, current_batch, user_state)

            new_state = %__MODULE__{
              state
              | current_batch_size: new_size,
                current_batch: new_batch,
                user_state: new_user_state,
                current_batch_item_count: new_count
            }

            {new_item, new_state}
        end
      end)

    now = System.monotonic_time(:millisecond)
    on_time? = now - new_state.last_batch_sent_at >= new_state.batch_wait_time_ms

    new_state =
      if on_time? and new_state.next_dispatch_msg_ref == nil,
        do: schedule_dispatch_if_earlier(new_state, 0),
        else: new_state

    user_resp = mod.handle_insert_response(updated_items, new_state.user_state)

    {new_state, user_resp}
  end

  def maybe_dispatch(%__MODULE__{} = state, mod) do
    %__MODULE__{
      batch_wait_time_ms: batch_wait_time_ms,
      last_batch_sent_at: last_batch_sent_at,
      in_flight_pool: in_flight_pool,
      batch_queue: batch_queue
    } = state

    now = System.monotonic_time(:millisecond)
    pool_idx = Enum.find_index(in_flight_pool, &is_nil/1)

    on_time? = now - last_batch_sent_at >= batch_wait_time_ms
    in_flight_available? = is_integer(pool_idx)
    has_batch_on_queue? = not :queue.is_empty(batch_queue)
    is_periodic? = batch_wait_time_ms > 0
    new_state = %__MODULE__{state | next_dispatch_msg_ref: nil}

    cond do
      not in_flight_available? ->
        schedule_dispatch_if_earlier(new_state, 10)

      has_batch_on_queue? ->
        new_state =
          new_state
          |> do_dispatch(pool_idx, mod)
          |> schedule_dispatch_if_earlier(1)

        new_state

      not on_time? ->
        new_state =
          schedule_dispatch_if_earlier(new_state, batch_wait_time_ms - (now - last_batch_sent_at))

        new_state

      is_periodic? ->
        new_state =
          new_state
          |> do_dispatch(pool_idx, mod)
          |> schedule_dispatch_if_earlier(batch_wait_time_ms)

        new_state

      true ->
        do_dispatch(new_state, pool_idx, mod)
    end
  end

  defp do_dispatch(%__MODULE__{} = state, pool_idx, mod) do
    %__MODULE__{
      batch_queue: batch_queue,
      in_flight_pool: in_flight_pool,
      user_state: user_state,
      current_batch_item_count: current_batch_item_count
    } = state

    queue_data =
      case :queue.out(batch_queue) do
        {{:value, queued_data}, new_queue} ->
          {queued_data, new_queue, false}

        {:empty, new_queue} ->
          if current_batch_item_count == 0,
            do: :noop,
            else: {state.current_batch, new_queue, true}
      end

    case queue_data do
      :noop ->
        state

      {data_to_send, new_batch_queue, sending_from_current?} ->
        dispatch_ref = make_ref()

        {:ok, new_user_state} = mod.handle_dispatch(data_to_send, user_state, dispatch_ref)

        new_state = %{
          state
          | user_state: new_user_state,
            batch_queue: new_batch_queue,
            last_batch_sent_at: System.monotonic_time(:millisecond),
            in_flight_pool: List.replace_at(in_flight_pool, pool_idx, dispatch_ref)
        }

        if sending_from_current?,
          do: reset_current_batch(new_state, mod),
          else: new_state
    end
  end

  def dispatch_completed(%__MODULE__{in_flight_pool: in_flight_pool} = state, dispatch_ref) do
    case Enum.find_index(in_flight_pool, fn i -> i == dispatch_ref end) do
      nil ->
        Logger.warning("Unkown dispatch ref received!")
        state

      pool_idx ->
        %{state | in_flight_pool: List.replace_at(in_flight_pool, pool_idx, nil)}
    end
  end

  defp move_batch_to_queue(
         %__MODULE__{batch_queue: queue, current_batch: curr_batch} = state,
         mod
       ) do
    %__MODULE__{state | batch_queue: :queue.in(curr_batch, queue)}
    |> reset_current_batch(mod)
  end

  defp reset_current_batch(%__MODULE__{} = state, mod) do
    {:ok, new_batch, user_state} = mod.init_batch(state.user_state)

    %__MODULE__{
      state
      | current_batch: new_batch,
        current_batch_size: 0,
        current_batch_item_count: 0,
        user_state: user_state
    }
  end

  defp schedule_dispatch_if_earlier(%__MODULE__{next_dispatch_msg_ref: nil} = state, time),
    do: %__MODULE__{
      state
      | next_dispatch_msg_ref: Process.send_after(self(), :maybe_dispatch, time)
    }

  defp schedule_dispatch_if_earlier(%__MODULE__{next_dispatch_msg_ref: ref} = state, time)
       when is_reference(ref) do
    if Process.read_timer(ref) > time do
      Process.cancel_timer(ref)

      %__MODULE__{
        state
        | next_dispatch_msg_ref: Process.send_after(self(), :maybe_dispatch, time)
      }
    else
      state
    end
  end

  # Macro
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use GenServer

      @behaviour Klife.GenBatcher

      def init(args) do
        Klife.GenBatcher.init(__MODULE__, args)
      end

      def handle_call({:insert_on_batch, items_list, sizes}, from, %Klife.GenBatcher{} = state) do
        {new_state, user_resp} =
          Klife.GenBatcher.insert_items(state, items_list, sizes, from, __MODULE__)

        {:reply, user_resp, new_state}
      end

      def handle_cast({:insert_on_batch, items_list, sizes}, %Klife.GenBatcher{} = state) do
        {new_state, _resp} =
          Klife.GenBatcher.insert_items(state, items_list, sizes, nil, __MODULE__)

        {:noreply, new_state}
      end

      def handle_info(:maybe_dispatch, %Klife.GenBatcher{} = state) do
        new_state = Klife.GenBatcher.maybe_dispatch(state, __MODULE__)
        {:noreply, new_state}
      end

      def handle_info({:complete_dispatch, dispatch_ref}, %Klife.GenBatcher{} = state) do
        new_state = Klife.GenBatcher.dispatch_completed(state, dispatch_ref)
        {:noreply, new_state}
      end
    end
  end
end

defmodule Klife.GenBatcher do
  @moduledoc false

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

  @type batch_insert_item :: term()
  @type batch :: term()
  @type dispatch_response :: {:ok, user_state}

  @type init_arg :: term()
  @type user_state :: term()

  @callback init_state(init_arg) :: {:ok, user_state} | {:error, reason :: term}
  @callback init_batch(user_state) :: {:ok, batch, user_state}
  @callback get_size(batch_insert_item) :: size :: non_neg_integer()
  @callback fit_on_batch?(batch_insert_item, batch) :: boolean()
  @callback handle_insert_item(batch_insert_item, batch, user_state) ::
              {
                :ok,
                updated_item :: batch_insert_item,
                updated_batch :: batch,
                updated_state :: user_state
              }

  @callback handle_insert_response(list(batch_insert_item), user_state) :: term
  @callback handle_dispatch(batch, user_state, reference) :: dispatch_response

  # Called once per insert request with all its items, before any of them is
  # counted or reaches handle_insert_item. Returns the items to insert: the
  # implementation may filter them, or keep some to hold or send elsewhere.
  # `meta` is the term given to insert_call/insert_cast.
  @callback handle_insert_batch(list(batch_insert_item), meta :: term, user_state) ::
              {:ok, list(batch_insert_item), user_state}

  @optional_callbacks handle_insert_batch: 3

  def start_link(mod, args, opts \\ []) do
    GenServer.start_link(mod, args, opts)
  end

  def insert_call(batcher_pid, items, meta \\ nil) when is_list(items) do
    GenServer.call(batcher_pid, {:insert_on_batch, items, meta})
  end

  def insert_cast(batcher_pid, items, meta \\ nil) when is_list(items) do
    GenServer.cast(batcher_pid, {:insert_on_batch, items, meta})
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
        schedule_dispatch(batch_wait_time_ms)
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

  def insert_items(%__MODULE__{} = state, items, _from, mod) do
    {updated_items, new_state} =
      Enum.map_reduce(items, state, fn item, acc_state ->
        size = mod.get_size(item)

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
        fit_on_current? = mod.fit_on_batch?(item, current_batch)

        cond do
          (size_overflow? or count_overflow? or not fit_on_current?) and not empty_current? ->
            new_state =
              acc_state
              |> move_batch_to_queue(mod)
              |> schedule_dispatch_if_earlier(0)

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

            new_state = %{
              acc_state
              | current_batch_size: new_size,
                current_batch: new_batch,
                user_state: new_user_state,
                current_batch_item_count: new_count
            }

            {new_item, new_state}
        end
      end)

    new_state =
      if new_state.next_dispatch_msg_ref == nil,
        do: schedule_dispatch_if_earlier(new_state, 0),
        else: new_state

    user_resp = mod.handle_insert_response(updated_items, new_state.user_state)

    {new_state, user_resp}
  end

  # Runs for the current dispatch run's message only (see the :maybe_dispatch handler):
  # every branch that wants another run schedules one
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
      # dispatch_completed/2 schedules the next run
      not in_flight_available? ->
        new_state

      has_batch_on_queue? ->
        new_state
        |> dispatch_queued_batches(mod)
        |> schedule_dispatch_if_earlier(0)

      not on_time? ->
        new_state =
          schedule_dispatch_if_earlier(new_state, batch_wait_time_ms - (now - last_batch_sent_at))

        new_state

      true ->
        new_state = do_dispatch(new_state, pool_idx, mod)

        if is_periodic? do
          schedule_dispatch_if_earlier(new_state, batch_wait_time_ms)
        else
          new_state
        end
    end
  end

  # Every free in flight slot takes a queued batch
  defp dispatch_queued_batches(%__MODULE__{} = state, mod) do
    pool_idx = Enum.find_index(state.in_flight_pool, &is_nil/1)

    if is_integer(pool_idx) and not :queue.is_empty(state.batch_queue),
      do: state |> do_dispatch(pool_idx, mod) |> dispatch_queued_batches(mod),
      else: state
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

  # Closes the current batch into the queue and replaces the queue with the
  # batches `fun` returns, for implementations that move batches in or out.
  def update_batch_queue(%__MODULE__{} = state, mod, fun) do
    state =
      if state.current_batch_item_count > 0, do: move_batch_to_queue(state, mod), else: state

    {batches, acc} = fun.(:queue.to_list(state.batch_queue))
    new_state = %__MODULE__{state | batch_queue: :queue.from_list(batches)}

    {schedule_dispatch_if_earlier(new_state, 0), acc}
  end

  def dispatch_completed(%__MODULE__{in_flight_pool: in_flight_pool} = state, dispatch_ref) do
    case Enum.find_index(in_flight_pool, fn i -> i == dispatch_ref end) do
      nil ->
        raise(
          "Unkown dispatch ref #{inspect(dispatch_ref)} received for #{state.user_state.__struct__}!"
        )

        state

      pool_idx ->
        new_state = %{state | in_flight_pool: List.replace_at(in_flight_pool, pool_idx, nil)}

        # The slot is free for what waits, and maybe_dispatch/2 keeps the batch wait time
        if :queue.is_empty(new_state.batch_queue) and new_state.current_batch_item_count == 0,
          do: new_state,
          else: schedule_dispatch_if_earlier(new_state, 0)
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

  # One dispatch run pending at a time: its message carries its ref, and the handler
  # drops any other (see __using__/1), so a run replaced here can't start a second loop
  defp schedule_dispatch_if_earlier(%__MODULE__{next_dispatch_msg_ref: nil} = state, time),
    do: %__MODULE__{state | next_dispatch_msg_ref: schedule_dispatch(time)}

  defp schedule_dispatch_if_earlier(%__MODULE__{next_dispatch_msg_ref: ref} = state, time)
       when is_reference(ref) do
    case Process.read_timer(ref) do
      # Fired, or sent: its message is already in the mailbox
      false ->
        state

      left_ms when left_ms > time ->
        Process.cancel_timer(ref)
        %__MODULE__{state | next_dispatch_msg_ref: schedule_dispatch(time)}

      _ ->
        state
    end
  end

  # A timer fires on the next millisecond at best, so a run due now is sent instead
  defp schedule_dispatch(0) do
    ref = make_ref()
    send(self(), {:timeout, ref, :maybe_dispatch})
    ref
  end

  defp schedule_dispatch(time_ms), do: :erlang.start_timer(time_ms, self(), :maybe_dispatch)

  # Macro
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use GenServer

      @behaviour Klife.GenBatcher

      @impl true
      def init(args) do
        Klife.GenBatcher.init(__MODULE__, args)
      end

      @impl Klife.GenBatcher
      def handle_insert_batch(items, _meta, user_state), do: {:ok, items, user_state}

      defoverridable handle_insert_batch: 3

      @impl true
      def handle_call({:insert_on_batch, items_list, meta}, from, %Klife.GenBatcher{} = state) do
        {:ok, items_list, user_state} = handle_insert_batch(items_list, meta, state.user_state)
        state = %Klife.GenBatcher{state | user_state: user_state}

        {new_state, user_resp} =
          Klife.GenBatcher.insert_items(state, items_list, from, __MODULE__)

        {:reply, user_resp, new_state}
      end

      @impl true
      def handle_cast({:insert_on_batch, items_list, meta}, %Klife.GenBatcher{} = state) do
        {:ok, items_list, user_state} = handle_insert_batch(items_list, meta, state.user_state)
        state = %Klife.GenBatcher{state | user_state: user_state}

        {new_state, _resp} =
          Klife.GenBatcher.insert_items(state, items_list, nil, __MODULE__)

        {:noreply, new_state}
      end

      @impl true
      def handle_info(
            {:timeout, ref, :maybe_dispatch},
            %Klife.GenBatcher{next_dispatch_msg_ref: ref} = state
          ) do
        new_state = Klife.GenBatcher.maybe_dispatch(state, __MODULE__)
        {:noreply, new_state}
      end

      # A run replaced by a newer one: dropped, so it schedules nothing
      def handle_info({:timeout, _ref, :maybe_dispatch}, %Klife.GenBatcher{} = state),
        do: {:noreply, state}

      def handle_info({:complete_dispatch, dispatch_ref}, %Klife.GenBatcher{} = state) do
        new_state = Klife.GenBatcher.dispatch_completed(state, dispatch_ref)
        {:noreply, new_state}
      end
    end
  end
end

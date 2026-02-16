defmodule Klife.Producer.Dispatcher do
  @moduledoc false
  defmodule Request do
    @moduledoc false
    defstruct [
      :producer_config,
      :data_to_send,
      :delivery_confirmation_pids,
      :base_time,
      :request_ref,
      :records_map
    ]
  end

  defstruct [
    :batcher_pid,
    :broker_id,
    :requests
  ]

  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  alias Klife.Connection.Broker
  alias Klife.Producer
  alias KlifeProtocol.Messages, as: M

  alias Klife.GenBatcher

  require Logger

  def start_link(args) do
    %{
      name: p_name,
      client_name: client_name
    } = Keyword.fetch!(args, :producer_config)

    broker_id = Keyword.fetch!(args, :broker_id)
    batcher_id = Keyword.fetch!(args, :batcher_id)

    GenServer.start_link(__MODULE__, args,
      name: via_tuple({__MODULE__, client_name, broker_id, p_name, batcher_id})
    )
  end

  @impl true
  def init(args) do
    state = %__MODULE__{
      requests: %{},
      broker_id: args[:broker_id],
      batcher_pid: args[:batcher_pid]
    }

    {:ok, state}
  end

  def dispatch(server, %Request{} = data),
    do: GenServer.call(server, {:dispatch, data})

  @impl true
  def handle_call({:dispatch, %Request{} = data}, _from, %__MODULE__{} = state) do
    %Request{
      request_ref: request_ref,
      producer_config: %{retry_backoff_ms: retry_ms},
      data_to_send: data_to_send
    } = data

    case do_dispatch(data, state) do
      :ok ->
        new_state = put_in(state.requests[request_ref], data)

        {:reply, :ok, new_state}

      {:error, :retry} ->
        Process.send_after(self(), {:dispatch, request_ref}, retry_ms)
        new_state = put_in(state.requests[request_ref], data)
        {:reply, :ok, new_state}

      {:error, :request_deadline} ->
        failed_topic_partitions = Map.keys(data_to_send)
        send(state.batcher_pid, {:bump_epoch, failed_topic_partitions})
        GenBatcher.complete_dispatch(state.batcher_pid, request_ref)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:dispatch, req_ref}, %__MODULE__{} = state) when is_reference(req_ref) do
    data =
      %Request{
        request_ref: request_ref,
        producer_config: %Producer{retry_backoff_ms: retry_ms},
        data_to_send: data_to_send
      } = Map.fetch!(state.requests, req_ref)

    case do_dispatch(data, state) do
      :ok ->
        {:noreply, state}

      {:error, :retry} ->
        Process.send_after(self(), {:dispatch, request_ref}, retry_ms)
        {:noreply, state}

      {:error, :request_deadline} ->
        failed_topic_partitions = Map.keys(data_to_send)
        send(state.batcher_pid, {:bump_epoch, failed_topic_partitions})
        GenBatcher.complete_dispatch(state.batcher_pid, request_ref)
        {:noreply, remove_request(state, req_ref)}
    end
  end

  def handle_info({:async_broker_response, req_ref, :timeout}, %__MODULE__{} = state) do
    case Map.get(state.requests, req_ref) do
      %{producer_config: %{retry_backoff_ms: retry_ms}} ->
        Process.send_after(self(), {:dispatch, req_ref}, retry_ms)
        {:noreply, state}

      _ ->
        Logger.warning(
          "Timeout message received for an unknown request ref",
          broker_id: state.broker_id
        )

        {:noreply, state}
    end
  end

  # TODO: Handle more specific codes
  @delivery_success_codes [0, 46]
  @delivery_discard_codes [18, 47, 10]
  def handle_info(
        {:async_broker_response, req_ref, binary_resp, M.Produce = msg_mod, msg_version},
        %__MODULE__{} = state
      ) do
    %__MODULE__{
      requests: requests,
      broker_id: broker_id
    } = state

    data =
      %Request{
        delivery_confirmation_pids: delivery_confirmation_pids,
        request_ref: ^req_ref,
        data_to_send: data_to_send,
        producer_config: %{name: producer_name, client_name: client_name} = p_config,
        records_map: records_map
      } = Map.fetch!(requests, req_ref)

    {:ok, resp} = apply(msg_mod, :deserialize_response, [binary_resp, msg_version])

    grouped_results =
      for %{name: topic_name, partition_responses: partition_resps} <- resp.content.responses,
          %{error_code: error_code, index: p_index} = p <- partition_resps do
        {topic_name, p_index, error_code, p[:base_offset]}
      end
      |> Enum.group_by(&(elem(&1, 2) in @delivery_success_codes))

    success_list = grouped_results[true] || []
    failure_list = grouped_results[false] || []

    success_list
    |> Enum.each(fn {topic, partition, _code, base_offset} ->
      delivery_confirmation_pids
      |> Map.get({topic, partition}, [])
      |> Enum.reverse()
      |> Enum.each(fn
        {pid, batch_offset, batch_idx} when is_pid(pid) ->
          send(pid, {:klife_produce, {:ok, base_offset + batch_offset}, batch_idx})

        {{m, f, a}, batch_offset} ->
          callback_rec =
            records_map
            |> Map.fetch!({topic, partition})
            |> Map.fetch!(batch_offset)
            |> Map.replace!(:offset, base_offset + batch_offset)

          Task.start(m, f, [{:ok, callback_rec} | a])

        {fun, batch_offset} when is_function(fun, 1) ->
          callback_rec =
            records_map
            |> Map.fetch!({topic, partition})
            |> Map.fetch!(batch_offset)
            |> Map.replace!(:offset, base_offset + batch_offset)

          Task.start(fn -> fun.({:ok, callback_rec}) end)
      end)
    end)

    grouped_errors =
      Enum.group_by(failure_list, fn {topic, partition, error_code, _base_offset} ->
        if error_code in @delivery_discard_codes do
          Logger.warning(
            "Non-retryable produce error on #{topic}:#{partition}, message discarded (error_code=#{error_code}) (client=#{inspect(client_name)}, producer=#{producer_name})",
            client: client_name,
            producer: producer_name,
            broker_id: broker_id,
            topic: topic,
            partition: partition,
            error_code: error_code
          )

          :discard
        else
          Logger.warning(
            "Produce error on #{topic}:#{partition}, message will be retried (error_code=#{error_code}) (client=#{inspect(client_name)}, producer=#{producer_name})",
            client: client_name,
            producer: producer_name,
            broker_id: broker_id,
            topic: topic,
            partition: partition,
            error_code: error_code
          )

          :retry
        end
      end)

    to_discard = grouped_errors[:discard] || []
    to_retry = grouped_errors[:retry] || []

    Enum.each(to_discard, fn {topic, partition, error_code, _base_offset} ->
      delivery_confirmation_pids
      |> Map.get({topic, partition}, [])
      |> Enum.reverse()
      |> Enum.each(fn
        {pid, _batch_offset, batch_idx} when is_pid(pid) ->
          send(pid, {:klife_produce, {:error, error_code}, batch_idx})

        {{m, f, a}, batch_offset} ->
          callback_rec =
            records_map
            |> Map.fetch!({topic, partition})
            |> Map.fetch!(batch_offset)
            |> Map.put(:error_code, error_code)

          Task.start(m, f, [{:error, callback_rec} | a])

        {fun, batch_offset} when is_function(fun, 1) ->
          callback_rec =
            records_map
            |> Map.fetch!({topic, partition})
            |> Map.fetch!(batch_offset)
            |> Map.put(:error_code, error_code)

          Task.start(fn -> fun.({:error, callback_rec}) end)
      end)
    end)

    to_retry_keys = Enum.map(to_retry, fn {t, p, _, _} -> {t, p} end)
    new_data_to_send = Map.take(data_to_send, to_retry_keys)

    if map_size(new_data_to_send) == 0 do
      GenBatcher.complete_dispatch(state.batcher_pid, req_ref)
      {:noreply, remove_request(state, req_ref)}
    else
      Process.send_after(self(), {:dispatch, req_ref}, p_config.retry_backoff_ms)
      new_req_data = %{data | data_to_send: new_data_to_send}

      new_state = %{
        state
        | requests: Map.put(requests, req_ref, new_req_data)
      }

      {:noreply, new_state}
    end
  end

  defp do_dispatch(%Request{} = data, %__MODULE__{} = state) do
    %Request{
      producer_config: %Producer{
        request_timeout_ms: req_timeout,
        delivery_timeout_ms: delivery_timeout,
        client_name: client_name,
        client_id: client_id,
        acks: acks,
        txn_id: txn_id
      },
      data_to_send: data_to_send,
      base_time: base_time,
      request_ref: req_ref
    } = data

    now = System.monotonic_time(:millisecond)
    headers = %{client_id: client_id}

    content = %{
      transactional_id: txn_id,
      acks: if(acks == :all, do: -1, else: acks),
      timeout_ms: req_timeout,
      topic_data: parse_data_before_send(data_to_send)
    }

    before_deadline? = now + req_timeout - base_time < delivery_timeout - :timer.seconds(2)

    with {:before_deadline?, true} <- {:before_deadline?, before_deadline?},
         :ok <-
           send_to_broker_async(
             client_name,
             state.broker_id,
             content,
             headers,
             req_ref,
             req_timeout
           ) do
      :ok
    else
      {:before_deadline?, false} ->
        {:error, :request_deadline}

      {:error, _reason} ->
        {:error, :retry}
    end
  end

  defp send_to_broker_async(client_name, broker_id, content, headers, req_ref, req_timeout) do
    opts = [
      async: true,
      callback_pid: self(),
      callback_ref: req_ref,
      timeout_ms: req_timeout
    ]

    Broker.send_message(M.Produce, client_name, broker_id, content, headers, opts)
  end

  defp parse_data_before_send(data_to_send) do
    data_to_send
    |> Enum.group_by(fn {k, _} -> elem(k, 0) end, fn {k, v} -> {elem(k, 1), v} end)
    |> Enum.map(fn {topic, partitions_list} ->
      %{
        name: topic,
        partition_data:
          Enum.map(partitions_list, fn {partition, batch} ->
            %{
              index: partition,
              records: Map.replace!(batch, :records, Enum.reverse(batch.records))
            }
          end)
      }
    end)
  end

  defp remove_request(%__MODULE__{} = state, req_ref) do
    %__MODULE__{requests: requests} = state
    %{state | requests: Map.delete(requests, req_ref)}
  end
end

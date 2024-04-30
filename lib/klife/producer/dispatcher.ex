defmodule Klife.Producer.Dispatcher do
  defmodule Request do
    defstruct [
      :producer_config,
      :batch_to_send,
      :delivery_confirmation_pids,
      :pool_idx,
      :base_time,
      :request_ref
    ]
  end

  defstruct [
    :batcher_pid,
    :broker_id,
    :requests
  ]

  use GenServer

  import Klife.ProcessRegistry

  alias Klife.Connection.Broker
  alias Klife.Producer
  alias Klife.Connection.MessageVersions, as: MV
  alias KlifeProtocol.Messages, as: M

  require Logger

  def start_link(args) do
    %{
      producer_name: p_name,
      cluster_name: cluster_name
    } = Keyword.fetch!(args, :producer_config)

    broker_id = Keyword.fetch!(args, :broker_id)
    batcher_id = Keyword.fetch!(args, :batcher_id)

    GenServer.start_link(__MODULE__, args,
      name: via_tuple({__MODULE__, cluster_name, broker_id, p_name, batcher_id})
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

  def dispatch(server, %__MODULE__.Request{} = data),
    do: GenServer.call(server, {:dispatch, data})

  @impl true
  def handle_call({:dispatch, %__MODULE__.Request{} = data}, _from, %__MODULE__{} = state) do
    %__MODULE__.Request{
      request_ref: request_ref,
      producer_config: %{retry_backoff_ms: retry_ms},
      pool_idx: pool_idx,
      batch_to_send: batch_to_send
    } = data

    %__MODULE__{
      batcher_pid: batcher_pid,
      requests: requests
    } = state

    case do_dispatch(data, state) do
      :ok ->
        new_state = %{state | requests: Map.put(requests, request_ref, data)}
        {:reply, :ok, new_state}

      {:error, :retry} ->
        Process.send_after(self(), {:dispatch, request_ref}, retry_ms)
        new_state = %{state | requests: Map.put(requests, request_ref, data)}
        {:reply, :ok, new_state}

      {:error, :request_deadline} ->
        failed_topic_partitions = Map.keys(batch_to_send)
        send(batcher_pid, {:bump_epoch, failed_topic_partitions})
        send(batcher_pid, {:request_completed, pool_idx})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:dispatch, req_ref}, %__MODULE__{} = state) when is_reference(req_ref) do
    data =
      %__MODULE__.Request{
        request_ref: request_ref,
        producer_config: %{retry_ms: retry_ms},
        pool_idx: pool_idx,
        batch_to_send: batch_to_send
      } = Map.fetch!(state.requests, req_ref)

    %__MODULE__{
      batcher_pid: batcher_pid,
      requests: requests
    } = state

    case do_dispatch(data, state) do
      :ok ->
        {:noreply, state}

      {:error, :retry} ->
        Process.send_after(self(), {:dispatch, request_ref}, retry_ms)
        {:noreply, state}

      {:error, :request_deadline} ->
        failed_topic_partitions = Map.keys(batch_to_send)
        send(batcher_pid, {:bump_epoch, failed_topic_partitions})
        send(batcher_pid, {:request_completed, pool_idx})

        new_state = %{state | requests: Map.delete(requests, request_ref)}
        {:noreply, new_state}
    end
  end

  @delivery_success_codes [0, 46]
  @delivery_discard_codes [18, 47]
  def handle_info({:broker_response, req_ref, binary_resp}, %__MODULE__{} = state) do
    %__MODULE__{
      batcher_pid: batcher_pid,
      requests: requests
    } = state

    data =
      %__MODULE__.Request{
        delivery_confirmation_pids: delivery_confirmation_pids,
        pool_idx: pool_idx,
        request_ref: ^req_ref,
        batch_to_send: batch_to_send,
        producer_config: %{cluster_name: cluster_name} = p_config
      } = Map.fetch!(requests, req_ref)

    {:ok, resp} = M.Produce.deserialize_response(binary_resp, MV.get(cluster_name, M.Produce))

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
      |> Enum.each(fn {pid, batch_offset} ->
        send(pid, {:klife_produce_sync, :ok, base_offset + batch_offset})
      end)
    end)

    case failure_list do
      [] ->
        send(batcher_pid, {:request_completed, pool_idx})
        {:noreply, %{state | requests: Map.delete(requests, req_ref)}}

      error_list ->
        # TODO: Enhance specific code error handling
        # TODO: One major problem with the current implementantion is that
        # one bad topic can hold the in flight request spot for a long time
        # can it be handled better without a new producer?
        grouped_errors =
          Enum.group_by(error_list, fn {topic, partition, error_code, _base_offset} ->
            cond do
              error_code in @delivery_discard_codes ->
                Logger.warning("""
                Fatal error while producing message. Message will be discarded!

                topic: #{topic}
                partition: #{partition}
                error_code: #{error_code}

                cluster: #{p_config.cluster_name}
                broker_id: #{state.broker_id}
                producer_name: #{p_config.producer_name}
                """)

                :discard

              true ->
                Logger.warning("""
                Error while producing message. Message will be retried!

                topic: #{topic}
                partition: #{partition}
                error_code: #{error_code}

                cluster: #{p_config.cluster_name}
                broker_id: #{state.broker_id}
                producer_name: #{p_config.producer_name}
                """)

                :retry
            end
          end)

        to_discard = grouped_errors[:discard] || []

        Enum.each(to_discard, fn {topic, partition, error_code, _base_offset} ->
          delivery_confirmation_pids
          |> Map.get({topic, partition}, [])
          |> Enum.reverse()
          |> Enum.each(fn {pid, _batch_offset} ->
            send(pid, {:klife_produce_sync, :error, error_code})
          end)
        end)

        to_drop_list = List.flatten([success_list, to_discard])
        to_drop_keys = Enum.map(to_drop_list, fn {t, p, _, _} -> {t, p} end)
        new_batch_to_send = Map.drop(batch_to_send, to_drop_keys)

        if Map.keys(new_batch_to_send) == [] do
          send(batcher_pid, {:request_completed, pool_idx})
          {:noreply, %{state | requests: Map.delete(requests, req_ref)}}
        else
          Process.send_after(self(), {:dispatch, req_ref}, p_config.retry_ms)
          new_req_data = %{data | batch_to_send: new_batch_to_send}
          new_state = %{state | requests: Map.put(requests, req_ref, new_req_data)}
          {:noreply, new_state}
        end
    end
  end

  defp do_dispatch(%__MODULE__.Request{} = data, %__MODULE__{} = state) do
    %__MODULE__.Request{
      producer_config: %Producer{
        request_timeout_ms: req_timeout,
        delivery_timeout_ms: delivery_timeout,
        cluster_name: cluster_name,
        client_id: client_id,
        acks: acks
      },
      batch_to_send: batch_to_send,
      base_time: base_time,
      request_ref: req_ref
    } = data

    now = System.monotonic_time(:millisecond)
    headers = %{client_id: client_id}

    content = %{
      transactional_id: nil,
      acks: if(acks == :all, do: -1, else: acks),
      timeout_ms: req_timeout,
      topic_data: parse_batch_before_send(batch_to_send)
    }

    before_deadline? = now + req_timeout - base_time < delivery_timeout - :timer.seconds(2)

    with {:before_deadline?, true} <- {:before_deadline?, before_deadline?},
         :ok <- send_to_broker_async(cluster_name, state.broker_id, content, headers, req_ref) do
      :ok
    else
      {:before_deadline?, false} ->
        {:error, :request_deadline}

      {:error, _reason} ->
        {:error, :retry}
    end
  end

  defp send_to_broker_async(cluster_name, broker_id, content, headers, req_ref) do
    opts = [
      async: true,
      callback: {__MODULE__, :broker_callback, [req_ref, self()]}
    ]

    Broker.send_message(M.Produce, cluster_name, broker_id, content, headers, opts)
  end

  def broker_callback(binary_response, req_ref, dispatcher_pid) do
    send(dispatcher_pid, {:broker_response, req_ref, binary_response})
  end

  defp parse_batch_before_send(batch_to_send) do
    batch_to_send
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
end

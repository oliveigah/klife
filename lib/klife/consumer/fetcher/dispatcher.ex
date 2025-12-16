defmodule Klife.Consumer.Fetcher.Dispatcher do
  defstruct [
    :requests,
    :broker_id,
    :batcher_pid,
    :fetcher_config,
    :rack_id
  ]

  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  alias Klife.Record
  alias Klife.GenBatcher
  alias Klife.Connection.Broker
  alias KlifeProtocol.Messages, as: M
  alias Klife.Consumer.Fetcher.Batcher

  def start_link(args) do
    %{
      name: p_name,
      client_name: client_name
    } = Keyword.fetch!(args, :fetcher_config)

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
      batcher_pid: args[:batcher_pid],
      fetcher_config: args[:fetcher_config],
      rack_id: args[:rack_id]
    }

    {:ok, state}
  end

  def dispatch(server, %Batcher.Batch{} = data),
    do: GenServer.call(server, {:dispatch, data})

  @impl true
  def handle_call({:dispatch, %Batcher.Batch{} = batch}, _from, %__MODULE__{} = state) do
    case do_dispatch(batch, state) do
      :ok ->
        new_state = put_in(state.requests[batch.dispatch_ref], batch)
        {:reply, :ok, new_state}

      {:error, reason} ->
        resp =
          batch.data
          |> Enum.map(fn {{t, p}, _item} ->
            {{t, p}, {:conn_error, reason}}
          end)
          |> Map.new()

        new_state = complete_batch(state, batch, resp)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_info(
        {:async_broker_response, req_ref, binary_resp, M.Fetch = msg_mod, msg_version},
        %__MODULE__{} = state
      ) do
    {:ok, %{content: %{responses: resp_list}}} =
      msg_mod.deserialize_response(binary_resp, msg_version)

    req_data = state.requests[req_ref].data

    result =
      for %{topic_id: t, partitions: p_list} <- resp_list,
          %{
            aborted_transactions: at,
            error_code: ec,
            partition_index: p,
            records: rec_batch_list
          } <- p_list,
          into: %{} do
        key = {t, p}

        case ec do
          0 ->
            first_aborted_offset =
              if state.fetcher_config.isolation_level == :read_committed do
                Enum.map(at, fn %{first_offset: fo} -> fo end)
                |> Enum.min(fn -> :infinity end)
              else
                :infinity
              end

            val =
              Enum.flat_map(rec_batch_list, fn rec_batch ->
                Record.parse_from_protocol(req_data[key].topic_name, p, rec_batch,
                  first_aborted_offset: first_aborted_offset
                )
              end)

            {key, {:ok, val}}

          err ->
            {key, {:error, err}}
        end
      end

    {:noreply, complete_batch(state, state.requests[req_ref], result)}
  end

  def handle_info({:check_timeout, req_ref}, %__MODULE__{requests: reqs} = state) do
    case Map.get(reqs, req_ref) do
      nil ->
        {:noreply, state}

      %Batcher.Batch{} = batch ->
        resp =
          batch.data
          |> Enum.map(fn {{t, p}, _item} -> {{t, p}, {:error, :timeout}} end)
          |> Map.new()

        {:noreply, complete_batch(state, batch, resp)}
    end
  end

  defp complete_batch(%__MODULE__{} = state, %Batcher.Batch{} = batch, resp_map) do
    Enum.each(batch.data, fn {{t, p}, %Batcher.BatchItem{} = item} ->
      case Map.get(resp_map, {t, p}) do
        nil ->
          send(
            item.__callback,
            {:klife_fetch_response, {t, p, item.offset_to_fetch}, {:error, :unkown_error}}
          )

        resp ->
          send(
            item.__callback,
            {:klife_fetch_response, {t, p, item.offset_to_fetch}, resp}
          )
      end
    end)

    :ok = GenBatcher.complete_dispatch(state.batcher_pid, batch.dispatch_ref)

    %__MODULE__{state | requests: Map.delete(state.requests, batch.dispatch_ref)}
  end

  defp do_dispatch(%Batcher.Batch{} = batch, state) do
    content =
      parse_batch_for_send(batch, state)

    headers = %{client_id: state.fetcher_config.client_id}

    opts = [
      async: true,
      callback_pid: self(),
      callback_ref: batch.dispatch_ref
    ]

    Broker.send_message(
      M.Fetch,
      state.fetcher_config.client_name,
      state.broker_id,
      content,
      headers,
      opts
    )
    |> case do
      :ok ->
        Process.send_after(
          self(),
          {:check_timeout, batch.dispatch_ref},
          state.fetcher_config.request_timeout_ms
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_batch_for_send(%Batcher.Batch{} = batch, %__MODULE__{} = state) do
    iso_lvl =
      case state.fetcher_config.isolation_level do
        :read_committed -> 1
        :read_uncommitted -> 0
      end

    parsed_data =
      Enum.group_by(batch.data, fn {{t, _p}, _v} -> t end, fn {{_t, _p}, v} -> v end)

    %{
      max_wait_ms: state.fetcher_config.max_wait_ms,
      # TODO: min_bytes as fetcher config
      min_bytes: 1,
      max_bytes: state.fetcher_config.max_bytes_per_request,
      isolation_level: iso_lvl,
      session_id: 0,
      session_epoch: 0,
      topics:
        Enum.map(parsed_data, fn {topic_id, items_list} ->
          %{
            topic_id: topic_id,
            partitions:
              Enum.map(items_list, fn %Batcher.BatchItem{} = item ->
                %{
                  partition: item.partition,
                  current_leader_epoch: -1,
                  fetch_offset: item.offset_to_fetch,
                  last_fetched_epoch: -1,
                  log_start_offset: -1,
                  partition_max_bytes: item.max_bytes
                }
              end)
          }
        end),
      forgotten_topics_data: [],
      rack_id: state.rack_id
    }
  end
end

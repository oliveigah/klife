defmodule Klife.TxnProducer do
  import Klife.ProcessRegistry

  require Logger

  alias Klife.Connection.Broker
  alias KlifeProtocol.Messages, as: M
  alias Klife.Producer.Controller, as: ProducerController

  alias Klife.Record

  @behaviour NimblePool

  @txn_producer_options [
    cluster_name: [type: :atom, required: true],
    client_id: [type: :string],
    delivery_timeout_ms: [type: :non_neg_integer, default: :timer.seconds(15)],
    request_timeout_ms: [type: :non_neg_integer, default: :timer.seconds(5)],
    retry_backoff_ms: [type: :non_neg_integer, default: :timer.seconds(1)],
    txn_timeout_ms: [type: :non_neg_integer, default: :timer.seconds(30)],
    compression_type: [type: {:in, [:none, :gzip, :snappy]}, default: :none],
    base_txn_id: [type: :string]
  ]

  defstruct Keyword.keys(@txn_producer_options) ++ [:worker_counter]

  defmodule WorkerState do
    defstruct [
      :cluster_name,
      :producer_id,
      :coordinator_id,
      :producer_epoch,
      :base_sequences,
      :txn_id,
      :worker_id,
      :pool_state
    ]
  end

  @impl NimblePool
  def init_pool(init_arg) do
    args = Keyword.take(init_arg, Keyword.keys(@txn_producer_options))
    validated_args = NimbleOptions.validate!(args, @txn_producer_options)
    args_map = Map.new(validated_args)

    base = %__MODULE__{
      client_id: "klife_txn_producer.#{args_map.cluster_name}",
      base_txn_id: :crypto.strong_rand_bytes(15) |> Base.url_encode64() |> binary_part(0, 15),
      worker_counter: 0
    }

    {:ok, Map.merge(base, args_map)}
  end

  @impl NimblePool
  def init_worker(%__MODULE__{} = pool_state) do
    %__MODULE__{
      cluster_name: cluster_name
    } = pool_state

    worker_id = pool_state.worker_counter + 1
    txn_id = "#{pool_state.base_txn_id}_#{worker_id}"

    broker_id = find_coordinator(cluster_name, txn_id)

    new_worker = %__MODULE__.WorkerState{
      cluster_name: cluster_name,
      producer_id: get_producer_id(pool_state, broker_id, txn_id),
      coordinator_id: broker_id,
      producer_epoch: 0,
      base_sequences: %{},
      txn_id: txn_id,
      worker_id: worker_id,
      pool_state: pool_state
    }

    {:ok, new_worker, %{pool_state | worker_counter: worker_id}}
  end

  defp find_coordinator(cluster_name, txn_id) do
    content = %{
      key_type: 1,
      coordinator_keys: [txn_id]
    }

    {:ok, %{content: resp}} = Broker.send_message(M.FindCoordinator, cluster_name, :any, content)

    [%{node_id: broker_id}] = resp.coordinators

    broker_id
  end

  @impl NimblePool
  def handle_checkout(:checkout, {_pid, _}, worker_state, %__MODULE__{} = pool_state) do
    {:ok, worker_state, worker_state, pool_state}
  end

  @impl NimblePool
  def handle_checkin(client_state, _from, _worker_state, %__MODULE__{} = pool_state) do
    {:ok, client_state, pool_state}
  end

  def run_txn(cluster_name, fun) do
    NimblePool.checkout!(pool_name(cluster_name), :checkout, fn _, state ->
      nil = setup_txn_ctx(state, cluster_name)

      result =
        try do
          fun.()
        catch
          _kind, reason ->
            Logger.error("Fail transaction. #{inspect({__STACKTRACE__})}")
            {:error, reason}
        end

      :ok =
        case result do
          {:ok, _} -> end_txn(cluster_name, :commit)
          :ok -> end_txn(cluster_name, :commit)
          _ -> end_txn(cluster_name, :abort)
        end

      %{worker_state: ws} = clean_txn_ctx(cluster_name)
      {result, ws}
    end)
  end

  defp end_txn(cluster_name, action) do
    committed? =
      case action do
        :commit -> true
        :abort -> false
      end

    %{
      worker_state: %__MODULE__.WorkerState{
        producer_id: p_id,
        producer_epoch: p_epoch,
        coordinator_id: b_id,
        txn_id: txn_id,
        pool_state: %__MODULE__{} = pool_state
      }
    } = get_txn_ctx(cluster_name)

    content = %{
      transactional_id: txn_id,
      producer_id: p_id,
      producer_epoch: p_epoch,
      committed: committed?
    }

    headers = %{client_id: pool_state.client_id}

    {:ok, %{content: %{error_code: 0}}} =
      Broker.send_message(M.EndTxn, cluster_name, b_id, content, headers)

    :ok
  end

  def produce(records, cluster_name, _opts) do
    txn_ctx =
      %{
        worker_state:
          %__MODULE__.WorkerState{
            producer_id: p_id,
            producer_epoch: p_epoch,
            coordinator_id: b_id,
            txn_id: txn_id,
            pool_state: %__MODULE__{} = pool_state,
            base_sequences: base_sequences
          } = worker_state,
        topic_partitions: txn_topic_partitions
      } = get_txn_ctx(cluster_name)

    recs_by_tp = Enum.group_by(records, fn %Record{} = r -> {r.topic, r.partition} end)

    new_topics_partitions =
      recs_by_tp
      |> Map.keys()
      |> Enum.reject(fn {t, p} -> MapSet.member?(txn_topic_partitions, {t, p}) end)
      |> Enum.group_by(fn {t, _p} -> t end, fn {_t, p} -> p end)

    txn_ctx =
      if new_topics_partitions != %{} do
        content = %{
          transactions: [
            %{
              transactional_id: txn_id,
              producer_id: p_id,
              producer_epoch: p_epoch,
              verify_only: false,
              topics:
                Enum.map(new_topics_partitions, fn {t, partitions} ->
                  %{
                    name: t,
                    partitions: partitions
                  }
                end)
            }
          ]
        }

        {:ok, %{content: %{error_code: 0}}} =
          Broker.send_message(M.AddPartitionsToTxn, cluster_name, b_id, content)

        new_txn_topic_partitions =
          Enum.reduce(new_topics_partitions, txn_topic_partitions, fn {t, pts}, acc ->
            Enum.reduce(pts, acc, fn p, acc2 -> MapSet.put(acc2, {t, p}) end)
          end)

        update_txn_ctx(cluster_name, %{txn_ctx | topic_partitions: new_txn_topic_partitions})
      else
        txn_ctx
      end

    callback_refs =
      recs_by_tp
      |> Enum.map(fn {{t, p}, recs} ->
        %{broker_id: broker_id} =
          ProducerController.get_topics_partitions_metadata(cluster_name, t, p)

        {broker_id, recs}
      end)
      |> Enum.map(fn {b, recs} ->
        content = %{
          transactional_id: txn_id,
          acks: -1,
          timeout_ms: :timer.seconds(5),
          topic_data: build_partition_data(recs, worker_state)
        }

        headers = %{client_id: pool_state.client_id}
        req_ref = make_ref()

        opts = [
          async: true,
          callback_pid: self(),
          callback_ref: req_ref
        ]

        :ok = Broker.send_message(M.Produce, cluster_name, b, content, headers, opts)
      end)

    base_offsets =
      for %{name: topic, partition_responses: pr} <- wait_responses(10_000, callback_refs),
          %{base_offset: base_offset, error_code: 0, index: partition} <- pr,
          into: %{} do
        {{topic, partition}, base_offset}
      end

    new_base_sequences =
      Enum.reduce(recs_by_tp, base_sequences, fn {{t, p}, recs}, acc ->
        key = {t, p}

        case Map.get(acc, key) do
          nil -> Map.put(acc, key, length(recs))
          curr -> Map.replace(acc, key, curr + length(recs))
        end
      end)

    _txn_ctx =
      update_txn_ctx(cluster_name, %{
        txn_ctx
        | worker_state: %{worker_state | base_sequences: new_base_sequences}
      })

    Enum.map_reduce(records, base_offsets, fn %Record{} = rec, offsets ->
      key = {rec.topic, rec.partition}
      rec_offset = Map.fetch!(offsets, key)
      {{:ok, %{rec | offset: rec_offset}}, Map.replace!(offsets, key, rec_offset + 1)}
    end)
    |> elem(0)
  end

  defp wait_responses(timeout_ms, refs) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_responses(deadline, length(refs), 0, [])
  end

  defp do_wait_responses(_deadline, max_resps, max_resps, resps), do: List.flatten(resps)

  defp do_wait_responses(deadline, max_resps, counter, resps) do
    now = System.monotonic_time(:millisecond)

    if deadline > now do
      receive do
        {:async_broker_response, _req_ref, binary_resp, M.Produce = msg_mod, msg_version} ->
          {:ok, resp} = apply(msg_mod, :deserialize_response, [binary_resp, msg_version])
          new_counter = counter + 1
          do_wait_responses(deadline, max_resps, new_counter, [resp.content.responses | resps])
      after
        deadline - now ->
          do_wait_responses(deadline, max_resps, counter, resps)
      end
    else
      raise "transaction timeout"
    end
  end

  defp build_partition_data([%Record{} | _] = recs, worker_state) do
    recs
    |> Enum.group_by(fn rec -> rec.topic end)
    |> Enum.map(fn {t, recs} -> {t, Enum.group_by(recs, fn r -> r.partition end)} end)
    |> Enum.map(fn {t, partitions_data} ->
      %{
        name: t,
        partition_data:
          Enum.map(partitions_data, fn {p, recs} ->
            pd = init_partition_data(worker_state, t, p)

            batch =
              Enum.reduce(recs, pd, fn %Record{} = rec, acc ->
                add_record_to_partition_data(acc, rec)
              end)

            %{
              index: p,
              records: Map.replace!(batch, :records, Enum.reverse(batch.records))
            }
          end)
      }
    end)
  end

  defp init_partition_data(
         %__MODULE__.WorkerState{
           base_sequences: bs,
           producer_epoch: p_epoch,
           producer_id: producer_id
         } = _state,
         topic,
         partition
       ) do
    key = {topic, partition}

    base_seq = Map.get(bs, key, 0)

    %{
      base_offset: 0,
      partition_leader_epoch: -1,
      magic: 2,
      # TODO: How to handle attributes here?
      attributes: KlifeProtocol.RecordBatch.encode_attributes(is_transactional: true),
      last_offset_delta: -1,
      base_timestamp: nil,
      max_timestamp: nil,
      producer_id: producer_id,
      producer_epoch: p_epoch,
      base_sequence: base_seq,
      records: [],
      records_length: 0
    }
  end

  defp add_record_to_partition_data(batch, %Record{} = record) do
    now = DateTime.to_unix(DateTime.utc_now())

    new_offset_delta = batch.last_offset_delta + 1
    timestamp_delta = if batch.base_timestamp == nil, do: 0, else: now - batch.base_timestamp

    new_rec = %{
      attributes: 0,
      timestamp_delta: timestamp_delta,
      offset_delta: new_offset_delta,
      key: record.key,
      value: record.value,
      headers: record.headers
    }

    %{
      batch
      | records: [new_rec | batch.records],
        records_length: batch.records_length + 1,
        last_offset_delta: new_offset_delta,
        max_timestamp: now,
        base_timestamp: min(batch.base_timestamp, now)
    }
  end

  def in_txn?(cluster), do: not is_nil(get_txn_ctx(cluster))

  defp setup_txn_ctx(state, cluster),
    do:
      Process.put({:klife_txn_ctx, cluster}, %{
        worker_state: state,
        topic_partitions: MapSet.new()
      })

  defp clean_txn_ctx(cluster), do: Process.delete({:klife_txn_ctx, cluster})

  defp get_txn_ctx(cluster), do: Process.get({:klife_txn_ctx, cluster})

  defp update_txn_ctx(cluster, new_state) do
    Process.put({:klife_txn_ctx, cluster}, new_state)
    new_state
  end

  def start_link(opts) do
    cluster_name = Keyword.fetch!(opts, :cluster_name)

    NimblePool.start_link(
      worker: {__MODULE__, opts},
      pool_size: 1,
      lazy: true,
      name: pool_name(cluster_name)
    )
  end

  def child_spec(opts) do
    cluster_name = Keyword.fetch!(opts, :cluster_name)

    %{
      id: {__MODULE__, cluster_name},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  defp pool_name(cluster_name), do: via_tuple({TxnProducerPool, cluster_name})

  defp get_producer_id(%__MODULE__{} = pool_state, broker_id, txn_id) do
    %__MODULE__{
      cluster_name: cluster_name,
      txn_timeout_ms: txn_timeout_ms
    } = pool_state

    content = %{
      transactional_id: txn_id,
      transaction_timeout_ms: txn_timeout_ms
    }

    {:ok, %{content: %{error_code: 0, producer_id: producer_id}}} =
      Broker.send_message(M.InitProducerId, cluster_name, broker_id, content)

    producer_id
  end
end

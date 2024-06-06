defmodule Klife.TxnProducerPool do
  import Klife.ProcessRegistry

  require Logger

  alias Klife.Connection.Broker
  alias KlifeProtocol.Messages, as: M

  alias Klife.Producer

  alias Klife.Record

  @behaviour NimblePool

  @txn_producer_options [
    cluster_name: [type: :atom, required: true],
    name: [type: :atom, required: true]
  ]

  defstruct Keyword.keys(@txn_producer_options) ++ [:worker_counter]

  defmodule WorkerState do
    defstruct [
      :worker_id,
      :producer_name,
      :cluster_name,
      :producer_id,
      :producer_epoch,
      :coordinator_id,
      :txn_id,
      :client_id
    ]
  end

  @impl NimblePool
  def init_pool(init_arg) do
    args = Keyword.take(init_arg, Keyword.keys(@txn_producer_options))
    validated_args = NimbleOptions.validate!(args, @txn_producer_options)
    args_map = Map.new(validated_args)

    base_map = %__MODULE__{
      worker_counter: 0
    }

    {:ok, Map.merge(base_map, args_map)}
  end

  @impl NimblePool
  def init_worker(%__MODULE__{} = pool_state) do
    worker_id = pool_state.worker_counter + 1
    worker = do_init_worker(pool_state, worker_id)
    {:ok, worker, %{pool_state | worker_counter: worker_id}}
  end

  defp do_init_worker(%__MODULE__{} = pool_state, worker_id) do
    %__MODULE__{cluster_name: cluster_name, name: pool_name} = pool_state
    producer_name = :"klife_txn_producer.#{pool_name}.#{worker_id}"

    {:ok,
     %{
       producer_id: producer_id,
       producer_epoch: producer_epoch,
       coordinator_id: coordinator_id,
       txn_id: txn_id,
       client_id: client_id
     }} = Producer.get_txn_pool_data(cluster_name, producer_name)

    %__MODULE__.WorkerState{
      cluster_name: cluster_name,
      producer_name: producer_name,
      producer_id: producer_id,
      producer_epoch: producer_epoch,
      coordinator_id: coordinator_id,
      txn_id: txn_id,
      client_id: client_id,
      worker_id: worker_id
    }
  end

  @impl NimblePool
  def handle_checkout(:checkout, {_pid, _}, worker_state, %__MODULE__{} = pool_state) do
    {:ok, worker_state, worker_state, pool_state}
  end

  @impl NimblePool
  def handle_checkin(
        {:error, _reason},
        _from,
        %__MODULE__.WorkerState{} = worker_state,
        %__MODULE__{} = pool_state
      ) do
    {:ok, do_init_worker(pool_state, worker_state.worker_id), pool_state}
  end

  def handle_checkin(
        %__MODULE__.WorkerState{} = client_worker_state,
        _from,
        _worker_state,
        pool_state
      ) do
    {:ok, client_worker_state, pool_state}
  end

  def run_txn(cluster_name, pool_name, fun) do
    NimblePool.checkout!(pool_name(cluster_name, pool_name), :checkout, fn _, state ->
      nil = setup_txn_ctx(state, cluster_name)

      result =
        try do
          fun.()
        catch
          _kind, reason ->
            Logger.error(
              "Failed transaction reason #{inspect(reason)}. #{inspect({__STACKTRACE__})}"
            )

            {:error, reason}
        end

      :ok =
        case result do
          {:ok, _} -> end_txn(cluster_name, :commit)
          :ok -> end_txn(cluster_name, :commit)
          _ -> end_txn(cluster_name, :abort)
        end

      %{worker_state: ws} = clean_txn_ctx(cluster_name)

      case result do
        {:error, _reason} ->
          {result, result}

        _ ->
          {result, ws}
      end
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
        coordinator_id: coordinator_id,
        txn_id: txn_id,
        client_id: client_id
      }
    } = get_txn_ctx(cluster_name)

    content = %{
      transactional_id: txn_id,
      producer_id: p_id,
      producer_epoch: p_epoch,
      committed: committed?
    }

    headers = %{client_id: client_id}

    {:ok, %{content: %{error_code: ec}}} =
      Broker.send_message(M.EndTxn, cluster_name, coordinator_id, content, headers)

    if committed? do
      0 = ec
    else
      true = ec in [0, 48]
    end

    :ok
  end

  def produce(records, cluster_name, _opts) do
    :ok = maybe_add_partition_to_txn(cluster_name, records)

    %{
      worker_state: %__MODULE__.WorkerState{producer_name: producer_name}
    } =
      get_txn_ctx(cluster_name)

    resp = Klife.Producer.produce(records, cluster_name, producer: producer_name)

    case Enum.find(resp, &match?({:error, _}, &1)) do
      nil -> resp
      err -> raise "error on produce txn. #{inspect(err)}"
    end
  end

  defp maybe_add_partition_to_txn(cluster_name, records) do
    tp_list = Enum.map(records, fn %Record{} = r -> {r.topic, r.partition} end)

    txn_ctx =
      %{
        worker_state: %__MODULE__.WorkerState{
          producer_id: p_id,
          cluster_name: cluster_name,
          txn_id: txn_id,
          producer_epoch: p_epoch,
          coordinator_id: coordinator_id
        },
        topic_partitions: txn_topic_partitions
      } = get_txn_ctx(cluster_name)

    grouped_tp_list =
      tp_list
      |> Enum.group_by(fn {t, _p} -> t end, fn {_t, p} -> p end)
      |> Map.to_list()

    content = %{
      transactions: [
        %{
          transactional_id: txn_id,
          producer_id: p_id,
          producer_epoch: p_epoch,
          verify_only: false,
          topics:
            Enum.map(grouped_tp_list, fn {t, partitions} ->
              %{
                name: t,
                partitions: partitions
              }
            end)
        }
      ]
    }

    :ok = add_partitions_to_txn(cluster_name, coordinator_id, content)

    new_txn_topic_partitions =
      Enum.reduce(tp_list, txn_topic_partitions, fn {t, p}, acc ->
        MapSet.put(acc, {t, p})
      end)

    update_txn_ctx(cluster_name, %{txn_ctx | topic_partitions: new_txn_topic_partitions})

    :ok
  end

  defp add_partitions_to_txn(cluster_name, coordinator_id, content) do
    deadline = System.monotonic_time(:millisecond) + :timer.seconds(10)
    do_add_partitions_to_txn(deadline, cluster_name, coordinator_id, content)
  end

  # TODO: Refactor this
  defp do_add_partitions_to_txn(deadline, cluster_name, coordinator_id, content) do
    if System.monotonic_time(:millisecond) < deadline do
      with {:ok, %{content: %{error_code: 0} = resp_content}} <-
             Broker.send_message(M.AddPartitionsToTxn, cluster_name, coordinator_id, content),
           %{results_by_transaction: [txn_resp]} <- resp_content,
           %{topic_results: t_results} <- txn_resp,
           true <-
             Enum.all?(t_results, fn t_result ->
               Enum.all?(t_result.results_by_partition, fn p_result ->
                 p_result.partition_error_code == 0
               end)
             end) do
        :ok
      else
        _err ->
          Process.sleep(Enum.random(10..50))
          do_add_partitions_to_txn(deadline, cluster_name, coordinator_id, content)
      end
    else
      raise "timeout while adding partition to txn"
    end
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
    NimblePool.start_link(
      worker: {__MODULE__, opts},
      pool_size: opts[:pool_size],
      name: pool_name(opts[:cluster_name], opts[:name]),
      lazy: false
    )
  end

  def child_spec(opts) do
    cluster_name = Keyword.fetch!(opts, :cluster_name)

    %{
      id: pool_name(cluster_name, opts[:name]),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  defp pool_name(cluster_name, pool_name), do: via_tuple({__MODULE__, cluster_name, pool_name})
end

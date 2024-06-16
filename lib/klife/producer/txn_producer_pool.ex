defmodule Klife.TxnProducerPool do
  import Klife.ProcessRegistry, only: [via_tuple: 1]

  require Logger

  alias Klife.Connection.Broker
  alias KlifeProtocol.Messages, as: M

  alias Klife.Producer

  alias Klife.Record

  @behaviour NimblePool

  @txn_producer_specific_opts [
    name: [
      type: :atom,
      required: true,
      doc: "Pool name. Can be used as an option on the transactional api"
    ],
    base_txn_id: [
      type: :string,
      required: false,
      default: "",
      doc:
        "Prefix used to define the `transactional_id` for the transactional producers. If not provided, a random string will be used."
    ],
    pool_size: [
      type: :non_neg_integer,
      default: 20,
      doc: "Number of transactional producers in the pool"
    ],
    txn_timeout_ms: [
      type: :non_neg_integer,
      default: :timer.seconds(90),
      doc:
        "The maximum amount of time, in milliseconds, that a transactional producer is allowed to remain open without either committing or aborting a transaction before it is considered expired"
    ]
  ]

  @txn_producer_options Producer.get_opts()
                        |> Keyword.take([
                          :delivery_timeout_ms,
                          :request_timeout_ms,
                          :retry_backoff_ms,
                          :compression_type
                        ])
                        |> Keyword.merge(@txn_producer_specific_opts)

  defstruct Keyword.keys(@txn_producer_options) ++ [:worker_counter, :client_name]

  @moduledoc """
  Pool of transactional producers.

  ## Configurations

  #{NimbleOptions.docs(@txn_producer_options)}
  """
  def get_opts, do: @txn_producer_options

  defmodule WorkerState do
    @moduledoc false
    defstruct [
      :worker_id,
      :producer_name,
      :client_name,
      :producer_id,
      :producer_epoch,
      :coordinator_id,
      :txn_id,
      :client_id
    ]
  end

  @impl NimblePool
  def init_pool(init_arg) do
    args = Map.take(init_arg, Map.keys(%__MODULE__{}))
    base_map = %__MODULE__{worker_counter: 0}
    {:ok, Map.merge(base_map, args)}
  end

  @impl NimblePool
  def init_worker(%__MODULE__{} = pool_state) do
    worker_id = pool_state.worker_counter + 1

    %__MODULE__{client_name: client_name, name: pool_name} = pool_state

    producer_name = :"klife_txn_producer.#{pool_name}.#{worker_id}"

    case Producer.get_pid(client_name, producer_name) do
      nil ->
        # if we get here we should probally just restart the pool
        {:error, {:unkown_producer, client_name, producer_name}}

      _ ->
        worker = %__MODULE__.WorkerState{
          client_name: client_name,
          producer_name: producer_name,
          worker_id: worker_id
        }

        {:ok, worker, %{pool_state | worker_counter: worker_id}}
    end
  end

  @impl NimblePool
  def handle_checkout(:checkout, {_pid, _}, worker_state, %__MODULE__{} = pool_state) do
    {:ok, worker_state, worker_state, pool_state}
  end

  @impl NimblePool
  def handle_checkin(_client_state, _from, %__MODULE__.WorkerState{} = worker_state, pool_state) do
    {:ok, worker_state, pool_state}
  end

  def run_txn(client_name, pool_name, fun) do
    NimblePool.checkout!(pool_name(client_name, pool_name), :checkout, fn _, state ->
      result =
        try do
          nil = setup_txn_ctx(state, client_name)

          result = fun.()

          :ok =
            case result do
              {:ok, _} -> end_txn(client_name, :commit)
              :ok -> end_txn(client_name, :commit)
              _ -> end_txn(client_name, :abort)
            end

          result
        catch
          _kind, reason ->
            Logger.error(
              "Failed kafka transaction reason #{inspect(reason)}. #{inspect({__STACKTRACE__})}"
            )

            {:error, reason}
        end

      clean_txn_ctx(client_name)

      {result, state}
    end)
  end

  defp end_txn(client_name, action) do
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
    } = get_txn_ctx(client_name)

    content = %{
      transactional_id: txn_id,
      producer_id: p_id,
      producer_epoch: p_epoch,
      committed: committed?
    }

    headers = %{client_id: client_id}

    {:ok, %{content: %{error_code: ec}}} =
      Broker.send_message(M.EndTxn, client_name, coordinator_id, content, headers)

    if committed?,
      do: 0 = ec,
      else: true = ec in [0, 48]

    :ok
  end

  def produce(records, client_name, _opts) do
    case maybe_add_partition_to_txn(client_name, records) do
      :ok ->
        %{
          worker_state: %__MODULE__.WorkerState{producer_name: producer_name}
        } =
          get_txn_ctx(client_name)

        Klife.Producer.produce(records, client_name, producer: producer_name)

      {:error, recs} ->
        recs
    end
  end

  defp maybe_add_partition_to_txn(client_name, records) do
    tp_list = Enum.map(records, fn %Record{} = r -> {r.topic, r.partition} end)

    txn_ctx =
      %{
        worker_state: %__MODULE__.WorkerState{
          producer_id: p_id,
          client_name: client_name,
          txn_id: txn_id,
          producer_epoch: p_epoch,
          coordinator_id: coordinator_id
        },
        topic_partitions: txn_topic_partitions
      } = get_txn_ctx(client_name)

    case Enum.reject(tp_list, fn tp -> MapSet.member?(txn_topic_partitions, tp) end) do
      [] ->
        :ok

      to_add_tp_list ->
        grouped_tp_list =
          to_add_tp_list
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

        case add_partitions_to_txn(client_name, coordinator_id, content) do
          :ok ->
            new_txn_topic_partitions =
              Enum.reduce(tp_list, txn_topic_partitions, fn {t, p}, acc ->
                MapSet.put(acc, {t, p})
              end)

            update_txn_ctx(client_name, %{txn_ctx | topic_partitions: new_txn_topic_partitions})

            :ok

          {:error, tp_error_list} ->
            error_map = Map.new(tp_error_list)

            resp =
              records
              |> Enum.map(fn r ->
                %{r | error_code: Map.get(error_map, {r.topic, r.partition})}
              end)
              |> Enum.map(fn r ->
                if r.error_code == 0, do: {:ok, r}, else: {:error, r}
              end)

            {:error, resp}
        end
    end
  end

  defp add_partitions_to_txn(client_name, coordinator_id, content) do
    deadline = System.monotonic_time(:millisecond) + :timer.seconds(10)
    do_add_partitions_to_txn(deadline, client_name, coordinator_id, content)
  end

  defp do_add_partitions_to_txn(deadline, client_name, coordinator_id, content) do
    if System.monotonic_time(:millisecond) < deadline do
      with {:ok, %{content: %{error_code: 0} = resp_content}} <-
             Broker.send_message(M.AddPartitionsToTxn, client_name, coordinator_id, content),
           %{results_by_transaction: [txn_resp]} <- resp_content,
           :ok <- check_add_partitions_resp(txn_resp) do
        :ok
      else
        {:error, :stop, error_codes} ->
          {:error, error_codes}

        _ ->
          Process.sleep(10)
          do_add_partitions_to_txn(deadline, client_name, coordinator_id, content)
      end
    else
      raise "timeout while adding partition to txn"
    end
  end

  defp check_add_partitions_resp(%{topic_results: t_results}) do
    result_set =
      for t_result <- t_results, p_result <- t_result.results_by_partition, into: MapSet.new() do
        p_result.partition_error_code
      end

    # TODO: Which error codes should be added here?
    ok_set = MapSet.new([0])
    stop_set = MapSet.new([3])

    cond do
      MapSet.subset?(result_set, ok_set) ->
        :ok

      not MapSet.disjoint?(result_set, stop_set) ->
        errors =
          for t_result <- t_results, p_result <- t_result.results_by_partition do
            {{t_result.name, p_result.partition_index}, p_result.partition_error_code}
          end
          |> Enum.reject(&is_nil/1)

        {:error, :stop, errors}

      true ->
        :retry
    end
  end

  def in_txn?(client), do: not is_nil(get_txn_ctx(client))

  defp setup_txn_ctx(%__MODULE__.WorkerState{} = state, client) do
    {:ok,
     %{
       producer_id: producer_id,
       producer_epoch: producer_epoch,
       coordinator_id: coordinator_id,
       txn_id: txn_id,
       client_id: client_id
     }} = Producer.get_txn_pool_data(state.client_name, state.producer_name)

    new_state = %{
      state
      | producer_id: producer_id,
        producer_epoch: producer_epoch,
        coordinator_id: coordinator_id,
        txn_id: txn_id,
        client_id: client_id
    }

    Process.put({:klife_txn_ctx, client}, %{
      worker_state: new_state,
      topic_partitions: MapSet.new()
    })
  end

  defp clean_txn_ctx(client), do: Process.delete({:klife_txn_ctx, client})

  defp get_txn_ctx(client), do: Process.get({:klife_txn_ctx, client})

  defp update_txn_ctx(client, new_state) do
    Process.put({:klife_txn_ctx, client}, new_state)
    new_state
  end

  @doc false
  def start_link(args) do
    NimblePool.start_link(
      worker: {__MODULE__, args},
      pool_size: args.pool_size,
      name: pool_name(args.client_name, args.name),
      lazy: false
    )
  end

  @doc false
  def child_spec(args) do
    %{
      id: pool_name(args.client_name, args.name),
      start: {__MODULE__, :start_link, [args]},
      type: :worker,
      restart: :permanent
    }
  end

  defp pool_name(client_name, pool_name), do: via_tuple({__MODULE__, client_name, pool_name})
end

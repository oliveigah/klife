defmodule Klife.Cluster do
  alias Klife
  alias Klife.Record

  @input_options [
    connection: [
      type: :non_empty_keyword_list,
      required: true,
      keys: Klife.Connection.Controller.get_opts()
    ],
    txn_pools: [
      type: {:list, {:keyword_list, Klife.TxnProducerPool.get_opts()}},
      type_doc: "List of `Klife.TxnProducerPool` configurations",
      required: false,
      doc:
        "List of configurations, each starting a pool of transactional producers for use with transactional api. A default pool is always created."
    ],
    producers: [
      type: {:list, {:keyword_list, Klife.Producer.get_opts()}},
      type_doc: "List of `Klife.Producer` configurations",
      required: false,
      doc:
        "List of configurations, each starting a new producer for use with produce api. A default producer is always created."
    ],
    topics: [type: {:list, :map}, required: false]
  ]
  @moduledoc """

  Configuration options:

  #{NimbleOptions.docs(@input_options)}

  """

  defmacro __using__(opts) do
    input_opts = @input_options

    quote bind_quoted: [opts: opts, input_opts: input_opts] do
      use Supervisor
      @otp_app opts[:otp_app]
      @input_opts input_opts

      # Startup API
      def start_link(args) do
        Supervisor.start_link(__MODULE__, args, name: __MODULE__)
      end

      @impl true
      def init(_args) do
        config = Application.get_env(@otp_app, __MODULE__)

        default_producer = [name: :klife_default_producer]
        default_txn_pool = [name: :klife_txn_pool]

        enriched_config =
          config
          |> Keyword.update(:producers, [], fn l -> [default_producer | l] end)
          |> Keyword.update(:txn_pools, [], fn l -> [default_txn_pool | l] end)
          |> Keyword.update!(:topics, fn ts ->
            Enum.map(ts, fn t -> Map.put_new(t, :producer, default_producer[:name]) end)
          end)

        validated_opts = NimbleOptions.validate!(enriched_config, @input_opts)
        cluster_name_kw = [{:cluster_name, __MODULE__}]

        conn_opts =
          validated_opts
          |> Keyword.fetch!(:connection)
          |> Keyword.merge(cluster_name_kw)

        producer_opts =
          validated_opts
          |> Keyword.take([:producers, :txn_pools, :topics])
          |> Keyword.merge(cluster_name_kw)

        children = [
          {Klife.Connection.Supervisor, conn_opts},
          {Klife.Producer.Supervisor, producer_opts}
        ]

        Supervisor.init(children, strategy: :one_for_one)
      end

      # Produce API
      def produce(%Record{} = rec, opts \\ []), do: Klife.produce(rec, __MODULE__, opts)
      def produce_batch(recs, opts \\ []), do: Klife.produce_batch(recs, __MODULE__, opts)
      def produce_batch_txn(recs, opts \\ []), do: Klife.produce_batch_txn(recs, __MODULE__, opts)
      def transaction(fun, opts \\ []), do: Klife.transaction(fun, __MODULE__, opts)
    end
  end
end

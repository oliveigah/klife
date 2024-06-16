defmodule Klife.Client do
  alias Klife
  alias Klife.Record

  @type record :: Klife.Record.t()
  @type list_of_records :: list(record)

  @default_producer_name :klife_default_producer
  @default_txn_pool :klife_default_txn_pool

  @doc false
  def default_producer_name(), do: @default_producer_name

  @doc false
  def default_txn_pool_name(), do: @default_txn_pool

  @input_options [
    connection: [
      type: :non_empty_keyword_list,
      required: true,
      keys: Klife.Connection.Controller.get_opts()
    ],
    default_txn_pool: [
      type: :atom,
      required: false,
      default: @default_txn_pool,
      doc:
        "Name of the txn pool to be used on transactions when a `:pool_name` is not provided as an option."
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
    topics: [
      type: {:list, {:non_empty_keyword_list, Klife.Topic.get_opts()}},
      type_doc: "List of `Klife.Topic` configurations",
      required: true,
      doc: "List of topics that will be managed by the client"
    ]
  ]

  @moduledoc """
  Defines a kafka client.

  To use it you must do 3 steps:
  - Use it in a module
  - Config the module on your config file
  - Start the module on your supervision tree

  ## Using it in a module

  When used it expects an `:otp_app` option that is the OTP application that has the client configuration.

  ```elixir
  defmodule MyApp.MyTestClient do
    use Klife.Client, otp_app: :my_app
  end
  ```

  > #### `use Klife.Client` {: .info}
  >
  > When you `use Klife.Client`, it will extend your module in two ways:
  >
  > - Define it as a proxy to a subset of the functions on `Klife` module,
  > using it's module's name as the `client_name` parameter.
  > One example of this is the `MyTestClient.produce/2` that forwards
  > both arguments to `Klife.produce/3` and inject `MyTestClient` as the
  > second argument.
  >
  > - Define it as a supervisor by calling `use Supervisor` and implementing
  > some related functions such as `start_link/1` and `init/1`, so it can be
  > started under on your app supervision tree.


  ## Configuration

  The client has a bunch of configuration options, you can read more below.
  But it will look somehting like this:

  ```elixir
  config :my_app, MyApp.Client,
    connection: [
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      ssl: false
    ],
    producers: [
      [
        name: :my_custom_producer,
        linger_ms: 5,
        max_in_flight_requests: 10
      ]
    ],
    topics: [
      [name: "my_topic_0", producer: :my_custom_producer],
      [name: "my_topic_1"]
    ]

  ```

  You can see more configuration examples on the ["Client configuration examples"](guides/examples/client_configuration.md) section.

  Configuration options:

  #{NimbleOptions.docs(@input_options)}


  ## Starting it

  Finally, it must be started on your application. It will look something like this:

  ```elixir
  defmodule MyApp.Application do
    def start(_type, _args) do
      children = [
        # some other modules...,
        MyApp.MyTestClient
      ]

      opts = [strategy: :one_for_one, name: MyApp.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end
  ```

  ## Interacting with Producer API

  In order to interact with the producer API you will work with `Klife.Record` module
  as your main input and output data structure.

  Usually you will give an record to some producer API function and it will return an
  enriched record with some new attributes based on what happened.

  As an input the `Klife.Record` may have the following attributes:
  - value (required)
  - key (optional)
  - headers (optional)
  - topic (required)
  - partition (optional)

  As an output the input record will be enriched with one or more the following attributes:
  - offset (if it was succesfully written)
  - partition (if the partition was provided by a partitioner)
  - error_code ([kafka protocol error code](https://kafka.apache.org/11/protocol.html#protocol_error_codes))

  So in summary the interaction goes like this:
  - Build one or more `Klife.Record`
  - Pass it to some producer API function
  - Receive an enriched version of the provided records


  ```elixir
  rec = %Klife.Record{value: "some_val", topic: "my_topic"}
  {:ok, %Klife.Record{offset: offset, partition: partition}} = MyTestClient.produce(rec)
  ```

  """

  @doc group: "Producer API"
  @doc """
  Produce a single record.

  It expects a `Klife.Record` struct containg at least `:value` and `:topic` and returns
  an ok/error tuple along side with the enriched version of the input record.

  The record's enriched attribute may be:
    - :offset, when the record is successfully produced
    - :partition, when it is not set on the input
    - :error_code, kafka's server error code

  ## Examples

    iex> rec = %Klife.Record{value: "my_val", topic: "my_topic"}
    iex> {:ok, %Klife.Record{} = enriched_rec} = MyTestClient.produce(rec)
    iex> true = is_number(enriched_rec.offset)
    iex> true = is_number(enriched_rec.partition)

  """
  @callback produce(record, opts :: Keyword.t()) :: {:ok, record} | {:error, record}

  @doc group: "Producer API"
  @callback produce_batch(list_of_records, opts :: Keyword.t()) :: list({:ok | :error, record})

  @doc group: "Transaction API"
  @callback produce_batch_txn(list_of_records, opts :: Keyword.t()) ::
              {:ok, list_of_records} | {:error, list_of_records}

  @doc group: "Transaction API"
  @callback transaction(fun :: function(), opts :: Keyword.t()) :: any()

  @doc group: "Transaction API"
  @callback in_txn?() :: true | false

  defmacro __using__(opts) do
    input_opts = @input_options

    quote bind_quoted: [opts: opts, input_opts: input_opts] do
      @behaviour Klife.Client

      use Supervisor
      @otp_app opts[:otp_app]
      @input_opts input_opts

      # Startup API
      @doc false
      def start_link(args) do
        Supervisor.start_link(__MODULE__, args, name: __MODULE__)
      end

      defp default_txn_pool_key(), do: {__MODULE__, :default_txn_pool}
      def get_default_txn_pool(), do: :persistent_term.get(default_txn_pool_key())

      @doc false
      @impl Supervisor
      def init(_args) do
        config = Application.get_env(@otp_app, __MODULE__)

        default_producer = [name: Klife.Client.default_producer_name()]
        default_txn_pool = [name: Klife.Client.default_txn_pool_name()]

        enriched_config =
          config
          |> Keyword.update(:producers, [], fn l -> [default_producer | l] end)
          |> Keyword.update(:txn_pools, [], fn l -> [default_txn_pool | l] end)

        validated_opts =
          enriched_config
          |> NimbleOptions.validate!(@input_opts)
          |> Keyword.update!(:producers, fn l -> Enum.map(l, &Map.new/1) end)
          |> Keyword.update!(:txn_pools, fn l -> Enum.map(l, &Map.new/1) end)
          |> Keyword.update!(:topics, fn l -> Enum.map(l, &Map.new/1) end)

        client_name_map = %{}

        conn_opts =
          validated_opts
          |> Keyword.fetch!(:connection)
          |> Map.new()
          |> Map.put(:client_name, __MODULE__)

        producer_opts =
          validated_opts
          |> Keyword.take([:producers, :txn_pools, :topics])
          |> Keyword.merge(client_name: __MODULE__)
          |> Map.new()

        children = [
          {Klife.Connection.Supervisor, conn_opts},
          {Klife.Producer.Supervisor, producer_opts}
        ]

        :persistent_term.put(default_txn_pool_key(), validated_opts[:default_txn_pool])

        Supervisor.init(children, strategy: :one_for_one)
      end

      def produce(%Record{} = rec, opts \\ []), do: Klife.produce(rec, __MODULE__, opts)
      def produce_batch(recs, opts \\ []), do: Klife.produce_batch(recs, __MODULE__, opts)
      def produce_batch_txn(recs, opts \\ []), do: Klife.produce_batch_txn(recs, __MODULE__, opts)
      def transaction(fun, opts \\ []), do: Klife.transaction(fun, __MODULE__, opts)
      def in_txn?(), do: Klife.in_txn?(__MODULE__)
    end
  end
end

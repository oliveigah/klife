defmodule Klife.Client do
  alias Klife
  alias Klife.Record

  @type record :: Klife.Record.t()
  @type list_of_records :: list(record)

  @default_producer_name :klife_default_producer
  @default_partitioner Klife.Producer.DefaultPartitioner
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
    default_producer: [
      type: :atom,
      required: false,
      default: @default_producer_name,
      doc:
        "Name of the producer to be used on produce API calls when a specific producer is not provided via configuration or option. If not provided a default producer will be started automatically."
    ],
    default_partitioner: [
      type: :atom,
      required: false,
      default: @default_partitioner,
      doc:
        "Partitioner module to be used on produce API calls when a specific partitioner is not provided via configuration or option."
    ],
    default_txn_pool: [
      type: :atom,
      required: false,
      default: @default_txn_pool,
      doc:
        "Name of the txn pool to be used on transactions when a `:pool_name` is not provided as an option. If not provided a default txn pool will be started automatically."
    ],
    txn_pools: [
      type: {:list, {:keyword_list, Klife.TxnProducerPool.get_opts()}},
      type_doc: "List of `Klife.TxnProducerPool` configurations",
      required: false,
      default: [],
      doc:
        "List of configurations, each starting a pool of transactional producers for use with transactional api."
    ],
    producers: [
      type: {:list, {:keyword_list, Klife.Producer.get_opts()}},
      type_doc: "List of `Klife.Producer` configurations",
      required: false,
      default: [],
      doc: "List of configurations, each starting a new producer for use with produce api."
    ],
    topics: [
      type: {:list, {:keyword_list, Klife.Topic.get_opts()}},
      type_doc: "List of `Klife.Topic` configurations",
      required: false,
      doc: "List of topics that may have special configurations",
      default: []
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
  defmodule MyApp.MyClient do
    use Klife.Client, otp_app: :my_app
  end
  ```

  > #### `use Klife.Client` {: .info}
  >
  > When you `use Klife.Client`, it will extend your module in two ways:
  >
  > - Define it as a proxy to a subset of the functions on `Klife` module,
  > using it's module's name as the `client_name` parameter.
  > One example of this is the `MyClient.produce/2` that forwards
  > both arguments to `Klife.produce/3` and inject `MyClient` as the
  > second argument.
  >
  > - Define it as a supervisor by calling `use Supervisor` and implementing
  > some related functions such as `start_link/1` and `init/1`, so it can be
  > started under on your app supervision tree.


  ## Configuration

  The client has a bunch of configuration options, you can read more below.
  But it will look somehting like this:

  ```elixir
  config :my_app, MyApp.MyClient,
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
      [name: "my_topic_0", producer: :my_custom_producer]
    ]

  ```

  You can see more configuration examples on the ["Client configuration examples"](guides/examples/client_configuration.md) section.

  ### Configuration options:

  #{NimbleOptions.docs(@input_options)}


  ## Starting it

  Finally, it must be started on your application. It will look something like this:

  ```elixir
  defmodule MyApp.Application do
    def start(_type, _args) do
      children = [
        # some other modules...,
        MyApp.MyClient
      ]

      opts = [strategy: :one_for_one, name: MyApp.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end
  ```

  ## Producer API overview

  In order to interact with the producer API you will work with `Klife.Record` module
  as your main input and output data structure.

  Usually you will give an record to some producer API function and it will return an
  enriched record with some new attributes based on what happened.

  So in summary the interaction goes like this:
  - Build one or more `Klife.Record`
  - Pass it to some producer API function
  - Receive an enriched version of the provided records

  ```elixir
  rec = %Klife.Record{value: "some_val", topic: "my_topic_1"}
  {:ok, %Klife.Record{offset: offset, partition: partition}} = MyClient.produce(rec)
  ```
  """

  @doc group: "Producer API"
  @doc """
  Produce a single record.

  It expects a `Klife.Record` struct containg at least `:value` and `:topic` and returns
  an ok/error tuple along side with the enriched version of the input record as described
  in ["Producer API Overview"](m:Klife.Client#producer-api-overview).

  ## Options

  #{NimbleOptions.docs(Klife.get_produce_opts())}

  ## Examples
      iex> rec = %Klife.Record{value: "my_val", topic: "my_topic_1"}
      iex> {:ok, %Klife.Record{} = enriched_rec} = MyClient.produce(rec)
      iex> true = is_number(enriched_rec.offset)
      iex> true = is_number(enriched_rec.partition)

  """
  @callback produce(record, opts :: Keyword.t()) :: {:ok, record} | {:error, record}

  @doc group: "Producer API"
  @doc """
  Produce a single record asynchronoulsy.

  The same as [`produce/2`](c:produce/2) but returns immediately. Accepts a callback
  option to execute arbitrary code after response is obtained.

  > #### Semantics and guarantees {: .info}
  >
  > This functions is implemented as `Task.start/1` calling [`produce/2`](c:produce/2).
  > Therefore there is no guarantees about record delivery or callback execution.

  ## Options

  #{NimbleOptions.docs(Klife.get_produce_opts() ++ Klife.get_async_opts())}

  ## Examples
      Anonymous Function:

      iex> rec = %Klife.Record{value: "my_val", topic: "my_topic_1"}
      iex> callback = fn resp ->
      ...>    {:ok, enriched_rec} = resp
      ...>    true = is_number(enriched_rec.offset)
      ...>    true = is_number(enriched_rec.partition)
      ...> end
      iex> :ok = MyClient.produce_async(rec, callback: callback)

      Using MFA:

      iex> defmodule CB do
      ...>    def exec(resp, my_arg1, my_arg2) do
      ...>      "my_arg1" = my_arg1
      ...>      "my_arg2" = my_arg2
      ...>      {:ok, enriched_rec} = resp
      ...>      true = is_number(enriched_rec.offset)
      ...>      true = is_number(enriched_rec.partition)
      ...>    end
      ...> end
      iex> rec = %Klife.Record{value: "my_val", topic: "my_topic_1"}
      iex> :ok = MyClient.produce_async(rec, callback: {CB, :exec, ["my_arg1", "my_arg2"]})

  """
  @callback produce_async(record, opts :: Keyword.t()) :: :ok

  @doc group: "Producer API"
  @doc """
  Produce a batch of records.

  It expects a list of `Klife.Record` structs containg at least `:value` and `:topic` and returns
  a list of ok/error tuples along side with the enriched version of the input record as described
  in ["Producer API Overview"](m:Klife.Client#producer-api-overview).

  The order of the response tuples on the returning list is the same as the input list. That means
  the first response tuple will be related to the first record on the input and so on.


  > #### Semantics and guarantees {: .info}
  >
  > This functions is semantically equivalent to call [`produce/2`](c:produce/2) multiple times and
  > wait for all responses. Which means that 2 records sent on the same batch may succeed or
  > fail independently.
  >
  > In other words that is no atomicity guarentees. If you need it see [`produce_batch_txn/2`](c:produce_batch_txn/2).
  >
  > The input list may contain records related to any topic/partition, for records of the same
  > topic/partition the order between them is guaranteed to be the same of the input, for records
  > of different topic/partition no order is guaranteed between them.
  >
  > See the partial error example below for more cotext.
  >

  ## Options

    #{NimbleOptions.docs(Klife.get_produce_opts())}

  ## Examples
      iex> rec1 = %Klife.Record{value: "my_val_1", topic: "my_topic_1"}
      iex> rec2 = %Klife.Record{value: "my_val_2", topic: "my_topic_2"}
      iex> rec3 = %Klife.Record{value: "my_val_3", topic: "my_topic_3"}
      iex> [{:ok, _resp1}, {:ok, _resp2}, {:ok, _resp3}] = MyClient.produce_batch([rec1, rec2, rec3])

  Partial error example:

      iex> rec1 = %Klife.Record{value: "my_val_1", topic: "my_topic_1"}
      iex> rec2 = %Klife.Record{value: :rand.bytes(2_000_000), topic: "my_topic_2"}
      iex> rec3 = %Klife.Record{value: "my_val_3", topic: "my_topic_3"}
      iex> [{:ok, _resp1}, {:error, %Klife.Record{error_code: 10}}, {:ok, _resp3}] = MyClient.produce_batch([rec1, rec2, rec3])

  In order to facilitate the response handling you can use `Klife.Record.verify_batch/1` or
  `Klife.Record.verify_batch!/1` functions.
  """
  @callback produce_batch(list_of_records, opts :: Keyword.t()) :: list({:ok | :error, record})

  @doc group: "Producer API"
  @doc """
  Produce a batch of records asynchronoulsy.

  The same as [`produce_batch/2`](c:produce_batch/2) but returns immediately. Accepts a callback
  option to execute arbitrary code after response is obtained.

  > #### Semantics and guarantees {: .info}
  >
  > This functions is implemented as `Task.start/1` calling [`produce_batch/2`](c:produce_batch/2).
  > Therefore there is no guarantees about record delivery or callback execution.

  ## Options

  #{NimbleOptions.docs(Klife.get_produce_opts() ++ Klife.get_async_opts())}

  ## Examples
      Anonymous Function:

      iex> rec1 = %Klife.Record{value: "my_val_1", topic: "my_topic_1"}
      iex> rec2 = %Klife.Record{value: "my_val_2", topic: "my_topic_2"}
      iex> rec3 = %Klife.Record{value: "my_val_3", topic: "my_topic_3"}
      iex> input = [rec1, rec2, rec3]
      iex> :ok = MyClient.produce_batch_async(input, callback: fn resp ->
      ...>  [{:ok, _resp1}, {:ok, _resp2}, {:ok, _resp3}] = resp
      ...> end)

      Using MFA:

      iex> defmodule CB2 do
      ...>    def exec(resp, my_arg1, my_arg2) do
      ...>      "arg1" = my_arg1
      ...>      "arg2" = my_arg2
      ...>      [{:ok, _resp1}, {:ok, _resp2}, {:ok, _resp3}] = resp
      ...>    end
      ...> end
      iex> rec1 = %Klife.Record{value: "my_val_1", topic: "my_topic_1"}
      iex> rec2 = %Klife.Record{value: "my_val_2", topic: "my_topic_2"}
      iex> rec3 = %Klife.Record{value: "my_val_3", topic: "my_topic_3"}
      iex> input = [rec1, rec2, rec3]
      iex> :ok = MyClient.produce_batch_async(input, callback: {CB2, :exec, ["arg1", "arg2"]})

  """
  @callback produce_batch_async(record, opts :: Keyword.t()) :: :ok

  @doc group: "Transaction API"
  @doc """
  Runs the given function inside a transaction.

  Every produce API call made inside the given function will be part of a transaction
  that will only commit if the returning value of fun is `:ok` or `{:ok, _any}`, any
  other return value will abort all records produced inside the given function.

  > #### Beware of performance costs {: .warning}
  > Each produce call inside the input function may have 1 extra network roundtrip to the broker
  > than a normal non transactional call.
  >
  > At the end of the transaction another round trip is needed in order to commit or abort
  > the transaction.


  > #### Produce semantics inside transaction {: .info}
  > All produce API calls keeps the same semantics as they have outside a transaction. This means
  > that records produced using `produce_batch/2` may still succeed/fail independently and a
  > `produce/2` call may still fail. Therefore it is user's responsability to verify and abort
  > the transaction if needed.


  ## Options

    #{NimbleOptions.docs(Klife.get_txn_opts())}

  ## Examples
      iex> {:ok, [_resp1, _resp2, _resp3]} = MyClient.transaction(fn ->
      ...>  rec1 = %Klife.Record{value: "my_val_1", topic: "my_topic_1"}
      ...>  {:ok, resp1} = MyClient.produce(rec1)
      ...>  rec2 = %Klife.Record{value: "my_val_2", topic: "my_topic_2"}
      ...>  rec3 = %Klife.Record{value: "my_val_3", topic: "my_topic_3"}
      ...>  [resp2, resp3] = MyClient.produce_batch([rec2, rec3])
      ...>  {:ok, [resp1, resp2, resp3]}
      ...> end)

  """
  @callback transaction(fun :: function(), opts :: Keyword.t()) :: any()

  @doc group: "Transaction API"
  @doc """
  Transactionally produce a batch of records.

  It expects a list of `Klife.Record` structs containg at least `:value` and `:topic` and returns
  a tuple ok/error tuple along side with the enriched version of the input records as described
  in ["Producer API Overview"](m:Klife.Client#producer-api-overview).

  The order of the response tuples on the returning list is the same as the input list. That means
  the first response tuple will be related to the first record on the input and so on.

  > #### Beware of performance costs {: .warning}
  > Each `produce_batch_txn/2` will have 2 extra network roundtrips to the broker than a non
  > transactional `produce_batch/2`. One for adding topic/partitions to the transaction and other
  > to commit or abort it.

  ## Options

    #{NimbleOptions.docs(Klife.get_txn_opts())}

  ## Examples
      iex> rec1 = %Klife.Record{value: "my_val_1", topic: "my_topic_1"}
      iex> rec2 = %Klife.Record{value: "my_val_2", topic: "my_topic_2"}
      iex> rec3 = %Klife.Record{value: "my_val_3", topic: "my_topic_3"}
      iex> {:ok, [_resp1, _resp2, _resp3]} = MyClient.produce_batch_txn([rec1, rec2, rec3])

  """
  @callback produce_batch_txn(list_of_records, opts :: Keyword.t()) ::
              {:ok, list_of_records} | {:error, list_of_records}

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
      defp default_producer_key(), do: {__MODULE__, :default_producer}
      defp default_partitioner_key(), do: {__MODULE__, :default_partitioner}

      def get_default_txn_pool(), do: :persistent_term.get(default_txn_pool_key())
      def get_default_producer(), do: :persistent_term.get(default_producer_key())
      def get_default_partitioner(), do: :persistent_term.get(default_partitioner_key())

      @doc false
      @impl Supervisor
      def init(_args) do
        Klife.Client.init(
          __MODULE__,
          @otp_app,
          @input_opts,
          default_txn_pool_key(),
          default_producer_key(),
          default_partitioner_key()
        )
      end

      @spec produce(Record.t(), opts :: list() | nil) :: {:ok, Record.t()} | {:error, Record.t()}
      def produce(%Record{} = rec, opts \\ []), do: Klife.produce(rec, __MODULE__, opts)

      @spec produce_batch(list(Record.t()), opts :: list() | nil) ::
              list({:ok, Record.t()} | {:error, Record.t()})
      def produce_batch(recs, opts \\ []), do: Klife.produce_batch(recs, __MODULE__, opts)

      @spec produce_async(Record.t(), opts :: list() | nil) :: :ok
      def produce_async(%Record{} = rec, opts \\ []),
        do: Klife.produce_async(rec, __MODULE__, opts)

      @spec produce_batch_async(Record.t(), opts :: list() | nil) :: :ok
      def produce_batch_async(recs, opts \\ []),
        do: Klife.produce_batch_async(recs, __MODULE__, opts)

      @spec produce_batch_txn(list(Record.t()), opts :: list() | nil) ::
              list({:ok, list(Record.t())}) | list({:error, list(Record.t())})
      def produce_batch_txn(recs, opts \\ []), do: Klife.produce_batch_txn(recs, __MODULE__, opts)

      @spec transaction(function(), opts :: list() | nil) :: any()
      def transaction(fun, opts \\ []), do: Klife.transaction(fun, __MODULE__, opts)
    end
  end

  @doc false
  def init(
        module,
        otp_app,
        input_opts,
        default_txn_pool_key,
        default_producer_key,
        default_partitioner_key
      ) do
    config = Application.get_env(otp_app, module)

    validated_opts = NimbleOptions.validate!(config, input_opts)

    default_producer_name = validated_opts[:default_producer]
    default_txn_pool_name = validated_opts[:default_txn_pool]
    default_partitioner = validated_opts[:default_partitioner]

    parsed_opts =
      validated_opts
      |> Keyword.update!(:producers, fn l ->
        default_producer =
          NimbleOptions.validate!(
            [name: default_producer_name],
            Klife.Producer.get_opts()
          )

        Enum.uniq_by([default_producer | l], fn p -> p[:name] end)
      end)
      |> Keyword.update!(:txn_pools, fn l ->
        default_txn_pool =
          NimbleOptions.validate!(
            [name: default_txn_pool_name],
            Klife.TxnProducerPool.get_opts()
          )

        Enum.uniq_by([default_txn_pool | l], fn p -> p[:name] end)
      end)
      |> Keyword.update(:topics, [], fn l ->
        Enum.map(l, fn topic ->
          topic
          |> Keyword.put_new(:default_producer, default_producer_name)
          |> Keyword.put_new(:default_partitioner, default_partitioner)
        end)
      end)
      |> Keyword.update!(:producers, fn l -> Enum.map(l, &Map.new/1) end)
      |> Keyword.update!(:txn_pools, fn l -> Enum.map(l, &Map.new/1) end)
      |> Keyword.update!(:topics, fn l -> Enum.map(l, &Map.new/1) end)

    conn_opts =
      parsed_opts
      |> Keyword.fetch!(:connection)
      |> Map.new()
      |> Map.put(:client_name, module)

    producer_opts =
      [client_name: module] ++ Keyword.take(parsed_opts, [:producers, :txn_pools, :topics])

    producer_opts = Map.new(producer_opts)

    children = [
      {Klife.Connection.Supervisor, conn_opts},
      {Klife.Producer.Supervisor, producer_opts}
    ]

    :persistent_term.put(default_txn_pool_key, parsed_opts[:default_txn_pool])
    :persistent_term.put(default_producer_key, parsed_opts[:default_producer])
    :persistent_term.put(default_partitioner_key, parsed_opts[:default_partitioner])

    Supervisor.init(children, strategy: :one_for_one)
  end
end

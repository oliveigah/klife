defmodule Klife.Client do
  alias Klife
  alias Klife.Record

  @type record :: Klife.Record.t()
  @type list_of_records :: list(record)

  @default_producer_name :klife_default_producer
  @default_partitioner Klife.Producer.DefaultPartitioner
  @default_txn_pool :klife_default_txn_pool
  @default_fetcher_name :klife_default_fetcher

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
    producers: [
      type: {:list, {:keyword_list, Klife.Producer.get_opts()}},
      type_doc: "List of `Klife.Producer` configurations",
      required: false,
      default: [],
      doc: "List of configurations, each starting a new producer for use with produce api."
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
    topics: [
      type: {:list, {:keyword_list, Klife.Topic.get_opts()}},
      type_doc: "List of `Klife.Topic` configurations",
      required: false,
      doc: "List of topics that may have special configurations",
      default: []
    ],
    default_fetcher: [
      type: :atom,
      required: false,
      default: @default_fetcher_name,
      doc:
        "Name of the default fetcher to be used on the consumer API when a specific fetcher is not provided via configuration or option. If not provided a default fetcher will be started automatically."
    ],
    fetchers: [
      type: {:list, {:keyword_list, Klife.Consumer.Fetcher.get_opts()}},
      type_doc: "List of `Klife.Consumer.Fetcher` configurations",
      required: false,
      default: [],
      doc: "List of configurations, each starting a new fetcher to be used with consumer api."
    ],
    disabled_features: [
      type: {:list, {:in, [:producer, :txn_producer]}},
      type_doc: "List atoms representing a features to disable.",
      required: false,
      doc: "`:producer` disable producer feature. `:txn_producer` disables transactions.",
      default: []
    ],
    enable_unkown_topics: [
      type: :boolean,
      required: false,
      default: true,
      doc:
        "Define if the client will be able to work with non configured topics. When `true` the client will collect metadata for all known topics of the cluster, this may have performance impacts on large clusters. When set to `false` the client will collect metadata only for topics defined on the `topics` options."
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
  > - Define it as a proxy to a subset of the functions on Klife module,
  > using its module name as the `client_name` parameter.
  > One example of this is `MyApp.MyClient.produce/2` that forwards
  > both arguments to the same function and injects `MyApp.MyClient` as an argument.
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

  You can see more configuration examples on the ["Client configuration examples"](guides/examples/client_configuration.md) section
  or an working application example on the `example` folder on the project's repository.

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

  ## Consumer API overview

  For continuous consumption of records, the recommended approach is to use
  `Klife.Consumer.ConsumerGroup`. It handles partition assignment, offset
  tracking, rebalancing, and fault tolerance automatically. See the
  `Klife.Consumer.ConsumerGroup` docs for details.

  The client also exposes lower-level fetch functions `fetch/4`, `fetch/2`, and
  `fetch_async/4`, for cases where a full consumer group is not needed. These are
  intended for standalone use: one-off reads, backfilling, debugging, or any
  workflow where you manage offsets yourself.

  The fetch functions return `Klife.Record` structs, the same data structure used
  throughout the producer API. Each returned record is fully enriched with all the
  relevant data available.

  ```elixir
  # Fetch a batch of records starting at a given offset
  {:ok, records} = MyClient.fetch("my_topic_1", 0, 42)

  # Fetch from multiple topic/partition/offset combinations in one request
  tpo_list = [{"my_topic_1", 0, 42}, {"my_topic_2", 3, 0}]
  %{{"my_topic_1", 0, 42} => {:ok, _}} = MyClient.fetch(tpo_list)

  # Async fetch result delivered as a message to the calling process
  {:ok, _pid} = MyClient.fetch_async("my_topic_1", 0, 42)
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
  > This functions executes the callback using `Task.start/1`.
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
  option to execute arbitrary code after response is obtained

  > #### Semantics and guarantees {: .info}
  > When callback is provided this functions is implemented as `Task.start/1`
  > calling [`produce_batch/2`](c:produce_batch/2) and executing the callback right after.
  > Therefore there is no guarantees about record delivery or callback execution.

  > #### Beware of process limits {: .warning}
  > Because this function spawns a new process for every new call with a callback defined
  > it may lead to a high number of processes to be spawned if it is executed inside loops.
  >
  > In order to avoid this you can increase the batch size you are calling it or
  > increase the system's process limit erlang flag.

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
      ...>       [{:ok, _resp1}, {:ok, _resp2}, {:ok, _resp3}] = resp
      ...>    end
      ...> end
      iex> rec1 = %Klife.Record{value: "my_val_1", topic: "my_topic_1"}
      iex> rec2 = %Klife.Record{value: "my_val_2", topic: "my_topic_2"}
      iex> rec3 = %Klife.Record{value: "my_val_3", topic: "my_topic_3"}
      iex> input = [rec1, rec2, rec3]
      iex> :ok = MyClient.produce_batch_async(input, callback: {CB2, :exec, ["arg1", "arg2"]})

  """
  @callback produce_batch_async(list(record), opts :: Keyword.t()) :: :ok

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

  @doc group: "Consumer API"
  @doc """
  Fetch records from a single topic/partition starting at the given offset.

  Returns an `{:ok, list_of_records}` tuple where the list contains all records
  available from `offset` up to `max_bytes` worth of data. Returns `{:error, reason}`
  on failure.

  ## Options

  #{NimbleOptions.docs(Klife.get_fetch_opts())}

  ## Examples
      iex> rec1 = %Klife.Record{value: "val_1", topic: "my_topic_1", partition: 0}
      iex> rec2 = %Klife.Record{value: "val_2", topic: "my_topic_1", partition: 0}
      iex> [{:ok, %Klife.Record{offset: o1}}, {:ok, _}] = MyClient.produce_batch([rec1, rec2])
      iex> {:ok, records} = MyClient.fetch("my_topic_1", 0, o1)
      iex> [%Klife.Record{value: "val_1"}, %Klife.Record{value: "val_2"}] = records

  """
  @callback fetch(
              topic :: String.t(),
              partition :: non_neg_integer(),
              offset :: non_neg_integer(),
              opts :: Keyword.t()
            ) :: {:ok, list_of_records} | {:error, any()}

  @doc group: "Consumer API"
  @doc """
  Fetch records from multiple topic/partition/offset combinations in a single request.

  Accepts a list of `{topic, partition, offset}` tuples and returns a map where
  each key is the input `{topic, partition, offset}` tuple and the value is an
  `{:ok, list_of_records}` or `{:error, reason}` tuple.

  This is more efficient than calling [`fetch/4`](c:fetch/4) multiple times in a loop
  because requests targeting the same broker are automatically batched into a single
  TCP request.

  ## Options

  #{NimbleOptions.docs(Klife.get_fetch_opts())}

  ## Examples
      iex> rec1 = %Klife.Record{value: "val_1", topic: "my_topic_1"}
      iex> rec2 = %Klife.Record{value: "val_2", topic: "my_topic_2"}
      iex> [{:ok, %Klife.Record{offset: o1, partition: p1}}, {:ok, %Klife.Record{offset: o2, partition: p2}}] = MyClient.produce_batch([rec1, rec2])
      iex> tpo_list = [{"my_topic_1", p1, o1}, {"my_topic_2", p2, o2}]
      iex> %{{"my_topic_1", ^p1, ^o1} => {:ok, resp1}, {"my_topic_2", ^p2, ^o2} => {:ok, resp2}} = MyClient.fetch(tpo_list)
      iex> [%Klife.Record{value: "val_1"}] = resp1
      iex> [%Klife.Record{value: "val_2"}] = resp2

  """
  @callback fetch(
              tpo_list ::
                list(
                  {topic :: String.t(), partition :: non_neg_integer(),
                   offset :: non_neg_integer()}
                ),
              opts :: Keyword.t()
            ) :: %{
              {String.t(), non_neg_integer(), non_neg_integer()} =>
                {:ok, list_of_records} | {:error, any()}
            }

  @doc group: "Consumer API"
  @doc """
  Sends an asynchronous fetch request for a single topic/partition/offset.

  Returns `{:ok, pid}` where `pid` is the batcher process handling the request, or
  `{:error, reason}` if the request could not be enqueued.

  The result is delivered as a message to the calling process in the form:

      {:klife_fetch_response, {topic, partition, offset}, {:ok, records} | {:error, reason}}

  This is useful for building standalone consumers or any process that needs non-blocking
  fetch semantics. The same primitive that `Klife.Consumer.ConsumerGroup` uses internally.

  ## Options

  #{NimbleOptions.docs(Klife.get_fetch_opts())}

  ## Examples

      iex> {:ok, %Klife.Record{partition: p, offset: o}} = MyClient.produce(%Klife.Record{value: "async_val", topic: "my_topic_1"})
      iex> {:ok, _pid} = MyClient.fetch_async("my_topic_1", p, o)
      iex> receive do
      ...>   {:klife_fetch_response, {"my_topic_1", ^p, ^o}, {:ok, records}} ->
      ...>     [%Klife.Record{value: "async_val"} | _] = records
      ...> after
      ...>   5_000 -> raise "timeout"
      ...> end

  """
  @callback fetch_async(
              topic :: String.t(),
              partition :: non_neg_integer(),
              offset :: non_neg_integer(),
              opts :: Keyword.t()
            ) :: {:ok, pid()} | {:error, any()}

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
      defp default_fetcher_key(), do: {__MODULE__, :default_fetcher}

      def get_default_txn_pool(), do: :persistent_term.get(default_txn_pool_key())
      def get_default_producer(), do: :persistent_term.get(default_producer_key())
      def get_default_partitioner(), do: :persistent_term.get(default_partitioner_key())
      def get_default_fetcher(), do: :persistent_term.get(default_fetcher_key())

      def get_default_request_timeout_ms(),
        do: Klife.Connection.Controller.get_default_request_timeout_ms(__MODULE__)

      @doc false
      @impl Supervisor
      def init(_args) do
        Klife.Client.init(
          __MODULE__,
          @otp_app,
          @input_opts,
          default_txn_pool_key(),
          default_producer_key(),
          default_partitioner_key(),
          default_fetcher_key()
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

      @spec produce_batch_async(list(Record.t()), opts :: list() | nil) :: :ok
      def produce_batch_async(recs, opts \\ []),
        do: Klife.produce_batch_async(recs, __MODULE__, opts)

      @spec produce_batch_txn(list(Record.t()), opts :: list() | nil) ::
              {:ok, list(Record.t())} | {:error, list(Record.t())}
      def produce_batch_txn(recs, opts \\ []), do: Klife.produce_batch_txn(recs, __MODULE__, opts)

      @spec transaction(function(), opts :: list() | nil) :: any()
      def transaction(fun, opts \\ []), do: Klife.transaction(fun, __MODULE__, opts)

      @spec fetch(String.t(), non_neg_integer(), non_neg_integer(), opts :: list()) ::
              {:ok, list(Record.t())} | {:error, any()}
      def fetch(topic, partition, offset, opts \\ []),
        do: Klife.fetch(topic, partition, offset, __MODULE__, opts)

      @spec fetch(
              list({String.t(), non_neg_integer(), non_neg_integer()}),
              opts :: list()
            ) :: %{
              {String.t(), non_neg_integer(), non_neg_integer()} =>
                {:ok, list(Record.t())} | {:error, any()}
            }
      def fetch(tpo_list, opts \\ []),
        do: Klife.fetch(tpo_list, __MODULE__, opts)

      @spec fetch_async(String.t(), non_neg_integer(), non_neg_integer(), opts :: list()) ::
              {:ok, pid()} | {:error, any()}
      def fetch_async(topic, partition, offset, opts \\ []),
        do: Klife.fetch_async(topic, partition, offset, __MODULE__, opts)
    end
  end

  @doc false
  def init(
        module,
        otp_app,
        input_opts,
        default_txn_pool_key,
        default_producer_key,
        default_partitioner_key,
        default_fetcher_key
      ) do
    config = Application.get_env(otp_app, module)

    validated_opts = NimbleOptions.validate!(config, input_opts)

    default_producer_name = validated_opts[:default_producer]
    default_txn_pool_name = validated_opts[:default_txn_pool]
    default_partitioner = validated_opts[:default_partitioner]
    default_fetcher_name = validated_opts[:default_fetcher]

    parsed_opts =
      validated_opts
      |> Keyword.update!(:producers, fn l ->
        default_producer =
          NimbleOptions.validate!(
            [name: default_producer_name],
            Klife.Producer.get_opts()
          )

        Enum.uniq_by(l ++ [default_producer], fn p -> p[:name] end)
      end)
      |> Keyword.update!(:txn_pools, fn l ->
        default_txn_pool =
          NimbleOptions.validate!(
            [name: default_txn_pool_name],
            Klife.TxnProducerPool.get_opts()
          )

        Enum.uniq_by(l ++ [default_txn_pool], fn p -> p[:name] end)
      end)
      |> Keyword.update!(:fetchers, fn l ->
        default_fetcher =
          NimbleOptions.validate!(
            [name: default_fetcher_name],
            Klife.Consumer.Fetcher.get_opts()
          )

        Enum.uniq_by(l ++ [default_fetcher], fn f -> f[:name] end)
      end)
      |> Keyword.update(:topics, [], fn l ->
        Enum.map(l, fn topic ->
          topic
          |> Keyword.put_new(:default_producer, default_producer_name)
          |> Keyword.put_new(:default_partitioner, default_partitioner)
        end)
      end)
      |> Klife.Helpers.keyword_list_to_map()

    conn_opts =
      parsed_opts
      |> Map.fetch!(:connection)
      |> Map.put(:client_name, module)

    producer_opts =
      parsed_opts
      |> Map.take([:producers, :txn_pools, :topics])
      |> Map.put(:client_name, module)

    consumer_opts =
      parsed_opts
      |> Map.take([:fetchers])
      |> Map.put(:client_name, module)

    metadata_cache_opts =
      parsed_opts
      |> Map.take([:topics, :enable_unkown_topics])
      |> Map.put(:client_name, module)

    children = [
      {Klife.Connection.Controller, conn_opts},
      {Klife.MetadataCache, metadata_cache_opts},
      {Klife.Producer.Supervisor, producer_opts},
      {Klife.Consumer.Supervisor, consumer_opts}
    ]

    :persistent_term.put(default_txn_pool_key, parsed_opts[:default_txn_pool])
    :persistent_term.put(default_producer_key, parsed_opts[:default_producer])
    :persistent_term.put(default_partitioner_key, parsed_opts[:default_partitioner])
    :persistent_term.put(default_fetcher_key, parsed_opts[:default_fetcher])

    Enum.each(parsed_opts[:disabled_features], fn feature ->
      Klife.Connection.Controller.disable_feature(feature, module)
    end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end

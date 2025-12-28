defmodule Simulator.Engine.Producer do
  use GenServer

  require Logger

  import Simulator.Engine.ProcessRegistry, only: [via_tuple: 1]

  alias Simulator.Engine

  defstruct [
    :client,
    :topic,
    :partition
  ]

  @impl true
  def init(init_args) do
    state = %__MODULE__{
      client: init_args.client,
      topic: init_args.topic,
      partition: init_args.partition
    }

    send(self(), :produce_loop)
    {:ok, state}
  end

  def start_link(args) do
    t = args.topic
    p = args.partition
    c = args.client
    GenServer.start_link(__MODULE__, args, name: via_tuple({__MODULE__, c, t, p}))
  end

  @impl true
  def handle_info(:produce_loop, %__MODULE__{} = state) do
    max_recs = 1
    rec_count = Enum.random(1..max_recs)
    chunk_size = Enum.random(1..rec_count)

    produce_results =
      Enum.map(1..rec_count, fn _i ->
        %Klife.Record{
          topic: state.topic,
          partition: state.partition,
          value: :rand.bytes(10)
        }
      end)
      |> Enum.chunk_every(chunk_size)
      |> Enum.map(fn chunk ->
        apply(state.client, :produce_batch, [chunk])
      end)

    for result <- produce_results,
        {status, %Klife.Record{} = rec} <- result do
      case status do
        :ok ->
          :ok = Engine.insert_produced_record(rec)

        :error ->
          Logger.error("Error on producer: error_code #{rec.error_code}")
      end
    end

    Process.send_after(self(), :produce_loop, 1000)
    {:noreply, state}
  end
end

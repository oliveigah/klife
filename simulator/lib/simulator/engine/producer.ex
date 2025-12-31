defmodule Simulator.Engine.Producer do
  use GenServer

  require Logger

  import Simulator.Engine.ProcessRegistry, only: [via_tuple: 1]

  alias Simulator.Engine

  defstruct [
    :client,
    :topic,
    :partition,
    :allowed_to_produce?,
    :max_records
  ]

  @impl true
  def init(init_args) do
    state = %__MODULE__{
      client: init_args.client,
      topic: init_args.topic,
      partition: init_args.partition,
      max_records: init_args.max_records
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
    new_state =
      if state.allowed_to_produce? do
        do_produce(state)
      else
        allowed? = Engine.allowed_to_produce?(state.topic, state.partition)

        if allowed? do
          Logger.info("Starting producer #{state.topic} #{state.partition}")
        end

        %{state | allowed_to_produce?: allowed?}
      end

    Process.send_after(self(), :produce_loop, 1000)
    {:noreply, new_state}
  end

  defp do_produce(%__MODULE__{} = state) do
    max_recs = state.max_records
    rec_count = Enum.random(1..max_recs)
    chunk_size = Enum.random(1..rec_count)

    to_produce =
      Enum.map(1..rec_count, fn _i ->
        rec = %Klife.Record{
          topic: state.topic,
          partition: state.partition,
          value: :rand.bytes(10),
          key: :crypto.strong_rand_bytes(64) |> Base.encode16()
        }

        :ok = Engine.insert_produced_record(rec)

        rec
      end)

    produce_results =
      to_produce
      |> Enum.chunk_every(chunk_size)
      |> Enum.map(fn chunk ->
        apply(state.client, :produce_batch, [chunk])
      end)

    for result <- produce_results,
        {status, %Klife.Record{} = rec} <- result do
      case status do
        :ok ->
          :ok

        :error ->
          Engine.rollback_produced_record(rec)
          Logger.error("Error on producer: error_code #{rec.error_code}")
      end
    end

    state
  end
end

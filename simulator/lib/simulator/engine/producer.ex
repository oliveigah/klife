defmodule Simulator.Engine.Producer do
  use GenServer

  require Logger

  import Simulator.Engine.ProcessRegistry, only: [via_tuple: 1]

  alias Simulator.Engine
  alias Simulator.EngineConfig

  defstruct [
    :client,
    :topic,
    :partition,
    :allowed_to_produce?,
    :max_records,
    :loop_interval_ms,
    :record_value_bytes,
    :record_key_bytes
  ]

  @impl true
  def init(init_args) do
    state = %__MODULE__{
      client: init_args.client,
      topic: init_args.topic,
      partition: init_args.partition,
      max_records: init_args.max_records,
      loop_interval_ms: init_args.loop_interval_ms,
      record_value_bytes: init_args.record_value_bytes,
      record_key_bytes: init_args.record_key_bytes
    }

    %EngineConfig{random_seeds_map: seeds_map} = Engine.get_config()

    seed =
      Map.fetch!(
        seeds_map,
        {:producer, EngineConfig.parse_topic(state.topic), state.partition, init_args.index}
      )

    :rand.seed(:exsss, seed)

    send(self(), :produce_loop)
    {:ok, state}
  end

  def start_link(args) do
    t = args.topic
    p = args.partition
    c = args.client
    idx = args.index
    GenServer.start_link(__MODULE__, args, name: via_tuple({__MODULE__, c, t, p, idx}))
  end

  @impl true
  def handle_info(:produce_loop, %__MODULE__{} = state) do
    new_state =
      if state.allowed_to_produce? do
        do_produce(state)
      else
        allowed? = Engine.allowed_to_produce?(state.topic, state.partition)
        %{state | allowed_to_produce?: allowed?}
      end

    jitter = Enum.random(1..1000) / 100
    Process.send_after(self(), :produce_loop, round(state.loop_interval_ms * jitter))
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
          value: :rand.bytes(state.record_value_bytes),
          key: :crypto.strong_rand_bytes(state.record_key_bytes) |> Base.encode16()
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

    recs =
      for result <- produce_results,
          {status, %Klife.Record{} = rec} <- result do
        case status do
          :ok ->
            :ok = Engine.confirm_produced_record(rec)
            rec

          :error ->
            Engine.rollback_produced_record(rec)
            Logger.error("Error on producer: error_code #{rec.error_code}")
        end
      end

    if :persistent_term.get({state.topic, state.partition}, false) do
      Logger.info(
        "Latest produced for #{state.topic} #{state.partition} offset #{List.last(recs).offset}"
      )
    end

    state
  end
end

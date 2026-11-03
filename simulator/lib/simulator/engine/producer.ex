defmodule Simulator.Engine.Producer do
  use GenServer

  require Logger

  import Simulator.Engine.ProcessRegistry, only: [via_tuple: 1]

  alias Klife.MetadataCache
  alias Simulator.Engine
  alias Simulator.EngineConfig

  defstruct [
    :client,
    :topic,
    :max_records,
    :loop_interval_ms,
    :record_value_bytes,
    :record_key_bytes,
    # Offset of the last record produced to each partition
    last_offsets: %{}
  ]

  @slow_produce_us :timer.seconds(10) * 1000

  @impl true
  def init(init_args) do
    state = %__MODULE__{
      client: init_args.client,
      topic: init_args.topic,
      max_records: init_args.max_records,
      loop_interval_ms: init_args.loop_interval_ms,
      record_value_bytes: init_args.record_value_bytes,
      record_key_bytes: init_args.record_key_bytes
    }

    %EngineConfig{random_seeds_map: seeds_map} = Engine.get_config()

    seed =
      Map.fetch!(
        seeds_map,
        {:producer, EngineConfig.parse_topic(state.topic), init_args.index}
      )

    :rand.seed(:exsss, seed)

    send(self(), :produce_loop)
    {:ok, state}
  end

  def start_link(args) do
    t = args.topic
    c = args.client
    idx = args.index
    GenServer.start_link(__MODULE__, args, name: via_tuple({__MODULE__, c, t, idx}))
  end

  @impl true
  def handle_info(:produce_loop, %__MODULE__{} = state) do
    new_state =
      if MetadataCache.metadata_exists?(state.client, state.topic, 0) do
        do_produce(state)
      else
        state
      end

    jitter = Enum.random(1..500) / 100
    Process.send_after(self(), :produce_loop, round(state.loop_interval_ms * jitter))
    {:noreply, new_state}
  end

  defp do_produce(%__MODULE__{} = state) do
    max_recs = state.max_records
    rec_count = Enum.random(1..max_recs)
    chunk_size = Enum.random(1..rec_count)

    to_produce =
      Enum.map(1..rec_count, fn _i ->
        rec =
          %Klife.Record{
            topic: state.topic,
            value: :rand.bytes(state.record_value_bytes),
            key: :crypto.strong_rand_bytes(state.record_key_bytes) |> Base.encode16()
          }
          |> Klife.add_partition!(state.client)

        :ok = Engine.insert_produced_record(rec)

        rec
      end)

    produce_results =
      to_produce
      |> Enum.chunk_every(chunk_size)
      |> Enum.map(fn chunk ->
        {elapsed_us, result} = :timer.tc(fn -> apply(state.client, :produce_batch, [chunk]) end)

        # A healthy call takes milliseconds, about a second when it meets a
        # leader change. Waiting out a handoff abort or a request timeout takes
        # far longer.
        if EngineConfig.force_stable?() and elapsed_us > @slow_produce_us do
          :ok =
            Engine.insert_violation(:slow_produce, %{
              topic: state.topic,
              records: length(chunk),
              elapsed_ms: div(elapsed_us, 1000)
            })
        end

        result
      end)

    last_offsets =
      for result <- produce_results,
          {status, %Klife.Record{} = rec} <- result,
          reduce: state.last_offsets do
        acc ->
          case status do
            :ok ->
              :ok = Engine.confirm_produced_record(rec)

              # This process's produce calls never overlap, so each record
              # must land after the ones it produced before to its partition
              last_offset = Map.get(acc, rec.partition)

              if last_offset != nil and rec.offset <= last_offset do
                :ok =
                  Engine.insert_violation(:produced_out_of_order, %{
                    topic: rec.topic,
                    partition: rec.partition,
                    offset: rec.offset,
                    previous_offset: last_offset
                  })
              end

              Map.put(acc, rec.partition, rec.offset)

            :error ->
              Engine.rollback_produced_record(rec)
              Logger.error("Error on producer: error_code #{inspect(rec.error_code)}")

              # Without injected failures nothing may fail
              if EngineConfig.force_stable?() do
                :ok =
                  Engine.insert_violation(:produce_error, %{
                    topic: rec.topic,
                    partition: rec.partition,
                    error_code: rec.error_code
                  })
              end

              acc
          end
      end

    %{state | last_offsets: last_offsets}
  end
end

defmodule Simulator.Engine.Consumer do
  alias Simulator.Engine
  alias Simulator.EngineConfig

  # Need to create multiple modules because the consumer group register itself
  # using {cg_mod.klife_client(), cg_mod, validated_args.group_name}
  # so it is not possible to reuse the same module for the same group
  for i <- 0..100 do
    defmodule :"#{__MODULE__}.NormalClient#{i}" do
      require Logger
      use Klife.Consumer.ConsumerGroup, client: Simulator.NormalClient

      def handle_record_batch(t, p, gn, r_list) do
        Simulator.Engine.Consumer.handle_record_batch(
          t,
          p,
          gn,
          r_list,
          __MODULE__
        )
      end

      def handle_consumer_start(topic, partition, group_name) do
        Logger.info(
          event: "consumer_start",
          topic: topic,
          partition: partition,
          group: group_name,
          mod: __MODULE__
        )

        %EngineConfig{random_seeds_map: seeds_map} = Engine.get_config()

        seed =
          Map.fetch!(
            seeds_map,
            {:consumer, EngineConfig.parse_topic(topic), partition, group_name, unquote(i)}
          )

        :rand.seed(:exsss, seed)

        :ok = Engine.set_consumer_ready(topic, partition, group_name)
      end

      def handle_consumer_stop(topic, partition, group_name, reason) do
        Logger.info(
          event: "consumer_stop",
          topic: topic,
          partition: partition,
          group: group_name,
          mod: __MODULE__,
          reason: reason
        )
      end
    end
  end

  for i <- 0..100 do
    defmodule :"#{__MODULE__}.TLSClient#{i}" do
      require Logger
      use Klife.Consumer.ConsumerGroup, client: Simulator.TLSClient

      def handle_record_batch(t, p, gn, r_list) do
        Simulator.Engine.Consumer.handle_record_batch(
          t,
          p,
          gn,
          r_list,
          __MODULE__
        )
      end

      def handle_consumer_start(topic, partition, group_name) do
        Logger.info(
          event: "consumer_start",
          topic: topic,
          partition: partition,
          group: group_name,
          mod: __MODULE__
        )

        %EngineConfig{random_seeds_map: seeds_map} = Engine.get_config()

        seed =
          Map.fetch!(
            seeds_map,
            {:consumer, EngineConfig.parse_topic(topic), partition, group_name, unquote(i)}
          )

        :rand.seed(:exsss, seed)

        :ok = Engine.set_consumer_ready(topic, partition, group_name)
      end

      def handle_consumer_stop(topic, partition, group_name, reason) do
        Logger.info(
          event: "consumer_stop",
          topic: topic,
          partition: partition,
          group: group_name,
          mod: __MODULE__,
          reason: reason
        )
      end
    end
  end

  def handle_record_batch(_t, _p, gn, recs, cg_mod) do
    # TODO: Add failure rate to the engine config
    should_fail_some? = :rand.uniform() >= 0.99

    to_fail =
      if should_fail_some?,
        do: Enum.random(recs).offset,
        else: List.last(recs).offset + 1

    Enum.map(recs, fn %Klife.Record{} = rec ->
      if rec.offset >= to_fail do
        {:retry, rec}
      else
        Engine.insert_consumed_record!(rec, gn, cg_mod)
        {:commit, rec}
      end
    end)
  end
end

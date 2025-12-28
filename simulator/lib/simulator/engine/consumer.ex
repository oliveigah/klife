defmodule Simulator.Engine.Consumer do
  alias Simulator.Engine

  # Need to create multiple modules because the consumer group register itself
  # using {cg_mod.klife_client(), cg_mod, validated_args.group_name}
  # so it is not possible to reuse the same module for the same group
  for i <- 1..100 do
    defmodule :"#{__MODULE__}.NormalClient#{i}" do
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
    end
  end

  for i <- 1..100 do
    defmodule :"#{__MODULE__}.TLSClient#{i}" do
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
    end
  end

  def handle_record_batch(_t, _p, gn, recs, cg_mod) do
    should_fail_some? = false
    # :rand.uniform() >= 0.90

    to_fail =
      if should_fail_some?,
        do: Enum.random(recs).offset,
        else: List.last(recs).offset + 1

    Enum.map(recs, fn %Klife.Record{} = rec ->
      if rec.offset >= to_fail do
        {:retry, rec}
      else
        # Assert that does not consume duplicates!
        Engine.insert_consumed_record!(rec, gn, cg_mod)

        {:commit, rec}
      end
    end)
  end
end

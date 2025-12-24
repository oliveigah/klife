defmodule Simulator.Engine.Consumer do
  # Need to create multiple modules because the consumer group register itself
  # using {cg_mod.klife_client(), cg_mod, validated_args.group_name}
  for i <- 1..100 do
    defmodule :"#{__MODULE__}.NormalClient#{i}" do
      use Klife.Consumer.ConsumerGroup, client: Simulator.NormalClient
      defdelegate handle_record_batch(t, p, r_list), to: Simulator.Engine.Consumer
    end
  end

  for i <- 1..100 do
    defmodule :"#{__MODULE__}.TLSClient#{i}" do
      use Klife.Consumer.ConsumerGroup, client: Simulator.TLSClient
      defdelegate handle_record_batch(t, p, r_list), to: Simulator.Engine.Consumer
    end
  end

  def handle_record_batch(_topic, _partition, recs) do
    Enum.map(recs, fn %Klife.Record{} = rec ->
      {:commit, rec}
    end)
  end
end

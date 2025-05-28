defmodule Klife.Behaviours.ConsumerGroup do
  @type error_action :: :commit | :skip | :retry | {:move_to, String.t()}

  @type callback_opts :: [
          {:handler_cooldown_ms, non_neg_integer()}
        ]

  @callback handle_record(topic :: String.t(), partition :: integer, record :: Klife.Record.t()) ::
              :ok
              | {:ok, callback_opts}
              | {:error, error_action}
              | {:error, error_action, callback_opts}

  @callback handle_record_batch(topic :: String.t(), partition :: integer, list(Klife.Record.t())) ::
              :ok
              | {:ok, callback_opts}
              | {:error, list({error_action, Klife.Record.t()})}
              | {:error, list({error_action, Klife.Record.t()}), callback_opts}

  @optional_callbacks handle_record: 3, handle_record_batch: 3
end

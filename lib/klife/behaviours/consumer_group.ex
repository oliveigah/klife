defmodule Klife.Behaviours.ConsumerGroup do
  @type action ::
          :commit | {:commit, String.t()} | {:skip, String.t()} | {:move_to, String.t()} | :retry

  @type callback_opts :: [
          {:handler_cooldown_ms, non_neg_integer()}
        ]

  @callback handle_record_batch(topic :: String.t(), partition :: integer, list(Klife.Record.t())) ::
              action
              | {action, callback_opts}
              | list({action, Klife.Record.t()})
              | {list({action, Klife.Record.t()}), callback_opts}
end

defmodule Klife.Behaviours.ConsumerGroup do
  # TODO: {:move_to, String.t()} or {:move_to, :retry} and {:move_to, :dlq}
  @type action :: :commit | {:skip, String.t()}

  @type callback_opts :: [
          {:handler_cooldown_ms, non_neg_integer()}
        ]

  @callback handle_record_batch(topic :: String.t(), partition :: integer, list(Klife.Record.t())) ::
              {action, :all}
              | {{action, :all}, callback_opts}
              | list({action, Klife.Record.t()})
              | {list({action, Klife.Record.t()}), callback_opts}
end

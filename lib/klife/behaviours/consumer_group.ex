defmodule Klife.Behaviours.ConsumerGroup do
  @type action :: :commit | :retry

  @type callback_opts :: [
          {:handler_cooldown_ms, non_neg_integer()}
        ]

  @callback handle_record_batch(
              topic :: String.t(),
              partition :: integer,
              group_name :: String.t(),
              list(Klife.Record.t())
            ) ::
              action
              | {action, callback_opts}
              | list({action, Klife.Record.t()})
              | {list({action, Klife.Record.t()}), callback_opts}

  @callback handle_consumer_start(
              topic :: String.t(),
              partition :: integer,
              group_name :: String.t()
            ) :: :ok

  @callback handle_consumer_stop(
              topic :: String.t(),
              partition :: integer,
              group_name :: String.t(),
              reason :: term
            ) :: :ok

  @optional_callbacks [handle_consumer_start: 3, handle_consumer_stop: 4]
end

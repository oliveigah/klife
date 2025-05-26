defmodule MyConsumerGroup do
  use Klife.Consumer.ConsumerGroup, client: MyClient
end

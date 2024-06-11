defmodule Klife.Topic do
  @topic_options [
    name: [
      type: :string,
      required: true,
      doc: "Topic's name"
    ],
    default_producer: [
      type: :atom,
      required: false,
      default: :klife_default_producer,
      doc: "Define the default producer to be used on produce API calls."
    ],
    default_partitioner: [
      type: :atom,
      required: false,
      default: Klife.Producer.DefaultPartitioner,
      doc:
        "Define the default partitioner module to be used on produce API calls. Must implement `Klife.Behaviours.Partitioner`"
    ]
  ]

  @doc false
  def get_opts(), do: @topic_options

  @moduledoc """
  Defines a topic

  ## Configurations

  #{NimbleOptions.docs(@topic_options)}
  """
end

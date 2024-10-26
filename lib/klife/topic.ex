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
      doc: "Define the default producer to be used on produce API calls."
    ],
    default_partitioner: [
      type: :atom,
      required: false,
      doc:
        "Define the default partitioner module to be used on produce API calls. Must implement `Klife.Behaviours.Partitioner`"
    ]
  ]

  @doc false
  def get_opts(), do: @topic_options

  @moduledoc """
  Defines a topic configuration.

  For now this struct is only useful for initial client configuration, but in the future it may be useful for the admin api as well.

  ## Client configurations

  #{NimbleOptions.docs(@topic_options)}
  """
end

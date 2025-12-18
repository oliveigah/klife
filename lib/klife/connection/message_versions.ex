defmodule Klife.Connection.MessageVersions do
  @moduledoc false

  alias KlifeProtocol.Messages, as: M
  alias Klife.Connection.Controller

  require Logger

  def get(client_name, mod), do: :persistent_term.get({:api_version, mod, client_name})

  def setup_versions(server_data, client_name) do
    do_setup_versions(client_versions(), server_data, client_name)
  end

  defp do_setup_versions([], _, _), do: :ok

  defp do_setup_versions([{mod, client_data} | rest], server_map, client_name) do
    api_key = mod.api_key()

    with server_data = %{} <- Map.get(server_map, api_key, :not_found),
         common_version <- min(server_data.max, client_data.max),
         false <- common_version < server_data.min or common_version < client_data.min do
      :ok = set_api_version(client_name, mod, common_version)
      do_setup_versions(rest, server_map, client_name)
    else
      _err ->
        Enum.each(client_data.required_for, fn feature ->
          Logger.warning(
            "The feature #{feature} will be disabled because could not agree on API version for #{inspect(mod)} api_key #{api_key} for client #{client_name}."
          )

          Controller.disable_feature(feature, client_name)
        end)

        do_setup_versions(rest, server_map, client_name)
    end
  end

  # TODO: Add compatibility notes by feature to readme
  defp client_versions do
    [
      {M.ApiVersions, %{min: 0, max: 0, required_for: [:connection]}},
      {M.CreateTopics, %{min: 0, max: 2, required_for: []}},
      {M.Metadata, %{min: 1, max: 13, required_for: [:connection]}},
      {M.Produce, %{min: 3, max: 9, required_for: [:producer, :txn_producer]}},
      {M.InitProducerId, %{min: 0, max: 0, required_for: [:producer_idempotence]}},
      {M.Fetch, %{min: 13, max: 17, required_for: [:consumer_group, :testing]}},
      {M.ListOffsets, %{min: 2, max: 2, required_for: [:testing, :consumer_group]}},
      {M.AddPartitionsToTxn, %{min: 4, max: 4, required_for: [:txn_producer]}},
      {M.FindCoordinator, %{min: 1, max: 6, required_for: [:txn_producer]}},
      {M.EndTxn, %{min: 3, max: 3, required_for: [:txn_producer]}},
      {M.SaslHandshake, %{min: 1, max: 1, required_for: [:sasl]}},
      {M.SaslAuthenticate, %{min: 1, max: 1, required_for: [:sasl]}},
      {M.ConsumerGroupHeartbeat, %{min: 0, max: 1, required_for: [:consumer_group]}},
      {M.OffsetFetch, %{min: 9, max: 9, required_for: [:consumer_group]}},
      {M.OffsetCommit, %{min: 9, max: 9, required_for: [:consumer_group]}}
    ]
  end

  defp set_api_version(client_name, mod, version),
    do: :persistent_term.put({:api_version, mod, client_name}, version)
end

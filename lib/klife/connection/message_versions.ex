defmodule Klife.Connection.MessageVersions do
  @moduledoc false

  alias KlifeProtocol.Messages, as: M

  require Logger

  def get(client_name, mod), do: :persistent_term.get({:api_version, mod, client_name})

  def setup_versions(server_data, client_name) do
    do_setup_versions(client_versions(), server_data, client_name)
  end

  defp do_setup_versions([], _, _), do: :ok

  # TODO: Handle non required messages
  defp do_setup_versions([{mod, client_data} | rest], server_map, client_name) do
    api_key = mod.api_key()

    server_data = Map.get(server_map, api_key, :not_found)

    found_on_broker? = server_data != :not_found
    raise? = Map.get(client_data, :raise?, true)

    with true <- found_on_broker?,
         common_version <- min(server_data.max, client_data.max),
         false <- common_version < server_data.min or common_version < client_data.min do
      :ok = set_api_version(client_name, mod, common_version)
      do_setup_versions(rest, server_map, client_name)
    else
      _err ->
        if raise? do
          raise(
            "Could not agree on API version for #{inspect(mod)} api_key #{api_key} for client #{client_name}."
          )
        else
          warning_for_message(mod, api_key, client_name)
          do_setup_versions(rest, server_map, client_name)
        end
    end
  end

  defp warning_for_message(
         mod,
         api_key,
         client_name
       )
       when mod in [M.AddPartitionsToTxn] do
    Logger.warning(
      "Transactions will not work because could not agree on API version for #{inspect(mod)} api_key #{api_key} for client #{client_name}."
    )
  end

  defp warning_for_message(
         mod,
         api_key,
         client_name
       ) do
    Logger.warning(
      "Some features may not work because could not agree on API version for #{inspect(mod)} api_key #{api_key} for client #{client_name}."
    )
  end

  defp client_versions do
    [
      {M.ApiVersions, %{min: 0, max: 0}},
      {M.CreateTopics, %{min: 0, max: 0}},
      {M.Metadata, %{min: 1, max: 1}},
      {M.Produce, %{min: 3, max: 9}},
      {M.InitProducerId, %{min: 0, max: 0}},
      {M.Fetch, %{min: 4, max: 4}},
      {M.ListOffsets, %{min: 2, max: 2}},
      {M.AddPartitionsToTxn, %{min: 4, max: 4, raise?: false}},
      {M.FindCoordinator, %{min: 4, max: 4}},
      {M.EndTxn, %{min: 3, max: 3}},
      {M.SaslHandshake, %{min: 1, max: 1}},
      {M.SaslAuthenticate, %{min: 1, max: 1}}
    ]
  end

  defp set_api_version(client_name, mod, version),
    do: :persistent_term.put({:api_version, mod, client_name}, version)
end

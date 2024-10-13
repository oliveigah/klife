defmodule Klife.Connection.MessageVersions do
  @moduledoc false

  alias KlifeProtocol.Messages, as: M

  def get(client_name, mod), do: :persistent_term.get({:api_version, mod, client_name})

  def setup_versions(server_data, client_name),
    do: do_setup_versions(client_versions(), server_data, client_name)

  defp do_setup_versions([], _, _), do: :ok

  # TODO: Handle non required messages
  defp do_setup_versions([{mod, client_data} | rest], server_map, client_name) do
    api_key = apply(mod, :api_key, [])

    server_data = Map.get(server_map, api_key, :not_found)

    not_found_on_broker? = server_data == :not_found

    if not_found_on_broker?,
      do: raise("Could not find required message #{inspect(mod)} for client #{client_name}")

    common_version = min(server_data.max, client_data.max)

    invalid_common_version? =
      common_version < server_data.min or common_version < client_data.min

    cond do
      not invalid_common_version? ->
        :ok = set_api_version(client_name, mod, common_version)
        do_setup_versions(rest, server_map, client_name)

      invalid_common_version? ->
        raise "Could not agree on API version for #{inspect(mod)} api_key #{api_key} for client #{client_name}. "
    end
  end

  defp client_versions do
    [
      {M.ApiVersions, %{min: 0, max: 0}},
      {M.CreateTopics, %{min: 0, max: 0}},
      {M.Metadata, %{min: 1, max: 1}},
      {M.Produce, %{min: 9, max: 9}},
      {M.InitProducerId, %{min: 0, max: 0}},
      {M.Fetch, %{min: 4, max: 4}},
      {M.ListOffsets, %{min: 2, max: 2}},
      {M.AddPartitionsToTxn, %{min: 4, max: 4}},
      {M.FindCoordinator, %{min: 4, max: 4}},
      {M.EndTxn, %{min: 3, max: 3}},
      {M.SaslHandshake, %{min: 0, max: 1}},
      {M.SaslAuthenticate, %{min: 0, max: 2}}
    ]
  end

  defp set_api_version(client_name, mod, version),
    do: :persistent_term.put({:api_version, mod, client_name}, version)
end

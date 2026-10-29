defmodule Simulator.Cluster do
  @moduledoc false

  @brokers %{2 => "kafka1", 3 => "kafka2", 4 => "kafka3"}

  def services, do: Map.values(@brokers) |> Enum.sort()
  def service(broker_id), do: Map.fetch!(@brokers, broker_id)

  def project, do: System.get_env("SIM_PROJECT", "compose_files")

  def start(service) do
    docker!(["start", container_id(service)])
    :ok
  end

  def stop(service) do
    docker!(["stop", "--time", "10", container_id(service)])
    :ok
  end

  def running_services do
    docker!([
      "ps",
      "--filter",
      "label=com.docker.compose.project=#{project()}",
      "--format",
      "{{.Label \"com.docker.compose.service\"}}"
    ])
    |> String.split("\n", trim: true)
    |> MapSet.new()
  end

  def save_logs(path) do
    File.write!(path, "")

    for service <- ["controller1" | services()] do
      since = :persistent_term.get(:simulation_wall_start, System.system_time(:second))
      logs = docker!(["logs", "--timestamps", "--since", to_string(since), container_id(service)])
      File.write!(path, "\n=== #{service} ===\n" <> logs, [:append])
    end

    :ok
  end

  defp container_id(service) when service in ["controller1", "kafka1", "kafka2", "kafka3"] do
    case docker!([
           "ps",
           "--all",
           "--filter",
           "label=com.docker.compose.project=#{project()}",
           "--filter",
           "label=com.docker.compose.service=#{service}",
           "--format",
           "{{.ID}}"
         ])
         |> String.split("\n", trim: true) do
      [id] -> id
      ids -> raise "Expected one #{project()}/#{service} container, found: #{inspect(ids)}"
    end
  end

  defp docker!(args) do
    case System.cmd("docker", args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "docker #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end
end

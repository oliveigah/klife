defmodule Mix.Tasks.Simulate do
  use Mix.Task

  @shortdoc "Run independent Kafka + MultiRunner workers in Docker Compose"
  @moduledoc """
  Starts one isolated Compose project per parallel worker. Each worker uses the
  existing MultiRunner to run simulations sequentially and writes directly to
  `simulations_data/<project>/`.

      mix simulate --parallel 2 --simulator-cpus 2 --simulator-memory 2g

  Docker options (limits apply to each worker, and to each broker):

    --simulator-cpus 2       --simulator-memory 2g
    --broker-cpus 1          --broker-memory 1g       --broker-heap 512m
    --controller-cpus 0.5    --controller-memory 512m --controller-heap 256m
    --kafka-version 4.4.0    --image klife-simulator:local
    --random-resources      --resource-profile 1:1g --resource-profile 2:2g
    --no-build

  MultiRunner options: --run-seconds 900 --total-seconds 86400.
  Replay: --rerun simulations_data/<project>/<simulation> runs that saved config
  once per worker, restoring its recorded Docker settings and run duration.
  Explicit Docker flags or --run-seconds override the saved values.
  Resource profiles choose a simulator CPU/memory pair once per worker. Without
  explicit profiles, random choices are 1:1g, 2:2g and 4:4g.
  Existing simulator environment variables, such as FORCE_STABLE and
  SASL_MECHANISM, are passed through. The task waits for all workers, saves their
  Compose logs and removes their containers, networks and volumes.
  """

  @root Path.expand("../../..", __DIR__)
  @requirements ["compile"]
  @docker_options [
    simulator_cpus: {"SIM_CPUS", "2", [:simulator, :cpus]},
    simulator_memory: {"SIM_MEMORY", "2g", [:simulator, :memory]},
    broker_cpus: {"BROKER_CPUS", "1", [:broker, :cpus]},
    broker_memory: {"BROKER_MEMORY", "1g", [:broker, :memory]},
    broker_heap: {"BROKER_HEAP", "512m", [:broker, :heap]},
    controller_cpus: {"CONTROLLER_CPUS", "0.5", [:controller, :cpus]},
    controller_memory: {"CONTROLLER_MEMORY", "512m", [:controller, :memory]},
    controller_heap: {"CONTROLLER_HEAP", "256m", [:controller, :heap]},
    kafka_version: {"KAFKA_VERSION", "4.4.0", [:kafka_version]},
    image: {"SIM_IMAGE", "klife-simulator:local", [:image]}
  ]

  @impl true
  def run(args) do
    switches =
      Enum.map(@docker_options, fn {key, _} -> {key, :string} end) ++
        [
          parallel: :integer,
          run_seconds: :integer,
          total_seconds: :integer,
          random_resources: :boolean,
          resource_profile: :keep,
          rerun: :string,
          no_build: :boolean,
          help: :boolean
        ]

    {opts, rest} = OptionParser.parse!(args, strict: switches)
    if rest != [], do: Mix.raise("Unexpected arguments: #{Enum.join(rest, " ")}")

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      {replay_dir, replay_config} =
        if directory = opts[:rerun] do
          if opts[:random_resources],
            do: Mix.raise("Use explicit resource flags to override a replay's resources")

          directory = Path.expand(directory)

          {%Simulator.EngineConfig{} = config, _} =
            Code.eval_file(Path.join(directory, "config.exs"))

          {directory, config}
        else
          {nil, nil}
        end

      parallel = Keyword.get(opts, :parallel, 1)
      saved_duration = if replay_config, do: replay_config.run_seconds
      run_seconds = Keyword.get(opts, :run_seconds, saved_duration || 900)

      for {key, value} <- [
            parallel: parallel,
            run_seconds: run_seconds,
            total_seconds: opts[:total_seconds]
          ],
          value != nil and value <= 0,
          do: Mix.raise("--#{key |> to_string() |> String.replace("_", "-")} must be positive")

      profiles =
        opts
        |> Keyword.get_values(:resource_profile)
        |> then(fn
          [] -> ["1:1g", "2:2g", "4:4g"]
          values -> values
        end)
        |> Enum.map(fn profile ->
          case String.split(profile, ":") do
            [cpu, memory] when cpu != "" and memory != "" -> {cpu, memory}
            _ -> Mix.raise("Invalid resource profile: #{profile}; expected CPU:MEMORY")
          end
        end)

      env =
        Enum.map(@docker_options, fn {key, {name, default, resource_path}} ->
          saved = if replay_config, do: get_in(replay_config.resources || %{}, resource_path)
          {name, Keyword.get(opts, key, saved || default)}
        end)

      env =
        env ++
          [
            {"SIM_UID", command!("id", ["-u"])},
            {"SIM_GID", command!("id", ["-g"])},
            {"DOCKER_GID", to_string(File.stat!("/var/run/docker.sock").gid)},
            {"SIM_CONFIG", if(replay_dir, do: "/replay/config.exs", else: "")},
            {"SIM_REPLAY_DIR", replay_dir || Path.join(@root, "docker")},
            {"RUN_SECONDS", to_string(run_seconds)},
            {"TOTAL_SECONDS", to_string(Keyword.get(opts, :total_seconds, 86400))}
          ]

      unless opts[:no_build], do: compose!(nil, env, ["build", "simulator"])

      batch =
        "#{System.system_time(:microsecond)}-#{Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)}"

      results =
        1..parallel
        |> Task.async_stream(
          fn index ->
            worker_env =
              if opts[:random_resources] do
                {cpu, memory} = Enum.random(profiles)

                env
                |> List.keystore("SIM_CPUS", 0, {"SIM_CPUS", cpu})
                |> List.keystore("SIM_MEMORY", 0, {"SIM_MEMORY", memory})
              else
                env
              end

            run_worker("klife-sim-#{batch}-#{index}", worker_env)
          end,
          max_concurrency: parallel,
          timeout: :infinity,
          ordered: false
        )
        |> Enum.to_list()

      unless Enum.all?(results, &(&1 == {:ok, :ok})),
        do: Mix.raise("Simulation workers failed; see simulations_data/<project>/compose.log")
    end
  end

  defp run_worker(project, env) do
    output = Path.join([@root, "simulations_data", project])
    File.mkdir_p!(output)
    env = [{"SIM_OUTPUT_DIR", output} | env]
    Mix.shell().info("Starting #{project}; data: #{output}")

    try do
      compose!(project, env, ["up", "-d", "--wait", "scram-users"])
      compose!(project, env, ["up", "-d", "--no-deps", "simulator"])
      id = compose!(project, env, ["ps", "--all", "--quiet", "simulator"])
      status = command!("docker", ["wait", id])
      if status != "0", do: Mix.raise("simulator exited with status #{status}")
      :ok
    rescue
      error ->
        Mix.shell().error("#{project}: #{Exception.message(error)}")
        :error
    after
      {_stream, _status} =
        System.cmd("docker", compose_args(project) ++ ["logs", "--no-color"],
          env: env,
          stderr_to_stdout: true,
          into: File.stream!(Path.join(output, "compose.log"))
        )

      {logs, status} =
        System.cmd("docker", compose_args(project) ++ ["down", "--volumes", "--remove-orphans"],
          env: env,
          stderr_to_stdout: true
        )

      if status != 0, do: Mix.shell().error("#{project}: cleanup failed: #{logs}")
    end
  end

  defp compose!(project, env, args),
    do: command!("docker", compose_args(project) ++ args, env: env)

  defp compose_args(nil), do: ["compose", "-f", Path.join(@root, "compose.yml")]
  defp compose_args(project), do: compose_args(nil) ++ ["-p", project]

  defp command!(command, args, opts \\ []) do
    case System.cmd(command, args, [stderr_to_stdout: true] ++ opts) do
      {output, 0} ->
        String.trim(output)

      {output, status} ->
        Mix.raise("#{command} #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end

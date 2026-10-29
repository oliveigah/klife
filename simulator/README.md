# Simulator

Randomized Klife workloads with stable and chaos scenarios.

```sh
cd simulator
mix simulate --parallel 2 \
  --simulator-cpus 2 --simulator-memory 2g \
  --broker-cpus 1 --broker-memory 1g
```

Requires Docker Compose and the project's Elixir/OTP toolchain. The
[Mix task](lib/mix/tasks/simulate.ex) builds the image once and starts one
[Compose project](compose.yml) per parallel worker. Each has its own simulator
VM, Kafka controller, three brokers, certificates, network and data, with no
published host ports. Broker failures affect only their worker's cluster.

Each worker runs the existing [MultiRunner](lib/simulator/multi_runner.ex), which
generates and runs simulations sequentially. Defaults are 15 minutes per
simulation and 24 hours per worker. Use `--run-seconds` and `--total-seconds` to
change these; total time is checked between simulations, so the last simulation
finishes before the worker exits. The task waits for all workers, saves Compose
logs and removes their containers and volumes. A worker exits nonzero on an
unexpected engine failure or invariant violations detected by MultiRunner.

Data is mounted directly into `simulator/simulations_data/<project>/<simulation>/`.
The existing per-simulation config, runtime logs, events and invariant files stay
there after cleanup. Each `config.exs` records simulator, broker and controller
CPU/memory limits, Kafka heaps, Kafka version and simulator image in `resources`.
It also records the simulation duration in `run_seconds`.
Parallel count is task-only. Resource limits remain fixed for the worker's life.
Review the saved logs and invariant files as part of release validation.

To choose a random simulator CPU/memory pair for each worker:

```sh
mix simulate --parallel 2 --random-resources \
  --resource-profile 1:1g --resource-profile 2:2g
```

Default random profiles are `1:1g`, `2:2g`, `4:4g`. Keep resources fixed for
performance comparisons. See `mix simulate --help` for broker/controller heaps,
Kafka version, image and other options. Limits apply separately to each container;
the task starts the requested parallel count without a host resource scheduler.

Existing simulator environment variables pass through to workers:

```sh
FORCE_STABLE=true SASL_MECHANISM=OAUTHBEARER mix simulate --parallel 2
```

- `FORCE_STABLE`: defaults to false (chaos), with no random selection of this flag;
  true disables injected failures and enables duplicate checks.
- `SASL_MECHANISM`: `PLAIN`, `SCRAM-SHA-256`, `SCRAM-SHA-512` or `OAUTHBEARER`;
  unset selects a random subset of all clients, including plaintext, for each
  simulation within each worker.
- `OAUTH_TOKEN_LIFETIME_S`: pins the token lifetime; otherwise each simulation
  chooses 75, 90 or 120 seconds. Use at least 72 seconds.

Replay a specific simulation from a specific worker:

```sh
mix simulate --rerun simulations_data/<project>/<simulation>
```

This mounts the saved run read-only and runs its config and random seeds once in
a fresh worker, using the recorded resource limits, heaps, Kafka version, image
and duration. Older configs without a saved duration default to 900 seconds.
New output goes into a new project directory, preserving the original run.
Explicit Docker flags or `--run-seconds` override saved values; `--parallel N`
replays the same simulation once in each of N independent workers. Topics get
fresh names through the existing replay code. Scheduling and failure timing can
still vary between replays.

The simulator uses the host Docker socket to stop/start brokers, selecting them
by Compose project and service labels. To inspect an active worker, use
`docker compose -f compose.yml -p <project> ps` or `logs -f simulator`.
If the host task is forcibly interrupted, clean up its projects with
`docker compose -f compose.yml -p <project> down --volumes --remove-orphans`.

For interactive runs against the existing host Kafka cluster, use `iex -S mix`.
Set `MULTI_RUN=true` for sequential simulations, `SIM_PROJECT` for the cluster's
Compose project (default `compose_files`), and `RERUN_TS` to replay a saved
simulation directory relative to `simulations_data/`.

Run configuration tests with `mix test --no-start` inside `simulator/`.

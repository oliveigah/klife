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

## Invariants

The engine checks these while a simulation runs, the periodic ones every 5
seconds, and saves violations to `invariants_violations.exs` in the simulation's
directory. Any violation makes MultiRunner fail the run. A record is tracked
once every consumer group has started consuming its partition.

| Violation | Raised when | Mode |
|---|---|---|
| `skipped_record` | An acknowledged record is still unconsumed after its group consumed a record produced after that acknowledgement | Both |
| `too_much_lag` | An acknowledged record is still unconsumed 30 s (stable) or 120 s (chaos) after its acknowledgement | Both |
| `stale_producer` | A partition that has produced gets no new acknowledged record for 20 consecutive checks | Both |
| `no_produce` | A group has consumed nothing from a partition more than 90 s after the topic's partition count last changed | Both |
| `consumed_unexpected_record` | A consumed record's topic, partition, value, key or headers differ from what was produced under its key | Both |
| `consumed_out_of_order` | A group consumes an offset lower than one it already consumed on that partition | Both |
| `consumed_offset_mismatch` | A record is consumed at an offset other than the one its producer was told. In chaos only a later offset counts, since a resend may leave an earlier copy. | Both |
| `produced_out_of_order` | A producer process gets an offset on a partition that is not after the last one it got there. Its produce calls never overlap. | Both |
| `produced_duplicate` | A key is consumed at two different offsets of a partition. Keys are unique per record and failed records are never produced again, so the record was written twice. | Both |
| `producer_leader_diverged` | A client's default producer keeps a partition on a batcher of another broker than the partition leader for a minute. A handoff that never completes leaves it behind. | Both |
| `consumed_duplicate` | A group consumes the same offset twice | Stable only, logged in chaos |
| `produce_error` | A produce call returns an error for a record | Stable only, logged in chaos |
| `slow_produce` | A produce call takes more than 10 s. A handoff abort or a request timeout takes that long, a leader change about a second. | Stable only |
| `epoch_bumped` | A partition's producer epoch changes on a client's default producer. A handoff that falls back to a new epoch may fail no record, but would make transactions fail. | Stable only |

Not checked: a record reported as failed that is written anyway. A consumed
record with no tracked entry is accepted.

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
  true disables injected failures and makes duplicates and producer errors
  invariant violations. Partition leaders still move (`move_leader`, a
  reassignment plus a preferred leader election with every broker alive), so
  the producer's leader handoff is checked under these stricter rules.
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

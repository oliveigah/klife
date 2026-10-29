Code.require_file("support.exs", __DIR__)

for path <- Path.wildcard(Path.join(__DIR__, "scenarios/*/scenario.exs")),
    do: Code.require_file(path)

Code.require_file("workload.exs", __DIR__)
Code.require_file("runner.exs", __DIR__)

[job] = System.argv()
Klife.ReleaseBenchmark.Runner.run(Klife.ReleaseBenchmark.Config.read(job))

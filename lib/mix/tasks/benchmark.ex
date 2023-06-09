if Mix.env() in [:dev] do
  defmodule Mix.Tasks.Benchmark do
    use Mix.Task

    def run(args) do
      Application.ensure_all_started(:klife)
      Process.sleep(1_000)
      apply(Mix.Tasks.Benchmark, :do_run_bench, args)
    end

    def do_run_bench("test") do
      Benchee.run(
        %{
          "test" => fn -> Klife.test() end
        },
        time: 10,
        memory_time: 2,
        parallel: 12
      )
    end
  end
end

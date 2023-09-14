if Mix.env() in [:dev] do
  defmodule Mix.Tasks.Benchmark do
    use Mix.Task

    def run(args) do
      Application.ensure_all_started(:klife)
      Process.sleep(1_000)
      apply(Mix.Tasks.Benchmark, :do_run_bench, args)
    end

    # def do_run_bench("test") do
    #   rec = %{
    #     value: "1",
    #     key: "key_1",
    #     headers: [%{key: "header_key", value: "header_value"}]
    #   }

    #   :persistent_term.put({:some, :key}, Application.fetch_env!(:klife, :clusters))

    #   Benchee.run(
    #     %{
    #       "app_env" => fn -> Application.fetch_env!(:klife, :clusters) end,
    #       "persistent_term" => fn -> :persistent_term.get({:some, :key}) end
    #     },
    #     time: 10,
    #     memory_time: 2
    #   )
    # end

    # def do_run_bench("test_batcher") do
    #   rec = %{
    #     value: "1",
    #     key: "key_1",
    #     headers: [%{key: "header_key", value: "header_value"}]
    #   }

    #   state = %Klife.Producer.Dispatcher{
    #     acks: :all,
    #     batch_size_bytes: 16000,
    #     client_id: "my_custom_client_id",
    #     cluster_name: :my_test_cluster_1,
    #     compression_type: :none,
    #     delivery_timeout_ms: 60000,
    #     enable_idempotence: true,
    #     linger_ms: 1000,
    #     max_inflight_requests: 2,
    #     max_retries: :infinity,
    #     producer_name: :my_batch_producer,
    #     request_timeout_ms: 15000,
    #     retry_backoff_ms: 1000,
    #     broker_id: 1002,
    #     data: %{}
    #   }

    #   Benchee.run(
    #     %{
    #       "%{map | data}" => fn ->
    #         Enum.reduce(1..1000, state, fn _i, new_state ->
    #           {:reply, :ok, new_state} =
    #             Klife.Producer.Dispatcher.handle_call({:produce, rec, "a", 0}, self(), new_state)

    #           new_state
    #         end)
    #       end
    #     },
    #     time: 10,
    #     memory_time: 2
    #   )
    # end
  end
end

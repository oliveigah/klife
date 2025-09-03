defmodule Klife.Consumer.ConsumerGroupTest do
  use ExUnit.Case, async: false

  alias Klife.Record

  alias Klife.TestUtils

  defp assert_assignment(exp_assigments, mod) do
    Enum.each(exp_assigments, fn {t, p} ->
      to_produce =
        Enum.map(1..3, fn _i ->
          %Record{topic: t, partition: p, value: :rand.bytes(10)}
        end)

      [{:ok, exp_rec1}, {:ok, exp_rec2}, {:ok, exp_rec3}] = MyClient.produce_batch(to_produce)

      assert_receive {^mod, :processed, ^t, ^p, recv_rec1}, 10_000
      assert_receive {^mod, :processed, ^t, ^p, recv_rec2}, 10_000
      assert_receive {^mod, :processed, ^t, ^p, recv_rec3}, 10_000

      TestUtils.assert_records(recv_rec1, exp_rec1)
      TestUtils.assert_records(recv_rec2, exp_rec2)
      TestUtils.assert_records(recv_rec3, exp_rec3)
    end)
  end

  @tag capture_log: true
  test "basic test", ctx do
    TestUtils.put_test_pid(ctx, self())

    defmodule TestCG1 do
      use Klife.Consumer.ConsumerGroup, client: MyClient

      @pid_key ctx
      @impl true
      def handle_record_batch(topic, partition, records) do
        parent = TestUtils.get_test_pid(@pid_key)

        Enum.each(records, fn %Record{} = r ->
          send(parent, {__MODULE__, :processed, topic, partition, r})
        end)

        :commit
      end

      @impl true
      def handle_consumer_start(topic, partition) do
        parent = TestUtils.get_test_pid(@pid_key)
        send(parent, {__MODULE__, :started_consumer, topic, partition})
        :ok
      end

      @impl true
      def handle_consumer_stop(topic, partition, reason) do
        parent = TestUtils.get_test_pid(@pid_key)
        send(parent, {__MODULE__, :stopped_consumer, topic, partition, reason})
        :ok
      end
    end

    defmodule TestCG2 do
      use Klife.Consumer.ConsumerGroup, client: MyClient

      @pid_key ctx
      @impl true
      def handle_record_batch(topic, partition, records) do
        parent = TestUtils.get_test_pid(@pid_key)

        Enum.each(records, fn r ->
          send(parent, {__MODULE__, :processed, topic, partition, r})
        end)

        :commit
      end

      @impl true
      def handle_consumer_start(topic, partition) do
        parent = TestUtils.get_test_pid(@pid_key)
        send(parent, {__MODULE__, :started_consumer, topic, partition})
        :ok
      end

      @impl true
      def handle_consumer_stop(topic, partition, reason) do
        parent = TestUtils.get_test_pid(@pid_key)
        send(parent, {__MODULE__, :stopped_consumer, topic, partition, reason})
        :ok
      end
    end

    defmodule TestCG3 do
      use Klife.Consumer.ConsumerGroup, client: MyClient

      @pid_key ctx
      @impl true
      def handle_record_batch(topic, partition, records) do
        parent = TestUtils.get_test_pid(@pid_key)

        Enum.each(records, fn r ->
          send(parent, {__MODULE__, :processed, topic, partition, r})
        end)

        :commit
      end

      @impl true
      def handle_consumer_start(topic, partition) do
        parent = TestUtils.get_test_pid(@pid_key)
        send(parent, {__MODULE__, :started_consumer, topic, partition})
        :ok
      end

      @impl true
      def handle_consumer_stop(topic, partition, reason) do
        parent = TestUtils.get_test_pid(@pid_key)
        send(parent, {__MODULE__, :stopped_consumer, topic, partition, reason})
        :ok
      end
    end

    consumer_opts = [
      topics: [
        [name: "test_consumer_topic_1"],
        [name: "test_consumer_topic_2"]
      ],
      group_name: Base.encode64(:rand.bytes(10))
    ]

    cg1_pid = start_supervised!({TestCG1, consumer_opts}, id: :cg1, restart: :temporary)

    cg1_assignments = [
      {"test_consumer_topic_1", 0},
      {"test_consumer_topic_1", 1},
      {"test_consumer_topic_1", 2},
      {"test_consumer_topic_1", 3},
      {"test_consumer_topic_2", 0},
      {"test_consumer_topic_2", 1}
    ]

    Enum.each(cg1_assignments, fn {t, p} ->
      assert_receive {TestCG1, :started_consumer, ^t, ^p}, 10_000
    end)

    assert_assignment(cg1_assignments, TestCG1)

    cg2_pid = start_supervised!({TestCG2, consumer_opts}, id: :cg2, restart: :temporary)

    assert_receive {TestCG1, :stopped_consumer, stopped_topic0, p0,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG1, :stopped_consumer, stopped_topic1, p1,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG1, :stopped_consumer, stopped_topic2, p2,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    cg2_assignments = [
      {stopped_topic0, p0},
      {stopped_topic1, p1},
      {stopped_topic2, p2}
    ]

    cg1_assignments = cg1_assignments -- cg2_assignments

    Enum.each(cg2_assignments, fn {t, p} ->
      assert_receive {TestCG2, :started_consumer, ^t, ^p}, 10_000
    end)

    assert_assignment(cg1_assignments, TestCG1)
    assert_assignment(cg2_assignments, TestCG2)

    start_supervised!({TestCG3, consumer_opts}, id: :cg3, restart: :temporary)

    assert_receive {TestCG1, :stopped_consumer, stopped_topic0, p0,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG2, :stopped_consumer, stopped_topic1, p1,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    cg3_assignments = [
      {stopped_topic0, p0},
      {stopped_topic1, p1}
    ]

    cg1_assignments = cg1_assignments -- cg3_assignments
    cg2_assignments = cg2_assignments -- cg3_assignments

    Enum.each(cg3_assignments, fn {t, p} ->
      assert_receive {TestCG3, :started_consumer, ^t, ^p}, 10_000
    end)

    assert_assignment(cg1_assignments, TestCG1)
    assert_assignment(cg2_assignments, TestCG2)
    assert_assignment(cg3_assignments, TestCG3)

    Process.exit(cg1_pid, :test)

    assert_receive {TestCG1, :stopped_consumer, stopped_topic0, p0,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG1, :stopped_consumer, stopped_topic1, p1,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG2, :started_consumer, cg2_t, cg2_p}, 10_000
    assert_receive {TestCG3, :started_consumer, cg3_t, cg3_p}, 10_000

    stopped_list = [{stopped_topic0, p0}, {stopped_topic1, p1}]

    assert {cg2_t, cg2_p} in stopped_list
    assert {cg3_t, cg3_p} in stopped_list

    cg2_assignments = cg2_assignments ++ [{cg2_t, cg2_p}]
    cg3_assignments = cg3_assignments ++ [{cg3_t, cg3_p}]

    assert length(cg2_assignments) == 3
    assert_assignment(cg2_assignments, TestCG2)

    assert length(cg3_assignments) == 3
    assert_assignment(cg3_assignments, TestCG3)

    Process.exit(cg2_pid, :test)

    assert_receive {TestCG2, :stopped_consumer, stopped_topic0, p0,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG2, :stopped_consumer, stopped_topic1, p1,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG2, :stopped_consumer, stopped_topic2, p2,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG3, :started_consumer, ^stopped_topic0, ^p0}, 10_000
    assert_receive {TestCG3, :started_consumer, ^stopped_topic1, ^p1}, 10_000
    assert_receive {TestCG3, :started_consumer, ^stopped_topic2, ^p2}, 10_000

    cg3_assignments = cg3_assignments ++ cg2_assignments
    assert length(cg3_assignments) == 6
    assert_assignment(cg3_assignments, TestCG3)
  end
end
